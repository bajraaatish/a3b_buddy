//
//  HotkeyConflictTests.swift
//  A3BBuddyTests — flexible hotkeys
//
//  Drives the conflict decision table. Pure value types, no app launch,
//  no TCC, no event tap.
//

import AppKit
import Carbon.HIToolbox
import Testing
@testable import A3BBuddy

private let space = UInt16(kVK_Space)
private let keyD = UInt16(kVK_ANSI_D)
private let keyQ = UInt16(kVK_ANSI_Q)
private let f5 = UInt16(kVK_F5)

private func evaluate(
    _ candidate: HotkeyBinding,
    for feature: HotkeyFeature = .dictation,
    slot: Int = 0,
    against bindings: [HotkeyFeature: [HotkeyBinding]] = [:]
) -> HotkeyConflict {
    HotkeyConflictChecker.evaluate(candidate, for: feature, slot: slot, against: bindings)
}

// MARK: - Standalone rules

struct HotkeyStandaloneRuleTests {
    @Test func modifierOnlyWithNoModifiersIsBlocked() {
        #expect(evaluate(.modifiersOnly([])).isBlocking)
    }

    @Test func bareFunctionKeyHoldWarnsAboutMacOSStealingIt() {
        guard case .warn = evaluate(.modifiersOnly(.function)) else {
            Issue.record("fn hold should warn, not block — it works, macOS just also acts on it")
            return
        }
    }

    /// `Shortcut.init?(event:)` strips `.function`, and RegisterEventHotKey has
    /// no bit for it. An fn combo would register garbage and never fire.
    @Test func functionKeyInsideAComboIsBlocked() {
        #expect(evaluate(.keyCombo(keyCode: keyD, modifiers: [.function, .command])).isBlocking)
    }

    @Test func comboNeedsAModifierThatIsNotShift() {
        #expect(evaluate(.keyCombo(keyCode: keyD, modifiers: [])).isBlocking)
        #expect(evaluate(.keyCombo(keyCode: keyD, modifiers: .shift)).isBlocking)
        #expect(evaluate(.keyCombo(keyCode: keyD, modifiers: [.shift, .command])) == .none)
    }

    /// F5 alone is a legitimate shortcut; "D" alone is not.
    @Test func bareFunctionKeyComboIsAllowed() {
        #expect(evaluate(.keyCombo(keyCode: f5, modifiers: [])) == .none)
    }

    @Test func systemShortcutsWarnButDoNotBlock() {
        let spotlight = evaluate(.keyCombo(keyCode: space, modifiers: .command))
        #expect(!spotlight.isBlocking)
        #expect(spotlight.message != nil)

        let quit = evaluate(.keyCombo(keyCode: keyQ, modifiers: .command))
        #expect(!quit.isBlocking)
    }
}

// MARK: - Pairwise rules

struct HotkeyPairwiseRuleTests {
    @Test func identicalCombosAcrossFeaturesAreBlocked() {
        let verdict = evaluate(
            .keyCombo(keyCode: keyD, modifiers: [.command, .shift]),
            for: .dictation,
            against: [.pushToTalk: [.keyCombo(keyCode: keyD, modifiers: [.command, .shift])]]
        )
        #expect(verdict.isBlocking)
    }

    @Test func sameKeyDifferentModifiersIsFine() {
        let verdict = evaluate(
            .keyCombo(keyCode: keyD, modifiers: [.command, .shift]),
            for: .dictation,
            against: [.pushToTalk: [.keyCombo(keyCode: keyD, modifiers: [.control, .option])]]
        )
        #expect(verdict == .none)
    }

    @Test func identicalModifierHoldsAreBlocked() {
        let verdict = evaluate(
            .modifiersOnly([.control, .option]),
            for: .dictation,
            against: [.pushToTalk: [.modifiersOnly([.control, .option])]]
        )
        #expect(verdict.isBlocking)
    }

    /// ⌃ ⊊ ⌃⌥ — the pair v1 used to ship. Survivable, because the 200 ms grace
    /// window separates them, so this warns rather than blocks. The shipped
    /// defaults no longer collide (see `shippedDefaultsAreDisjoint`), but a user
    /// may still choose a pair like this.
    @Test func prefixOverlappingHoldsWarnAboutTheGraceWindow() {
        let verdict = evaluate(
            .modifiersOnly(.control),
            for: .dictation,
            against: [.pushToTalk: [.modifiersOnly([.control, .option])]]
        )
        #expect(!verdict.isBlocking)
        #expect(verdict.message != nil)
    }

    @Test func supersetHoldAlsoWarns() {
        let verdict = evaluate(
            .modifiersOnly([.control, .option]),
            for: .pushToTalk,
            against: [.dictation: [.modifiersOnly(.control)]]
        )
        #expect(!verdict.isBlocking)
        #expect(verdict.message != nil)
    }

    @Test func disjointHoldsAreFine() {
        let verdict = evaluate(
            .modifiersOnly(.command),
            for: .dictation,
            against: [.pushToTalk: [.modifiersOnly([.control, .option])]]
        )
        #expect(verdict == .none)
    }

    /// You cannot type ⌃⌥Space without first holding ⌃⌥, which fires the hold.
    /// Unreachable, so blocked. Note ⊆, not ⊊ — an exact match blocks too.
    @Test func comboWhoseModifiersContainAnExistingHoldIsBlocked() {
        let exact = evaluate(
            .keyCombo(keyCode: space, modifiers: [.control, .option]),
            for: .dictation,
            against: [.pushToTalk: [.modifiersOnly([.control, .option])]]
        )
        #expect(exact.isBlocking)

        let strictSuperset = evaluate(
            .keyCombo(keyCode: space, modifiers: [.control, .option, .shift]),
            for: .dictation,
            against: [.pushToTalk: [.modifiersOnly([.control, .option])]]
        )
        #expect(strictSuperset.isBlocking)
    }

    @Test func holdThatPrefixesAnExistingComboIsBlocked() {
        let verdict = evaluate(
            .modifiersOnly(.control),
            for: .pushToTalk,
            against: [.dictation: [.keyCombo(keyCode: space, modifiers: [.control, .option])]]
        )
        #expect(verdict.isBlocking)
    }

    @Test func holdDisjointFromAnExistingCombosModifiersIsFine() {
        let verdict = evaluate(
            .modifiersOnly(.control),
            for: .pushToTalk,
            against: [.dictation: [.keyCombo(keyCode: space, modifiers: .option)]]
        )
        #expect(verdict == .none)
    }

    /// The whole point of the `slot` parameter: re-recording the same binding
    /// into the slot it already occupies must not conflict with itself.
    @Test func aBindingDoesNotConflictWithItsOwnSlot() {
        let existing: [HotkeyFeature: [HotkeyBinding]] = [.dictation: [.modifiersOnly(.control)]]
        #expect(evaluate(.modifiersOnly(.control), for: .dictation, slot: 0, against: existing) == .none)
    }

    @Test func aBindingDoesConflictWithItsOwnFeaturesOtherSlot() {
        let existing: [HotkeyFeature: [HotkeyBinding]] = [.dictation: [.modifiersOnly(.control)]]
        #expect(evaluate(.modifiersOnly(.control), for: .dictation, slot: 1, against: existing).isBlocking)
    }

    /// A pairwise block must win over a merely-standalone warning.
    @Test func blockBeatsWarn() {
        let verdict = evaluate(
            .keyCombo(keyCode: space, modifiers: .command),   // system shortcut → warn
            for: .dictation,
            against: [.pushToTalk: [.keyCombo(keyCode: space, modifiers: .command)]]  // duplicate → block
        )
        #expect(verdict.isBlocking)
    }

    /// The shipped defaults must at minimum be saveable.
    @Test func shippedDefaultsAreNotBlocking() {
        let defaults = Dictionary(
            uniqueKeysWithValues: HotkeyFeature.allCases.map { ($0, $0.defaultBindings) }
        )
        for feature in HotkeyFeature.allCases {
            for (slot, binding) in feature.defaultBindings.enumerated() {
                let verdict = evaluate(binding, for: feature, slot: slot, against: defaults)
                #expect(!verdict.isBlocking, "\(feature.displayName) slot \(slot): \(verdict.message ?? "")")
            }
        }
    }
}

// MARK: - Value semantics

struct HotkeyBindingTests {
    @Test func roundTripsThroughJSON() throws {
        let bindings: [HotkeyBinding] = [
            .modifiersOnly([.control, .option]),
            .keyCombo(keyCode: space, modifiers: .option),
        ]
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode([HotkeyBinding].self, from: data) == bindings)
    }

    /// Device-side and caps-lock bits must never reach persistence, or two
    /// bindings the user thinks are identical compare unequal.
    @Test func unrecognizedModifierBitsAreStripped() {
        let noisy = HotkeyBinding.modifiersOnly([.control, .capsLock, .numericPad])
        #expect(noisy == .modifiersOnly(.control))
    }

    @Test func displayStringUsesAppleGlyphOrder() {
        #expect(HotkeyBinding.modifiersOnly([.command, .control, .shift, .option]).displayString == "⌃⌥⇧⌘")
        #expect(HotkeyBinding.modifiersOnly(.function).displayString == "fn")
        #expect(HotkeyBinding.keyCombo(keyCode: space, modifiers: .option).displayString == "⌥Space")
        #expect(HotkeyBinding.keyCombo(keyCode: keyD, modifiers: [.command, .shift]).displayString == "⇧⌘D")
    }

    @Test func onlyModifierOnlyHoldsNeedInputMonitoring() {
        #expect(HotkeyBinding.modifiersOnly(.control).requiresInputMonitoring)
        #expect(!HotkeyBinding.keyCombo(keyCode: space, modifiers: .option).requiresInputMonitoring)
    }

    // MARK: Mouse buttons

    @Test func mouseButtonRoundTripsThroughJSON() throws {
        let bindings: [HotkeyBinding] = [.mouseButton(number: 3), .modifiersOnly(.control)]
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode([HotkeyBinding].self, from: data) == bindings)
    }

    /// The new case encodes under its own key, so a blob written before it existed
    /// still decodes. Adding a mouse binding must never need a schema migration.
    @Test func preMouseBlobStillDecodes() throws {
        let legacy = #"[{"modifiersOnly":{"modifiers":262144}},{"keyCombo":{"modifiers":524288,"keyCode":49}}]"#
        let decoded = try JSONDecoder().decode([HotkeyBinding].self, from: Data(legacy.utf8))
        #expect(decoded == [.modifiersOnly(.control), .keyCombo(keyCode: space, modifiers: .option)])
    }

    /// Button 3 is what every mouse calls "Mouse 4".
    @Test func mouseButtonDisplayStringIsOneBased() {
        #expect(HotkeyBinding.mouseButton(number: 3).displayString == "Mouse 4")
        #expect(HotkeyBinding.mouseButton(number: 4).displayString == "Mouse 5")
    }

    @Test func aMouseButtonNeedsTheEventTapButIsNotACombo() {
        let mouse4 = HotkeyBinding.mouseButton(number: 3)
        #expect(mouse4.requiresInputMonitoring)
        #expect(!mouse4.isKeyCombo)
        #expect(!mouse4.isModifiersOnly)
        #expect(mouse4.mouseButtonNumber == 3)
        #expect(mouse4.modifierFlags.isEmpty)
    }
}

// MARK: - Mouse-button conflict rules

struct HotkeyMouseConflictTests {
    private func evaluate(
        _ candidate: HotkeyBinding,
        for feature: HotkeyFeature = .dictation,
        slot: Int = 0,
        against bindings: [HotkeyFeature: [HotkeyBinding]] = [:]
    ) -> HotkeyConflict {
        HotkeyConflictChecker.evaluate(candidate, for: feature, slot: slot, against: bindings)
    }

    @Test(arguments: [3, 4])
    func sideButtonsAreAllowed(_ number: Int) {
        #expect(evaluate(.mouseButton(number: number)) == .none)
    }

    /// Binding left-click would make the Mac unusable; middle-click is paste in a
    /// terminal and close-tab in a browser.
    @Test(arguments: [0, 1, 2, 5])
    func everyOtherButtonIsBlocked(_ number: Int) {
        #expect(evaluate(.mouseButton(number: number)).isBlocking)
    }

    @Test func theSameButtonTwiceIsBlocked() {
        let verdict = evaluate(
            .mouseButton(number: 3),
            for: .dictation,
            against: [.pushToTalk: [.mouseButton(number: 3)]]
        )
        #expect(verdict.isBlocking)
    }

    @Test func differentButtonsCoexist() {
        let verdict = evaluate(
            .mouseButton(number: 3),
            for: .dictation,
            against: [.pushToTalk: [.mouseButton(number: 4)]]
        )
        #expect(verdict == .none)
    }

    /// A button and a key are orthogonal channels. An empty modifier set must not
    /// fall into the subset rules, where it is a strict subset of everything.
    @Test func aMouseButtonNeverConflictsWithAKeyboardBinding() {
        let against: [HotkeyFeature: [HotkeyBinding]] = [
            .pushToTalk: [.modifiersOnly([.control, .option]), .keyCombo(keyCode: space, modifiers: .option)]
        ]
        #expect(evaluate(.mouseButton(number: 3), for: .dictation, against: against) == .none)
        #expect(evaluate(.modifiersOnly([.control, .shift]), for: .dictation,
                         against: [.pushToTalk: [.mouseButton(number: 3)]]) == .none)
        #expect(evaluate(.keyCombo(keyCode: keyD, modifiers: [.command, .shift]), for: .dictation,
                         against: [.pushToTalk: [.mouseButton(number: 3)]]) == .none)
    }
}
