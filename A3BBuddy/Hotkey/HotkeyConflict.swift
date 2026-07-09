//
//  HotkeyConflict.swift
//  Buddy — flexible hotkeys
//
//  Decides whether a candidate binding may be saved. Pure and synchronous so
//  the recorder can call it on every keystroke and the tests can drive the
//  whole decision table without launching anything.
//
//  The rules exist because the engine matches modifier-only bindings on an
//  *exact* modifier set. That makes some pairings merely awkward (⌃ and ⌃⌥ —
//  survivable, the grace window separates them) and others genuinely
//  unreachable (⌃⌥ and ⌃⌥Space — you cannot type the combo without first
//  holding the bare modifiers, which fires the other feature).
//
//  There is no public API for "is this shortcut taken by macOS".
//  KeyboardShortcuts reads it through `CopySymbolicHotKeys()`, an undocumented
//  CoreServices SPI, and keeps the result `internal`. We ship a denylist of the
//  ones users actually try, and only *warn* — a wrong denylist entry that
//  blocked would be worse than the collision it prevents.
//

import AppKit
import Carbon.HIToolbox

enum HotkeyConflict: Equatable {
    case none
    /// Saveable, but something will surprise the user. Orange caption.
    case warn(String)
    /// Not saveable. Red caption, keep focus, beep.
    case block(String)

    var isBlocking: Bool {
        if case .block = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .none: nil
        case .warn(let message), .block(let message): message
        }
    }

    /// `.block` beats `.warn` beats `.none`.
    fileprivate var severity: Int {
        switch self {
        case .none: 0
        case .warn: 1
        case .block: 2
        }
    }
}

enum HotkeyConflictChecker {

    /// - Parameter slot: the index being edited. It's excluded from the
    ///   comparison so re-recording a binding never conflicts with itself.
    static func evaluate(
        _ candidate: HotkeyBinding,
        for feature: HotkeyFeature,
        slot: Int,
        against bindings: [HotkeyFeature: [HotkeyBinding]]
    ) -> HotkeyConflict {
        var verdicts = [standaloneVerdict(candidate)]
        if verdicts[0].isBlocking { return verdicts[0] }

        for otherFeature in HotkeyFeature.allCases {
            for (otherSlot, existing) in (bindings[otherFeature] ?? []).enumerated() {
                if otherFeature == feature, otherSlot == slot { continue }
                verdicts.append(
                    pairwiseVerdict(candidate, feature, versus: existing, otherFeature)
                )
            }
        }

        return verdicts.max(by: { $0.severity < $1.severity }) ?? .none
    }

    // MARK: Rules that don't depend on the other bindings

    static func standaloneVerdict(_ candidate: HotkeyBinding) -> HotkeyConflict {
        let modifiers = candidate.modifierFlags

        switch candidate {
        case .modifiersOnly:
            if modifiers.isEmpty {
                return .block("Pick at least one modifier key.")
            }
            if modifiers == .function {
                return .warn(
                    "macOS may also act on 🌐. Set System Settings → Keyboard → "
                    + "“Press 🌐 key to” → Do Nothing to stop the emoji picker opening."
                )
            }
            return .none

        case .keyCombo(let keyCode, _):
            // Shortcut.init?(event:) strips .function and RegisterEventHotKey
            // has no bit for it — an fn combo would register garbage and never
            // fire. fn only works as a bare hold, matched in the event tap.
            if modifiers.contains(.function) {
                return .block("Shortcuts can’t combine 🌐 with another key. Use 🌐 on its own.")
            }
            // Function keys are the exception: F5 alone is a real shortcut.
            let hasRealModifier = !modifiers.isEmpty && modifiers != .shift
            if !hasRealModifier, !HotkeyBinding.isFunctionKey(keyCode) {
                return .block("Add ⌘, ⌃, or ⌥ — a shortcut needs at least one of them.")
            }
            if systemShortcuts.contains(candidate) {
                return .warn("\(candidate.displayString) is a macOS system shortcut. macOS will act on it too.")
            }
            return .none

        case .mouseButton(let number):
            guard HotkeyBinding.bindableMouseButtons.contains(number) else {
                return .block("Only the side buttons — Mouse 4 and Mouse 5 — can be used.")
            }
            return .none
        }
    }

    // MARK: Rules that compare two bindings

    private static func pairwiseVerdict(
        _ candidate: HotkeyBinding,
        _ feature: HotkeyFeature,
        versus existing: HotkeyBinding,
        _ otherFeature: HotkeyFeature
    ) -> HotkeyConflict {
        let owner = otherFeature == feature
            ? "\(feature.displayName)’s other shortcut"
            : otherFeature.displayName

        switch (candidate, existing) {

        case (.keyCombo(let candidateKey, _), .keyCombo(let existingKey, _)):
            guard candidateKey == existingKey, candidate.modifierFlags == existing.modifierFlags else {
                return .none
            }
            return .block("\(candidate.displayString) is already used by \(owner).")

        case (.modifiersOnly, .modifiersOnly):
            let candidateSet = candidate.modifierFlags
            let existingSet = existing.modifierFlags

            if candidateSet == existingSet {
                return .block("\(candidate.displayString) is already used by \(owner).")
            }
            if candidateSet.isStrictSubset(of: existingSet) {
                return .warn(
                    "\(candidate.displayString) is the start of \(existing.displayString) (\(owner)). "
                    + "\(feature.displayName) will wait 200 ms before starting so the two can be told apart."
                )
            }
            if existingSet.isStrictSubset(of: candidateSet) {
                return .warn(
                    "\(existing.displayString) (\(owner)) is the start of \(candidate.displayString). "
                    + "\(owner) will wait 200 ms before starting so the two can be told apart."
                )
            }
            return .none

        // A bare hold that is a prefix of a combo is unreachable: pressing the
        // combo's modifiers fires the hold first, every single time. Note ⊆,
        // not ⊊ — exact-set matching means ⌃⌥ fires on the way to ⌃⌥Space too.
        case (.keyCombo, .modifiersOnly):
            guard existing.modifierFlags.isSubset(of: candidate.modifierFlags) else { return .none }
            return .block(
                "Holding \(existing.displayString) to reach \(candidate.displayString) "
                + "would start \(owner) first."
            )

        case (.modifiersOnly, .keyCombo):
            guard candidate.modifierFlags.isSubset(of: existing.modifierFlags) else { return .none }
            return .block(
                "Holding \(candidate.displayString) to reach \(existing.displayString) (\(owner)) "
                + "would start \(feature.displayName) first."
            )

        case (.mouseButton(let candidateButton), .mouseButton(let existingButton)):
            guard candidateButton == existingButton else { return .none }
            return .block("\(candidate.displayString) is already used by \(owner).")

        // A button and a key are orthogonal input channels: neither can be a prefix
        // of the other, so none of the subset reasoning above applies. Pressing a
        // bound button while a keyboard hold is live ends that hold and starts this
        // one — see `HotkeyStateMachine.mouseButtonsChanged`.
        case (.mouseButton, .modifiersOnly), (.mouseButton, .keyCombo),
             (.modifiersOnly, .mouseButton), (.keyCombo, .mouseButton):
            return .none
        }
    }

    // MARK: System shortcut denylist

    /// Not exhaustive, and not meant to be. These are the ones users reach for.
    static let systemShortcuts: Set<HotkeyBinding> = [
        .keyCombo(keyCode: UInt16(kVK_Space), modifiers: .command),            // Spotlight
        .keyCombo(keyCode: UInt16(kVK_Space), modifiers: .control),            // Previous input source
        .keyCombo(keyCode: UInt16(kVK_Space), modifiers: [.control, .option]), // Next input source
        .keyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command, .option]), // Finder search
        .keyCombo(keyCode: UInt16(kVK_Tab), modifiers: .command),              // App switcher
        .keyCombo(keyCode: UInt16(kVK_ANSI_Q), modifiers: .command),           // Quit
        .keyCombo(keyCode: UInt16(kVK_ANSI_W), modifiers: .command),           // Close window
        .keyCombo(keyCode: UInt16(kVK_ANSI_H), modifiers: .command),           // Hide
        .keyCombo(keyCode: UInt16(kVK_ANSI_M), modifiers: .command),           // Minimise
        .keyCombo(keyCode: UInt16(kVK_ANSI_3), modifiers: [.shift, .command]), // Screenshot
        .keyCombo(keyCode: UInt16(kVK_ANSI_4), modifiers: [.shift, .command]),
        .keyCombo(keyCode: UInt16(kVK_ANSI_5), modifiers: [.shift, .command]),
        .keyCombo(keyCode: UInt16(kVK_Escape), modifiers: [.option, .command]), // Force Quit
        .keyCombo(keyCode: UInt16(kVK_F2), modifiers: .control),                // Menu bar focus
        .keyCombo(keyCode: UInt16(kVK_F3), modifiers: .control),                // Dock focus
        .keyCombo(keyCode: UInt16(kVK_F4), modifiers: .control),                // Window focus
        .keyCombo(keyCode: UInt16(kVK_F11), modifiers: []),                     // Show desktop
        .keyCombo(keyCode: UInt16(kVK_F12), modifiers: []),                     // Dashboard / Launchpad
        .keyCombo(keyCode: UInt16(kVK_UpArrow), modifiers: .control),           // Mission Control
        .keyCombo(keyCode: UInt16(kVK_DownArrow), modifiers: .control),         // App Exposé
        .keyCombo(keyCode: UInt16(kVK_LeftArrow), modifiers: .control),         // Space left
        .keyCombo(keyCode: UInt16(kVK_RightArrow), modifiers: .control),        // Space right
    ]
}

// `isSubset(of:)` / `isStrictSubset(of:)` come free from SetAlgebra, which
// every OptionSet conforms to. No helpers needed.
