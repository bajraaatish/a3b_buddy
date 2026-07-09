//
//  HotkeyStateMachineTests.swift
//  A3BBuddyTests — flexible hotkeys
//
//  The whole hotkey decision table, driven by synthetic events. No TCC, no event
//  tap, no app launch, no wall clock — `HotkeyStateMachine` is a pure value type
//  and the grace deadline is just another method call.
//
//  The failure mode these guard against is typing garbage into the user's
//  documents, so they are exhaustive on purpose.
//

import AppKit
import Carbon.HIToolbox
import Testing
@testable import A3BBuddy

// MARK: - Fixtures

private let ctrl = HotkeyBinding.modifiersOnly(.control)
private let ctrlOption = HotkeyBinding.modifiersOnly([.control, .option])
private let ctrlShift = HotkeyBinding.modifiersOnly([.control, .shift])
private let optionShift = HotkeyBinding.modifiersOnly([.option, .shift])
private let fnHold = HotkeyBinding.modifiersOnly(.function)
private let cmdShiftD = HotkeyBinding.keyCombo(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift])
private let optionSpace = HotkeyBinding.keyCombo(keyCode: UInt16(kVK_Space), modifiers: .option)

private let mouse4 = HotkeyBinding.mouseButton(number: 3)
private let mouse5 = HotkeyBinding.mouseButton(number: 4)

private let keyC = UInt16(kVK_ANSI_C)
private let escape = UInt16(kVK_Escape)

/// `NSEvent.pressedMouseButtons` is a bitmask, bit N = button N.
private func buttons(_ numbers: Int...) -> Int {
    numbers.reduce(0) { $0 | (1 << $1) }
}
private let noButtons = 0

private func machine(
    dictation: [HotkeyBinding] = [ctrlShift],
    pushToTalk: [HotkeyBinding] = [ctrlOption]
) -> HotkeyStateMachine {
    HotkeyStateMachine(table: HotkeyMatchTable(bindings: [
        .dictation: dictation,
        .pushToTalk: pushToTalk,
    ]))
}

/// The deliberately-ambiguous config the grace window exists for: ⌃ is a strict
/// prefix of ⌃⌥, so pressing push-to-talk passes through dictation's hold.
private func ambiguousMachine() -> HotkeyStateMachine {
    machine(dictation: [ctrl], pushToTalk: [ctrlOption])
}

private let noModifiers: NSEvent.ModifierFlags = []

// MARK: - Match table

@Suite struct HotkeyMatchTableTests {
    @Test func exactBeatsSuperset() {
        // With ⌃ and ⌃⇧ both bound to dictation, pressing ⌃⇧ is a press of ⌃⇧.
        let table = HotkeyMatchTable(bindings: [.dictation: [ctrl, ctrlShift], .pushToTalk: []])
        #expect(table.match(.dictation, [.control, .shift]) == .exact(ctrlShift))
        #expect(table.match(.dictation, [.control]) == .exact(ctrl))
        #expect(table.match(.dictation, [.control, .command]) == .superset)
        #expect(table.match(.dictation, [.command]) == .none)
        #expect(table.match(.dictation, noModifiers) == .none)
    }

    @Test func combosNeverMatchModifiers() {
        let table = HotkeyMatchTable(bindings: [.dictation: [cmdShiftD], .pushToTalk: []])
        #expect(table.match(.dictation, [.command, .shift]) == .none)
        #expect(table.combo(at: 0, for: .dictation) == cmdShiftD)
        #expect(table.combo(at: 1, for: .dictation) == nil)
    }

    @Test func ambiguityIsAPropertyOfTheWholeBindingSet() {
        let disjoint = HotkeyMatchTable(bindings: [.dictation: [ctrlShift], .pushToTalk: [ctrlOption]])
        #expect(!disjoint.isAmbiguous(ctrlShift))
        #expect(!disjoint.isAmbiguous(ctrlOption))

        let overlapping = HotkeyMatchTable(bindings: [.dictation: [ctrl], .pushToTalk: [ctrlOption]])
        #expect(overlapping.isAmbiguous(ctrl))
        #expect(!overlapping.isAmbiguous(ctrlOption))
    }

    @Test func onlyHoldsNeedTheEventTap() {
        #expect(HotkeyMatchTable(bindings: [.dictation: [ctrlShift], .pushToTalk: []]).needsEventTap)
        #expect(!HotkeyMatchTable(bindings: [.dictation: [cmdShiftD], .pushToTalk: [optionSpace]]).needsEventTap)
        #expect(!HotkeyMatchTable(bindings: [:]).needsEventTap)
    }
}

// MARK: - Unambiguous holds (the shipped defaults)

@Suite struct HotkeyHoldTests {
    @Test func exactMatchArmsAndPressesImmediately() {
        var state = machine()
        #expect(state.flagsChanged([.control]).events.isEmpty)  // ⌃ alone matches nothing
        #expect(state.flagsChanged([.control, .shift]).events == [
            .armed(.dictation), .pressed(.dictation, .modifierHold),
        ])
        #expect(state.flagsChanged(noModifiers).events == [.released(.dictation)])
    }

    @Test func typingCapitalsRecordsNothing() {
        // The bug this whole wave exists to kill: ⇧ alone was the dictation hold.
        var state = machine()
        #expect(state.flagsChanged([.shift]).events.isEmpty)
        #expect(state.keyDown(UInt16(kVK_ANSI_H)).events.isEmpty)
        #expect(state.flagsChanged(noModifiers).events.isEmpty)
    }

    @Test func supersetAbortsDictation() {
        var state = machine()
        _ = state.flagsChanged([.control, .shift])
        #expect(state.flagsChanged([.control, .shift, .command]).events == [
            .cancelled(.dictation, .supersetModifier),
        ])
    }

    @Test func supersetOnlyReleasesPushToTalk() {
        // An accidental ⇧ mid-utterance must not throw the audio away.
        var state = machine()
        _ = state.flagsChanged([.control, .option])
        #expect(state.flagsChanged([.control, .option, .shift]).events == [.released(.pushToTalk)])
    }

    @Test func suppressionSurvivesUntilTheModifiersClear() {
        var state = machine()
        _ = state.flagsChanged([.control, .shift])
        _ = state.flagsChanged([.control, .shift, .command])   // aborted, suppressed

        // Back on an exact ⌃⇧, but the user never meant to dictate.
        #expect(state.flagsChanged([.control, .shift]).events.isEmpty)
        // Falls clear of the binding — latch releases.
        #expect(state.flagsChanged([.control]).events.isEmpty)
        #expect(state.flagsChanged([.control, .shift]).events == [
            .armed(.dictation), .pressed(.dictation, .modifierHold),
        ])
    }

    /// macOS coalesces near-simultaneous modifier presses: slamming ⌃ and ⌥ together
    /// can arrive as one `flagsChanged(⌃⌥)`, so a ⌃ binding never sees its `.exact`.
    /// Lifting ⌥ then delivers `.exact(⌃)` — which must not start dictation.
    @Test func simultaneousChordSuppressesTheSubset() {
        var state = ambiguousMachine()
        let chord = state.flagsChanged([.control, .option])
        #expect(chord.events == [.armed(.pushToTalk), .pressed(.pushToTalk, .modifierHold)])

        let liftOption = state.flagsChanged([.control])
        #expect(liftOption.events == [.released(.pushToTalk)])
        #expect(state.phase(for: .dictation) == .idle)

        #expect(state.flagsChanged(noModifiers).events.isEmpty)
    }

    @Test func theTwoShippedDefaultsNeverSeeEachOther() {
        var state = machine()
        #expect(state.flagsChanged([.control, .option]).events == [
            .armed(.pushToTalk), .pressed(.pushToTalk, .modifierHold),
        ])
        #expect(state.phase(for: .dictation) == .idle)
        #expect(state.flagsChanged([.control]).events == [.released(.pushToTalk)])
    }

    @Test func aBareFunctionKeyIsAHoldLikeAnyOther() {
        var state = machine(dictation: [fnHold], pushToTalk: [])
        #expect(state.flagsChanged([.function]).events == [
            .armed(.dictation), .pressed(.dictation, .modifierHold),
        ])
        #expect(state.flagsChanged(noModifiers).events == [.released(.dictation)])
    }

    @Test func unrecognisedFlagsAreNoise() {
        var state = machine()
        // Caps lock and the numeric-pad bit ride along on real events.
        let noisy: NSEvent.ModifierFlags = [.control, .shift, .capsLock, .numericPad]
        #expect(state.flagsChanged(noisy).events == [
            .armed(.dictation), .pressed(.dictation, .modifierHold),
        ])
    }

    @Test func duplicateFlagsChangedIsANoOp() {
        // The tap and the local monitor both deliver when Buddy is frontmost.
        var state = machine()
        _ = state.flagsChanged([.control, .shift])
        #expect(state.flagsChanged([.control, .shift]).events.isEmpty)
    }

    @Test func switchingBetweenTwoHoldsOfTheSameFeature() {
        // ⌃ is a strict prefix of ⌃⇧, so it arms behind the grace window.
        var state = machine(dictation: [ctrl, ctrlShift], pushToTalk: [])
        #expect(state.flagsChanged([.control]).events == [.armed(.dictation)])
        #expect(state.graceElapsed(.dictation, ctrl).events == [.pressed(.dictation, .modifierHold)])

        // ⌃⇧ is an exact match too, so this is a switch, not a superset abort.
        #expect(state.flagsChanged([.control, .shift]).events == [
            .released(.dictation), .armed(.dictation), .pressed(.dictation, .modifierHold),
        ])
        #expect(state.phase(for: .dictation) == .held(ctrlShift, .modifierHold))
    }
}

// MARK: - Grace window

@Suite struct HotkeyGraceWindowTests {
    @Test func ambiguousHoldArmsButDoesNotPress() {
        var state = ambiguousMachine()
        let outcome = state.flagsChanged([.control])
        #expect(outcome.events == [.armed(.dictation)])
        #expect(outcome.scheduleGrace == [.init(feature: .dictation, binding: ctrl)])
        #expect(state.phase(for: .dictation) == .pending(ctrl))
    }

    @Test func deadlineElapsesIntoAPress() {
        var state = ambiguousMachine()
        _ = state.flagsChanged([.control])
        #expect(state.graceElapsed(.dictation, ctrl).events == [.pressed(.dictation, .modifierHold)])
        #expect(state.phase(for: .dictation) == .held(ctrl, .modifierHold))
    }

    /// Trace A: ⌃⌥ pressed as a 40 ms roll. The subset's `disarmed` must reach its
    /// adapter *before* the superset's `pressed` reaches the other one, or two
    /// `AVAudioEngine`s contend for the input node.
    @Test func supersetCancelsTheGraceAndDisarmsBeforeTheWinnerPresses() {
        var state = ambiguousMachine()
        _ = state.flagsChanged([.control])

        let outcome = state.flagsChanged([.control, .option])
        #expect(outcome.events == [
            .disarmed(.dictation),
            .armed(.pushToTalk),
            .pressed(.pushToTalk, .modifierHold),
        ])
        #expect(outcome.cancelGrace == [.dictation])

        // A late timer must not resurrect the loser.
        #expect(state.graceElapsed(.dictation, ctrl).events.isEmpty)
    }

    /// Without flush-on-release, any press shorter than the grace window emits
    /// nothing at all — and `HotkeyManager`'s 0.35 s double-tap hands-free lock
    /// becomes unreachable, because both taps would have to be held ≥200 ms.
    /// A release *proves* it was never a chord: you cannot reach ⌃⌥ by letting go of ⌃.
    @Test func flushOnReleaseKeepsDoubleTapLockReachable() {
        var state = ambiguousMachine()
        _ = state.flagsChanged([.control])

        let outcome = state.flagsChanged(noModifiers)
        #expect(outcome.events == [
            .pressed(.dictation, .modifierHold),
            .released(.dictation),
        ])
        #expect(outcome.cancelGrace == [.dictation])
        #expect(state.phase(for: .dictation) == .idle)

        // Second tap of the double-tap, same shape.
        _ = state.flagsChanged([.control])
        #expect(state.flagsChanged(noModifiers).events == [
            .pressed(.dictation, .modifierHold),
            .released(.dictation),
        ])
    }

    @Test func duplicateFlagsChangedDoesNotRestartGrace() {
        var state = ambiguousMachine()
        _ = state.flagsChanged([.control])
        let repeated = state.flagsChanged([.control])
        #expect(repeated.events.isEmpty)
        #expect(repeated.scheduleGrace.isEmpty)
        #expect(repeated.cancelGrace.isEmpty)
    }

    @Test func lateDeadlineForAStaleBindingIsIgnored() {
        var state = machine(dictation: [ctrl, ctrlShift], pushToTalk: [ctrlOption])
        _ = state.flagsChanged([.control])                 // pending(⌃)
        _ = state.flagsChanged([.control, .shift])         // switches to ⌃⇧
        #expect(state.graceElapsed(.dictation, ctrl).events.isEmpty)
    }

    /// Trace D. ⌃C on an ambiguous hold never becomes a recording at all — no pill,
    /// no cue, no cancel. Today it starts one and aborts it a frame later.
    @Test func otherKeyDownDuringGraceDisarmsWithoutEverPressing() {
        var state = ambiguousMachine()
        _ = state.flagsChanged([.control])

        let outcome = state.keyDown(keyC)
        #expect(outcome.events == [.disarmed(.dictation)])
        #expect(outcome.cancelGrace == [.dictation])
        #expect(state.graceElapsed(.dictation, ctrl).events.isEmpty)
    }

    /// Trace E. ⌃-click is a right-click; the hold must not survive it.
    @Test func mouseDownDuringGraceDisarms() {
        var state = ambiguousMachine()
        _ = state.flagsChanged([.control])
        #expect(state.mouseButtonsChanged(1 << 0).events == [.disarmed(.dictation)])
    }
}

// MARK: - Cancels

@Suite struct HotkeyCancelTests {
    @Test func otherKeyDownCancelsAHeldDictation() {
        var state = machine()
        _ = state.flagsChanged([.control, .shift])
        let outcome = state.keyDown(keyC)
        #expect(outcome.events == [.cancelled(.dictation, .otherKeyDown)])
        #expect(!outcome.consumesEvent)
    }

    @Test func mouseDownCancelsAHeldDictation() {
        var state = machine()
        _ = state.flagsChanged([.control, .shift])
        #expect(state.mouseButtonsChanged(1 << 0).events == [.cancelled(.dictation, .mouseDown)])
    }

    @Test func pushToTalkIgnoresMouseDownAndOtherKeyDown() {
        var state = machine()
        _ = state.flagsChanged([.control, .option])
        #expect(state.keyDown(keyC).events.isEmpty)
        #expect(state.mouseButtonsChanged(1 << 0).events.isEmpty)
        #expect(state.isHeld(.pushToTalk))
    }

    /// Esc rides its own channel because a hands-free session holds no modifier —
    /// the machine's phase is `.idle` and there is nothing to `cancel`.
    /// It must not *also* arrive as `.cancelled(.otherKeyDown)`, which a lock ignores.
    @Test func escapeIsLastEventAndSuppressesOtherKeyDownCancel() {
        var state = machine()
        state.setEscapeCancelsActiveSession(true, for: .dictation)
        _ = state.flagsChanged([.control, .shift])

        let outcome = state.keyDown(escape)
        #expect(outcome.events == [.escapePressed(.dictation)])
        #expect(outcome.consumesEvent)
        #expect(state.isHeld(.dictation))   // the modifiers are still physically down
        #expect(state.flagsChanged(noModifiers).events == [.released(.dictation)])
    }

    @Test func escapeDuringGraceDisarmsThenReportsItself() {
        var state = ambiguousMachine()
        state.setEscapeCancelsActiveSession(true, for: .dictation)
        _ = state.flagsChanged([.control])

        #expect(state.keyDown(escape).events == [
            .disarmed(.dictation),
            .escapePressed(.dictation),
        ])
    }

    @Test func escapeIsOnlyConsumedWhileASessionIsActive() {
        var state = machine()
        #expect(!state.keyDown(escape).consumesEvent)

        state.setEscapeCancelsActiveSession(true, for: .dictation)
        #expect(state.keyDown(escape).consumesEvent)

        state.setEscapeCancelsActiveSession(false, for: .dictation)
        #expect(!state.keyDown(escape).consumesEvent)
    }

    @Test func pushToTalkNeverSeesEscape() {
        var state = machine()
        _ = state.flagsChanged([.control, .option])
        // Dictation reports Esc unconditionally; push-to-talk has no Esc affordance.
        #expect(state.keyDown(escape).events == [.escapePressed(.dictation)])
        #expect(state.isHeld(.pushToTalk))
    }
}

// MARK: - Carbon combos

@Suite struct HotkeyComboTests {
    @Test func comboPressesAndReleases() {
        var state = machine(dictation: [ctrlShift, cmdShiftD], pushToTalk: [])
        #expect(state.comboKeyDown(.dictation, slot: 0).events == [
            .armed(.dictation), .pressed(.dictation, .keyCombo),
        ])
        #expect(state.comboKeyUp(.dictation, slot: 0).events == [.released(.dictation)])
    }

    @Test func comboSessionIgnoresModifierFlags() {
        var state = machine(dictation: [ctrlShift, cmdShiftD], pushToTalk: [])
        _ = state.comboKeyDown(.dictation, slot: 0)

        // Carbon owns the session until its key-up. The hold must not steal it.
        #expect(state.flagsChanged([.control, .shift]).events.isEmpty)
        #expect(state.flagsChanged(noModifiers).events.isEmpty)
        #expect(state.comboKeyUp(.dictation, slot: 0).events == [.released(.dictation)])
    }

    @Test func aComboPressedDuringAHoldIsDropped() {
        var state = machine(dictation: [ctrlShift, cmdShiftD], pushToTalk: [])
        _ = state.flagsChanged([.control, .shift])
        #expect(state.comboKeyDown(.dictation, slot: 0).events.isEmpty)
    }

    @Test func aComboWithNoBindingIsDropped() {
        var state = machine()
        #expect(state.comboKeyDown(.dictation, slot: 0).events.isEmpty)
        #expect(state.comboKeyUp(.dictation, slot: 0).events.isEmpty)
    }
}

// MARK: - Lifecycle

@Suite struct HotkeyLifecycleTests {
    /// Risk 6: terminate before swapping, or the release that would have ended the
    /// session no longer matches anything and the recorder runs to the 5-minute cap.
    @Test func rebindingWhileHeldTerminatesTheSession() {
        var state = machine()
        _ = state.flagsChanged([.control, .shift])

        let outcome = state.setTable(HotkeyMatchTable(bindings: [
            .dictation: [optionShift], .pushToTalk: [ctrlOption],
        ]))
        #expect(outcome.events == [.cancelled(.dictation, .bindingsChanged)])
        #expect(state.phase(for: .dictation) == .idle)

        // And the new binding works, with no restart.
        #expect(state.flagsChanged([.option, .shift]).events == [
            .armed(.dictation), .pressed(.dictation, .modifierHold),
        ])
    }

    @Test func rebindingWhileArmedDisarms() {
        var state = ambiguousMachine()
        _ = state.flagsChanged([.control])
        let outcome = state.setTable(HotkeyMatchTable(bindings: [.dictation: [ctrlShift], .pushToTalk: []]))
        #expect(outcome.events == [.disarmed(.dictation)])
        #expect(outcome.cancelGrace == [.dictation])
    }

    @Test func releaseIfHeldEndsOneFeatureOnly() {
        var state = machine()
        _ = state.flagsChanged([.control, .option])
        #expect(state.releaseIfHeld(.pushToTalk, reason: .monitoringStopped).events == [
            .cancelled(.pushToTalk, .monitoringStopped),
        ])
        #expect(state.releaseIfHeld(.dictation, reason: .monitoringStopped).events.isEmpty)
    }

    @Test func terminateAllClearsEveryFeature() {
        var state = ambiguousMachine()
        _ = state.flagsChanged([.control])            // dictation pending
        _ = state.graceElapsed(.dictation, ctrl)      // dictation held

        let outcome = state.terminateAll(reason: .monitoringStopped)
        #expect(outcome.events == [.cancelled(.dictation, .monitoringStopped)])
        #expect(state.phase(for: .dictation) == .idle)
        #expect(state.terminateAll(reason: .monitoringStopped).events.isEmpty)
    }
}

// MARK: - Invariants

@Suite struct HotkeyInvariantTests {
    /// Every `pressed` is followed by exactly one `released` or `cancelled`, per
    /// feature. That balance is what lets both adapters delete their own
    /// press-source tracking — and what stops a recorder running forever.
    @Test func pressedAndReleasedAreBalancedPerFeature() {
        var state = machine(dictation: [ctrl, cmdShiftD], pushToTalk: [ctrlOption])
        var events: [HotkeyEvent] = []

        func run(_ outcome: HotkeyStateMachine.Outcome) { events += outcome.events }

        run(state.flagsChanged([.control]))                     // dictation armed (ambiguous)
        run(state.graceElapsed(.dictation, ctrl))               // pressed
        run(state.keyDown(keyC))                                // cancelled
        run(state.flagsChanged(noModifiers))                    // nothing: already ended
        run(state.flagsChanged([.control, .option]))            // pushToTalk pressed
        run(state.flagsChanged([.control, .option, .shift]))    // pushToTalk released (policy)
        run(state.flagsChanged(noModifiers))
        run(state.comboKeyDown(.dictation, slot: 0))            // ⌘⇧D pressed
        run(state.flagsChanged([.control]))                     // ignored: combo owns it
        run(state.comboKeyUp(.dictation, slot: 0))              // released
        run(state.flagsChanged(noModifiers))

        for feature in HotkeyFeature.allCases {
            let mine = events.filter { $0.feature == feature }
            let presses = mine.filter { if case .pressed = $0 { return true } else { return false } }.count
            let ends = mine.filter {
                switch $0 {
                case .released, .cancelled: true
                default: false
                }
            }.count
            #expect(presses == ends, "\(feature) has \(presses) presses and \(ends) endings")
            #expect(presses > 0)
        }
        #expect(!state.isHeld(.dictation))
        #expect(!state.isHeld(.pushToTalk))
    }

    /// Every `armed` is answered by exactly one `pressed` or `disarmed`, or the
    /// microphone stays open with nothing on screen.
    @Test func armedIsAlwaysAnsweredByPressedOrDisarmed() {
        var state = ambiguousMachine()
        var events: [HotkeyEvent] = []

        events += state.flagsChanged([.control]).events              // armed
        events += state.flagsChanged([.control, .option]).events     // disarmed + ptt armed/pressed
        events += state.flagsChanged([.control]).events              // ptt released
        events += state.flagsChanged(noModifiers).events

        let armed = events.filter { if case .armed = $0 { return true } else { return false } }
        let answered = events.filter {
            switch $0 {
            case .pressed, .disarmed: true
            default: false
            }
        }
        #expect(armed.count == answered.count)
        #expect(armed.count == 2)
    }
}

// MARK: - Mouse buttons

@Suite struct HotkeyMouseButtonTests {
    /// Dictation on Mouse 4, push-to-talk on its usual ⌃⌥ hold.
    private func mouseMachine(
        dictation: [HotkeyBinding] = [mouse4],
        pushToTalk: [HotkeyBinding] = [ctrlOption]
    ) -> HotkeyStateMachine {
        machine(dictation: dictation, pushToTalk: pushToTalk)
    }

    @Test func boundButtonPressesAndReleases() {
        var state = mouseMachine()

        let down = state.mouseButtonsChanged(buttons(3))
        #expect(down.events == [.armed(.dictation), .pressed(.dictation, .mouseButton)])
        #expect(down.consumesEvent)
        #expect(state.isHeld(.dictation))

        let up = state.mouseButtonsChanged(noButtons)
        #expect(up.events == [.released(.dictation)])
        #expect(up.consumesEvent)          // swallow both halves, or the app sees a stray mouse-up
        #expect(!state.isHeld(.dictation))
    }

    /// A bound button must not trip the cancel path that any other click does.
    @Test func boundButtonDoesNotCancelItsOwnFeature() {
        var state = mouseMachine()
        _ = state.mouseButtonsChanged(buttons(3))
        #expect(state.isHeld(.dictation))
    }

    @Test func unboundClickIsNotConsumedAndStillCancelsDictation() {
        var state = mouseMachine()
        _ = state.mouseButtonsChanged(buttons(3))          // dictation held on Mouse 4

        let leftClick = state.mouseButtonsChanged(buttons(3, 0))
        #expect(leftClick.events == [.cancelled(.dictation, .mouseDown)])
        // Only bit 0 changed, and nobody bound it — the click must reach the app.
        #expect(!leftClick.consumesEvent)
        #expect(!state.isHeld(.dictation))
    }

    /// Mouse 4 goes up after the hold was already cancelled. There is nothing left
    /// to release, but the up must still be swallowed: its down was.
    @Test func theUpOfABoundButtonIsSwallowedEvenWithNoLiveHold() {
        var state = mouseMachine()
        _ = state.mouseButtonsChanged(buttons(3))
        _ = state.mouseButtonsChanged(buttons(3, 0))       // left click cancels dictation
        let up = state.mouseButtonsChanged(buttons(0))     // Mouse 4 released
        #expect(up.events.isEmpty)
        #expect(up.consumesEvent)
    }

    @Test func plainLeftClickIsNeverConsumed() {
        var state = mouseMachine()
        #expect(!state.mouseButtonsChanged(buttons(0)).consumesEvent)
    }

    /// The hazard this feature creates. Push-to-talk has `cancelsOnMouseDown == false`,
    /// so without an explicit termination both features would record at once and two
    /// AVAudioEngines would fight for the input node.
    @Test func boundButtonEndsTheOtherFeaturesLiveSession() {
        var state = mouseMachine(dictation: [mouse4], pushToTalk: [ctrlOption])
        _ = state.flagsChanged([.control, .option])
        #expect(state.isHeld(.pushToTalk))

        let outcome = state.mouseButtonsChanged(buttons(3))
        #expect(outcome.events == [
            .cancelled(.pushToTalk, .mouseDown),
            .armed(.dictation),
            .pressed(.dictation, .mouseButton),
        ])
        #expect(state.isHeld(.dictation))
        #expect(!state.isHeld(.pushToTalk))
    }

    /// A mouse hold owns no modifiers, so modifier traffic must not end it.
    @Test func modifiersDoNotDisturbAMouseHold() {
        var state = mouseMachine(dictation: [mouse4], pushToTalk: [])
        _ = state.mouseButtonsChanged(buttons(3))

        #expect(state.flagsChanged([.control]).events.isEmpty)
        #expect(state.flagsChanged(noModifiers).events.isEmpty)
        #expect(state.isHeld(.dictation))
    }

    @Test func otherKeyDownCancelsAMouseHold() {
        var state = mouseMachine()
        _ = state.mouseButtonsChanged(buttons(3))
        #expect(state.keyDown(keyC).events == [.cancelled(.dictation, .otherKeyDown)])
    }

    /// The resync after macOS kills the tap: the button came up while we were deaf,
    /// so the first mask we see again has it clear. The hold must end, not strand.
    @Test func resyncWithTheButtonAlreadyUpEndsTheHold() {
        var state = mouseMachine()
        _ = state.mouseButtonsChanged(buttons(3))
        #expect(state.mouseButtonsChanged(noButtons).events == [.released(.dictation)])
        #expect(!state.isHeld(.dictation))
    }

    /// Both sources deliver when Buddy is frontmost; the second mask is identical.
    @Test func aRepeatedMaskIsADuplicateAndDoesNothing() {
        var state = mouseMachine()
        _ = state.mouseButtonsChanged(buttons(3))
        #expect(state.mouseButtonsChanged(buttons(3)).events.isEmpty)
        #expect(state.isHeld(.dictation))
    }

    @Test func pressWhileAlreadyHeldByModifiersIsIgnored() {
        var state = mouseMachine(dictation: [ctrlShift, mouse4], pushToTalk: [])
        _ = state.flagsChanged([.control, .shift])
        #expect(state.mouseButtonsChanged(buttons(3)).events.isEmpty)
        #expect(state.isHeld(.dictation))
    }

    @Test func pushToTalkOnMouse5Works() {
        var state = mouseMachine(dictation: [ctrlShift], pushToTalk: [mouse5])
        let outcome = state.mouseButtonsChanged(buttons(4))
        #expect(outcome.events == [.armed(.pushToTalk), .pressed(.pushToTalk, .mouseButton)])
        #expect(state.isHeld(.pushToTalk))
    }

    @Test func aMouseBindingNeedsTheEventTap() {
        let table = HotkeyMatchTable(bindings: [.dictation: [mouse4], .pushToTalk: []])
        #expect(table.needsEventTap)
        #expect(table.hasMouseButtons)
    }

    /// A mouse binding must never be filed as a Carbon combo — that would shift
    /// every `KeyboardShortcuts.Name` slot out from under `combo(at:)`.
    @Test func aMouseBindingIsNotACarbonCombo() {
        let table = HotkeyMatchTable(bindings: [.dictation: [mouse4, optionSpace], .pushToTalk: []])
        #expect(table.combo(at: 0, for: .dictation) == optionSpace)
        #expect(table.combo(at: 1, for: .dictation) == nil)
    }
}
