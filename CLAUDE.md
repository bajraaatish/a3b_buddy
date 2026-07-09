# a3b Buddy — Agent Instructions

One macOS menu-bar app (LSUIElement) merging two features:

- **Whisper dictation** — local speech-to-text (WhisperKit), hold-hotkey to record, pastes into the frontmost app. History/insights window, SwiftData store.
- **Clicky companion** — push-to-talk (ctrl+option) voice chat with Claude. Screenshots your screen, streams answers via a Cloudflare Worker proxy, speaks via ElevenLabs, points a cursor-following triangle at UI elements.

Owner: Aatish — designer, not a software engineer. Explain technical decisions in plain terms when they matter.

## Layout

```
A3BBuddy.xcodeproj      one project, one app target "a3b Buddy" (bundle id com.a3b.buddy)
A3BBuddy/               app sources (Xcode 16 synced folder — files added here join the target automatically)
  App/                  entry + integration: A3BBuddyApp (@main), AppDelegate (owns BOTH feature graphs), WhisperMenuBridge
  Audio/ History/ Hotkey/ Insertion/ Overlay/ Settings/ Shared/ Stats/ Transcription/   Whisper feature
  Buddy/                Clicky feature (CompanionManager, MenuBarPanelManager, OverlayWindow, …)
A3BBuddyTests/          unit tests (@testable import A3BBuddy)
Info.plist              custom keys (Sparkle feed, VoiceTranscriptionProvider, usage strings) — merged with generated plist
A3BBuddy.entitlements   sandbox off, mic/camera/network
worker/                 Cloudflare Worker proxy (Claude / ElevenLabs / AssemblyAI keys live there)
docs/whisper/ docs/clicky/   pre-merge docs of each app — architecture details still accurate per-feature
verification/wiring-requests/   agents that may not touch app-entry files leave wiring notes here
```

## Merge architecture (read before touching entry points)

- Single `@main` = `A3BBuddyApp` (`App/A3BBuddyApp.swift`). Only scene: Settings (Whisper's SettingsView).
- `AppDelegate` owns both graphs: Whisper (engine/store/stats/pill/onboarding) and Clicky (CompanionManager + MenuBarPanelManager).
- **One menu bar icon**: Clicky's `MenuBarPanelManager` NSStatusItem. Whisper's MenuBarExtra is gone; its menu actions live in the panel via `WhisperMenuBridge` (App/WhisperMenuBridge.swift).
- Whisper's history/insights window is a plain NSWindow made in `AppDelegate.openMainWindow()` (was a SwiftUI Window scene; panel is AppKit and can't use openWindow). **Settings is the same** (`openSettingsWindow()`): `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, …)` silently does nothing here — `to: nil` resolves via the key window's responder chain, and an LSUIElement app clicked from a `.nonactivatingPanel` has no key window and is not active. Don't reintroduce it.
- Hotkeys are user-bindable, stored as `[HotkeyBinding]` JSON (`hotkey.dictation`, `hotkey.pushToTalk`) via `Hotkey/HotkeyBindingStore`. Defaults are **disjoint**: dictation = hold ⌃⇧, push-to-talk = hold ⌃⌥ (neither is a prefix of the other, so neither waits on a grace timer). `HotkeyConflictChecker` gates every rebind — `.warn` is saveable, `.block` isn't. See `BUDDY-V3-PLAN.md`.
- **One** CGEventTap for the whole app, in `Hotkey/HotkeyEngine` (`HotkeyEventSource` owns the tap; `HotkeyStateMachine` is pure and decides what events mean). `Hotkey/HotkeyManager` and `Buddy/GlobalPushToTalkShortcutMonitor` are now adapters that subscribe to `engine.events` and own no input code. Design: `docs/hotkey-engine-design.md`.
- The tap is listen-only **unless** a mouse button is bound *and* Accessibility is granted, in which case it is a `.defaultTap` so the bound button can be swallowed (Mouse 4 must not also mean Back). `tapCreate` failing with `.defaultTap` falls back to `.listenOnly` — never trade working hotkeys for swallowing. The tap honours `Outcome.consumesEvent` **only for mouse events**: `consumesEvent` is also set for Esc during a live session, and swallowing that in the global tap would swallow Esc system-wide.
- `engine.start()` runs in `applicationDidFinishLaunching` *after* both adapters exist — `events` is a `PassthroughSubject` and drops anything sent with no subscriber.
- A subset hold (⌃) that prefixes another feature's hold (⌃⌥) waits 200 ms before committing. `armed` fires at t=0 and prewarms the mic (`RealDictationEngine.prewarmRecording()`), so the grace window costs no audio. Disjoint defaults mean this path is dormant.
- The Settings hotkey recorder calls `HotkeyEngine.shared.suspend()` while capturing, or recording ⌃⇧ would start a dictation behind the window.
- Combo bindings are registered with Carbon via `KeyboardShortcuts`; bare-modifier holds and mouse buttons are matched in the event tap. Carbon *consumes* a keystroke, a listen-only tap only observes, so a combo must never be tap-matched — it would type the character into the field you're dictating into.
- `HotkeyBinding` has three shapes: `.modifiersOnly`, `.keyCombo`, `.mouseButton(number:)` (only 3 and 4 — "Mouse 4"/"Mouse 5" — are bindable). Partition on `isKeyCombo`, **never** `!isModifiersOnly`, or a mouse binding takes a Carbon slot index. `.mouseButton` reports empty `modifierFlags`, so it must never reach the conflict checker's modifier-subset rules. A bound mouse press ends any other live session first: push-to-talk has `cancelsOnMouseDown == false`, so otherwise it would record on top of a live dictation hold.
- `KeyboardShortcuts.Name`s carry **no `default:`**. `Name.init` writes its default into UserDefaults as a side effect at static-init time, which races `HotkeyMigration`. Migration is the only seeder.
- Info.plist strategy: GENERATE_INFOPLIST_FILE=YES **plus** INFOPLIST_FILE=Info.plist. Custom/usage keys go in the file; display name via INFOPLIST_KEY_. Don't put the same key in both.

## Hard rules (inherited from both apps)

1. `A3BBuddy/Shared/Contracts.swift` is frozen. Need a change? Stop and ask.
2. Do NOT run `xcodebuild` against the user's installed/granted app or Xcode's derived data — TCC grants die. Compile checks: unsigned build to a throwaway `-derivedDataPath` with `CODE_SIGNING_ALLOWED=NO` only. The user builds with Cmd+R.
3. Only the foreman agent (FABLE-1) edits `.xcodeproj`, `Info.plist`, entitlements, and `App/` entry files. Others write code + a wiring note in `verification/wiring-requests/<agent>.md`.
4. Only FABLE-1 touches `Buddy/CompanionManager.swift`.
5. Known non-blocking warnings (Swift 6 concurrency, deprecated onChange in OverlayWindow.swift): do not fix.
6. Recording pill appears ONLY while recording/transcribing. Never idle on screen.
7. No new features beyond the active plan; append ideas to `docs/whisper/LATER.md`.
8. All buttons show pointer cursor on hover (`.pointerCursor()` from Buddy/DesignSystem.swift).

## Gotchas already researched (don't rediscover)

- Bare-modifier hold needs **Input Monitoring** (listen-only CGEventTap), not Accessibility; grant applies after relaunch. A bound mouse button works on Input Monitoring too, but only **Accessibility** lets the tap swallow it, so without that grant Mouse 4 also triggers Back in the app underneath.
- Pill/companion panels must be `.nonactivatingPanel` — focus must never leave the target app.
- LSUIElement windows need `NSApp.activate(ignoringOtherApps: true)` or they open behind other apps.
- Secure input fields block synthetic ⌘V — Whisper detects and falls back to clipboard + notification.
- If paste stops working after a rebuild: remove + re-add app in Privacy & Security → Accessibility.
- Shared URLSession for AssemblyAI streaming — one long-lived session per provider, never per session (socket-pool corruption).
- WhisperKit model registry name is `large-v3-v20240930`; models download at runtime (never commit `*.mlmodelc`).
- `AppBundleConfiguration.stringValue(forKey:)` reads Info.plist keys (e.g. `VoiceTranscriptionProvider`) at runtime.

## Build & run

Open `A3BBuddy.xcodeproj`, scheme "a3b Buddy", Cmd+R. First launch on the new bundle id re-requests all permissions (mic, speech, screen recording, accessibility, input monitoring) — expected.

## Worker

`worker/` — `npx wrangler deploy`; secrets: ANTHROPIC_API_KEY, ASSEMBLYAI_API_KEY, ELEVENLABS_API_KEY. Routes: /chat, /tts, /transcribe-token.
