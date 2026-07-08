# Buddy v3 — Task Division for Agents

Branch `merge-clicky-whisper-plan`. One local macOS menu-bar app (`com.a3b.buddy`): Whisper
dictation (WhisperKit) + Buddy companion (wine cursor, push-to-talk, local STT/TTS).

Three asks drive this wave:

1. Rebuild the Whisper recording pill to match `reference/` exactly.
2. The dictation hotkey setting **doesn't work**. Make *any* key bindable, for Whisper and
   Buddy independently.
3. Ship a standalone `.app` (no Xcode) — **deferred**, see §9. Do not start it.

**Read this whole file before starting your task.**

---

## STATUS (live)

| Lane | State |
|---|---|
| **W0 foundation** | ✅ merged — `5107e98` |
| **RECORDER** | ✅ merged — landed with W0 (`HotkeyRecorderView` + `SettingsView`) |
| **AUDIT** | ✅ merged — `979417f`; stale copy applied, wiring request resolved |
| **PILL** | ✅ merged — `9d58c7e` (four states, geometry trap fixed) |
| **ENGINE** | ✅ merged — `191fb4b` (one tap, pure state machine, bridge deleted) |
| **W2 wiring** | ✅ `8d8f31f` — engine started, prewarm wired, recorder gated, Settings window fixed, `ModifierOnlyShortcut` deleted |
| **W3 standalone .app** | ⬜ deferred, do not start |

All lanes merged. `build-for-testing` is green.

### Left to do — all of it needs the machine, not an agent

1. **Cmd+R.** Menu bar → *Dictation Settings* now opens a real window. Rebind both features.
2. **Cmd+U.** `HotkeyStateMachineTests` + `HotkeyEngineTests` (1047 lines) have **never been executed
   in the app.** ENGINE compiled the state machine standalone with `swiftc` and ran 53 assertions
   plus a 4000-step randomised walk, but `xcodebuild test` launches an unsigned `com.a3b.buddy` and
   would take the TCC grants with it (hard rule 2). Run them from Xcode.
3. **`verification/v3-regression.md`.** The one to check hardest, in ENGINE's own words: *revoke
   Accessibility while dictation is bound to a hold — push-to-talk must stop within 1.5 s and
   dictation must keep recording.* That property is what the two-tap split gave away for free, and
   it is the single thing this merge could silently lose.
4. **Decide the `.failed` pill state** (`verification/v3-audit-report.md` §3). `RealDictationEngine`
   holds `.failed` for 2.5 s so "failure shows on the pill briefly", but
   `RecordingPanelController` hides the panel on `.failed`. The state is unreachable — a 2.5 s
   window where dictation can't restart and the user sees nothing. Either give the pill a fifth
   state or delete the sleep.
5. **Check TCC.** Privacy & Security → Accessibility / Input Monitoring / Microphone. See the note
   in `verification/wiring-requests/audit.md`.
6. **Tag `v0.3`** on green.

**Two corrections to §3 below, learned the hard way:**
- `-target` **cannot** be combined with `-derivedDataPath`. Use `-scheme "a3b Buddy"` —
  `xcodebuild` autocreates the scheme even in a fresh worktree (verified).
- `SWIFT_VERSION = 5.0` and `SWIFT_STRICT_CONCURRENCY` is unset (`minimal`). There is
  no Swift 6 strict concurrency here; don't plan around diagnostics that won't appear.

**A temporary shim exists.** `Hotkey/HotkeyBindingBridge.swift` points the two old
matchers at `HotkeyBindingStore`, because Settings now edits the store while
`HotkeyManager` / `GlobalPushToTalkShortcutMonitor` still read the legacy
`ModifierOnlyShortcut` keys. Without it, rebinding a hotkey does nothing —
the exact bug this wave exists to fix. **ENGINE deletes it**, along with
`ModifierOnlyShortcut` in `Settings/Prefs.swift`.

---

## 0. Two findings that shape everything

### 0.1 The dictation hotkey is actively broken, not merely inflexible

`Settings/Prefs.swift:17` stores the dictation hold under the legacy key `"holdKey"`.
That key is **absent** from `com.a3b.buddy`, so `HotkeyManager.swift:243` falls back to its
code default: `.shift`.

Trace `HotkeyManager.handleFlagsChanged` (`:213`):

- Press ⇧ → `.exact` → `holdPressed()` → `keyDown()` → `onStartRecording()`. **Every Shift
  press opens the mic.**
- Type a capital → `handleCancelKey` (`:348`) → `cancel()`. Mic starts and aborts on every
  capital letter.
- Tap ⇧ alone under the 0.35 s `tapWindow` → `keyUp()` (`:288`) → `finish()` fires 0.35 s
  later → **transcribes ~0.3 s of silence and pastes it into the frontmost app.**

That is the bug. The Settings picker displays "⇧ Shift" — a value the user never chose.

### 0.2 A flexible-hotkey system already exists. The merge ate it.

Branch `feature/merge-a3b-buddy`, commit **`1c07ada`**. Orphaned:
`git merge-base --is-ancestor 7890caf HEAD` → false.

Six files under the pre-merge path `whisper/Whisper/Hotkey/`:

| File | What it is |
|---|---|
| `HotkeyBinding.swift` | `enum HotkeyBinding { case keyCombo(keyCode:modifiers:), modifiersOnly(modifiers:) }`. Codable, glyph rendering (`⌃⌥`, `⌥Space`, `fn`), full QWERTY keyCode→label map, `requiresInputMonitoring` |
| `HotkeyFeature.swift` | `.dictation` / `.pushToTalk`, each carrying `supersetPolicy`, `cancelsOnOtherKeyDown`, `cancelsOnMouseDown`, `maxBindings: 2`, `defaultBindings` |
| `HotkeyConflict.swift` | `HotkeyConflictChecker.evaluate(...)` → `.none` / `.warn(msg)` / `.block(msg)`. Pure, synchronous, no UserDefaults. Knows a bare hold that prefixes a combo is unreachable. Ships a macOS system-shortcut denylist |
| `HotkeyBindingStore.swift` | `@MainActor ObservableObject`, `@Published bindings: [HotkeyFeature: [HotkeyBinding]]`, JSON in UserDefaults, write-through to Carbon via `KeyboardShortcuts.setShortcut` |
| `HotkeyMigration.swift` | One-shot legacy → new translation |
| `ShortcutNames.swift` | Four `KeyboardShortcuts.Name`s, **none carrying `default:`** |
| `HotkeyConflictTests.swift` | Swift Testing decision table |

It even ran on this machine — `defaults read com.a3b.buddy` shows `hotkeyMigrationVersion = 1`,
`hotkey.dictation = [modifiersOnly(⌃), keyCombo(⌥Space)]`, `hotkey.pushToTalk = [modifiersOnly(⌃⌥)]`.

**`HotkeyEngine` — the CGEventTap that consumes these bindings — is referenced throughout
their comments but was never written.** That is the real remaining work.

Read them with:

```bash
git show 1c07ada:whisper/Whisper/Hotkey/HotkeyBinding.swift
git show 1c07ada:whisper/Whisper/Hotkey/HotkeyFeature.swift
git show 1c07ada:whisper/Whisper/Hotkey/HotkeyConflict.swift
git show 1c07ada:whisper/Whisper/Hotkey/HotkeyBindingStore.swift
git show 1c07ada:whisper/Whisper/Hotkey/HotkeyMigration.swift
git show 1c07ada:whisper/Whisper/Hotkey/ShortcutNames.swift
git show 1c07ada:whisper/WhisperTests/HotkeyConflictTests.swift
```

---

## 1. Decisions already made (do not relitigate)

- **Default hotkeys: dictation `⌃⇧`, push-to-talk `⌃⌥`.** Disjoint modifier sets — neither
  is a prefix of the other, so nothing waits on a grace timer and no first syllable is
  clipped. (The *previous* intended defaults ⌃ and ⌃⌥ collide: ⌃ ⊊ ⌃⌥.)
- The engine still **implements** the grace window, because `HotkeyConflictChecker` only
  *warns* on prefix-overlapping holds — the user may deliberately bind them.
- **Hotkey UI lives in the existing native Settings window**, rewritten. Reached via ⌘, and
  the menu-bar panel's "Dictation Settings" row.
- **Dictation ships with one binding** (the ⌃⇧ hold). The old ⌥Space alternate is dropped —
  commit `2f09ab7`'s message says it "wasn't firing", and ⌥Space types a non-breaking space
  in most text fields. The user can add an alternate.

---

## 2. Roster

| Agent | Model / CLI | Owns |
|---|---|---|
| **FOREMAN** | Claude Code, Opus 4.8 | W0 foundation, all merges, wiring, dynamic copy, final regression. Sole editor of `.xcodeproj`, `Info.plist`, `*.entitlements`, `A3BBuddy/App/*`, `Buddy/CompanionManager.swift`, `Settings/Prefs.swift` |
| **ENGINE** | Claude Code, Opus 4.8, **max effort** | `Hotkey/HotkeyEngine.swift` (new) + rewire `Hotkey/HotkeyManager.swift` and `Buddy/GlobalPushToTalkShortcutMonitor.swift` |
| **RECORDER** | Codex CLI (GPT-5.x) | `Settings/HotkeyRecorderView.swift` (new) + the Hotkeys section of `Settings/SettingsView.swift` |
| **PILL** | Claude Code, Sonnet 5, high effort | `Overlay/PillView.swift` + `Overlay/RecordingPanelController.swift` |
| **AUDIT** | Gemini CLI, read-only | Writes only into `verification/`. Never edits source. |

**Why ENGINE gets the strongest model:** CGEventTap lifetime, `Unmanaged` refcon,
`MainActor.assumeIsolated`, timer-cancellation races, and Carbon-consumes-vs-tap-observes
semantics. The failure mode is *typing garbage into the user's documents*. Do not economise.

### Merge-conflict surface

```
ENGINE    Hotkey/HotkeyEngine.swift, Hotkey/HotkeyManager.swift,
          Buddy/GlobalPushToTalkShortcutMonitor.swift
RECORDER  Settings/HotkeyRecorderView.swift, Settings/SettingsView.swift
PILL      Overlay/PillView.swift, Overlay/RecordingPanelController.swift
FOREMAN   Settings/Prefs.swift, App/*, Buddy/CompanionManager.swift
```

Disjoint by construction. No lane touches another's files.

### Worktrees

```bash
git worktree add ../buddy-engine   feature/hotkey-engine
git worktree add ../buddy-recorder feature/hotkey-recorder
git worktree add ../buddy-pill     feature/whisper-pill-ui
```

FOREMAN stays on `merge-clicky-whisper-plan`.

---

## 3. Hard rules (all agents)

1. **Never run `xcodebuild` against the installed app or Xcode's DerivedData** — it kills the
   TCC permission grants. Compile-check only with a throwaway path:
   ```bash
   xcodebuild -project A3BBuddy.xcodeproj -scheme "a3b Buddy" \
     -configuration Debug -destination 'platform=macOS' \
     -derivedDataPath /tmp/<yourname>-dd CODE_SIGNING_ALLOWED=NO build
   ```
   Delete the temp dir after. The user builds/runs with Cmd+R.
2. **Only FOREMAN** edits `.xcodeproj`, `Info.plist`, `A3BBuddy.entitlements`,
   `A3BBuddy/App/*`, `Buddy/CompanionManager.swift`, `Settings/Prefs.swift`. Need a change
   there? Write `verification/wiring-requests/<agent>.md` — what to wire, where
   (`file:symbol`), why, how to verify. FOREMAN applies at merge time.
3. `A3BBuddy/Shared/Contracts.swift` is **frozen**. Stop and ask.
4. `A3BBuddy/` and `A3BBuddyTests/` are Xcode 16 **synced root groups**
   (`project.pbxproj:38-47`) — new files join the target automatically. No `.xcodeproj` edit
   is needed for any file in this plan.
5. Do **not** rename the literal `"a3b-buddy"` where it's a filesystem path —
   `~/Library/Application Support/a3b-buddy/` holds the STT/TTS helpers.
6. Do **not** change the bundle id `com.a3b.buddy`. It re-triggers every permission prompt.
7. Recording pill appears **only** while recording/transcribing. Never idle on screen.
8. All buttons show a pointer cursor on hover — `.pointerCursor()` from `Buddy/DesignSystem.swift`.
9. Don't fix the known non-blocking warnings (Swift 6 concurrency; deprecated `onChange` in
   `OverlayWindow.swift`).

---

## 4. Waves

```
W0  FOREMAN — blocks ENGINE + RECORDER. PILL and AUDIT start immediately.
      port the six salvaged files, adapt migration, add PrefKeys,
      wire HotkeyBindingStore into AppDelegate, stop the Shift bleeding

W1  parallel
      ENGINE    HotkeyEngine + rewire both consumers
      RECORDER  HotkeyRecorderView + SettingsView       (needs W0 types only)
      PILL      PillView 4 states                        (no dependency)
      AUDIT     read-only sweep                          (no dependency)

W2  FOREMAN — merge pill → recorder → engine (low → high risk).
      Unsigned compile-check + Cmd+R eyeball between each.
      Then dynamic copy, delete ModifierOnlyShortcut, update CLAUDE.md, tag v0.3.

W3  DEFERRED — standalone .app. Not until W2 is green.
```

---

## 5. W0 — Foundation (FOREMAN)

One commit. The app must build and behave identically afterwards — new types are added but
nothing consumes them yet.

1. **Stop the bleeding.** `HotkeyManager.swift:243` — fallback default `.shift` →
   `ModifierOnlyShortcut(rawValue: "control+shift")!`. One line. Without it the user's build
   stays unusable while the lanes run.

2. **Port six files** into `A3BBuddy/Hotkey/`, verbatim except:
   - `HotkeyFeature.displayName` — `"Talk to Clicky"` → `"Talk to Buddy"`.
   - `HotkeyFeature.defaultBindings`:
     ```swift
     case .dictation:  [.modifiersOnly([.control, .shift])]
     case .pushToTalk: [.modifiersOnly([.control, .option])]
     ```
   - `HotkeyBindingStore.swift` keeps the `import Combine` that `1c07ada` added.
   - `ShortcutNames.swift` — keep all four Names, keep them **without `default:`**. Load-bearing:
     `Name.init` writes its default into UserDefaults as a side effect at static-init time,
     before `applicationDidFinishLaunching`, and would race the migration.

3. **Rewrite `HotkeyMigration.swift`'s legacy readers.** The salvaged version parses
   `"holdKey"` with an old single-modifier `HoldKey` enum (`"control"`, `"fn"`, `"off"`).
   The **current** branch writes that same key in a multi-modifier format via
   `ModifierOnlyShortcut` (`"control+option"`, `"shift"`, `"off"`). Parse the `+`-joined
   token form; `"off"` ⇒ emit no hold binding. Also read
   `"pushToTalkModifierOnlyShortcut"` instead of blind-seeding push-to-talk.

4. **Migration version 2.** Three populations must all land correctly:

   | Population | Stored state | Required outcome |
   |---|---|---|
   | Fresh install | nothing | seed ⌃⇧ / ⌃⌥ |
   | Ran only `merge-clicky-whisper-plan` | `holdKey` (new format), `pushToTalkModifierOnlyShortcut`, no `hotkey.*` | translate both, respect `"off"` |
   | **This machine** | `hotkeyMigrationVersion = 1`, `hotkey.dictation = [⌃, ⌥Space]`, `hotkey.pushToTalk = [⌃⌥]` | replace the colliding `⌃` hold with `⌃⇧`; leave a customised binding alone |

   `currentVersion = 2`. Keep every v1 write guarded by `defaults.object(forKey:) == nil`.
   Add a v2-only step that rewrites the dictation hold **only if** the stored bindings are
   exactly the v1 default pair `[.modifiersOnly(⌃), .keyCombo(Space, ⌥)]`. Anything else is
   the user's choice — untouched.

5. **`Prefs.swift`** — add `dictationBinding = "hotkey.dictation"`,
   `pushToTalkBinding = "hotkey.pushToTalk"`,
   `hotkeyMigrationVersion = "hotkeyMigrationVersion"`.
   **Keep `ModifierOnlyShortcut`** for now — the old `HotkeyManager` and
   `GlobalPushToTalkShortcutMonitor` still read it until ENGINE lands. Deleted in W2.

6. **`AppDelegate.swift`** — declared *before* `private let hotkeys = HotkeyManager()`:
   ```swift
   /// Declaration order is init order. Constructing the store runs HotkeyMigration,
   /// which must finish before HotkeyManager touches the KeyboardShortcuts.Name statics.
   let hotkeyBindings = HotkeyBindingStore.shared
   ```

7. **Port `HotkeyConflictTests.swift`** to `A3BBuddyTests/`, swapping
   `@testable import Whisper` → `@testable import A3BBuddy`.

**Exit:** unsigned build green; tests green; Cmd+R → dictation holds ⌃⇧, capitals type
normally, no phantom pastes; `defaults read com.a3b.buddy` shows `hotkeyMigrationVersion = 2`
and `hotkey.dictation` = ⌃⇧.

---

## 6. W1·A — ENGINE (Opus 4.8, max effort)

**Goal:** one listen-only CGEventTap replaces today's two, and both features read their
triggers from `HotkeyBindingStore`.

### New `A3BBuddy/Hotkey/HotkeyEngine.swift`

- Single `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
  options: .listenOnly, …)` on `CFRunLoopGetMain()`. Mask:
  `flagsChanged | keyDown | leftMouseDown | rightMouseDown | otherMouseDown`.
  Re-enable on `.tapDisabledByTimeout` / `.tapDisabledByUserInput`.
- Matches **only** `.modifiersOnly` bindings. `.keyCombo` bindings are *never* tap-matched:
  Carbon consumes those keystrokes, a tap only observes, so tap-matching a combo would type
  the character into whatever field the user is dictating into. (Spelled out at the top of
  the salvaged `HotkeyBinding.swift`.)
- Exact-modifier-set match against `HotkeyBinding.recognizedModifiers`
  (`.control, .option, .shift, .command, .function`) — everything else in `CGEventFlags`
  (caps lock, numeric pad, left/right device bits, `.maskNonCoalesced`) is noise.
- **Grace window.** When binding X is a strict subset of another feature's binding Y, X must
  not fire immediately — pressing Y passes through X. Delay X's `pressed` by ~200 ms; cancel
  the pending fire if Y becomes exact within the window. Dormant with the ⌃⇧ / ⌃⌥ defaults,
  but `HotkeyConflictChecker` only *warns* on such pairs, so a user can still create one.
  Specify timer ownership and cancellation precisely.
- Per-feature policy read from `HotkeyFeature`, never branched inline: `supersetPolicy`
  (`.abort` dictation / `.release` pushToTalk), `cancelsOnOtherKeyDown`, `cancelsOnMouseDown`.
- Combo path: `KeyboardShortcuts.onKeyDown/onKeyUp` for all four Names.
- Live rebind: observe `HotkeyBindingStore.$bindings`. Tear the tap down entirely when
  `store.needsInputMonitoring == false` (a combo-only setup needs zero permissions).
- Emit a per-feature `pressed` / `released` / `cancelled` stream; both adapters subscribe.

### Rewire the two consumers

- **`HotkeyManager.swift`** — deletes its tap, its fallback `NSEvent` monitors, its
  `handleFlagsChanged`, and `currentModifierOnlyShortcut`. **Keeps its public contract
  exactly:** `onStartRecording`, `onStopAndTranscribe`, `onCancel`, `onLockChange`,
  `cancelFromButton()`, `confirmFromButton()`, the 0.35 s double-tap hands-free lock, Esc
  cancel, 5-minute hard stop.
- **`GlobalPushToTalkShortcutMonitor.swift`** — deletes its tap. **Keeps**
  `shortcutTransitionPublisher: PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>`
  and `@Published isShortcutCurrentlyPressed` byte-for-byte. `CompanionManager` depends on both.

### ⚠️ Permission-gating trap

Today the two taps are gated on **different** permissions. Whisper's on Input Monitoring
(`Permissions.inputMonitoringGranted`). Buddy's is started/stopped by `CompanionManager`'s
**Accessibility** poller (`CompanionManager.swift:248-252`), which calls `start()`/`stop()`
every few seconds.

After unification the tap is created on Input Monitoring, and PTT's `start()`/`stop()` must
become an **enable/disable flag on the PTT subscription**, not a tap teardown. Otherwise the
Accessibility poller rips the tap out from under dictation on a loop, and it will look like
a flaky tap.

### Tests

Make the event source a protocol so `HotkeyEngineTests` can feed synthetic `flagsChanged`
sequences — no TCC, no tap, no app launch. Cover: exact match; superset abort vs release;
grace-window fire and grace-window cancel; keyDown cancel; mouseDown cancel; live rebind;
teardown when no hold binding remains.

**May not edit** `Buddy/CompanionManager.swift`, `App/*`, `Shared/Contracts.swift`.
Anything needed there → `verification/wiring-requests/engine.md`.

**Exit:** bind an arbitrary combo and an arbitrary bare-modifier hold to each feature; both
fire; rebinding is live with no restart; typing a paragraph full of capitals records nothing;
⌃C in another app reaches that app untouched; PTT still drives the cursor overlay.

---

## 7. W1·B — RECORDER (Codex CLI)

**Goal — the approved Settings layout:**

```
Settings ▸ Hotkeys
┌──────────────────────────────┐
│ Dictation                    │
│   Primary    [ ⌃⇧      ] ⌫  │
│   Alternate  [ Record… ]     │
│                              │
│ Talk to Buddy                │
│   Primary    [ ⌃⌥      ] ⌫  │
│   Alternate  [ Record… ]     │
│                              │
│ ⚠ ⌃ is the start of ⌃⌥ …     │
│                [Reset all]   │
└──────────────────────────────┘
```

### New `A3BBuddy/Settings/HotkeyRecorderView.swift`

An `NSViewRepresentable` over a custom `NSView` that becomes first responder while recording
and swallows `keyDown(with:)`, `flagsChanged(with:)`, `performKeyEquivalent(with:)`.

- **Capture rule.** While recording: a `keyDown` carrying a non-empty recognized modifier set
  (or a function key) ⇒ `.keyCombo(keyCode:modifiers:)`. Modifiers pressed and then **fully
  released with no keyDown in between** ⇒ `.modifiersOnly(thatMaximalSet)`. This is the whole
  reason a custom view is needed — `KeyboardShortcuts.Recorder` cannot record a bare modifier.
- Esc = abandon recording. ⌫ / ⌦ = clear the binding (`store.setBinding(nil, at:for:)`).
- Live feedback via
  `HotkeyConflictChecker.evaluate(candidate, for: feature, slot: slot, against: store.bindings)`:
  - `.warn` → orange caption, save allowed.
  - `.block` → red caption, `NSSound.beep()`, keep focus, refuse to save.
- Renders `binding.displayString` (`⌃⇧`, `⌥Space`, `fn`) when idle.
- `.pointerCursor()` on every button (hard rule 8).

### Rewrite the Hotkeys section of `SettingsView.swift` (`:36-81`)

Two feature groups × two slots, each a recorder + clear button; the conflict caption; a
"Reset all hotkeys" button (`store.resetToDefaults()`); the Input Monitoring grant row shown
iff `store.needsInputMonitoring && !Permissions.inputMonitoringGranted` (reuse
`Permissions.requestInputMonitoring()` / `openInputMonitoringSettings()`).

**Delete:** both `KeyboardShortcuts.Recorder`s, both `ModifierOnlyShortcut` `Picker`s,
`enforceKeyboardShortcutConflicts()` (`:178-211`),
`enforceModifierOnlyShortcutConflicts(changed:)` (`:213-241`), and the four `accepted*`
`@State` caches (`:22-25`). `HotkeyConflictChecker` replaces all of it.

Leave Speech model / Microphone / General untouched. Bind to `HotkeyBindingStore.shared`
(`@ObservedObject`; it's a `@MainActor ObservableObject` with `@Published bindings`).

**Does not touch** `HotkeyManager.swift`, `GlobalPushToTalkShortcutMonitor.swift`,
`HotkeyEngine.swift`, `Prefs.swift`, or `App/*`. It calls only `HotkeyBindingStore` +
`HotkeyConflictChecker`, both landed in W0 — so this lane never blocks on ENGINE.

**Exit:** record ⌘⇧D for dictation → saves and displays. Record a bare `fn` hold → saves,
orange caption about the emoji picker. Try to give dictation ⌃⌥ while push-to-talk owns it →
red caption, beep, refused. Clear a binding → "Record…". Reset all → ⌃⇧ / ⌃⌥.

---

## 8. W1·C — PILL (Sonnet 5, high effort)

**Goal:** `Overlay/PillView.swift` matches the four images in `reference/` exactly. The pill
appears **only** while recording or transcribing (hard rule 7).

| Image | State | Shows |
|---|---|---|
| `holding hotkey mode.png` | `.recording`, silent, unlocked | dark capsule, centred row of small white **dots** |
| `talking mode.png` | `.recording` with audio | same capsule, centred white **EQ bars** |
| `hands-free mode.png` | `.recording` + `controls.isHandsFreeLocked` | left **dark-grey circle, white ✕**; centre dots; right **white circle, dark ✓** |
| `loading ui.png` | `.transcribing` | centre dots + right-side **radial spoke spinner** |

`reference/*.png` are byte-identical to `docs/reference/whisper-pill/*.png` (sha1-verified).

- The hands-free surface is **already live**. `Overlay/RecordingControls.swift` is an
  `ObservableObject` already passed into `PillView(engine:controls:)`:
  `controls.isHandsFreeLocked` gates the ✕/✓; ✕ calls `controls.onCancel()`; ✓ calls
  `controls.onConfirm()`. `RecordingPanelController.swift:31-33` already flips
  `ignoresMouseEvents` off exactly while locked. **Today `PillView` declares `controls` and
  never reads it — that's the whole gap.**
- **Drop the red recording dot** (`PillView.swift:49-53`) and the "Transcribing" text label
  (`:78-80`). Neither appears in any reference image.
- **The resting dots must animate.** Today the waveform advances only inside
  `.onChange(of: engine.audioLevel)` (`:37-40`), so a silent pill is frozen — the 3 pt floor
  in `barHeight` (`:69`) merely makes it *look* like dots. Add a `TimelineView(.animation)`
  idle pulse. Working reference at `Buddy/OverlayWindow.swift:704-738`
  (`A3BBuddyWaveformView`, `idlePulse = (sin(phase) + 1) / 2 * 1.5`).
- **Spinner:** port `A3BBuddySpinnerView` (`Buddy/OverlayWindow.swift:744-769` — trimmed
  `Circle` + `AngularGradient`, 0.8 s linear `repeatForever`). It's `private` to that file
  and wine-coloured; make a white variant local to `PillView.swift` rather than editing
  `OverlayWindow.swift`.
- ⚠️ **Geometry trap.** `220 × 44` is hard-coded in **two** places: `PillView.swift:33` and
  `RecordingPanelController.swift:60`. Hands-free adds ✕ and ✓ (~72 pt). Either make the panel
  size-to-fit its `NSHostingView` and animate the frame on lock change, or reserve the button
  width in all states. **Change both, or the hosting view clips.**
- Adopt `DS.` tokens from `Buddy/DesignSystem.swift` where they fit (`DS.CornerRadius.pill`,
  `DS.Animation.fast`). The pill currently uses raw `.black` / `.white` / `.red`.
- One `#Preview` per state. The existing "Hands-free" preview (`:99`) is a lie — it renders
  identically to "Recording".

**Do not edit** `RecordingControls.swift`, `HotkeyManager.swift`, `Shared/Contracts.swift`,
`App/*`. `RecordingPanelController.swift` **is** yours.

**Exit:** four states pixel-close to the references; ✕ discards and ✓ transcribes in
hands-free; no pill at idle; no clipping when the pill widens; four `#Preview`s. Post
before/after screenshots.

---

## 9. W1·D — AUDIT (Gemini CLI, read-only)

Writes **only** into `verification/`. Never edits source.

1. **`verification/v3-regression.md`** — the manual matrix FOREMAN runs at W2: dictation
   hold/release/paste; double-tap hands-free → ✕ and ✓; Esc cancel; 5-min stop; ⌃C
   passthrough; typing capitals records nothing; push-to-talk → STT → Claude → TTS → cursor
   points; rebind both, relaunch, bindings persist; conflict warn vs block; one menu-bar
   icon; no idle pill; no permission re-prompt.
2. **Stale-copy sweep.** These hardcode ⌃⌥ and go wrong the moment the user rebinds:
   - `Buddy/CompanionPanelView.swift:184` — `Text("Hold Control+Option to talk.")`
   - `Buddy/CompanionManager.swift:794` — `"press control + option and introduce yourself"` (FOREMAN-only file)
   - `Buddy/OverlayWindow.swift:217` — comment only
   - `CLAUDE.md:32` — still says "dictation = hold ⌃ (or ⌥Space combo)"
   - `verification/wiring-requests/gpt-1.md` item 5 — already open, same issue
3. **Dead-code report** (report, do not remove): `ModifierOnlyShortcut.keyCapsuleLabels`
   (`Prefs.swift:138`, zero call sites) · `CompanionResponseOverlayManager` (whole file,
   self-referential only) · `speechToTextProviderRow` and
   `permissionRow(label:iconName:isGranted:settingsURL:)` in `CompanionPanelView.swift`
   (never called) · `showA3BCursorToggleRow` (commented out at `:58-65`).
4. **Bug to confirm:** `RealDictationEngine.swift:150-151` says "failure shows on the pill
   briefly", but `RecordingPanelController.swift:37-42` orders the panel *out* on `.failed`.
   The error state is unreachable. Decide with FOREMAN whether the pill gets a fifth state or
   the comment goes.

---

## 10. W2 — Merge + wiring (FOREMAN)

Merge low-risk → high-risk: **pill → recorder → engine.** Unsigned compile-check and a Cmd+R
eyeball between each.

- Apply each lane's `verification/wiring-requests/*.md`.
- **Dynamic copy.** Replace the hardcoded strings with
  `HotkeyBindingStore.shared.bindings(for: .pushToTalk).first?.displayString ?? "your push-to-talk key"`
  in `CompanionPanelView.swift:184` and `CompanionManager.swift:794`. Closes `gpt-1.md` item 5.
- **Delete `ModifierOnlyShortcut`** from `Prefs.swift`, plus the legacy `holdKey` /
  `pushToTalkModifierOnlyShortcut` constants once `HotkeyMigration` is their only reader.
- Update `CLAUDE.md` — the hotkey-defaults line, and the "two listen-only CGEventTaps coexist"
  paragraph, which is no longer true.
- Tag `v0.3` on green.

---

## 11. W3 — Standalone `.app` (DEFERRED — do not start)

Documented so it isn't rediscovered. **Gated on W2 being green.**

1. Release archive → `Product ▸ Archive`.
2. **Developer ID Application** certificate; sign with hardened runtime
   (`codesign --options runtime`) — entitlements already carry mic/camera/network, sandbox off.
3. Notarise: `xcrun notarytool submit --wait`, then `xcrun stapler staple`.
4. Package: DMG or zip.
5. Sparkle auto-update — `Info.plist` already carries the feed key (`SUFeedURL`); the appcast
   needs hosting.
6. `LSUIElement` and login-item registration (`AppDelegate.registerAsLoginItemIfNeeded()`) are
   already in place.

Steps 2–3 need an Apple Developer account ($99/yr), and only matter if the app is handed to
someone else. For local use, a Release build copied to `/Applications` works — it just
re-triggers every permission prompt once.

---

## 12. End-to-end verification (after W2)

Cmd+R, then:

1. **The original bug is dead.** Open TextEdit. Type `Hello World` with real capitals. No
   pill, nothing recorded, nothing pasted.
2. **Dictation.** Hold ⌃⇧, speak, release → bars while talking, dots while silent, spinner
   while transcribing → text pastes.
3. **Hands-free.** Double-tap ⌃⇧ → pill widens, ✕ and ✓ appear. ✓ transcribes. ✕ discards.
   Esc also cancels.
4. **Push-to-talk.** Hold ⌃⌥, ask Buddy something → cursor waveform → spinner → spoken answer
   → triangle points. Dictation must **not** fire.
5. **Rebinding.** Settings ▸ Hotkeys. Record ⌘⇧D for dictation → fires immediately, no
   restart. Record bare `fn` → orange caption, works. Give dictation ⌃⌥ → red caption + beep,
   refused. Reset all → ⌃⇧ / ⌃⌥.
6. **Persistence.** Quit, relaunch. Bindings survive.
   `defaults read com.a3b.buddy | grep hotkey` → `hotkeyMigrationVersion = 2`.
7. **Passthrough.** With dictation on ⌃⇧: ⌃C in Terminal still interrupts; ⌃-click still
   right-clicks.
8. **Unit tests.** `HotkeyConflictTests` (ported) + `HotkeyEngineTests` (new, synthetic event
   source) pass — no TCC, no tap, no app launch.

---

## 13. Risks

- **An event-tap bug pastes garbage into the user's documents.** The reason ENGINE gets Opus
  at max effort plus a synthetic-event test harness. Verification step 1 exists to catch it.
- **The Accessibility poller vs. the unified tap** (`CompanionManager.swift:248-252`). §6. Get
  it wrong and dictation dies every few seconds, looking like a flaky tap.
- **Migration on the owner's machine.** `hotkeyMigrationVersion` is already `1` with the old
  colliding ⌃ default stored. Skip the v2 step and the grace-window path silently becomes
  load-bearing.
- **Panel geometry.** Two hard-coded `220 × 44`s. Miss one and the hands-free ✕/✓ clip.
- **TCC grants.** No lane may run `xcodebuild` against the installed app or Xcode's
  DerivedData. Throwaway `-derivedDataPath` with `CODE_SIGNING_ALLOWED=NO` only.

---

## 14. Wiring-request protocol

Non-foreman agents needing a change in `.xcodeproj`, `Info.plist`, entitlements, `App/*`,
`CompanionManager.swift`, or `Prefs.swift` drop `verification/wiring-requests/<agent>.md`:
what to wire, where (`file:symbol`), why, how to verify. FOREMAN applies at merge time.
