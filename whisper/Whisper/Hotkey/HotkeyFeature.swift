//
//  HotkeyFeature.swift
//  Whisper — flexible hotkeys
//
//  The two things a hotkey can trigger, and the only place their behavioural
//  differences are written down. Everything downstream (HotkeyEngine,
//  HotkeyManager, the push-to-talk adapter) reads its policy from here rather
//  than branching on the feature.
//
//  Each feature holds an ordered list of bindings: slot 0 is the primary,
//  slot 1 the alternate. Whisper has always had two triggers running at once
//  (a ⌃ hold *and* an ⌥Space combo); the array preserves that and hands the
//  same capability to push-to-talk.
//

import AppKit
import Carbon.HIToolbox

/// What happens when a *superset* of a modifier-only binding is pressed —
/// you're holding ⌃ for dictation and ⌥ joins in.
enum HotkeySupersetPolicy {
    /// Discard the session. The extra modifier means this was a shortcut
    /// (⌃C, ⌃⌘F), not dictation. Whisper's behaviour since day one.
    case abort
    /// End the session normally, keeping whatever was captured. Clicky's
    /// push-to-talk: an accidental ⇧ shouldn't throw the utterance away.
    case release
}

enum HotkeyFeature: String, CaseIterable, Codable, Identifiable, Sendable {
    case dictation
    case pushToTalk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dictation: "Dictation"
        case .pushToTalk: "Talk to Clicky"
        }
    }

    var defaultsKey: String {
        switch self {
        case .dictation: PrefKey.dictationBinding
        case .pushToTalk: PrefKey.pushToTalkBinding
        }
    }

    /// Primary + one alternate. Raising this means adding more
    /// `KeyboardShortcuts.Name`s in ShortcutNames.swift — one per combo slot.
    var maxBindings: Int { 2 }

    /// Shipped defaults. Deliberately prefix-conflicted (⌃ ⊊ ⌃⌥) because both
    /// are load-bearing muscle memory; HotkeyEngine's grace window is what
    /// makes them coexist. See the plan, §2.4.
    var defaultBindings: [HotkeyBinding] {
        switch self {
        case .dictation:
            [
                .modifiersOnly(.control),
                .keyCombo(keyCode: UInt16(kVK_Space), modifiers: .option),
            ]
        case .pushToTalk:
            [.modifiersOnly([.control, .option])]
        }
    }

    var supersetPolicy: HotkeySupersetPolicy {
        switch self {
        case .dictation: .abort
        case .pushToTalk: .release
        }
    }

    /// Whisper cancels an unlocked hold the moment any other key is pressed,
    /// so ⌃C reaches the app underneath untouched. Push-to-talk doesn't —
    /// clicky's matcher ignores keyDown entirely for modifier-only shortcuts.
    var cancelsOnOtherKeyDown: Bool {
        switch self {
        case .dictation: true
        case .pushToTalk: false
        }
    }

    /// Same reasoning, for ⌃-click (which macOS treats as a right-click).
    var cancelsOnMouseDown: Bool {
        switch self {
        case .dictation: true
        case .pushToTalk: false
        }
    }
}
