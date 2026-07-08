# Whisper — Workstream Split for Claude Code

*How a professional team would divide this build: three workstreams + integration. Each maps to a separate Claude Code session with its own scope, owned folders, and a contract it must not break.*

---

## The team model

| Workstream | Real-world role | Owns (folders) | Risk |
|---|---|---|---|
| **A — Core Engine** | Platform/systems engineer | `Hotkey/` `Audio/` `Transcription/` `Insertion/` `Shared/` | High |
| **B — Frontend** | Product engineer + designer (you drive design) | `Overlay/` `History/` (views) `Stats/` (views) `Settings/` `Assets` | Low |
| **C — Data & Stats** | Backend/data engineer | `History/Dictation.swift` `Stats/StatsCalculator.swift` | Low |
| **Integration** | Tech lead (you + one Claude Code session) | `WhisperApp.swift`, wiring, QA matrix | Medium |

Why this split works: A touches system APIs and permissions (the hard part). B is pure SwiftUI against mock data. C is pure logic, fully unit-testable. None of them block each other — because of the contracts below.

---

## The contracts (agree first, like a real team)

Professional teams parallelize by agreeing on interfaces before writing code. These protocols live in `Shared/Contracts.swift`, written at kickoff, frozen afterward. Any change = a "team meeting" (you approving an edit).

```swift
import Foundation
import Combine

// ── State machine every UI element observes ──────────────
enum DictationState: Equatable {
    case idle
    case recording(startedAt: Date)
    case transcribing
    case failed(DictationError)
}

enum DictationError: Error, Equatable {
    case micDenied, accessibilityDenied
    case modelNotReady, transcriptionFailed, insertionFailed
}

// ── Workstream A implements these ────────────────────────
protocol DictationEngine: ObservableObject {
    var state: DictationState { get }          // @Published
    var audioLevel: Float { get }              // @Published, 0–1, drives waveform
    func startRecording()
    func stopAndTranscribe() async -> DictationResult?
    func cancel()
}

struct DictationResult {
    let text: String
    let duration: TimeInterval
    let targetAppBundleID: String
    let targetAppName: String
}

// ── Workstream C implements these ────────────────────────
protocol DictationStore {
    func save(_ result: DictationResult) throws
    func all() throws -> [DictationRecord]      // newest first
    func delete(id: UUID) throws
    func search(_ query: String) throws -> [DictationRecord]
}

struct DictationRecord: Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date
    let duration: TimeInterval
    let wordCount: Int
    let wpm: Double
    let targetAppName: String
}

protocol StatsProviding {
    func summary(days: Int) -> StatsSummary
    func dailyActivity(weeksBack: Int) -> [DayActivity]   // heatmap
    func appBreakdown(days: Int) -> [AppUsage]            // bar chart
}

struct StatsSummary { let totalWords: Int; let avgWPM: Double; let activeDays: Int; let currentStreak: Int; let wordsThisMonth: Int; let wordsLastMonth: Int }
struct DayActivity { let date: Date; let words: Int; let topApp: String? }
struct AppUsage { let appName: String; let words: Int }
```

Workstream B consumes all of the above and implements nothing from it. B ships with `MockDictationEngine` and `MockDictationStore` (fake waveform, canned transcripts, 90 days of generated stats) so every screen is buildable and previewable on day one, before A or C exist.

---

## Workstream A — Core Engine (the hard 20%)

**Mission:** hold key → speak → release → correct text pasted into the frontmost app in ~1 s. No UI beyond console logs.

Deliverables, in order:
1. `Permissions.swift` — mic + Accessibility checks, prompt flows, Settings deep-links.
2. `AudioRecorder.swift` — AVAudioEngine tap → 16 kHz mono Float32; publishes `audioLevel`.
3. `TranscriptionService.swift` — WhisperKit wrapper; model download with progress; `openai_whisper-large-v3-v20240930_626MB` default.
4. `HotkeyManager.swift` — KeyboardShortcuts hold/release; double-tap = hands-free lock; Esc = cancel.
5. `TextInserter.swift` — clipboard save → write → ⌘V CGEvent → restore; secure-input detection; fail → clipboard + notification.
6. `RealDictationEngine.swift` — composes 1–5, implements `DictationEngine`.

**Done when:** a 5-line test harness dictates into Notes, Safari, Slack, VS Code, Terminal. State transitions logged and correct.

## Workstream B — Frontend

**Mission:** every pixel. Built entirely against mocks — zero dependency on A/C.

Deliverables:
1. `PillView.swift` + `RecordingPanel.swift` — non-activating NSPanel; dark pill above Dock; waveform driven by `audioLevel`; states: recording → transcribing → gone. Appears only while active (Wispr's lesson).
2. `HistoryView.swift` — timestamped transcript log, Copy/Delete per row, search.
3. `InsightsView.swift` — WPM gauge, total words + month badge, streak heatmap, per-app bars.
4. `SettingsView.swift` — hotkey recorder, model picker, mic picker, launch-at-login, sounds, retention.
5. Menu bar content, onboarding sheet (mic → accessibility → try it), app icon.

**Done when:** whole app is clickable with mock data; every `DictationState` and error state has a designed representation.

## Workstream C — Data & Stats

**Mission:** truth in numbers. Pure logic, no UI, no system APIs.

Deliverables:
1. `Dictation.swift` — SwiftData @Model.
2. `SwiftDataStore.swift` — implements `DictationStore`.
3. `StatsCalculator.swift` — implements `StatsProviding`. WPM = wordCount ÷ (duration/60), computed once at save. Streak = consecutive days with ≥1 dictation. Heatmap/day grouping in local timezone.
4. Unit tests: WPM math, streak edges (today empty, timezone rollover), month comparisons.

**Done when:** tests pass. This is the only workstream with formal tests — numbers must be honest.

## Integration (tech lead)

**Mission:** swap mocks for real implementations. `WhisperApp.swift` injects `RealDictationEngine` + `SwiftDataStore` into B's views. Then the QA matrix: 5 target apps × paste behavior, permission-revoked states, rebuild-drops-Accessibility check, model-download interrupt, hands-free lock, Esc cancel.

---

## Build order (who works when)

```
Kickoff  ── write Shared/Contracts.swift + mocks
              │
              ├── Session A: Core Engine        ┐
              ├── Session B: Frontend           ├─ parallel, independent
              └── Session C: Data & Stats       ┘
              │
Integrate ── wire real impls, QA matrix, fix
              │
Polish    ── daily-drive a week, LATER.md for ideas
```

C finishes first (smallest). B finishes second. A takes longest. Integration starts when A lands.

## Running this in Claude Code — practical rules

1. **One session per workstream.** Open each with: "I own Workstream <X> in WORKSTREAMS.md. Read CLAUDE.md, ROADMAP.md, and Shared/Contracts.swift first. Do not edit files outside your owned folders. Do not modify Contracts.swift."
2. **Contracts are law.** If a session claims it must change a contract, it stops and reports why. You arbitrate.
3. **Commit per deliverable**, prefixed: `A: audio capture at 16kHz`, `B: pill waveform states`, `C: streak calculator + tests`.
4. **Sequential is fine too.** If juggling parallel sessions is overhead, run C → B → A → Integration in one session. Same contracts, same isolation, same result — just slower. Recommended if this is your first Xcode project.
5. **I am the design director for B.** Review screenshots each B milestone; Claude Code iterates until it matches my taste.
