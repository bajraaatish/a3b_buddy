//
//  HotkeyMigration.swift
//  Buddy — flexible hotkeys
//
//  Translates every legacy trigger store into `hotkey.dictation` /
//  `hotkey.pushToTalk`, once, on first launch after an update. Versioned,
//  because there have now been two rounds of it.
//
//    v1  holdKey                        → dictation .modifiersOnly
//        KeyboardShortcuts_dictation    → dictation .keyCombo
//        pushToTalkModifierOnlyShortcut → pushToTalk .modifiersOnly
//        KeyboardShortcuts_pushToTalk   → pushToTalk .keyCombo
//
//    v2  retire the ⌃ dictation hold. v1 shipped ⌃ for dictation next to ⌃⌥
//        for push-to-talk, and ⌃ ⊊ ⌃⌥ — every ⌃⌥ press passes through ⌃, so
//        dictation had to sit behind a 200 ms grace window and clipped its
//        first syllable. ⌃⇧ is disjoint from ⌃⌥. Only rewrites a binding the
//        user never touched.
//
//  Fresh installs land on the same values, which is why this runs before
//  anything reads a binding. It has to: `KeyboardShortcuts.Name.init` writes
//  its `default:` into UserDefaults as a side effect, so if a Name carried a
//  default we'd be migrating a value we had just caused. None of them do —
//  this file is the single seeder.
//
//  Three populations must all land correctly:
//
//    fresh install          nothing stored          → seed ⌃⇧ / ⌃⌥
//    pre-flexible build     legacy keys, no hotkey.* → translate, respect "off"
//    ran the v1 migration   hotkeyMigrationVersion=1 → v2 step only
//

import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

enum HotkeyMigration {
    static let currentVersion = 2

    /// What a legacy `KeyboardShortcuts` store held for a given Name.
    enum LegacyCombo: Equatable {
        /// Key absent — the user never recorded a combo. Don't invent one.
        case neverSet
        /// Key present but nil — the user deliberately cleared it. Respect that.
        case clearedByUser
        case shortcut(HotkeyBinding)
    }

    /// `legacyCombo` is injectable so the tests can drive the never-set /
    /// cleared / set cases without a real KeyboardShortcuts store. It's
    /// `@MainActor` because the default implementation is.
    @MainActor
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        legacyCombo: @MainActor (HotkeyFeature, UserDefaults) -> LegacyCombo = readLegacyCombo
    ) {
        let installedVersion = defaults.integer(forKey: PrefKey.hotkeyMigrationVersion)
        guard installedVersion < currentVersion else { return }

        if installedVersion < 1 {
            migrate(.dictation, defaults: defaults, legacyCombo: legacyCombo(.dictation, defaults))
            migrate(.pushToTalk, defaults: defaults, legacyCombo: legacyCombo(.pushToTalk, defaults))
            separateDuplicateHolds(defaults: defaults)
        }

        if installedVersion < 2 {
            retireCollidingDictationHold(defaults: defaults)
        }

        defaults.set(currentVersion, forKey: PrefKey.hotkeyMigrationVersion)
    }

    // MARK: v1 — legacy stores → [HotkeyBinding]

    /// A feature's bindings are `[hold?, combo?]`. Both halves are carried
    /// forward only when the user explicitly chose them; otherwise the shipped
    /// default fills in. Absent ≠ off: `"off"` is a choice and stays a choice.
    static func migrate(
        _ feature: HotkeyFeature,
        defaults: UserDefaults,
        legacyCombo: LegacyCombo
    ) {
        guard defaults.object(forKey: feature.defaultsKey) == nil else { return }

        var bindings: [HotkeyBinding] = []

        if let legacyHold = defaults.string(forKey: feature.legacyModifierOnlyKey) {
            // `nil` here means the raw value was "off" — the user turned the
            // bare hold off and lived on the combo alone. Don't hand it back.
            if let modifiers = legacyModifiers(fromRawValue: legacyHold) {
                bindings.append(.modifiersOnly(modifiers))
            }
        } else {
            bindings.append(contentsOf: feature.defaultBindings)
        }

        switch legacyCombo {
        case .neverSet, .clearedByUser:
            break
        case .shortcut(let binding):
            bindings.append(binding)
        }

        HotkeyBindingStore.write(Array(bindings.prefix(feature.maxBindings)), to: feature.defaultsKey, in: defaults)
    }

    /// Parses both legacy spellings of a modifier-only hold:
    ///
    ///   pre-merge `HoldKey`           "control"  "fn"  "off"
    ///   merged `ModifierOnlyShortcut` "control+option"  "shift"  "off"
    ///
    /// Returns `nil` for `"off"` and for anything unparseable — both mean
    /// "emit no hold binding".
    static func legacyModifiers(fromRawValue rawValue: String) -> NSEvent.ModifierFlags? {
        let tokens = rawValue.split(separator: "+").map(String.init)
        guard !tokens.isEmpty else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        for token in tokens {
            guard let flag = legacyModifierFlags[token] else { return nil } // "off" lands here
            modifiers.insert(flag)
        }
        return modifiers.isEmpty ? nil : modifiers
    }

    private static let legacyModifierFlags: [String: NSEvent.ModifierFlags] = [
        "control": .control,
        "option": .option,
        "command": .command,
        "shift": .shift,
        "fn": .function,
    ]

    /// Reads whatever `KeyboardShortcuts` persisted for this feature's first
    /// combo slot. Reads the raw key first: `getShortcut(for:)` returns nil both
    /// for "never set" and "cleared", and those two want different outcomes.
    @MainActor
    static func readLegacyCombo(_ feature: HotkeyFeature, _ defaults: UserDefaults) -> LegacyCombo {
        guard let name = feature.comboShortcutNames.first else { return .neverSet }
        guard defaults.object(forKey: "KeyboardShortcuts_\(name.rawValue)") != nil else { return .neverSet }
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return .clearedByUser }
        return .shortcut(.keyCombo(keyCode: UInt16(shortcut.carbonKeyCode), modifiers: shortcut.modifiers))
    }

    /// Migration is the one path that writes bindings without going through
    /// `HotkeyConflictChecker`. A user who had set the old dictation dropdown to
    /// ⌃⌥ would land here holding push-to-talk's binding, and both features
    /// would fire on every press. Give dictation its default back instead.
    static func separateDuplicateHolds(defaults: UserDefaults) {
        let dictation = HotkeyBindingStore.read(from: PrefKey.dictationBinding, in: defaults) ?? []
        let pushToTalk = HotkeyBindingStore.read(from: PrefKey.pushToTalkBinding, in: defaults) ?? []

        // Compare raw values: NSEvent.ModifierFlags is an OptionSet, not Hashable.
        let pushToTalkHolds = Set(pushToTalk.filter(\.isModifiersOnly).map(\.modifierFlags.rawValue))
        guard dictation.contains(where: { $0.isModifiersOnly && pushToTalkHolds.contains($0.modifierFlags.rawValue) }) else {
            return
        }

        let combos = dictation.filter { !$0.isModifiersOnly }
        HotkeyBindingStore.write(
            HotkeyFeature.dictation.defaultBindings + combos,
            to: PrefKey.dictationBinding,
            in: defaults
        )
    }

    // MARK: v2 — retire the prefix-conflicting ⌃ hold

    /// What v1 wrote for a user who never customised anything.
    static let version1DictationDefault: [HotkeyBinding] = [
        .modifiersOnly(.control),
        .keyCombo(keyCode: UInt16(kVK_Space), modifiers: .option),
    ]

    static func retireCollidingDictationHold(defaults: UserDefaults) {
        let stored = HotkeyBindingStore.read(from: PrefKey.dictationBinding, in: defaults)
        guard stored == version1DictationDefault else { return }

        HotkeyBindingStore.write(
            HotkeyFeature.dictation.defaultBindings,
            to: PrefKey.dictationBinding,
            in: defaults
        )
    }
}
