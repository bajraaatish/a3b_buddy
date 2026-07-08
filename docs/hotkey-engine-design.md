# HotkeyEngine — design brief for the ENGINE lane

Read `BUDDY-V3-PLAN.md` §6 first. This is the detail behind it, from a dedicated
architecture pass. **Corrections applied after the pass are marked ✅ VERIFIED or
⚠️ CORRECTED** — the pass got two things wrong.

W0 has landed. The value types, store, migration, and tests are on
`merge-clicky-whisper-plan`. Your job is `HotkeyEngine` and the two adapters.

---

## 0. Facts established (don't re-derive)

**✅ The two CGEventTaps can safely become one.** TCC gates event taps per
*process*, not per tap. A listen-only keyboard tap at `.cgSessionEventTap` is
admitted if the process holds **either** Accessibility **or** Input Monitoring.
Both taps live in one process, so today's split gate — Whisper on
`Permissions.inputMonitoringGranted` (`HotkeyManager.swift:74`), Buddy on
`CompanionManager`'s Accessibility poller (`CompanionManager.swift:248-252`) — is
an app-level *lifecycle policy* wearing a permission gate's clothes.

What the split genuinely buys is **delivery gating**: revoking Accessibility stops
push-to-talk while dictation keeps working. Preserve that by moving the gate one
layer down:

| Concern | Today | After |
|---|---|---|
| Tap **creation** | two taps, two gates | one tap, gated on `store.needsInputMonitoring && Permissions.eventTapPermitted`; `tapCreate == nil` is authoritative |
| Tap **lifetime** | Buddy's torn down/recreated by a 1.5 s poller | owned solely by `HotkeyEngine`; torn down only when `needsInputMonitoring == false` |
| **Delivery** to PTT | implied by tap existence | `GlobalPushToTalkShortcutMonitor.isEnabled`, flipped by `start()` / `stop()` |

Add to `Shared/Permissions.swift`:
```swift
/// A listen-only keyboard event tap is admitted with EITHER grant.
static var eventTapPermitted: Bool { inputMonitoringGranted || accessibilityGranted }
```

This deletes the hack at `GlobalPushToTalkShortcutMonitor.swift:122-132` ("don't
restart the tap or the poller kills the waveform mid-press"). With `start()`
reduced to `isEnabled = true`, the poller physically cannot interrupt a press.
`CompanionManager` is never touched.

**✅ `HotkeyManager.swift:149-169`'s `NSEvent.addGlobalMonitorForEvents` fallback
is dead code.** Global keyboard/flagsChanged monitors need the same TCC grant as
the tap. It fires exactly when the tap would have worked. Delete it; keep the
Settings grant CTA. This is a comment change, not a behaviour change — say so in
the commit message, because the current comments promise otherwise.

**⚠️ CORRECTED — build command.** The pass recommended `-target "a3b Buddy"` over
`-scheme`, claiming no shared scheme exists. There is indeed no shared scheme
(`xcuserdata/` is gitignored), **but `xcodebuild` autocreates one, and
`-target` cannot be combined with `-derivedDataPath`** (it errors: "The flag
-scheme, -testProductsPath, or -xctestrun is required"). Verified working from a
clean worktree:
```bash
xcodebuild -project A3BBuddy.xcodeproj -scheme "a3b Buddy" \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/engine-dd CODE_SIGNING_ALLOWED=NO build
```

**⚠️ CORRECTED — concurrency.** `SWIFT_VERSION = 5.0` and
`SWIFT_STRICT_CONCURRENCY` is unset (i.e. `minimal`) in `project.pbxproj`.
`CLAUDE.md`'s "Swift 6 concurrency warnings" is about
`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`, not strict concurrency. Don't
plan around diagnostics that won't appear.

**✅ Migration is done and tested.** `HotkeyMigration` is at `currentVersion = 2`
with 12 passing population tests in `A3BBuddyTests/HotkeyMigrationTests.swift`.
Don't touch it. In particular the old `HoldKey(rawValue:) ?? .control` bug — which
silently turned a user's `"shift"` and `"control+option"` into `⌃` — is fixed and
regression-tested.

---

## 1. Delete this when you land

`A3BBuddy/Hotkey/HotkeyBindingBridge.swift` is a temporary shim. Settings edits
`HotkeyBindingStore`, but the old matchers read the legacy `ModifierOnlyShortcut`
defaults keys, so without it rebinding a hotkey does nothing. The bridge points
the old matchers at the new store. When `HotkeyEngine` replaces both matchers,
delete the bridge, delete `ModifierOnlyShortcut` from `Settings/Prefs.swift`, and
delete `ModifierOnlyShortcut(flags:)`.

---

## 2. The grace window, and why it needs an `armed` / `pressed` split

With the shipped defaults (dictation `⌃⇧`, push-to-talk `⌃⌥`) the sets are
**disjoint**, so `isAmbiguous` is false for both and **this entire path is
dormant**. It exists because `HotkeyConflictChecker` only *warns* about
prefix-overlapping holds — a user can deliberately bind `⌃` and `⌃⌥`.

When binding X is a strict subset of another feature's binding Y, pressing Y emits
`flagsChanged(X)` then `flagsChanged(Y)` ~20–80 ms apart. Exact-set matching means
X's feature sees `.exact` first, every time. X must wait ~200 ms.

But `AudioRecorder` has **no ring buffer** — `start()` installs the tap and samples
accumulate from that moment (`AudioRecorder.swift:61-72`). A naive 200 ms delay
before `startRecording()` clips 200 ms of audio, violating "no dropped
first-syllable on record."

Resolution: **starting the mic is not the same as committing to a session.**

- `.armed(f)` at **t = 0**, zero latency. `RealDictationEngine.prewarmRecording()`
  starts `AudioRecorder`, captures the frontmost app, records `armedAt`, leaves
  `state == .idle`. No pill, no `NSSound("Tink")`, no `DictationState` change.
- `.pressed(f)` at **t = graceInterval** (or immediately when unambiguous).
  `startRecording()` sees `recorder.isRecording == true`, skips `recorder.start()`
  (already guarded at `AudioRecorder.swift:43`), plays the cue, sets
  `state = .recording(startedAt: armedAt)`.
- `.disarmed(f)` → `discardPrewarm()` → `recorder.cancel()` iff still `.idle`.

**The 200 ms recorded during the grace window is kept.** Backdating `startedAt` to
`armedAt` keeps the pill's elapsed timer honest;
`stopAndTranscribe()`'s `duration = samples.count / 16000`
(`RealDictationEngine.swift:85`) is already sample-derived. `AudioRecorder` needs
zero changes.

This is *strictly better than today*, where `recorder.start()` runs at press time
and the ~20–150 ms of `AVAudioEngine.start()` latency is lost audio.

### Ambiguity is a property of the binding set

```swift
func isAmbiguous(_ binding: HotkeyBinding) -> Bool {
    guard binding.isModifiersOnly else { return false }
    return allModifierOnlyBindings.contains {
        $0 != binding && binding.modifierFlags.isStrictSubset(of: $0.modifierFlags)
    }
}
```
`.keyCombo` never participates: `HotkeyConflictChecker`'s `(.keyCombo, .modifiersOnly)`
rule *blocks* any combo whose modifiers are a superset of an existing hold.

### Timer ownership

One `DispatchWorkItem` per feature in `graceTimers[HotkeyFeature]`, scheduled with
`DispatchQueue.main.asyncAfter`.

**Not `Timer.scheduledTimer`.** `Timer` attaches to `.default` run-loop mode and
stalls during menu tracking and live window resize. The tap's run-loop source is
added with `.commonModes` (`HotkeyManager.swift:114`), so the tap fires during a
menu track — a `Timer`-backed grace window would never fire, and dictation would
silently never start with a menu open. (`HotkeyManager.swift:363`'s 5-minute
`Timer` has the same latent bug; 5-minute tolerance hides it. Swap it while you're
in there.)

### The three ways a grace window terminates

1. **Deadline elapses** → commit. `pressed`.
2. **Flags become a superset** → the chord won. `cancelGrace`, `disarmed`, `suppressed = true`.
3. **Flags drop below the binding** → **flush**. A release *proves* it was never a
   chord: you cannot reach `⌃⌥` by letting go of `⌃`. Commit and immediately release.

```swift
case (.pending(b), .none):
    o.cancelGrace(f)
    phase[f] = .held(b, .modifierHold)
    o.pressed(f, .modifierHold)     // ← the flush
    o.released(f)
    phase[f] = .idle
    suppressed[f] = false
```

**Flush-on-release is mandatory, not an optimisation.** Without it, any press
shorter than 200 ms emits nothing, and `HotkeyManager`'s double-tap hands-free lock
(`tapWindow = 0.35 s`, `HotkeyManager.swift:36, 271-276`) becomes unreachable: both
taps would have to be held 200–349 ms. Name the test
`flushOnReleaseKeepsDoubleTapLockReachable`.

---

## 3. Event ordering across features

`Outcome.events` is built in **two passes over the features**, never sorted:

- **Pass 1 — terminations** (`.none` / `.superset` / keyDown / mouseDown):
  emits `disarmed`, `released`, `cancelled`.
- **Pass 2 — initiations** (`.idle → .exact`): emits `armed`, `pressed`.

That single rule guarantees the losing subset's `.disarmed` reaches
`RealDictationEngine.discardPrewarm()` **before** the winning superset's `.pressed`
reaches `BuddyDictationManager` — so the two `AVAudioEngine`s never contend for the
input node. Keep `discardPrewarm()` synchronous.

---

## 4. State machine

```swift
enum Phase: Equatable {
    case idle
    case pending(HotkeyBinding)                    // armed, grace timer running
    case held(HotkeyBinding, HotkeyTriggerSource)  // committed
}
struct FeatureState: Equatable { var phase: Phase = .idle; var suppressed = false }
```

`suppressed` is the engine-side home of `HotkeyManager.holdSuppressedUntilReleased`
(`:52`). macOS coalesces near-simultaneous modifier presses: slamming `⌃⌥` together
can produce one `flagsChanged(⌃⌥)`, so a `⌃` binding never sees `.exact`. When `⌥`
is later lifted (flags → `⌃`), `.exact` arrives and must **not** fire. `suppressed`
clears only on full release.

`flagsChanged(M)`, per feature:

| Phase | Match | Pass | Action | Events |
|---|---|---|---|---|
| any | `.none` | 1 | `.pending` → cancelGrace; `.held(_, .modifierHold)` → end. → `.idle`, `suppressed = false` | `.disarmed` / `.released` |
| `.pending(b)` | `.none` | 1 | **flush** | `.pressed`, `.released` |
| `.idle`, `!suppressed` | `.exact(b)` | 2 | `isAmbiguous(b)` ? `.pending(b)` + scheduleGrace : `.held(b, .modifierHold)` | `.armed` [, `.pressed`] |
| `.idle`, `suppressed` | `.exact(b)` | — | nothing | — |
| `.pending(b)` / `.held(b,_)` | `.exact(b)` | — | duplicate (tap + local monitor) | — |
| `.pending(b)` | `.superset` | 1 | cancelGrace, `.idle`, `suppressed = true` | `.disarmed` |
| `.held(b, .modifierHold)` | `.superset` | 1 | `.idle`, `suppressed = true`, apply `feature.supersetPolicy` | `.cancelled(_, .supersetModifier)` if `.abort`; `.released` if `.release` |
| `.held(_, .keyCombo)` | anything | — | a Carbon combo owns the session | — |
| `.idle` | `.superset` | 1 | `suppressed = true` | — |

`otherKeyDown(k)`, for features with `cancelsOnOtherKeyDown`:
```
if k == kVK_Escape && f.cancelsOnEscape:
    // Esc must reach a LOCKED session, which the engine can't see (phase .idle).
    // Emit .escapePressed LAST; do NOT also emit .cancelled(.otherKeyDown).
    deferred.append(.escapePressed(f))
    if .pending: cancelGrace; .disarmed; .idle; suppressed = true
else:
    if .pending: cancelGrace; .disarmed; .idle; suppressed = true
    if .held(_, .modifierHold): .cancelled(f, .otherKeyDown); .idle; suppressed = true
o.events += deferred
o.consumesEvent = (k == kVK_Escape) && escapeCancelsActiveSession.values.contains(true)
```
`mouseDown`: same shape, gated on `f.cancelsOnMouseDown`.

`HotkeyFeature` gains exactly one property:
```swift
/// Whisper's Esc kills the recording even in hands-free lock.
/// Push-to-talk has no Esc affordance.
var cancelsOnEscape: Bool { self == .dictation }
```

The machine **enforces one trigger per feature at a time** — a `.exact` flags match
while `.held(_, .keyCombo)` is dropped, and a `comboKeyDown` while
`.held(_, .modifierHold)` is dropped. That makes `.pressed` and
`.released`/`.cancelled` exactly balanced per feature, which is the invariant that
lets both adapters delete their source tracking:
`HotkeyManager.holdSessionActive` (`:51, 256, 260`) and
`GlobalPushToTalkShortcutMonitor.ActiveShortcutSource` (`:19-22, 236-250`).

---

## 5. Public API

```swift
enum HotkeyTriggerSource: Equatable, Sendable { case modifierHold, keyCombo }

enum HotkeyCancelReason: Equatable, Sendable {
    case supersetModifier, otherKeyDown, mouseDown, bindingsChanged, monitoringStopped
}

enum HotkeyEvent: Equatable, Sendable {
    case armed(HotkeyFeature)       // t=0, always. Warm the mic. Show nothing.
    case disarmed(HotkeyFeature)    // the arm lost. Discard what `armed` warmed.
    case pressed(HotkeyFeature, HotkeyTriggerSource)
    case released(HotkeyFeature)
    case cancelled(HotkeyFeature, HotkeyCancelReason)
    case escapePressed(HotkeyFeature)  // phase-independent; always last of its outcome
    var feature: HotkeyFeature { … }
}

@MainActor
final class HotkeyEngine {
    static let shared = HotkeyEngine(store: .shared)
    static let graceInterval: TimeInterval = 0.2

    let events = PassthroughSubject<HotkeyEvent, Never>()
    @Published private(set) var isEventTapActive = false

    init(store: HotkeyBindingStore,
         tapSource: HotkeyEventSource = CGEventTapSource(),
         localSource: HotkeyEventSource? = LocalMonitorSource(),
         graceInterval: TimeInterval = HotkeyEngine.graceInterval,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> HotkeyCancellable = mainQueueSchedule)

    /// Idempotent. MUST be called from applicationDidFinishLaunching, AFTER both
    /// adapters have subscribed — PassthroughSubject drops events with no subscriber.
    func start()
    func stop()
    func isHeld(_ feature: HotkeyFeature) -> Bool
    func releaseIfHeld(_ feature: HotkeyFeature, reason: HotkeyCancelReason)
    func setEscapeCancelsActiveSession(_ active: Bool, for feature: HotkeyFeature)
}
```

Event-source seam — the only file importing CoreGraphics:
```swift
enum HotkeyRawEvent: Equatable { case flags(NSEvent.ModifierFlags), keyDown(UInt16), mouseDown }
enum HotkeyEventDisposition { case pass, consume }

@MainActor
protocol HotkeyEventSource: AnyObject {
    var onEvent: ((HotkeyRawEvent) -> HotkeyEventDisposition)? { get set }
    func enable() -> Bool          // false ⇒ TCC denied / tapCreate returned nil
    func disable()
    func currentFlags() -> NSEvent.ModifierFlags   // resync after .tapDisabledByTimeout
}
```
`CGEventTapSource` ignores the disposition (listen-only). `LocalMonitorSource`
honours it — that's how Esc keeps getting swallowed inside Buddy's own windows,
replacing `HotkeyManager.swift:186-192`.

---

## 6. Adapter rewiring

### `HotkeyManager`

**Delete:** `:49-58` (hold + tap state), `:61-62` (the `KeyboardShortcuts.onKeyDown/onKeyUp(for: .dictation)`
registration — the engine is now the sole registrar; `legacyKeyDownHandlers` is
append-only and can never be removed, so a duplicate registration double-fires
`keyDown()`), `:63-65`, `:68-262`, `:338-357`.

**Keep verbatim:** `:27-32` (the four closures), `:36-37`, `:39-47`, `:266-336`
(`keyDown`, `keyUp`, `finish`, `cancel`, `cancelFromButton`, `confirmFromButton`,
`reset`), `:359-367` (swap `Timer` → `DispatchWorkItem`).

**Add:**
```swift
/// Fired the instant a bare-modifier dictation hold goes down, before the engine
/// has decided whether it's a press or the prefix of a chord. Warm the mic; show nothing.
var onArm: () -> Void = {}
var onDisarm: () -> Void = {}
```

```swift
private func handle(_ event: HotkeyEvent) {
    switch event {
    case .armed:    onArm()
    case .disarmed: onDisarm()
    case .pressed:  keyDown()
    case .released: guard !isLocked else { return }; keyUp()
    case .cancelled:
        // Locked hands-free ignores superset/otherKeyDown/mouseDown, exactly as
        // today's `holdSessionActive, !isLocked` guards did (:232, :348, :355).
        guard !isLocked else { return }
        cancel()
    case .escapePressed: cancel()   // honoured even when locked (:341-346)
    }
}
```
Call `engine.setEscapeCancelsActiveSession(isActive, for: .dictation)` from
`keyDown` / `reset`.

### `GlobalPushToTalkShortcutMonitor`

Mark `@MainActor` (safe: `CompanionManager` is `@MainActor`). **Drop `deinit`**
(`:44-49`) — a `@MainActor` class can't call MainActor methods from `deinit`, and
`CompanionManager.stop()` already calls `stop()` (`:226`).

**Delete:** `:19-34`, `:63-215`, `:263-271`.
**Keep byte-for-byte:** `:17` `shortcutTransitionPublisher`, `:36` `@Published isShortcutCurrentlyPressed`.

```swift
/// Idempotent. Called every 1.5 s by CompanionManager's accessibility poller
/// (:249-252). Deliberately does NOT touch the event tap — that is what made
/// :122-132's "don't restart or you kill the waveform" hack necessary.
func start() { isEnabled = true }

func stop() {
    isEnabled = false
    engine.releaseIfHeld(.pushToTalk, reason: .monitoringStopped)
    publishReleaseIfNeeded()
}
```
`pushToTalk.supersetPolicy == .release`, so the engine already converts a superset
into `.released`, preserving `:229-231`. `CompanionManager` compiles untouched.

### `RealDictationEngine` — two additive methods

```swift
private var armedAt: Date?

/// Never prompts for mic access: a permission sheet on a bare hold is hostile.
func prewarmRecording() {
    guard case .idle = state, !recorder.isRecording,
          Permissions.micStatus == .authorized else { return }
    captureTargetApp()
    try? recorder.start(preferredDeviceUID: UserDefaults.standard.string(forKey: PrefKey.preferredMicID) ?? "")
    armedAt = recorder.isRecording ? .now : nil
}

func discardPrewarm() {
    guard case .idle = state, recorder.isRecording else { return }
    recorder.cancel()
    armedAt = nil
}
```
`beginCapture()` (`:131-148`): skip `recorder.start()` when already recording;
`state = .recording(startedAt: armedAt ?? .now)`; clear `armedAt`. `cancel()`
(`:122-127`) clears `armedAt`.

These are **concrete methods, not protocol members** — `Shared/Contracts.swift`
stays frozen. Mirror them as no-ops in `Mocks.MockDictationEngine` so
`typealias ActiveEngine` can still flip.

`AppDelegate.wireHotkeys()` (foreman-only — file a wiring request):
```swift
hotkeys.onArm    = { [weak self] in self?.engine.prewarmRecording() }
hotkeys.onDisarm = { [weak self] in self?.engine.discardPrewarm() }
```
plus `HotkeyEngine.shared.start()` in `applicationDidFinishLaunching`, **after**
`companionManager` exists.

---

## 7. Tests

Seams: `HotkeyStateMachine` (pure), `HotkeyMatchTable` (pure), the `schedule:`
closure (injectable clock — fire the deadline synchronously, no `Task.sleep`),
`HotkeyEventSource` (`FakeEventSource`), and `HotkeyCarbonRegistrar`
(already landed in W0 — `NullCarbonRegistrar` keeps `swift test` from registering
live system-wide hotkeys and clobbering the developer's real `KeyboardShortcuts_*`
keys, because `KeyboardShortcuts` hardcodes `UserDefaults.standard`).

`HotkeyStateMachineTests`: traces A–F below, plus
`flushOnReleaseKeepsDoubleTapLockReachable`, `simultaneousChordSuppressesTheSubset`,
`duplicateFlagsChangedDoesNotRestartGrace`, `comboSessionIgnoresModifierFlags`,
`pressedAndReleasedAreBalancedPerFeature`,
`pushToTalkIgnoresMouseDownAndOtherKeyDown`,
`escapeIsLastEventAndSuppressesOtherKeyDownCancel`.

### Traces (with a deliberately-ambiguous ⌃ / ⌃⌥ config)

**A. ⌃⌥ push-to-talk, 40 ms roll.**
```
t=0    flags ⌃    P2: armed(dictation), pending(⌃), scheduleGrace → prewarm: mic on, no pill
t=40   flags ⌃⌥  P1: dictation (pending,superset) → cancelGrace, disarmed, suppressed
                  P2: pushToTalk (idle, exact ⌃⌥), !isAmbiguous → armed + pressed
                     → discardPrewarm() runs BEFORE monitor.send(.pressed) ✓
t=2000 flags ⌥   P1: pushToTalk released; dictation suppressed = false
```
Reverse release (⌥ first → flags ⌃): dictation is `suppressed`, ignores `.exact(⌃)`.

**B. Genuine ⌃ hold.** `armed` t=0 → mic live by ~t=40. `graceElapsed` t=200 →
`pressed`, `startedAt = armedAt`, Tink, pill. Samples span t≈40…end. **Zero clipped
syllables.** Pill and cue appear 200 ms late — exactly what the conflict checker's
warn copy promises.

**C. Double-tap lock, 120 ms taps.** Both taps flush-on-release → `keyDown`/`keyUp`
pairs land inside `tapWindow` → `isLocked = true`. See `flushOnRelease…` test.

**D. ⌃C.** `armed` t=0; `otherKeyDown(C)` t=50 → `disarmed`, `suppressed`. Mic off.
**No pill flash, no Tink, no cancel** — today this starts-then-cancels a real
recording (`:348-350`). Strict improvement.

**E. ⌃-click.** Same via `cancelsOnMouseDown`. PTT's is `false`, so ⌃⌥ + click keeps
recording — matching today (Buddy's tap has no mouse mask at all, `:134`).

**F. Esc during a locked hands-free session.** Phase is `.idle`.
`otherKeyDown(53)` → `.escapePressed(.dictation)` → `cancel()`. PTT never sees it.

---

## 8. Manual verification

Snapshot first: `defaults read com.a3b.buddy`.

1. Break on `CGEvent.tapCreate` — hit **exactly once** per launch.
2. Settings → both holds `Off` → tap destroyed (`isEventTapActive == false`). Set a
   hold back → tap recreated, **no relaunch**.
3. **Revoke Accessibility.** Within 1.5 s push-to-talk stops firing, **but dictation
   still records** (the tap survives on Input Monitoring). Re-grant → PTT resumes,
   no relaunch. *Check this hardest — it is the one thing the two-tap split gave you
   for free.*
4. Hold ⌃⇧ and start speaking **immediately**. Confirm the first word survives. 5×.
5. Press ⌃⌥ as a natural chord 20×. Buddy's waveform every time; the Whisper pill
   **zero** times; no Tink.
6. Hold ⌃⇧, press `C`. Nothing happens — no pill, no Tink — and ⌃⇧C reaches the app.
7. Slam ⌃ and ⌥ together, then lift ⌥ while holding ⌃. Dictation must **not** start.
8. Double-tap ⌃⇧ (~120 ms/tap). Lock engages, ✕/✓ show. Esc discards; ✓ transcribes.
9. While locked, hold ⌃⇧ and press `C`. Session **survives**.
10. Start a hold, and *while holding* change the binding in Settings. Session cancels
    cleanly — no stuck pill, no runaway recorder.

---

## 9. Risks

1. **Slow work inside the tap callback.** `AVAudioEngine.start()` can take 20–150 ms
   on the main thread from the tap callback → can trip `.tapDisabledByTimeout` and
   stall every keystroke system-wide. **Already true today**
   (`:98` → `handleFlagsChanged` → `holdPressed` → `keyDown` → `onStartRecording` →
   `recorder.start()`). Keep the `.tapDisabledByTimeout` re-enable.
2. **No resync after `.tapDisabledByTimeout`.** Latent in *both* current taps. Events
   drop while the tap is off; a held modifier's release can be lost → the session
   runs to the 5-minute cap. On re-enable, read
   `CGEventSource.flagsState(.combinedSessionState)` and feed it as a synthetic
   `flagsChanged`. Same hook for `NSWorkspace.willSleepNotification` and screen lock.
3. **Naive grace window breaks the double-tap lock.** Fixed by flush-on-release.
   Guard it with a named test, or a later "simplification" will silently require two
   ≥200 ms taps inside a 350 ms window.
4. **Duplicate `onKeyDown` registrations.** `legacyKeyDownHandlers` is append-only.
   Leaving `HotkeyManager.swift:61-62` or `GlobalPushToTalkShortcutMonitor.swift:64-74`
   in place while the engine also registers → `keyDown()` fires twice per combo press.
5. **`PassthroughSubject` drops events with no subscriber.** `HotkeyEngine.start()`
   must run after both adapters' `init`.
6. **Live rebind while held.** Terminate every `.pending` / `.held` feature
   (`.disarmed` / `.cancelled(_, .bindingsChanged)`) **before** swapping the match
   table, or the release becomes unmatched and the session hangs.
7. **Mic-indicator blink.** With an *ambiguous* dictation hold, every press of the
   superset arms `AVAudioEngine` for ≤200 ms and macOS shows the orange mic dot.
   With the shipped disjoint `⌃⇧` / `⌃⌥`, `isAmbiguous` is false everywhere and this
   never fires. Only users who deliberately create a prefix conflict see it — and
   `HotkeyConflictChecker` already warns them.
8. **PTT still clips its own first syllable.** `startPushToTalkFromKeyboardShortcut`
   is `async` and starts its `AVAudioEngine` after provider setup
   (`BuddyDictationManager.swift:371-381`). The engine emits `.armed(.pushToTalk)`;
   the adapter ignores it. Wiring that to a Buddy prewarm is a clean follow-up, out
   of scope.
9. **Slow-chord abort (verification step 7) is correct but reads as a bug.** The
   grace window only covers chords completed within 200 ms.
