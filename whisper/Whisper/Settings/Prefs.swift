//
//  Prefs.swift
//  Whisper — Workstream B
//
//  @AppStorage keys and the enums behind Settings pickers.
//

import AppKit
import Foundation

enum PrefKey {
    static let modelVariant = "modelVariant"
    static let preferredMicID = "preferredMicID"
    static let soundCues = "soundCues"
    static let retention = "retention"
    static let hasOnboarded = "hasOnboarded"
    static let holdKey = "holdKey"
}

/// Which bare modifier is the hold-to-talk trigger. The recordable combo in
/// Settings works regardless; `off` leaves only the combo.
enum HoldKey: String, CaseIterable, Identifiable {
    case control
    case option
    case command
    case fn
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .command: "⌘ Command"
        case .fn: "🌐 fn (Globe)"
        case .off: "Off — combo only"
        }
    }

    /// Short symbol for captions ("Hold ⌃ to record…").
    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        case .fn: "fn"
        case .off: ""
        }
    }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .control: .control
        case .option: .option
        case .command: .command
        case .fn: .function
        case .off: nil
        }
    }

    static var current: HoldKey {
        HoldKey(rawValue: UserDefaults.standard.string(forKey: PrefKey.holdKey) ?? "") ?? .control
    }
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
