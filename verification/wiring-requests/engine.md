# ENGINE — wiring requests

Branch `feature/hotkey-engine`, off `5107e98` (W0). Implements `BUDDY-V3-PLAN.md` §6 as
refined by `docs/hotkey-engine-design.md`. Everything below is in FOREMAN-only files.

Merge order per plan §10: **last** (highest risk).

---

## 1. `App/AppDelegate.swift` — prewarm the mic on `armed` (required)

`HotkeyManager` gained two closures. Without them the grace window costs 200 ms of
audio, and `⌃C` on an ambiguous hold still starts-then-aborts a real recording.

In `wireHotkeys()`, next to the existing four:

```swift
// The engine reports `armed` the instant a dictation trigger goes down, before it
// has decided whether it's a press or the prefix of a chord (⌃ on the way to ⌃⌥).
// AudioRecorder has no ring buffer — samples accumulate only from start() — so the
// mic opens here. Silent: no pill, no cue, no state change.
hotkeys.onArm    = { [weak self] in self?.engine.prewarmRecording() }
hotkeys.onDisarm = { [weak self] in self?.engine.discardPrewarm() }
```

`prewarmRecording()` / `discardPrewarm()` are **concrete** methods on
`RealDictationEngine` (and no-ops on `MockDictationEngine`), not `DictationEngine`
requirements — `Shared/Contracts.swift` stays frozen. `typealias ActiveEngine` still flips.

**Verify:** hold ⌃⇧ and speak immediately, 5×. The first word survives. Compare against
`git stash`-ing this hunk: the first ~100 ms of `AVAudioEngine.start()` is lost today.

---

## 2. `App/AppDelegate.swift` — start the engine (required)

`HotkeyEngine.events` is a `PassthroughSubject`; it **drops anything sent before a
subscriber exists**. Both adapters subscribe in their own `init`, and both are stored
properties (`hotkeys` :35, `companionManager` :60), so they are live by the time
`applicationDidFinishLaunching` runs. Start it there, after `wireHotkeys()`:

```swift
wireHotkeys()
HotkeyEngine.shared.start()   // idempotent; creates the one CGEventTap
```

Keep `let hotkeyBindings = HotkeyBindingStore.shared` declared before `hotkeys` — the
migration still has to finish before anything reads a binding.

**Verify:** breakpoint on `CGEvent.tapCreate` → hit **exactly once** per launch.

---

## 3. W2 cleanup this branch unblocks

- **`Hotkey/HotkeyBindingBridge.swift` — deleted on this branch.** Both matchers it
  bridged are gone. (Its own header said to.)
- **`Settings/Prefs.swift`** — `ModifierOnlyShortcut`, `ModifierOnlyShortcut(flags:)`, and
  the legacy `holdKey` / `pushToTalkModifierOnlyShortcut` constants are now read by
  `HotkeyMigration` and `SettingsView` only. Delete them once RECORDER's `SettingsView`
  rewrite lands (the legacy `PrefKey`s stay — migration reads them).
- **`CLAUDE.md`:32-33** — the "two listen-only CGEventTaps still coexist" paragraph is
  no longer true. One tap, in `Hotkey/HotkeyEngine`. The bridge sentence goes too.
- **`docs/hotkey-engine-design.md`** — implemented; keep or fold into `docs/whisper/`.

---

## 4. For RECORDER (not a FOREMAN file — pass it on)

`Settings/HotkeyRecorderView.swift` **must** bracket recording with:

```swift
.onAppear/focus:  HotkeyEngine.shared.suspend()
.onDisappear/blur: HotkeyEngine.shared.resume()
```

Without it, recording ⌘⇧D for dictation *fires* dictation (Carbon consumes the key before
any responder sees it), and recording a bare ⌃⇧ starts a recording behind the Settings
window. `suspend()` unregisters the Carbon combos and stops matching; it deliberately does
**not** destroy the tap.

---

## 5. Deviations from `docs/hotkey-engine-design.md`

Followed it closely. Three notes:

1. **`HotkeyFeature` gained `cancelsOnEscape`**, as the brief specifies. That is a W0 file.
2. **`Shared/Permissions.swift` gained `eventTapPermitted`**, as the brief specifies.
3. **`HotkeyEngine.init` takes no default arguments.** `CGEventTapSource()` is `@MainActor`
   and a default argument is evaluated in the *caller's* isolation — the exact trap
   `HotkeyBindingStore`'s `HotkeyCarbonRegistrar` comment warns about. Real graph:
   `convenience init(store:)`. Tests use the five-argument designated init.
4. **The tap is not gated on `Permissions.eventTapPermitted`**, only prompted by it.
   `tapCreate == nil` is authoritative, per the brief's own §0.

`suspend()` / `resume()` are additive — the brief doesn't cover the recorder's own capture,
and §4 above is why they exist.

---

## 6. What was verified, and what wasn't

- `xcodebuild … -derivedDataPath /tmp/engine-dd CODE_SIGNING_ALLOWED=NO build` → **green**.
- `… build-for-testing` → **green**. Tests were **not run**: `xcodebuild test` launches an
  unsigned `com.a3b.buddy` and would take the TCC grants with it (hard rule 2). Run them
  with **Cmd+U** in Xcode.
- `HotkeyStateMachine` — the part that decides whether garbage gets typed into a document —
  was compiled standalone with `swiftc` (no app, no tap, no TCC) and executed against 53
  assertions plus a 4000-step randomised walk. The walk asserts, per feature:
  never two sessions open at once · never a stray `released`/`cancelled` · every `armed`
  answered by exactly one `pressed` or `disarmed` · everything balanced at the end.
  All green.
- **Not verified:** the real `CGEventTapSource` and `LocalMonitorSource`, `KeyboardShortcuts`
  combo registration, and the prewarm path against a real `AVAudioEngine`. Those need
  `verification/v3-regression.md` on the machine.

### The one to check hardest

Revoke **Accessibility** while dictation is bound to a hold. Within 1.5 s push-to-talk must
stop firing — and **dictation must keep recording**. That property is what the two-tap split
gave away for free, and it is the single thing this merge could silently lose.
`PushToTalkMonitorTests.stoppingPushToTalkLeavesDictationRecording` covers it, but only
against a fake tap.
