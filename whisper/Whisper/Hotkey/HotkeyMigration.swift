//
//  HotkeyMigration.swift
//  Whisper — flexible hotkeys
//
//  Translates the two legacy trigger stores into `hotkey.dictation` /
//  `hotkey.pushToTalk`, once, on first launch after the update:
//
//    holdKey                 (⌃ by default)      → .modifiersOnly(⌃)
//    KeyboardShortcuts_dictation (⌥Space)        → .keyCombo(Space, ⌥)
//    BuddyPushToTalkShortcut.controlOption       → .modifiersOnly(⌃⌥)
//
//  The clicky side has no stored value at all — it was a compile-time
//  constant — so "migration" there just means seeding the default.
//
//  Fresh installs land on the same values, which is why this runs before
//  anything reads a binding. It has to: `KeyboardShortcuts.Name.init` writes
//  its `default:` into UserDefaults as a side effect, so if a Name carried a
//  default we'd be migrating a value we had just caused. `.dictation` no
//  longer has one — this file is the single seeder.
//

import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

enum HotkeyMigration {
    static let currentVersion = 1

    /// What the pre-merge `KeyboardShortcuts_dictation` key held.
    enum LegacyCombo: Equatable {
        /// Key absent — a fresh install. Seed the shipped default.
        case neverSet
        /// Key present but nil — the user deliberately cleared the combo. Respect that.
        case clearedByUser
        case shortcut(HotkeyBinding)
    }

    /// `legacyCombo` is injectable so the tests can drive the never-set /
    /// cleared / set cases without a real KeyboardShortcuts store. It's
    /// `@MainActor` because the default implementation is.
    @MainActor
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        legacyCombo: @MainActor (UserDefaults) -> LegacyCombo = readLegacyDictationCombo
    ) {
        guard defaults.integer(forKey: PrefKey.hotkeyMigrationVersion) < currentVersion else { return }

        migrateDictation(defaults: defaults, legacyCombo: legacyCombo(defaults))
        migratePushToTalk(defaults: defaults)

        defaults.set(currentVersion, forKey: PrefKey.hotkeyMigrationVersion)
    }

    // MARK: Dictation

    static func migrateDictation(defaults: UserDefaults, legacyCombo: LegacyCombo) {
        guard defaults.object(forKey: PrefKey.dictationBinding) == nil else { return }

        var bindings: [HotkeyBinding] = []

        // `holdKey` absent → the old default, ⌃. `off` → the user turned the
        // bare hold off and lived on the combo alone; don't hand it back.
        let legacyHoldKey = HoldKey(rawValue: defaults.string(forKey: PrefKey.holdKey) ?? "") ?? .control
        if let holdFlag = legacyHoldKey.flag {
            bindings.append(.modifiersOnly(holdFlag))
        }

        switch legacyCombo {
        case .neverSet:
            bindings.append(.keyCombo(keyCode: UInt16(kVK_Space), modifiers: .option))
        case .clearedByUser:
            break
        case .shortcut(let binding):
            bindings.append(binding)
        }

        HotkeyBindingStore.write(bindings, to: PrefKey.dictationBinding, in: defaults)
    }

    /// Reads whatever `KeyboardShortcuts` persisted for `.dictation` before the
    /// update. Reads the raw key first: `getShortcut(for:)` returns nil both for
    /// "never set" and "cleared", and those two want different outcomes.
    @MainActor
    static func readLegacyDictationCombo(_ defaults: UserDefaults) -> LegacyCombo {
        guard defaults.object(forKey: "KeyboardShortcuts_dictation") != nil else { return .neverSet }
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .dictation) else { return .clearedByUser }
        return .shortcut(
            .keyCombo(keyCode: UInt16(shortcut.carbonKeyCode), modifiers: shortcut.modifiers)
        )
    }

    // MARK: Push-to-talk

    static func migratePushToTalk(defaults: UserDefaults) {
        guard defaults.object(forKey: PrefKey.pushToTalkBinding) == nil else { return }
        // Clicky hardcoded `.controlOption`. Nothing to read; seed it.
        HotkeyBindingStore.write(
            HotkeyFeature.pushToTalk.defaultBindings,
            to: PrefKey.pushToTalkBinding,
            in: defaults
        )
    }
}
