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
    static let dictationModifierOnlyShortcut = "holdKey"
    static let pushToTalkModifierOnlyShortcut = "pushToTalkModifierOnlyShortcut"
}

/// Which modifier-only shortcut is the hold-to-talk trigger. The recordable
/// combo in Settings works regardless; `off` leaves only the combo.
struct ModifierOnlyShortcut: RawRepresentable, CaseIterable, Identifiable, Hashable {
    struct ModifierDefinition {
        let rawValue: String
        let displayName: String
        let symbol: String
        let keyLabel: String
        let flag: NSEvent.ModifierFlags
    }

    static let control = Self(rawValue: "control")!
    static let controlOption = Self(rawValue: "control+option")!
    static let off = Self(rawValue: "off")!

    static let allCases: [ModifierOnlyShortcut] = {
        var shortcuts = [ModifierOnlyShortcut.off]
        let maxMask = 1 << modifierDefinitions.count

        for mask in 1..<maxMask {
            let rawValue = modifierDefinitions.enumerated()
                .compactMap { index, definition in
                    (mask & (1 << index)) == 0 ? nil : definition.rawValue
                }
                .joined(separator: "+")

            if let shortcut = ModifierOnlyShortcut(rawValue: rawValue) {
                shortcuts.append(shortcut)
            }
        }

        return shortcuts.sorted { lhs, rhs in
            if lhs == .off { return true }
            if rhs == .off { return false }
            if lhs.modifierCount != rhs.modifierCount {
                return lhs.modifierCount < rhs.modifierCount
            }
            return lhs.rawValue < rhs.rawValue
        }
    }()

    private static let offRawValue = "off"
    private static let modifierDefinitions: [ModifierDefinition] = [
        .init(rawValue: "control", displayName: "Control", symbol: "⌃", keyLabel: "ctrl", flag: .control),
        .init(rawValue: "option", displayName: "Option", symbol: "⌥", keyLabel: "option", flag: .option),
        .init(rawValue: "command", displayName: "Command", symbol: "⌘", keyLabel: "command", flag: .command),
        .init(rawValue: "shift", displayName: "Shift", symbol: "⇧", keyLabel: "shift", flag: .shift),
        .init(rawValue: "fn", displayName: "fn (Globe)", symbol: "fn", keyLabel: "fn", flag: .function)
    ]
    private static let modifierDefinitionByRawValue = Dictionary(
        uniqueKeysWithValues: modifierDefinitions.map { ($0.rawValue, $0) }
    )
    private static let modifierOrder = Dictionary(
        uniqueKeysWithValues: modifierDefinitions.enumerated().map { ($0.element.rawValue, $0.offset) }
    )

    let rawValue: String

    init?(rawValue: String) {
        if rawValue == Self.offRawValue {
            self.rawValue = rawValue
            return
        }

        let rawTokens = rawValue.split(separator: "+").map(String.init)
        let uniqueTokens = Set(rawTokens)

        guard !rawTokens.isEmpty,
              rawTokens.count == uniqueTokens.count,
              rawTokens.allSatisfy({ Self.modifierDefinitionByRawValue[$0] != nil }) else {
            return nil
        }

        self.rawValue = Self.normalizedRawValue(for: rawTokens)
    }

    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags? {
        guard self != .off else { return nil }

        return definitions.reduce(into: NSEvent.ModifierFlags()) { flags, definition in
            flags.insert(definition.flag)
        }
    }

    var displayName: String {
        guard self != .off else { return "Off - combo only" }

        return definitions
            .map { "\($0.symbol) \($0.displayName)" }
            .joined(separator: " + ")
    }

    /// Short symbol for captions ("Hold ⌃ to record...").
    var symbol: String {
        definitions.map(\.symbol).joined()
    }

    var keyCapsuleLabels: [String] {
        definitions.map(\.keyLabel)
    }

    static func current(for defaultsKey: String, default defaultShortcut: ModifierOnlyShortcut) -> ModifierOnlyShortcut {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return ModifierOnlyShortcut(rawValue: rawValue) ?? defaultShortcut
    }

    private var modifierCount: Int {
        definitions.count
    }

    private var definitions: [ModifierDefinition] {
        guard self != .off else { return [] }

        return rawValue.split(separator: "+").compactMap {
            Self.modifierDefinitionByRawValue[String($0)]
        }
    }

    private static func normalizedRawValue(for tokens: [String]) -> String {
        tokens.sorted {
            (modifierOrder[$0] ?? .max) < (modifierOrder[$1] ?? .max)
        }
        .joined(separator: "+")
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
