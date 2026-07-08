//
//  HotkeyMigrationTests.swift
//  A3BBuddyTests — flexible hotkeys
//
//  Drives the migration against every population that can reach it. Uses a
//  in-memory HotkeyDefaults and an injected legacy-combo reader, so no test
//  touches `UserDefaults.standard`, KeyboardShortcuts' real store, or Carbon.
//

import AppKit
import Carbon.HIToolbox
import Testing
@testable import A3BBuddy

private let space = UInt16(kVK_Space)
private let keyD = UInt16(kVK_ANSI_D)

/// No disk, no `cfprefsd`, no stray `~/Library/Preferences/<uuid>.plist`.
/// See `HotkeyDefaults.swift` for why a `UserDefaults(suiteName:)` cannot be
/// cleaned up reliably from a `defer`.
private func withScratchDefaults(_ body: (HotkeyDefaults) throws -> Void) rethrows {
    try body(InMemoryHotkeyDefaults())
}

private func dictationBindings(_ defaults: HotkeyDefaults) -> [HotkeyBinding]? {
    HotkeyBindingStore.read(from: PrefKey.dictationBinding, in: defaults)
}

private func pushToTalkBindings(_ defaults: HotkeyDefaults) -> [HotkeyBinding]? {
    HotkeyBindingStore.read(from: PrefKey.pushToTalkBinding, in: defaults)
}

/// Stand-in for the real `KeyboardShortcuts` reader.
private func combos(
    dictation: HotkeyMigration.LegacyCombo = .neverSet,
    pushToTalk: HotkeyMigration.LegacyCombo = .neverSet
) -> @MainActor (HotkeyFeature, HotkeyDefaults) -> HotkeyMigration.LegacyCombo {
    { feature, _ in feature == .dictation ? dictation : pushToTalk }
}

// MARK: - The dual-format hold parser

struct LegacyHoldParsingTests {
    /// Pre-merge `HoldKey` raw values: single tokens.
    @Test func parsesTheOldSingleModifierSpelling() {
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "control") == .control)
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "option") == .option)
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "command") == .command)
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "fn") == .function)
    }

    /// Merged `ModifierOnlyShortcut` raw values: `+`-joined. The salvaged
    /// migration parsed these with `HoldKey(rawValue:) ?? .control`, silently
    /// turning ⇧ and ⌃⌥ into ⌃.
    @Test func parsesTheNewMultiModifierSpelling() {
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "shift") == .shift)
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "control+option") == [.control, .option])
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "control+shift") == [.control, .shift])
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "command+shift") == [.command, .shift])
    }

    @Test func offAndGarbageProduceNoHold() {
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "off") == nil)
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "") == nil)
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "banana") == nil)
        #expect(HotkeyMigration.legacyModifiers(fromRawValue: "control+banana") == nil)
    }
}

// MARK: - Population matrix

@MainActor
struct HotkeyMigrationPopulationTests {

    /// Nothing stored anywhere.
    @Test func freshInstallSeedsBothDefaults() {
        withScratchDefaults { defaults in
            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(dictationBindings(defaults) == [.modifiersOnly([.control, .shift])])
            #expect(pushToTalkBindings(defaults) == [.modifiersOnly([.control, .option])])
            #expect(defaults.integer(forKey: PrefKey.hotkeyMigrationVersion) == 2)
        }
    }

    /// A fresh install must NOT inherit v1's ⌃ hold or its ⌥Space alternate.
    @Test func freshInstallDoesNotShipTheCollidingDefaults() {
        withScratchDefaults { defaults in
            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(dictationBindings(defaults) != HotkeyMigration.version1DictationDefault)
        }
    }

    /// The exact state of the owner's machine: v1 already ran and stored the
    /// prefix-conflicting ⌃ hold (⌃ ⊊ ⌃⌥). v2 must retire it.
    @Test func alreadyMigratedV1UserLosesTheCollidingHold() {
        withScratchDefaults { defaults in
            HotkeyBindingStore.write(
                HotkeyMigration.version1DictationDefault,
                to: PrefKey.dictationBinding,
                in: defaults
            )
            HotkeyBindingStore.write(
                [.modifiersOnly([.control, .option])],
                to: PrefKey.pushToTalkBinding,
                in: defaults
            )
            defaults.set(1, forKey: PrefKey.hotkeyMigrationVersion)

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(dictationBindings(defaults) == [.modifiersOnly([.control, .shift])])
            // Push-to-talk was already correct and must be untouched.
            #expect(pushToTalkBindings(defaults) == [.modifiersOnly([.control, .option])])
            #expect(defaults.integer(forKey: PrefKey.hotkeyMigrationVersion) == 2)
        }
    }

    /// A v1 user who customised dictation keeps their choice. v2 only retires
    /// the untouched default pair.
    @Test func alreadyMigratedV1UserWithACustomHoldIsUntouched() {
        withScratchDefaults { defaults in
            let custom: [HotkeyBinding] = [.modifiersOnly(.function)]
            HotkeyBindingStore.write(custom, to: PrefKey.dictationBinding, in: defaults)
            HotkeyBindingStore.write([.modifiersOnly([.control, .option])], to: PrefKey.pushToTalkBinding, in: defaults)
            defaults.set(1, forKey: PrefKey.hotkeyMigrationVersion)

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(dictationBindings(defaults) == custom)
        }
    }

    @Test func alreadyOnV2ShortCircuits() {
        withScratchDefaults { defaults in
            let custom: [HotkeyBinding] = [.modifiersOnly(.command)]
            HotkeyBindingStore.write(custom, to: PrefKey.dictationBinding, in: defaults)
            defaults.set(2, forKey: PrefKey.hotkeyMigrationVersion)

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(dictationBindings(defaults) == custom)
            #expect(pushToTalkBindings(defaults) == nil) // never seeded — we returned early
        }
    }

    /// The exact case the salvaged `HoldKey(rawValue:) ?? .control` corrupted.
    @Test func currentBranchShiftHoldSurvives() {
        withScratchDefaults { defaults in
            defaults.set("shift", forKey: PrefKey.dictationModifierOnlyShortcut)

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(dictationBindings(defaults) == [.modifiersOnly(.shift)])
        }
    }

    @Test func currentBranchCustomPushToTalkHoldIsCarriedForwardNotReseeded() {
        withScratchDefaults { defaults in
            defaults.set("command+shift", forKey: PrefKey.pushToTalkModifierOnlyShortcut)

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(pushToTalkBindings(defaults) == [.modifiersOnly([.command, .shift])])
        }
    }

    /// "off" is a choice, not an absence. Don't hand the hold back.
    @Test func holdOffProducesNoModifierHold() {
        withScratchDefaults { defaults in
            defaults.set("off", forKey: PrefKey.dictationModifierOnlyShortcut)

            HotkeyMigration.runIfNeeded(
                defaults: defaults,
                legacyCombo: combos(dictation: .shortcut(.keyCombo(keyCode: space, modifiers: .option)))
            )

            #expect(dictationBindings(defaults) == [.keyCombo(keyCode: space, modifiers: .option)])
        }
    }

    @Test func explicitComboIsCarriedForward() {
        withScratchDefaults { defaults in

            HotkeyMigration.runIfNeeded(
                defaults: defaults,
                legacyCombo: combos(dictation: .shortcut(.keyCombo(keyCode: keyD, modifiers: [.command, .shift])))
            )

            #expect(dictationBindings(defaults) == [
                .modifiersOnly([.control, .shift]),
                .keyCombo(keyCode: keyD, modifiers: [.command, .shift]),
            ])
        }
    }

    /// `getShortcut` returns nil for both "never set" and "cleared". A combo the
    /// user deliberately deleted must not come back.
    @Test func clearedComboIsNotResurrected() {
        withScratchDefaults { defaults in

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos(dictation: .clearedByUser))

            #expect(dictationBindings(defaults) == [.modifiersOnly([.control, .shift])])
        }
    }

    /// The nil-guard, not the version integer, is the real idempotency.
    @Test func neverOverwritesAnExistingBinding() {
        withScratchDefaults { defaults in
            let custom: [HotkeyBinding] = [.modifiersOnly(.command)]
            HotkeyBindingStore.write(custom, to: PrefKey.dictationBinding, in: defaults)
            // version 0 → the whole migration body runs
            defaults.set("shift", forKey: PrefKey.dictationModifierOnlyShortcut)

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(dictationBindings(defaults) == custom)
        }
    }

    @Test func neverExceedsMaxBindings() {
        withScratchDefaults { defaults in
            defaults.set("control+shift", forKey: PrefKey.dictationModifierOnlyShortcut)

            HotkeyMigration.runIfNeeded(
                defaults: defaults,
                legacyCombo: combos(dictation: .shortcut(.keyCombo(keyCode: keyD, modifiers: .command)))
            )

            #expect(dictationBindings(defaults)?.count == HotkeyFeature.dictation.maxBindings)
        }
    }

    /// Migration is the one path that writes bindings without consulting
    /// `HotkeyConflictChecker`. A current-branch user who set the dictation
    /// dropdown to ⌃⌥ would otherwise land holding push-to-talk's binding, and
    /// both features would fire on every press.
    @Test func aDictationHoldThatDuplicatesPushToTalkIsSeparated() {
        withScratchDefaults { defaults in
            defaults.set("control+option", forKey: PrefKey.dictationModifierOnlyShortcut)
            defaults.set("control+option", forKey: PrefKey.pushToTalkModifierOnlyShortcut)

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(pushToTalkBindings(defaults) == [.modifiersOnly([.control, .option])])
            #expect(dictationBindings(defaults) == [.modifiersOnly([.control, .shift])])
        }
    }

    /// …but a non-colliding custom hold is left exactly as the user set it.
    @Test func aDistinctDictationHoldIsNotSeparated() {
        withScratchDefaults { defaults in
            defaults.set("command+shift", forKey: PrefKey.dictationModifierOnlyShortcut)
            defaults.set("control+option", forKey: PrefKey.pushToTalkModifierOnlyShortcut)

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(dictationBindings(defaults) == [.modifiersOnly([.command, .shift])])
        }
    }
}

// MARK: - Golden file: what v1 actually wrote to disk

/// The v2 step only fires when the stored dictation bindings compare `==` to
/// `version1DictationDefault`. That comparison happens after a JSON round-trip,
/// so a mismatch in the *encoding* — not the values — would silently skip the
/// migration and leave the owner on the colliding ⌃ hold.
///
/// This is the literal blob `defaults read com.a3b.buddy hotkey.dictation`
/// returned on the development machine, written by the v1 migration.
struct Version1GoldenBlobTests {
    private static let v1DictationBlobOnDisk = #"""
    [{"modifiersOnly":{"modifiers":262144}},{"keyCombo":{"modifiers":524288,"keyCode":49}}]
    """#

    @Test func theBlobOnDiskDecodesToVersion1Default() throws {
        let data = Data(Self.v1DictationBlobOnDisk.utf8)
        let decoded = try JSONDecoder().decode([HotkeyBinding].self, from: data)

        #expect(decoded == HotkeyMigration.version1DictationDefault)
    }

    /// 262144 == .control, 524288 == .option, 49 == Space. If AppKit ever
    /// renumbered these the blob would decode into something else entirely.
    @Test func theRawModifierValuesAreWhatWeThinkTheyAre() {
        #expect(NSEvent.ModifierFlags.control.rawValue == 262144)
        #expect(NSEvent.ModifierFlags.option.rawValue == 524288)
        #expect(space == 49)
    }

    /// End to end, against the real bytes: a machine holding this blob at
    /// version 1 must come out the other side on ⌃⇧.
    @MainActor
    @Test func theOwnersMachineMigratesOffTheCollidingHold() {
        withScratchDefaults { defaults in
            defaults.set(Data(Self.v1DictationBlobOnDisk.utf8), forKey: PrefKey.dictationBinding)
            defaults.set(
                Data(#"[{"modifiersOnly":{"modifiers":786432}}]"#.utf8), // ⌃⌥
                forKey: PrefKey.pushToTalkBinding
            )
            defaults.set(1, forKey: PrefKey.hotkeyMigrationVersion)

            HotkeyMigration.runIfNeeded(defaults: defaults, legacyCombo: combos())

            #expect(dictationBindings(defaults) == [.modifiersOnly([.control, .shift])])
            #expect(pushToTalkBindings(defaults) == [.modifiersOnly([.control, .option])])
            #expect(defaults.integer(forKey: PrefKey.hotkeyMigrationVersion) == 2)
        }
    }
}

// MARK: - The shipped defaults must stay disjoint

struct ShippedDefaultsTests {
    /// The whole reason ⌃⇧ replaced ⌃: neither default may be a subset of the
    /// other, or one of them sits behind HotkeyEngine's 200 ms grace window and
    /// clips its first syllable.
    @Test func shippedDefaultsAreDisjoint() {
        let dictation = HotkeyFeature.dictation.defaultBindings
            .filter(\.isModifiersOnly).map(\.modifierFlags)
        let pushToTalk = HotkeyFeature.pushToTalk.defaultBindings
            .filter(\.isModifiersOnly).map(\.modifierFlags)

        #expect(!dictation.isEmpty)
        #expect(!pushToTalk.isEmpty)

        for lhs in dictation {
            for rhs in pushToTalk {
                #expect(!lhs.isSubset(of: rhs), "\(lhs) ⊆ \(rhs) — needs a grace window")
                #expect(!rhs.isSubset(of: lhs), "\(rhs) ⊆ \(lhs) — needs a grace window")
            }
        }
    }

    /// And the checker must agree, or Settings would refuse to display them.
    @Test func shippedDefaultsRaiseNoConflict() {
        let all: [HotkeyFeature: [HotkeyBinding]] = [
            .dictation: HotkeyFeature.dictation.defaultBindings,
            .pushToTalk: HotkeyFeature.pushToTalk.defaultBindings,
        ]
        for feature in HotkeyFeature.allCases {
            for (slot, binding) in all[feature]!.enumerated() {
                let verdict = HotkeyConflictChecker.evaluate(binding, for: feature, slot: slot, against: all)
                #expect(verdict == .none, "\(binding.displayString) → \(String(describing: verdict.message))")
            }
        }
    }
}
