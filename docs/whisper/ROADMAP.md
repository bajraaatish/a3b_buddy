# Whisper — Build Roadmap

*Personal macOS speech-to-text app. Native Swift/SwiftUI, local transcription, system-wide dictation.*

---

## Decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Engine | **WhisperKit** (Argmax, MIT) | Swift-native CoreML package. Async/await API, auto ANE/GPU scheduling, handles model download + audio resampling. No C bridging. Powers Superwhisper. |
| Default model | **large-v3 turbo** — named `large-v3-v20240930` in WhisperKit (use the `626MB` quantized variant) | Near large-v3 accuracy at ~medium speed. A 10–30 s utterance transcribes in <1 s on M-series. Fallback: `small` if RAM-constrained. |
| UI | **SwiftUI + MenuBarExtra**, macOS 14+ | Native, ~50–100 MB RAM vs Wispr's 800 MB Electron. |
| Hotkey | **KeyboardShortcuts** (sindresorhus) + CGEventTap for fn key | KeyboardShortcuts = permission-free custom combos. CGEventTap only if you want bare-fn hold like Wispr. |
| Insertion | Clipboard save → write → simulated ⌘V → restore | What Wispr and every clone actually does. AX API fallback later. |
| Storage | **SwiftData** | Simple @Model/@Query, perfect at transcript-log scale. Switch to GRDB only if full-text search needed later. |
| Distribution | Direct (not App Store) | CGEvent posting requires unsandboxed app. Personal use — irrelevant constraint. |

**Permissions the app will request:** Microphone, Accessibility (paste simulation), Input Monitoring (only if fn-key mode added).

**Reference repos to study:** [VocaMac](https://github.com/jatinkrmalik/vocamac) (small, readable, exact same pipeline), [Parakey](https://github.com/rcourtman/parakey) (fn PTT, 100 ms latency), [VoiceInk](https://github.com/beingpax/VoiceInk) (feature-complete, but GPL — study, don't copy).

---

## Architecture

```
┌ Menu bar (MenuBarExtra) ── settings, history window, quit
│
│  Hold hotkey ▶ HotkeyManager
│                   │
│                   ▼
│              AudioRecorder (AVAudioEngine → 16 kHz mono Float32)
│                   │            │
│                   │            ▼
│                   │       Floating pill (non-activating NSPanel,
│                   │       waveform, appears only while recording)
│                   ▼
│  Release ▶ TranscriptionService (WhisperKit)
│                   │
│                   ▼
│              TextInserter (clipboard swap + ⌘V CGEvent)
│                   │
│                   ▼
│              HistoryStore (SwiftData: text, timestamp,
│              duration, word count, WPM, target app)
│                   │
│                   ▼
│              Stats window (history log, WPM gauge,
│              totals, streak heatmap)
```

Modules — one folder each, one responsibility each:
`App/` · `Hotkey/` · `Audio/` · `Transcription/` · `Insertion/` · `Overlay/` · `History/` · `Stats/` · `Settings/`

### Data model (SwiftData)

```swift
@Model class Dictation {
    var text: String          // final transcript
    var createdAt: Date
    var duration: TimeInterval // recording length, seconds
    var wordCount: Int         // text.split(whitespace).count
    var wpm: Double            // wordCount / (duration / 60)
    var targetApp: String      // frontmost app bundle name
}
```

Everything on the stats screen derives from this one table: total words = sum, average WPM = weighted mean, streaks = distinct active days, per-app chart = group by targetApp.

---

## Phases

Each phase ends with something that runs. Never move on with a broken build.

### Phase 0 — Project setup (half a day)
- Xcode project: SwiftUI app, macOS 14+, `LSUIElement = YES` (no dock icon), `NSMicrophoneUsageDescription` in Info.plist, App Sandbox OFF.
- **Enable automatic code signing with your Apple ID team.** Unsigned builds get a new identity every rebuild and macOS silently drops the Accessibility grant — hours of "why did paste stop working." Stable signing prevents it.
- Add SPM packages: WhisperKit — package URL `https://github.com/argmaxinc/argmax-oss-swift` (renamed from argmaxinc/WhisperKit at v1.0.0, May 2026; old URL redirects), select the **WhisperKit** library product, needs Xcode 16+ — and KeyboardShortcuts.
- Git init, `.gitignore`, first commit.
- `MenuBarExtra` with a mic icon and a Quit button.
- **Done when:** app runs, icon in menu bar, quits cleanly.

### Phase 1 — Core pipeline, ugly version (1–2 days)
The riskiest 20% — prove the whole loop before any polish.
- Mic permission + `AVAudioEngine` capture → 16 kHz mono buffer.
- WhisperKit: download the turbo model (`openai_whisper-large-v3-v20240930_626MB`) on first run — ~600 MB, so wire up WhisperKit's download-progress callback from day one. Transcribe a recorded buffer.
- KeyboardShortcuts global hotkey: hold = record, release = transcribe.
- Print transcript to console. No UI yet.
- **Done when:** hold key → speak → release → correct text in console in ~1 s.

### Phase 2 — Text insertion (1 day)
- Accessibility permission flow (`AXIsProcessTrustedWithOptions` prompt + Settings deep-link).
- TextInserter: save clipboard → write transcript → post ⌘V CGEvent → restore clipboard after delay.
- Edge cases: paste fails → leave text on clipboard + notify; empty transcript → do nothing; secure input fields (password boxes, Secure Keyboard Entry terminals) block synthetic ⌘V → detect and fall back to clipboard + notification.
- Debug tip: if paste stops working after a rebuild, remove + re-add the app in System Settings → Privacy & Security → Accessibility.
- **Done when:** dictation lands in Notes, browser, Slack, terminal — any app.

### Phase 3 — Recording pill overlay (1–2 days)
Your design skills earn their keep here.
- Non-activating `NSPanel` (`.nonactivatingPanel`, `.floating`, `canJoinAllSpaces`, `fullScreenAuxiliary`) hosting SwiftUI — focus must never leave the target text field.
- Dark pill centered above the Dock. Live waveform from audio levels. States: recording → transcribing (subtle spinner) → gone.
- **Wispr's lesson: appears only while recording.** No idle presence.
- Small sound cue on start/stop (optional toggle).
- **Done when:** pill mirrors your voice, never steals focus, vanishes instantly.

### Phase 4 — History + stats (2–3 days)
- SwiftData `Dictation` model; save every dictation (word count, duration, WPM, frontmost app captured at record-start).
- Main window (opened from menu bar), sidebar: **History** and **Insights**. Because `LSUIElement` hides the dock icon, call `NSApp.activate(ignoringOtherApps: true)` when opening — otherwise the window appears behind other apps.
- History: timestamped transcript list, per-row Copy / Delete, search field.
- Insights: WPM gauge (average, last 30 days), total words + this-month badge, streak heatmap (GitHub-style calendar), per-app bar chart.
- Menu bar: "Paste last transcript."
- **Done when:** every dictation logged; stats update live; numbers verified against a stopwatch test.

### Phase 5 — Settings + resilience (1–2 days)
- Settings: hotkey recorder, model picker (`large-v3-v20240930` turbo / `small` — re-download handled by WhisperKit), mic input picker, launch-at-login (`SMAppService`), sound toggle, history retention (keep forever / 30 days / off).
- Hands-free mode: double-tap hotkey to lock recording, tap to stop.
- Esc cancels recording (still logged, like Wispr).
- Max duration guard (5 min warn behavior optional; hard stop prevents runaway memory).
- Error states: mic missing, model not downloaded, no Accessibility permission — each with a clear prompt.
- **Done when:** you can hand the app to a stranger and they can configure it without you.

### Phase 6 — Polish + daily driving (ongoing)
- App icon, onboarding sheet (3 steps: mic → accessibility → try it).
- Use it daily for a week; fix what annoys you. This is the real QA.
- Optional later, in rough priority order: custom dictionary (find/replace pairs post-transcription), Apple `SpeechTranscriber` backend on macOS 26+ (faster), local LLM light-cleanup via Ollama (filler-word removal only — remember the "soul is gone" complaint), Parakeet/FluidAudio engine for max speed, share-card image export of stats.

**Total estimate: 6–10 working days for an engineer; realistically 2–3 calendar weeks driving it with Claude Code.** Phases 1–2 are the technical risk; Phase 3's NSPanel focus behavior and permission debugging are where time slips.

---

## Rules of the build

1. One phase at a time. Each phase compiles and runs before the next starts.
2. Commit at every "Done when" checkpoint.
3. No feature enters v1 that isn't in the Phase list. Ideas go to a `LATER.md`.
4. Test insertion in at least: Notes, Safari, Slack/Discord, VS Code, Terminal — the AX behavior differs per app.
5. WPM must be honest: words ÷ recording duration, computed at save time, never recomputed from edited text.
