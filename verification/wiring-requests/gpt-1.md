# GPT-1 wiring request — flexible hotkeys

Implemented Phase B source changes in the merged `A3BBuddy/` tree:

- `A3BBuddy/Hotkey/ShortcutNames.swift`
  - Adds `KeyboardShortcuts.Name.pushToTalk`.
  - Leaves dictation's existing default combo intact.
- `A3BBuddy/Settings/Prefs.swift`
  - Replaces the single `HoldKey` model with `ModifierOnlyShortcut`.
  - Preserves the existing dictation storage key (`holdKey`) and default (`control`).
  - Adds `pushToTalkModifierOnlyShortcut`, defaulting to `control+option` to preserve Clicky's fresh-install behavior.
- `A3BBuddy/Hotkey/HotkeyManager.swift`
  - Dictation modifier-only hold now supports modifier combinations, not only a single modifier.
  - Keeps combo handling through `KeyboardShortcuts`.
- `A3BBuddy/Buddy/BuddyDictationManager.swift`
  - Removes Clicky's hardcoded shortcut option table.
  - Keeps `BuddyPushToTalkShortcut.ShortcutTransition` as the `CompanionManager` contract.
- `A3BBuddy/Buddy/GlobalPushToTalkShortcutMonitor.swift`
  - Adds `KeyboardShortcuts` key-down/key-up handling for `.pushToTalk`.
  - Keeps the CGEventTap path for modifier-only push-to-talk.
  - Preserves `shortcutTransitionPublisher` and `isShortcutCurrentlyPressed`.
  - Releases any active push-to-talk state when the configured shortcut changes.
- `A3BBuddy/Settings/SettingsView.swift`
  - Adds a shared "Hotkeys" section with recorders for "Dictation (Whisper)" and "Push-to-talk (Clicky)".
  - Adds modifier-only selectors for both features.
  - Reverts and warns inline when the same combo or modifier-only shortcut is assigned to both.

Wiring needed from FABLE:

1. Ensure the merged target compiles all `A3BBuddy/**/*.swift` files that should ship, including the six files above.
2. Ensure the merged target links `KeyboardShortcuts` for both Whisper and Buddy hotkey code paths.
3. Remove or exclude Clicky's old `@main` file (`A3BBuddy/Buddy/leanring_buddyApp.swift`) from the merged target.
4. The current project wiring does not compile app sources yet. `xcodebuild -project A3BBuddy.xcodeproj -scheme Whisper -configuration Debug -destination 'platform=macOS' build` currently fails at link with missing `_main`; the generated link file only contains package objects.
5. There is still hardcoded onboarding copy in `A3BBuddy/Buddy/CompanionManager.swift`:
   - `press control + option and introduce yourself`
   Replace it after app-entry wiring with dynamic copy such as `press \(BuddyPushToTalkShortcut.pushToTalkDisplayText) and introduce yourself`, or with generic "use your push-to-talk hotkey" copy.

Verification completed here:

- `xcrun swiftc -parse` passes for the changed hotkey/settings files.
- Full Xcode build is blocked by current Phase A project wiring, before this lane's source can be linked into an app binary.
- Latest build log: `.context/xcodebuild-hotkeys.log`.
