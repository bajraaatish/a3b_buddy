# Buddy v3 — Audit Report

This report presents the findings of the **AUDIT** agent regarding stale copy, dead code, and logical bugs discovered during the codebase analysis for the Buddy v3 hotkey unification workstream.

---

## 1. Stale-Copy Sweep

The following references hardcode the legacy hotkey `⌃⌥` (Control + Option) or specify incorrect defaults/architectures. They must be updated during W2 wiring to support dynamic bindings:

### 1.1 `A3BBuddy/Buddy/CompanionPanelView.swift` (Line 184)
* **Code:**
  ```swift
  Text("Hold Control+Option to talk.")
  ```
* **Issue:** Hardcoded instruction string. If the user changes their Push-to-Talk hotkey, this UI prompt becomes misleading.
* **Remedy:** FOREMAN should replace this with a dynamic copy bound to the active PTT hotkey:
  ```swift
  Text("Hold \(HotkeyBindingStore.shared.bindings(for: .pushToTalk).first?.displayString ?? "your push-to-talk key") to talk.")
  ```

### 1.2 `A3BBuddy/Buddy/CompanionManager.swift` (Line 794)
* **Code:**
  ```swift
  let message = "press control + option and introduce yourself"
  ```
* **Issue:** Hardcoded string streamed word-by-word to the user during the onboarding sequence.
* **Remedy:** FOREMAN should replace this with a dynamic string referencing the PTT hotkey:
  ```swift
  let hotkeyStr = HotkeyBindingStore.shared.bindings(for: .pushToTalk).first?.displayString.lowercased() ?? "your push-to-talk key"
  let message = "press \(hotkeyStr) and introduce yourself"
  ```

### 1.3 `A3BBuddy/Buddy/OverlayWindow.swift` (Line 217)
* **Code:**
  ```swift
  // Onboarding prompt — "press control + option and say hi" streamed after the intro starts.
  ```
* **Issue:** Stale developer comment referencing the old hardcoded shortcut.
* **Remedy:** Update comment to:
  ```swift
  // Onboarding prompt — streamed after the intro starts using the dynamic Push-to-Talk shortcut.
  ```

### 1.4 `CLAUDE.md` (Line 32)
* **Code:**
  ```markdown
  - Two listen-only CGEventTaps coexist: Whisper Hotkey/HotkeyManager and Clicky Buddy/GlobalPushToTalkShortcutMonitor. Hotkey defaults: dictation = hold ⌃ (or ⌥Space combo), push-to-talk = hold ⌃⌥. Whisper's tap is exact-match and cancels when another modifier joins, so ⌃⌥ reaches Clicky only.
  ```
* **Issue:** Documented architecture is stale. Dictation default is changing to `⌃⇧`, Push-to-Talk default is `⌃⌥`, and the event taps are being unified into a single listen-only `HotkeyEngine`.
* **Remedy:** FOREMAN should update this line to reflect the unified `HotkeyEngine` and corrected defaults.

### 1.5 `verification/wiring-requests/gpt-1.md` (Item 5)
* **Issue:** Already open item pointing out the onboarding copy issue in `CompanionManager.swift`.
* **Remedy:** Closed/resolved by the dynamic copy implementation in Wave 2.

---

## 2. Dead-Code Report

The following symbols have no active usage or references outside of their own declarations. They are candidates for deletion in Wave 2:

### 2.1 `ModifierOnlyShortcut.keyCapsuleLabels`
* **Location:** [A3BBuddy/Settings/Prefs.swift:L149](file:///Users/aatishbajracharya/Documents/Projects/Dev/a3b-buddy/A3BBuddy/Settings/Prefs.swift#L149)
* **Status:** `Zero call sites`. Used to provide labels for custom modifier combinations under the old settings page, but now replaced by `HotkeyBinding` formatting.

### 2.2 `CompanionResponseOverlayManager` & View Models
* **Location:** [A3BBuddy/Buddy/CompanionResponseOverlay.swift](file:///Users/aatishbajracharya/Documents/Projects/Dev/a3b-buddy/A3BBuddy/Buddy/CompanionResponseOverlay.swift)
* **Status:** `Unused`. The entire file is self-contained. Neither the manager class nor the SwiftUI view is instantiated or referenced in any active pipeline.

### 2.3 `speechToTextProviderRow`
* **Location:** [A3BBuddy/Buddy/CompanionPanelView.swift:L583](file:///Users/aatishbajracharya/Documents/Projects/Dev/a3b-buddy/A3BBuddy/Buddy/CompanionPanelView.swift#L583)
* **Status:** `Unused`. This panel item row is declared but never called or placed in the main body.

### 2.4 `permissionRow(label:iconName:isGranted:settingsURL:)`
* **Location:** [A3BBuddy/Buddy/CompanionPanelView.swift:L500](file:///Users/aatishbajracharya/Documents/Projects/Dev/a3b-buddy/A3BBuddy/Buddy/CompanionPanelView.swift#L500)
* **Status:** `Unused`. Decoupled helper method with zero active call sites.

### 2.5 `showA3BCursorToggleRow`
* **Location:** [A3BBuddy/Buddy/CompanionPanelView.swift:L556](file:///Users/aatishbajracharya/Documents/Projects/Dev/a3b-buddy/A3BBuddy/Buddy/CompanionPanelView.swift#L556)
* **Status:** `Commented Out`. The layout row invocation is commented out on line 63 (`// showA3BCursorToggleRow`).

---

## 3. Bug Confirmation: Engine vs. Panel Controller Failure Mismatch

### 3.1 Code Comparison
* **In `RealDictationEngine.swift` (Line 152):**
  ```swift
  private func fail(_ error: DictationError) {
      state = .failed(error)
      failResetTask?.cancel()
      failResetTask = Task { @MainActor [weak self] in
          try? await Task.sleep(nanoseconds: 2_500_000_000)
          guard let self, case .failed = self.state else { return }
          self.state = .idle
      }
  }
  ```
* **In `RecordingPanelController.swift` (Line 37):**
  ```swift
  private func sync() {
      switch engine.state {
      case .recording, .transcribing:
          show()
      case .idle, .failed:
          hide()
      }
  }
  ```

### 3.2 Analysis
The comments in `RealDictationEngine.swift` explain: `"Failure shows on the pill briefly, then the engine returns to idle so the pill dismisses and the next dictation can start."`

However, because `RecordingPanelController.swift` maps the `.failed` state to `hide()`, the panel hides **instantly** when an error occurs.
1. The user never gets visual feedback that dictation failed (e.g. mic permission denied).
2. The 2.5-second sleep in `.failed` state before reverting to `.idle` is effectively a blind window where the user cannot start a new dictation, but cannot see why.

### 3.3 Recommendation for FOREMAN & PILL Lanes
* **Option A (Fix Pill Visuals):**
  Allow the panel to show on `.failed` state. Update `PillView` to render a brief red or error-style state indicating the failure, matching the 2.5-second reset window.
* **Option B (Remove Dead Window):**
  If failure feedback is not desired on the pill, update `RealDictationEngine` to reset directly to `.idle` without the 2.5-second sleep block.

---

## 4. Swift Concurrency Unit Test Build Failure

During execution of the unit test target (`xcodebuild test`), compilation fails under Swift 6 strict concurrency checks:
* **Error:** `call to main actor-isolated initializer 'init()' in a synchronous nonisolated context` in `HotkeyBindingStore.swift:55:41`.
* **Cause:** `KeyboardShortcutsCarbonRegistrar` is `@MainActor`-isolated and initialized as a default argument in the constructor signature of `HotkeyBindingStore`. Default arguments are evaluated in a non-isolated caller context.
* **Fix:** Change the default value to `nil` and assign `self.carbon = carbon ?? KeyboardShortcutsCarbonRegistrar()` inside the class initializer body. See [verification/wiring-requests/audit.md](file:///Users/aatishbajracharya/Documents/Projects/Dev/a3b-buddy/verification/wiring-requests/audit.md) for the proposed diff.
