//
//  Prefs.swift
//  Whisper — Workstream B
//
//  @AppStorage keys and the enums behind Settings pickers.
//

import Foundation

enum PrefKey {
    static let modelVariant = "modelVariant"
    static let preferredMicID = "preferredMicID"
    static let soundCues = "soundCues"
    static let retention = "retention"
    static let hasOnboarded = "hasOnboarded"

    // ── Flexible hotkeys. JSON-encoded `[HotkeyBinding]`. ────
    static let dictationBinding = "hotkey.dictation"
    static let pushToTalkBinding = "hotkey.pushToTalk"
    static let hotkeyMigrationVersion = "hotkeyMigrationVersion"

    // ── Legacy. Read once by HotkeyMigration, then never again. ────
    // Both hold a `+`-joined modifier list ("control+option", "shift", "off").
    // `holdKey` is older still and may hold a single token from the pre-merge
    // `HoldKey` enum — `HotkeyMigration.legacyModifiers(fromRawValue:)` parses
    // both. Kept so a downgrade to a pre-v3 build is non-destructive.
    static let dictationModifierOnlyShortcut = "holdKey"
    static let pushToTalkModifierOnlyShortcut = "pushToTalkModifierOnlyShortcut"
}

enum ModelVariant: String, CaseIterable, Identifiable {
    case turbo
    case small

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turbo: "Large v3 Turbo — best accuracy (626 MB)"
        case .small: "Small — lower RAM (~460 MB)"
        }
    }

    /// WhisperKit registry folder name. Gotcha: turbo is `large-v3-v20240930`, not "large-v3-turbo".
    var whisperKitName: String {
        switch self {
        case .turbo: "openai_whisper-large-v3-v20240930_626MB"
        case .small: "openai_whisper-small"
        }
    }
}

enum HistoryRetention: String, CaseIterable, Identifiable {
    case forever
    case thirtyDays
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forever: "Keep forever"
        case .thirtyDays: "Keep 30 days"
        case .off: "Don't save history"
        }
    }
}
