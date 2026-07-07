# Wispr Flow Teardown — Research Report

*Basis for building "Whisper," a personal macOS speech-to-text app. Researched July 2026.*

---

## 1. What Wispr Flow is

Cloud-based AI dictation app for Mac/Windows/iOS/Android. Hold a key anywhere, speak, release — clean formatted text appears at your cursor in whatever app you're in. Founded by Tanay Kothari and Sahaj Garg, $81M raised. Mac launch Oct 2024.

The core pitch: "4× faster than typing" (they claim 220 WPM vs ~45 WPM typing; real users report 115–184 WPM).

---

## 2. Design & UI

Wispr Flow has exactly three UI surfaces. This restraint is the design lesson — the app disappears until you need it.

### a) Menu bar icon
Dropdown with: Home, Paste last transcript, Shortcuts, Microphone picker (device submenu with auto-detect), Languages, Help, Quit. No dock icon by default.

### b) The "Flow Bar" — floating pill
A tiny dark rounded lozenge centered at the bottom of the screen, just above the Dock.

- **Idle:** condensed pill with a dotted waveform.
- **Hover:** expands, shows hint text in light pink: "Click or hold ⌘→ to start dictating."
- **Recording:** expands, live white waveform bars react to your voice. Waveform flattens on silence; persistent silence triggers a "Microphone is not working" notification.
- Right-click menu: "Hide for 1 hour," mic picker.
- Repositions itself relative to the Dock. Can host an optional Scratchpad button and language-switcher circle.
- **Key lesson: it's now hidden by default.** Users found it intrusive; there are whole YouTube tutorials on disabling it. An overlay indicator must be unobtrusive and easy to dismiss.

### c) Main window (Electron)
Light, clean, consumer-grade. Left sidebar: **Home, Dictionary, Snippets, Styles, Scratchpad, Insights.**

- **Home:** greeting ("Welcome back, Scott"), headline stats strip ("30 days · 50.3K words · 158 WPM"), personalization banner, then a **timestamped log of every dictation** (Recent activity) — each row has Copy / Retry / Report / Delete.
- **Settings:** sidebar groups — General, System, Vibe coding, Experimental; Account, Team, Plans & Billing, Data and Privacy.

Style summary: dark pill overlay with pink accent text; light polished main app. Reviewers consistently call it "feels like a consumer product."

---

## 3. UX & Interaction model

This is the part worth cloning most carefully.

**Push-to-talk (default).** Hold **fn** (auto-assigns Ctrl+Opt on keyboards without fn), speak, release → text pastes at cursor. Audible ping + waveform confirm recording. Hotkey remappable (up to 4 shortcuts, mouse buttons supported).

**Hands-free mode.** fn+Space or double-tap the PTT key → locked listening session; press fn again to stop and paste. Esc cancels (transcript still saved to history). Sessions warn at 5 min, hard-stop at 6 min.

**No live transcription display.** Text appears only after release — the opposite of Apple dictation. Lets you pause and think mid-dictation without half-formed text on screen.

**Text insertion.** Temporarily hijacks the clipboard: writes transcript → simulates paste → restores your previous clipboard. Remembers which text field had focus when dictation started. If paste fails, text stays on clipboard with a notification. Requires macOS Accessibility permission.

**AI cleanup ("Polish").** After transcription, an LLM pass: removes filler words, fixes grammar/punctuation, smart formatting ("first, second…" → numbered list, "new line" → break), and **spoken self-correction** ("email Peter — sorry, Benjamin" → "email Benjamin"; "strike that" works). Intensity configurable (Light Cleanup ↔ full rewrite). Criticism: heavy polish strips the user's voice ("the soul is gone").

**Tone matching ("Styles").** Detects the frontmost app's category — Personal messages / Work messages / Email / Other — and applies a tone (Formal, Casual, etc.). WhatsApp → casual, Gmail → formal.

**Custom dictionary.** Manual entries + misspelling pairs + **auto-learn**: Flow picks up your unique words and casing from usage ("macOS," "HTTPS").

**Snippets.** Exact voice phrase → expanded text block (calendar link, address).

**Command Mode (paid).** Hold fn+Ctrl, speak a command: transform selected text ("make this more concise," "translate to Polish") or generate inline.

**Latency.** Engineering target <700 ms end-to-end at p99 (ASR <200 ms, LLM <200 ms, ~200 ms network budget). Runs fine-tuned Llama on Baseten/TensorRT-LLM in AWS.

---

## 4. Tracking & stats (your key feature request)

Two places: Home tab (quick stats + history) and a dedicated **Insights** page.

### History (Home tab)
Every dictation logged with timestamp and full transcript. Per-row actions: Copy, Retry, Report, Delete. "Paste last transcript" also lives in the menu bar. Even interrupted/cancelled dictations land in history.

### Insights → "Your Usage" tab — five tiles
1. **WPM** — animated semicircular gauge, plus a percentile vs global typists ("Top 4%," range Top 0.1%–99%).
2. **Corrections by Flow** — count of filler words/errors the AI fixed.
3. **Total words dictated** — with month-over-month comparison badge.
4. **App usage breakdown** — horizontal bar chart by category (Personal Messages, Work Messages, Emails, AI Prompts, Documents, Other); hover shows Light/Moderate/Power usage.
5. **Streak heatmap** — GitHub-style calendar of daily activity; current-streak days glow; hover shows words + top app that day; arrows page back 4 weeks.

Also: a "Your Voice" profile tab (superlatives, peak dictation time) and shareable branded stat cards (total words, streak, WPM, heatmap) exportable as images.

**WPM math:** words in transcript ÷ recording duration. Aggregate WPM = average across dictations. "Time saved" framing = words dictated ÷ 45 WPM typing baseline minus actual time — Wispr only uses this on their pricing page, not in-app.

---

## 5. Architecture (theirs vs ours)

**Wispr Flow is 100% cloud.** Official FAQ: "Transcription always happens in the cloud." Pipeline: audio → cloud ASR → fine-tuned Llama cleanup (context + style + dictionary applied) → text back → clipboard paste. Client is Electron (~800 MB idle RAM, 8–10 s cold start). Free tier: 2,000 words/week on desktop (5,000 hard cap; iOS 1,000/week); Pro $15/mo ($12/mo annual).

**Our build inverts this:** local WhisperKit transcription on Apple Silicon, native SwiftUI (~50–100 MB RAM), zero cost, works offline, nothing leaves the machine. On short push-to-talk utterances, local large-v3-turbo transcribes in well under a second on M-series — competitive with their 700 ms cloud round-trip.

---

## 6. User criticisms — what to avoid

- **Cloud dependency:** unusable offline, laggy on bad WiFi, privacy unease (2025 backlash over screen-context/training data forced an apology and opt-in defaults). Our local approach kills this entire category.
- **Electron weight:** ~800 MB RAM idle, slow start, fan spin. Native Swift avoids it.
- **Subscription fatigue:** $15/mo vs one-time local rivals. Ours is free.
- **Over-polishing:** AI rewrite can erase your voice. If we add cleanup later, default to light-touch.
- **Intrusive overlay:** Flow Bar hidden by default now. Our pill should be minimal and only appear while recording.
- **Quirks:** 6-min cap, "new line" needs unnatural pause, exact-match snippets. Trustpilot 2.7/5 — polish beats feature count.

---

## 7. Feature parity target for "Whisper" v1

Copy: push-to-talk hotkey, hands-free toggle, floating recording pill (recording-only), clipboard-paste insertion with restore, full dictation history with copy/delete, WPM + total words + per-dictation stats, streak heatmap, menu-bar-only presence.

Skip (v1): AI polish/LLM cleanup, tone matching, snippets, Command Mode, dictionary auto-learn, multi-language UI, share cards. All addable later.

---

## Sources

- Podfeet review (best UI/UX description w/ screenshots): https://www.podfeet.com/blog/2026/03/wispr-flow-scott-willsey/
- Official docs — first dictation, Flow Bar, hands-free: https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation
- Insights/Usage tab doc: https://docs.wisprflow.ai/articles/8760230576-your-usage-tab-track-your-dictation-stats-in-wispr-flow
- Flow Styles: https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles
- Command Mode: https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode
- Baseten case study (latency/pipeline): https://www.baseten.co/resources/customers/wispr-flow/
- Privacy/cloud confirmation: https://wisprflow.ai/privacy · Pricing: https://wisprflow.ai/pricing
- Reviews/criticism: https://efficient.app/apps/wispr-flow · https://zackproser.com/blog/wisprflow-review · https://www.getvoibe.com/resources/wispr-flow-review/
- TechCrunch funding: https://techcrunch.com/2025/06/24/wispr-flow-raises-30m-from-menlo-ventures-for-its-ai-powered-dictation-app/
