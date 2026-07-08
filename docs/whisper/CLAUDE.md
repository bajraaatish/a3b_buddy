# Whisper — Project Context for Claude Code

Personal macOS speech-to-text app (Wispr Flow clone, local-only). Owner: Aatish — designer, not a software engineer. Explain technical decisions in plain terms when they matter; don't over-explain basics of design.

## Read first
- `ROADMAP.md` — phases, stack decisions, rules of the build
- `WORKSTREAMS.md` — team split (A: Core Engine, B: Frontend, C: Data & Stats), interface contracts, session rules
- `REPORT.md` — Wispr Flow teardown (the UX reference)

## Stack (locked — do not relitigate)
- Swift / SwiftUI, macOS 14+, MenuBarExtra, `LSUIElement = YES`
- WhisperKit via SPM: `https://github.com/argmaxinc/argmax-oss-swift` (WhisperKit library product, Xcode 16+)
- Default model: `openai_whisper-large-v3-v20240930_626MB`
- KeyboardShortcuts (sindresorhus) for hotkeys
- Text insertion: clipboard save → write → simulated ⌘V CGEvent → restore
- SwiftData for history/stats
- App Sandbox OFF, direct distribution, automatic signing with real team ID (unsigned rebuilds silently drop the Accessibility grant)

## Hard rules
1. `Shared/Contracts.swift` is frozen. Need a change? Stop and ask.
2. Stay inside your workstream's owned folders (see WORKSTREAMS.md table).
3. Every "Done when" checkpoint = a commit. Prefix commits with workstream letter (`A:`, `B:`, `C:`).
4. WPM = wordCount ÷ (duration/60), computed once at save time, never recomputed.
5. No new features outside the roadmap — append ideas to `LATER.md`.
6. Test insertion in: Notes, Safari, Slack/Discord, VS Code, Terminal.
7. Recording pill: appears ONLY while recording/transcribing. Never idle on screen.

## Gotchas already researched (don't rediscover)
- WhisperKit model registry name is `large-v3-v20240930`, not "large-v3-turbo".
- Pill panel must be `.nonactivatingPanel` — focus must never leave the target text field.
- With LSUIElement, windows need `NSApp.activate(ignoringOtherApps: true)` or they open behind other apps.
- Secure input fields (passwords, Secure Keyboard Entry) block synthetic ⌘V — detect, fall back to clipboard + notification.
- If paste stops working after a rebuild: remove + re-add app in Privacy & Security → Accessibility.
- Bare-modifier hold (⌃/⌥/fn) needs **Input Monitoring** (kIOHIDRequestTypeListenEvent), not Accessibility — NSEvent global flagsChanged monitors stay silent without it. Use a listen-only CGEventTap; grant applies only after app relaunch.
