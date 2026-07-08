# Buddy v3 — Manual Regression Matrix

This document defines the manual regression matrix to be run by **FOREMAN** at **W2** to verify the integrated hotkey and overlay features.

## Test Matrix Dashboard

| Test ID | Scenario | Expected Outcome | Status |
| :--- | :--- | :--- | :---: |
| **STT-1** | Hold/Release Dictation | Hold `⌃⇧` -> Speak -> Release. Pill shows EQ/dots, audio transcribes, and text pastes into frontmost app. | `[ ]` |
| **STT-2** | Hands-Free Toggle (Double-Tap) | Double-tap `⌃⇧`. Pill locks on screen, widens, and displays `✕` and `✓` buttons. | `[ ]` |
| **STT-3** | Hands-Free Cancel (`✕`) | Click `✕` button on hands-free pill. Pill dismisses, dictation aborts, no text is pasted. | `[ ]` |
| **STT-4** | Hands-Free Confirm (`✓`) | Click `✓` button on hands-free pill. Pill spinner shows, transcribes, pastes, and dismisses. | `[ ]` |
| **STT-5** | Keyboard Cancel (`Esc`) | Press `Esc` while recording (held or hands-free). Dictation aborts, pill dismisses immediately. | `[ ]` |
| **STT-6** | Hard Stop Limit (5 Minutes) | Start recording, let run. Recording stops and transcribes automatically at the 5-minute mark. | `[ ]` |
| **STT-7** | Modifier Passthrough | Press `⌃C` in Terminal or `⌃+Click` in Finder. Native behavior fires; key tap does not block OS modifier. | `[ ]` |
| **STT-8** | Capital Letter Typing | Open TextEdit. Type `Hello World` using `Shift` key. No mic starts, no capitals bleed, no silence pasted. | `[ ]` |
| **PTT-1** | Push-to-Talk Pipeline | Hold `⌃⌥` -> Speak -> Release. STT runs -> Claude processes -> TTS speaks -> cursor points at target. | `[ ]` |
| **UI-1** | One Menu-Bar Icon | Only Clicky's icon is in the menu bar. Whisper menu is embedded in the panel. | `[ ]` |
| **UI-2** | No Idle Pill | The recording/transcription pill is never visible on screen during idle. | `[ ]` |
| **UI-3** | Hover Effects | All interactive buttons (✕, ✓, settings rows) show the `.pointerCursor()` on hover. | `[ ]` |
| **SET-1** | Rebind Hotkeys | In Settings ▸ Hotkeys: Bind Dictation to `⌘⇧D` and Push-to-Talk to bare `fn`. Changes are instant. | `[ ]` |
| **SET-2** | Conflict Warning | Bind a bare modifier that prefixes a combo. Verify orange warning caption appears; save is permitted. | `[ ]` |
| **SET-3** | Conflict Block | Try to assign `⌃⌥` to Dictation while Push-to-Talk has it. Verify red caption + beep; save blocked. | `[ ]` |
| **SET-4** | Persistence | Quit app, run `defaults read com.a3b.buddy \| grep hotkey`. Relaunch. Custom hotkeys remain. | `[ ]` |
| **SYS-1** | No Permission Re-prompt | Relaunching the app does not trigger new TCC dialogs for Input Monitoring/Accessibility. | `[ ]` |

---

## Detailed Steps & Execution Procedures

### STT-1: Hold/Release Dictation
1. Open a text editor (e.g., TextEdit) and focus the text insertion cursor.
2. Press and hold the Dictation hotkey (`⌃⇧`).
3. Speak a test sentence: `"Testing dictation hold and release."`
4. Release the hotkey.
5. **Verify:**
   - The pill is visible at the bottom-center of the screen during recording.
   - White EQ bars animate while you speak; small white dots pulse during silence.
   - When released, the pill shows the radial spinner (transcribing state) and then fades out.
   - The text `"Testing dictation hold and release."` is successfully pasted into the text editor.

### STT-2: Hands-Free Toggle (Double-Tap)
1. Focus TextEdit.
2. Double-tap the Dictation hotkey (`⌃⇧`) within 0.35 seconds.
3. **Verify:**
   - The pill appears and locks on screen (hands-free lock mode).
   - The pill widens by ~72 pt (no clipping).
   - A dark-grey circle containing a white `✕` appears on the left.
   - A white circle containing a dark `✓` appears on the right.
   - The pill accepts mouse clicks (`ignoresMouseEvents` is disabled).

### STT-3: Hands-Free Cancel (`✕`)
1. While in hands-free lock mode, hover over the `✕` button. Confirm it shows a pointer cursor.
2. Click the `✕` button.
3. **Verify:**
   - The pill dismisses immediately.
   - No transcription is performed, and no text is pasted.

### STT-4: Hands-Free Confirm (`✓`)
1. Double-tap `⌃⇧` to enter hands-free mode. Speak `"Confirm this text."`
2. Hover over the `✓` button. Confirm it shows a pointer cursor.
3. Click the `✓` button.
4. **Verify:**
   - The pill transitions to the transcribing state (showing the white radial spinner on the right).
   - The text is pasted.
   - The pill dismisses.

### STT-5: Keyboard Cancel (`Esc`)
1. Start recording (either holding or hands-free).
2. Press the `Escape` key.
3. **Verify:**
   - The recording stops immediately.
   - The pill dismisses.
   - No text is pasted.

### STT-6: Hard Stop Limit (5 Minutes)
1. Start recording and leave the microphone active.
2. Wait 5 minutes.
3. **Verify:**
   - The recording stops automatically at 5 minutes.
   - Transcription occurs, and whatever was spoken is pasted.

### STT-7: Modifier Passthrough
1. Open Terminal. Type `top` or a long running command.
2. Press `⌃C`.
3. **Verify:**
   - Terminal receives the interrupt (`SIGINT`) signal and terminates the command.
   - The recording pill does NOT appear.
   - In Finder, hold `⌃` and click a file. Verify the context menu appears.

### STT-8: Capital Letter Typing
1. Open TextEdit.
2. Type `"Hello World. This is Antigravity."` (using the `Shift` key to capitalize).
3. **Verify:**
   - The letters capitalize normally.
   - No recording pill triggers.
   - No short silence is transcribed or pasted into the text editor.

### PTT-1: Push-to-Talk Pipeline
1. Press and hold the Push-to-Talk hotkey (`⌃⌥`).
2. **Verify:**
   - The wine-colored cursor waveform overlay appears near the cursor.
3. Speak a command: `"Where is the target?"`
4. Release the hotkey.
5. **Verify:**
   - The waveform stops and the spinner animates.
   - Buddy responds via ElevenLabs TTS (if enabled/configured) or logs the text in the companion panel.
   - The cursor moves/points to targets if instructed.
   - Dictation does NOT fire concurrently.

### UI-1: One Menu-Bar Icon
1. Look at the macOS menu bar.
2. **Verify:**
   - Only Clicky's application icon is present.
   - Whisper-specific actions (e.g., Settings, History) are available in the dropdown panel.

### UI-2: No Idle Pill
1. Minimize or close the settings pane. Let the app sit idle.
2. **Verify:**
   - The pill is not visible anywhere on the screen.

### UI-3: Hover Effects
1. Hover over settings buttons, list rows, and the hands-free pill buttons (`✕`/`✓`).
2. **Verify:**
   - All interactive elements exhibit a pointer cursor.

### SET-1: Rebind Hotkeys
1. Open Settings ▸ Hotkeys.
2. Click the Dictation recorder, then press `⌘⇧D`.
3. Click the Push-to-Talk recorder, then press the bare `fn` key.
4. **Verify:**
   - Both hotkeys update instantly in the UI.
   - Rebound keys function immediately for their respective actions without an app restart.

### SET-2: Conflict Warning
1. Try to record a hold modifier that prefixes another feature's shortcut.
2. **Verify:**
   - An orange warning caption appears.
   - The binding is successfully saved.

### SET-3: Conflict Block
1. Try to record `⌃⌥` for Dictation when Push-to-Talk is already using `⌃⌥`.
2. **Verify:**
   - A red caption appears explaining the conflict.
   - A system beep (`NSSound.beep()`) is heard.
   - The settings picker refuses to save the new binding.

### SET-4: Persistence
1. With custom hotkeys bound, quit the application.
2. Open Terminal and run:
   ```bash
   defaults read com.a3b.buddy | grep hotkey
   ```
3. **Verify:**
   - `hotkeyMigrationVersion = 2` is output.
   - Custom keys are printed in the UserDefaults dictionary.
4. Relaunch the application. Verify the custom hotkeys are still active.

### SYS-1: No Permission Re-prompt
1. Relaunch the application.
2. **Verify:**
   - No TCC permission alerts (Accessibility or Input Monitoring) are shown if they were previously authorized.
