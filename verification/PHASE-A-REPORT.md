# Phase A — Project Merge (FABLE-1) — DONE

One Xcode project at repo root; one target **"a3b Buddy"** (`com.a3b.buddy`); Whisper project is the host, Clicky sources transplanted into `A3BBuddy/Buddy/`.

## Evidence

- `xcodebuild build` (Debug, arm64, **unsigned**, throwaway derived data — never touches TCC-granted apps): **BUILD SUCCEEDED**.
- Built bundle verified: `CFBundleDisplayName = a3b Buddy`, `CFBundleIdentifier = com.a3b.buddy`, `LSUIElement = true`, all three usage strings present, `VoiceTranscriptionProvider = assemblyai`, Sparkle feed keys intact, `ff.mp3` + PostHog/KeyboardShortcuts bundles in Resources, `AppIcon.icns` generated from `logo/a3b-pp-offwhite-1024.png`.

## What changed (structure)

| Was | Now |
|---|---|
| `whisper/Whisper.xcodeproj` | `A3BBuddy.xcodeproj` (targets renamed, SPM: +Sparkle, +posthog-ios; deployment 14.2) |
| `whisper/Whisper/` | `A3BBuddy/` (Xcode 16 synced folder) |
| `clicky/leanring-buddy/` | `A3BBuddy/Buddy/` |
| `clicky/leanring-buddy.xcodeproj` | deleted (dead) |
| clicky `Info.plist` + whisper INFOPLIST_KEYs | root `Info.plist` union (INFOPLIST_FILE + GENERATE_INFOPLIST_FILE) |
| `leanring-buddy.entitlements` | root `A3BBuddy.entitlements` |
| `clicky/worker/` | `worker/` |
| both apps' docs | `docs/whisper/`, `docs/clicky/` |

## App entry merge

- `@main` = `A3BBuddyApp` (Settings scene only). Clicky's `leanring_buddyApp`/`CompanionAppDelegate` deleted; launch work folded into `AppDelegate` (analytics, panel manager, CompanionManager.start, login item, WillTerminate stop).
- **One menu bar icon**: Clicky's `MenuBarPanelManager` (plan §3 recommended path — no fallback needed, no user decision required). Whisper's MenuBarExtra removed.
- Whisper menu actions now in the panel via `WhisperMenuBridge` (`App/WhisperMenuBridge.swift`): live dictation status row, History & Insights, Paste Last Transcript, Dictation Settings.
- Whisper's main window: SwiftUI `Window` scene → plain NSWindow in `AppDelegate.openMainWindow()` (`MainWindowView` itself untouched). Settings opens via `showSettingsWindow:`.
- `MenuBarContent.swift` deleted (superseded by panel rows).

## Collision sweep result

Zero duplicate top-level types/global symbols across the two codebases (checked classes/structs/enums/protocols/typealiases, global funcs/vars, Notification.Name and KeyboardShortcuts.Name extensions). Only asset collision was AppIcon/AccentColor — removed from the Buddy copy; host catalog now carries the a3b logo icon.

## Hotkey coexistence (current defaults, pre-Phase-B)

Two listen-only CGEventTaps coexist. Whisper hold ⌃ is exact-match: when ⌥ joins, whisper cancels and suppresses until release, so ⌃⌥ drives Clicky push-to-talk only. Side effect kept from stock behavior: pressing ⌃ first may flash the whisper pill for an instant before ⌥ joins. Phase B's conflict guard is the real fix.

## Notes for Wave 1

- **GPT-1 (hotkeys)**: branch from post-merge main. `KeyboardShortcuts.Name.pushToTalk` already exists in `A3BBuddy/Hotkey/ShortcutNames.swift`. Monitor to refactor: `A3BBuddy/Buddy/GlobalPushToTalkShortcutMonitor.swift`. Do not touch `Buddy/CompanionManager.swift`, `App/*`, project file — wiring notes go in `verification/wiring-requests/gpt-1.md`.
- **FLASH-1 (glow)**: file is `A3BBuddy/Buddy/OverlayWindow.swift`. Single-file diff.
- User must Cmd+R once: new bundle id ⇒ macOS re-asks all permissions (mic, speech, screen recording, accessibility, input monitoring). Expected, one-time.
- App registers itself as a login item on launch (stock Clicky behavior, kept).
