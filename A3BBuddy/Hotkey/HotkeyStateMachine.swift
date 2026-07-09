//
//  HotkeyStateMachine.swift
//  Buddy — flexible hotkeys
//
//  The whole decision table for "did the user just trigger a hotkey", as a pure
//  value type. No tap, no timers, no UserDefaults, no AppKit beyond
//  `NSEvent.ModifierFlags`. `HotkeyEngine` is the shell that feeds it real events
//  and acts on its `Outcome`; `HotkeyStateMachineTests` feeds it synthetic ones.
//
//  Three ideas do most of the work:
//
//  **armed vs pressed.** `armed` fires at t=0 on every hold, `pressed` when the
//  engine has decided it really is a hold and not the prefix of a chord. The mic
//  warms on `armed`, so a 200 ms grace window costs zero audio. `disarmed` undoes
//  an `armed` that lost.
//
//  **Exact-set matching.** ⌃ never triggers a ⌃⌥ binding and ⌃⌥ never triggers a
//  ⌃ one. Everything outside `HotkeyBinding.recognizedModifiers` is masked off.
//
//  **`suppressed`.** macOS coalesces near-simultaneous modifier presses: slamming
//  ⌃⌥ together can arrive as a single `flagsChanged(⌃⌥)`, so a ⌃ binding never
//  sees its `.exact`. When ⌥ is lifted, `.exact(⌃)` arrives and must *not* fire.
//  The latch clears only when the modifiers fall clear of the binding entirely.
//

import AppKit
import Carbon.HIToolbox

// MARK: - Vocabulary

enum HotkeyTriggerSource: Equatable, Sendable {
    case modifierHold
    case keyCombo
    case mouseButton
}

enum HotkeyCancelReason: Equatable, Sendable {
    /// Another modifier joined mid-hold: ⌃C, ⌃⌘F. The chord wins.
    case supersetModifier
    case otherKeyDown
    case mouseDown
    /// The binding was edited out from under a live session.
    case bindingsChanged
    /// The feature's adapter stopped listening (push-to-talk lost Accessibility).
    case monitoringStopped
}

enum HotkeyEvent: Equatable, Sendable {
    /// t = 0 on every hold and combo. Warm the microphone. Show nothing.
    case armed(HotkeyFeature)
    /// The arm lost a race with a longer chord. Discard whatever `armed` warmed.
    case disarmed(HotkeyFeature)
    case pressed(HotkeyFeature, HotkeyTriggerSource)
    case released(HotkeyFeature)
    case cancelled(HotkeyFeature, HotkeyCancelReason)
    /// Phase-independent, and always the last event of its outcome: Esc must reach
    /// a hands-free session, which holds no modifier and so has no phase at all.
    case escapePressed(HotkeyFeature)

    var feature: HotkeyFeature {
        switch self {
        case .armed(let feature), .disarmed(let feature), .released(let feature),
             .escapePressed(let feature):
            feature
        case .pressed(let feature, _), .cancelled(let feature, _):
            feature
        }
    }
}

// MARK: - Match table

/// Everything the machine needs to know about the current bindings, precomputed.
struct HotkeyMatchTable: Equatable {
    enum Match: Equatable {
        case none
        case exact(HotkeyBinding)
        /// The pressed modifiers strictly contain one of this feature's holds.
        case superset
    }

    private let holdsByFeature: [HotkeyFeature: [HotkeyBinding]]
    private let combosByFeature: [HotkeyFeature: [HotkeyBinding]]
    private let mouseButtonsByFeature: [HotkeyFeature: [Int]]
    private let ambiguousHolds: Set<HotkeyBinding>

    init(bindings: [HotkeyFeature: [HotkeyBinding]]) {
        var holds: [HotkeyFeature: [HotkeyBinding]] = [:]
        var combos: [HotkeyFeature: [HotkeyBinding]] = [:]
        var mouseButtons: [HotkeyFeature: [Int]] = [:]
        for feature in HotkeyFeature.allCases {
            let all = bindings[feature] ?? []
            holds[feature] = all.filter(\.isModifiersOnly)
            // `isKeyCombo`, not `!isModifiersOnly`: a mouse binding filed here would
            // shift every Carbon slot index out from under `combo(at:)`.
            combos[feature] = all.filter(\.isKeyCombo)
            mouseButtons[feature] = all.compactMap(\.mouseButtonNumber)
        }
        holdsByFeature = holds
        combosByFeature = combos
        mouseButtonsByFeature = mouseButtons

        let everyHold = holds.values.flatMap { $0 }
        ambiguousHolds = Set(everyHold.filter { candidate in
            everyHold.contains { candidate.modifierFlags.isStrictSubset(of: $0.modifierFlags) }
        })
    }

    /// Holds and mouse buttons are tap-matched, and only the tap needs a grant.
    var needsEventTap: Bool {
        holdsByFeature.values.contains { !$0.isEmpty } || hasMouseButtons
    }

    /// Drives the `.defaultTap` upgrade — only a mouse binding wants to swallow.
    var hasMouseButtons: Bool {
        mouseButtonsByFeature.values.contains { !$0.isEmpty }
    }

    func holds(for feature: HotkeyFeature) -> [HotkeyBinding] {
        holdsByFeature[feature] ?? []
    }

    func combo(at slot: Int, for feature: HotkeyFeature) -> HotkeyBinding? {
        let combos = combosByFeature[feature] ?? []
        return slot < combos.count ? combos[slot] : nil
    }

    /// Bound to *any* feature. An unbound press keeps its old meaning: it cancels
    /// dictation. A bound one is a trigger and must never cancel its own feature.
    func isBoundMouseButton(_ number: Int) -> Bool {
        mouseButtonsByFeature.values.contains { $0.contains(number) }
    }

    func feature(forMouseButton number: Int) -> HotkeyFeature? {
        // `HotkeyConflictChecker` blocks binding one button to two features, so at
        // most one owner exists; `first` rather than a crash if that ever slips.
        HotkeyFeature.allCases.first { mouseButtonsByFeature[$0]?.contains(number) == true }
    }

    /// A hold that is a strict prefix of *any* other hold cannot fire on contact:
    /// pressing the longer set passes through the shorter one on the way.
    /// `.keyCombo` never participates — `HotkeyConflictChecker` blocks any combo
    /// whose modifiers are a superset of an existing hold.
    func isAmbiguous(_ binding: HotkeyBinding) -> Bool {
        ambiguousHolds.contains(binding)
    }

    /// `.exact` beats `.superset`: with ⌃ and ⌃⇧ both bound, pressing ⌃⇧ is a
    /// press of ⌃⇧, not a chord over ⌃.
    func match(_ feature: HotkeyFeature, _ modifiers: NSEvent.ModifierFlags) -> Match {
        let holds = holds(for: feature)
        if let exact = holds.first(where: { $0.modifierFlags == modifiers }) {
            return .exact(exact)
        }
        if holds.contains(where: { $0.modifierFlags.isStrictSubset(of: modifiers) }) {
            return .superset
        }
        return .none
    }
}

// MARK: - State machine

struct HotkeyStateMachine {
    enum Phase: Equatable {
        case idle
        /// `armed`, grace timer running, not yet committed.
        case pending(HotkeyBinding)
        case held(HotkeyBinding, HotkeyTriggerSource)
    }

    struct FeatureState: Equatable {
        var phase: Phase = .idle
        var suppressed = false
    }

    struct GraceRequest: Equatable {
        let feature: HotkeyFeature
        let binding: HotkeyBinding
    }

    /// What the shell must do. Events are already in dispatch order.
    struct Outcome: Equatable {
        var events: [HotkeyEvent] = []
        var cancelGrace: [HotkeyFeature] = []
        var scheduleGrace: [GraceRequest] = []
        /// Honoured by `LocalMonitorSource` always, and by `CGEventTapSource` only
        /// for mouse buttons and only when it managed to create a `.defaultTap`.
        var consumesEvent = false

        /// Merges `other` after self, keeping dispatch order. `consumesEvent` is
        /// sticky: one consuming part makes the whole outcome consume.
        mutating func append(_ other: Outcome) {
            events += other.events
            cancelGrace += other.cancelGrace
            scheduleGrace += other.scheduleGrace
            consumesEvent = consumesEvent || other.consumesEvent
        }
    }

    private(set) var table: HotkeyMatchTable
    private(set) var states: [HotkeyFeature: FeatureState]
    private var escapeCancelsActiveSession: [HotkeyFeature: Bool] = [:]
    /// Last seen `NSEvent.pressedMouseButtons`. Presses and releases are its diff.
    private var pressedMouseButtons = 0

    private static let escapeKeyCode = UInt16(kVK_Escape)

    init(table: HotkeyMatchTable) {
        self.table = table
        states = Dictionary(uniqueKeysWithValues: HotkeyFeature.allCases.map { ($0, FeatureState()) })
    }

    func phase(for feature: HotkeyFeature) -> Phase {
        states[feature]?.phase ?? .idle
    }

    func isHeld(_ feature: HotkeyFeature) -> Bool {
        if case .held = phase(for: feature) { return true }
        return false
    }

    /// `HotkeyManager` mirrors its own `isActive` here so Esc gets swallowed inside
    /// Buddy's own windows exactly while there is a session to swallow it for.
    mutating func setEscapeCancelsActiveSession(_ isActive: Bool, for feature: HotkeyFeature) {
        escapeCancelsActiveSession[feature] = isActive
    }

    // MARK: Modifiers

    /// Two passes over the features, never sorted. Terminations first, initiations
    /// second — that is what guarantees the losing subset's `disarmed` reaches its
    /// adapter *before* the winning superset's `pressed` reaches the other one, so
    /// two `AVAudioEngine`s never contend for the input node.
    mutating func flagsChanged(_ rawModifiers: NSEvent.ModifierFlags) -> Outcome {
        let modifiers = rawModifiers.intersection(HotkeyBinding.recognizedModifiers)
        var outcome = Outcome()

        // ── Pass 1: terminations ────────────────────────────────
        for feature in HotkeyFeature.allCases {
            var state = states[feature]!
            defer { states[feature] = state }

            switch (state.phase, table.match(feature, modifiers)) {

            // A release *proves* it was never a chord — you cannot reach ⌃⌥ by
            // letting go of ⌃. Flush: commit the press and end it immediately.
            // Without this, any press shorter than the grace window emits nothing
            // and the double-tap hands-free lock becomes unreachable.
            case (.pending, .none):
                outcome.cancelGrace.append(feature)
                outcome.events.append(.pressed(feature, .modifierHold))
                outcome.events.append(.released(feature))
                state.phase = .idle
                state.suppressed = false

            case (.pending, .superset):
                outcome.cancelGrace.append(feature)
                outcome.events.append(.disarmed(feature))
                state.phase = .idle
                state.suppressed = true

            // Armed on one hold, landed on another (⌃ and ⌃⇧ both bound).
            case (.pending(let armed), .exact(let matched)) where matched != armed:
                outcome.cancelGrace.append(feature)
                outcome.events.append(.disarmed(feature))
                state.phase = .idle

            case (.held(_, .modifierHold), .none):
                outcome.events.append(.released(feature))
                state.phase = .idle
                state.suppressed = false

            case (.held(_, .modifierHold), .superset):
                switch feature.supersetPolicy {
                case .abort: outcome.events.append(.cancelled(feature, .supersetModifier))
                case .release: outcome.events.append(.released(feature))
                }
                state.phase = .idle
                state.suppressed = true

            case (.held(let heldBinding, .modifierHold), .exact(let matched)) where matched != heldBinding:
                outcome.events.append(.released(feature))
                state.phase = .idle

            case (.idle, .none):
                state.suppressed = false

            case (.idle, .superset):
                state.suppressed = true

            // `.idle` + `.exact` is pass 2's business. A repeat of the binding we
            // are already on is a duplicate — the tap and the local monitor both
            // deliver when Buddy is frontmost. A `.keyCombo` session ignores
            // modifiers entirely; Carbon owns it until its key-up.
            default:
                break
            }
        }

        // ── Pass 2: initiations ─────────────────────────────────
        for feature in HotkeyFeature.allCases {
            var state = states[feature]!
            guard case .idle = state.phase, !state.suppressed else { continue }
            guard case .exact(let binding) = table.match(feature, modifiers) else { continue }

            outcome.events.append(.armed(feature))
            if table.isAmbiguous(binding) {
                state.phase = .pending(binding)
                outcome.scheduleGrace.append(GraceRequest(feature: feature, binding: binding))
            } else {
                state.phase = .held(binding, .modifierHold)
                outcome.events.append(.pressed(feature, .modifierHold))
            }
            states[feature] = state
        }

        return outcome
    }

    /// The grace deadline elapsed with the modifiers still exactly on the binding.
    mutating func graceElapsed(_ feature: HotkeyFeature, _ binding: HotkeyBinding) -> Outcome {
        var outcome = Outcome()
        guard case .pending(let armed) = states[feature]!.phase, armed == binding else { return outcome }
        states[feature]!.phase = .held(binding, .modifierHold)
        outcome.events.append(.pressed(feature, .modifierHold))
        return outcome
    }

    // MARK: Keys and clicks

    mutating func keyDown(_ keyCode: UInt16) -> Outcome {
        var outcome = Outcome()
        var deferredEscapes: [HotkeyEvent] = []
        let isEscape = keyCode == Self.escapeKeyCode

        for feature in HotkeyFeature.allCases {
            if isEscape, feature.cancelsOnEscape {
                deferredEscapes.append(.escapePressed(feature))
            }
            guard feature.cancelsOnOtherKeyDown else { continue }

            var state = states[feature]!
            defer { states[feature] = state }

            switch state.phase {
            case .pending:
                // Never became a recording. No pill, no cue, nothing to cancel:
                // ⌃C now costs a warmed mic instead of a started-then-aborted one.
                outcome.cancelGrace.append(feature)
                outcome.events.append(.disarmed(feature))
                state.phase = .idle
                state.suppressed = true

            case .held(_, .modifierHold), .held(_, .mouseButton):
                // Esc is reported on its own channel — a locked hands-free session
                // must see it, and `.cancelled` is exactly what a lock ignores.
                guard !isEscape else { break }
                outcome.events.append(.cancelled(feature, .otherKeyDown))
                state.phase = .idle
                state.suppressed = true

            case .held(_, .keyCombo), .idle:
                break
            }
        }

        outcome.events += deferredEscapes
        outcome.consumesEvent = isEscape && escapeCancelsActiveSession.values.contains(true)
        return outcome
    }

    /// `pressed` is a bitmask of the buttons physically down. Everything is derived
    /// from its difference with the previous mask, which is what makes a resync
    /// after macOS kills the tap indistinguishable from a normal release.
    ///
    /// Terminations run before initiations, for the same reason `flagsChanged` does
    /// it: a feature that is ending must reach its adapter before the one that is
    /// starting, or two `AVAudioEngine`s contend for the input node.
    mutating func mouseButtonsChanged(_ pressed: Int) -> Outcome {
        let newlyPressed = pressed & ~pressedMouseButtons
        let newlyReleased = pressedMouseButtons & ~pressed
        pressedMouseButtons = pressed

        var outcome = Outcome()

        // ── Releases: a mouse hold ends when its own button comes up ────
        for feature in HotkeyFeature.allCases {
            guard case .held(let binding, .mouseButton) = states[feature]!.phase,
                  let button = binding.mouseButtonNumber,
                  newlyReleased & (1 << button) != 0
            else { continue }

            states[feature]!.phase = .idle
            states[feature]!.suppressed = false
            outcome.events.append(.released(feature))
        }

        // Swallow both halves of a bound button, or the app underneath sees a
        // mouse-up with no matching mouse-down.
        outcome.consumesEvent = bitsSet(newlyPressed | newlyReleased).contains { table.isBoundMouseButton($0) }

        for button in bitsSet(newlyPressed) {
            guard let owner = table.feature(forMouseButton: button) else {
                // ── Unbound click: the old behaviour, unchanged ────
                outcome.append(cancelForUnboundClick())
                continue
            }

            // ── Bound click: one session at a time ────
            guard case .idle = states[owner]!.phase else { continue }
            // Push-to-talk does not cancel on mouse-down, so without this a bound
            // button could start it *on top of* a live dictation hold.
            for other in HotkeyFeature.allCases where other != owner {
                outcome.append(terminate(other, reason: .mouseDown))
            }

            states[owner]!.phase = .held(.mouseButton(number: button), .mouseButton)
            states[owner]!.suppressed = false
            outcome.events.append(.armed(owner))
            outcome.events.append(.pressed(owner, .mouseButton))
        }

        return outcome
    }

    /// Any click that isn't a hotkey kills an unlocked dictation, so ⌃-click
    /// (which macOS treats as a right-click) reaches the app underneath untouched.
    private mutating func cancelForUnboundClick() -> Outcome {
        var outcome = Outcome()

        for feature in HotkeyFeature.allCases where feature.cancelsOnMouseDown {
            var state = states[feature]!
            defer { states[feature] = state }

            switch state.phase {
            case .pending:
                outcome.cancelGrace.append(feature)
                outcome.events.append(.disarmed(feature))
                state.phase = .idle
                state.suppressed = true

            case .held(_, .modifierHold), .held(_, .mouseButton):
                outcome.events.append(.cancelled(feature, .mouseDown))
                state.phase = .idle
                state.suppressed = true

            case .held(_, .keyCombo), .idle:
                break
            }
        }

        return outcome
    }

    /// Ends whatever `feature` is doing, whatever that is. `.idle` stays silent.
    private mutating func terminate(_ feature: HotkeyFeature, reason: HotkeyCancelReason) -> Outcome {
        var outcome = Outcome()
        var state = states[feature]!
        defer { states[feature] = state }

        switch state.phase {
        case .pending:
            outcome.cancelGrace.append(feature)
            outcome.events.append(.disarmed(feature))
        case .held:
            outcome.events.append(.cancelled(feature, reason))
        case .idle:
            return outcome
        }
        state.phase = .idle
        state.suppressed = true
        return outcome
    }

    /// The indices of the set bits, low to high. Mice report far fewer than 32
    /// buttons; the cap just keeps this from walking the whole word.
    private func bitsSet(_ mask: Int) -> [Int] {
        (0 ..< 32).filter { mask & (1 << $0) != 0 }
    }

    // MARK: Carbon combos

    /// One trigger per feature at a time. A combo pressed during a modifier hold
    /// is dropped, and vice versa — that is what keeps `pressed` and
    /// `released`/`cancelled` exactly balanced, and lets both adapters delete
    /// their own source tracking.
    mutating func comboKeyDown(_ feature: HotkeyFeature, slot: Int) -> Outcome {
        var outcome = Outcome()
        guard case .idle = states[feature]!.phase else { return outcome }
        guard let binding = table.combo(at: slot, for: feature) else { return outcome }

        states[feature]!.phase = .held(binding, .keyCombo)
        outcome.events.append(.armed(feature))
        outcome.events.append(.pressed(feature, .keyCombo))
        return outcome
    }

    mutating func comboKeyUp(_ feature: HotkeyFeature, slot: Int) -> Outcome {
        var outcome = Outcome()
        guard case .held(_, .keyCombo) = states[feature]!.phase else { return outcome }

        states[feature]!.phase = .idle
        outcome.events.append(.released(feature))
        return outcome
    }

    // MARK: Lifecycle

    /// Terminate every live session *before* the table swaps, or the release that
    /// would have ended it no longer matches anything and the session hangs.
    mutating func setTable(_ newTable: HotkeyMatchTable) -> Outcome {
        let outcome = terminateAll(reason: .bindingsChanged)
        table = newTable
        return outcome
    }

    mutating func terminateAll(reason: HotkeyCancelReason) -> Outcome {
        var outcome = Outcome()

        for feature in HotkeyFeature.allCases {
            var state = states[feature]!
            defer { states[feature] = state }

            switch state.phase {
            case .pending:
                outcome.cancelGrace.append(feature)
                outcome.events.append(.disarmed(feature))
            case .held:
                outcome.events.append(.cancelled(feature, reason))
            case .idle:
                continue
            }
            state.phase = .idle
            state.suppressed = false
        }

        return outcome
    }

    mutating func releaseIfHeld(_ feature: HotkeyFeature, reason: HotkeyCancelReason) -> Outcome {
        var outcome = Outcome()
        var state = states[feature]!
        defer { states[feature] = state }

        switch state.phase {
        case .pending:
            outcome.cancelGrace.append(feature)
            outcome.events.append(.disarmed(feature))
        case .held:
            outcome.events.append(.cancelled(feature, reason))
        case .idle:
            return outcome
        }
        state.phase = .idle
        state.suppressed = false
        return outcome
    }
}
