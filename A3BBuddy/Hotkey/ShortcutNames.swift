//
//  ShortcutNames.swift
//  Buddy — flexible hotkeys
//
//  One `KeyboardShortcuts.Name` per *combo* slot per feature. Modifier-only
//  holds don't need one — Carbon can't register a bare modifier, so those are
//  matched in the event tap instead.
//
//  None of these carry a `default:`. `Name.init` writes its default straight
//  into UserDefaults the first time the static is touched, and the statics get
//  touched before `applicationDidFinishLaunching` runs. A default here would
//  race HotkeyMigration and seed a value the migration then reads back as if
//  the user had chosen it. HotkeyMigration is the only seeder.
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Hold to record, release to transcribe. Double-tap locks hands-free.
    static let dictation = Self("dictation")
    static let dictationAlternate = Self("dictationAlternate")

    /// Hold to talk to Buddy; release to send.
    static let pushToTalk = Self("pushToTalk")
    static let pushToTalkAlternate = Self("pushToTalkAlternate")
}

extension HotkeyFeature {
    /// Carbon registration slots, in order. A feature with two `.keyCombo`
    /// bindings fills both; one combo fills only the first.
    var comboShortcutNames: [KeyboardShortcuts.Name] {
        switch self {
        case .dictation: [.dictation, .dictationAlternate]
        case .pushToTalk: [.pushToTalk, .pushToTalkAlternate]
        }
    }
}
