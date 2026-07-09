//
//  HotkeyBinding.swift
//  Buddy — flexible hotkeys
//
//  One user-assignable trigger. Two shapes:
//
//    .keyCombo      ⌥Space, ⌘⇧D — a key plus modifiers. Registered with Carbon
//                   via KeyboardShortcuts, which *consumes* the key event. A
//                   listen-only CGEventTap cannot, so tap-matching a combo
//                   would type the character into whatever field you're
//                   dictating into. Never tap-match these.
//
//    .modifiersOnly ⌃, ⌃⌥, fn — a bare modifier hold. Carbon can't register
//                   these at all, so they're matched in the event tap.
//
//    .mouseButton   Mouse 4, Mouse 5 — a side-button hold, also matched in the
//                   event tap. Carries no modifiers: ⌃+Mouse 4 is just Mouse 4.
//
//  NSEvent.ModifierFlags isn't Codable, so the keyboard cases store `rawValue`.
//  Everything here is a pure value type: no MainActor, no UserDefaults,
//  no KeyboardShortcuts. That keeps the conflict rules unit-testable.
//

import AppKit
import Carbon.HIToolbox

enum HotkeyBinding: Codable, Equatable, Hashable {
    case keyCombo(keyCode: UInt16, modifiers: UInt)
    case modifiersOnly(modifiers: UInt)
    /// A macOS mouse button number, as reported by `NSEvent.buttonNumber`:
    /// 0 left, 1 right, 2 middle, 3 and 4 the side buttons. Only 3 and 4 are
    /// bindable — see `bindableMouseButtons`.
    case mouseButton(number: Int)

    /// The only five modifiers we ever look at. Everything else in a
    /// `CGEventFlags` / `NSEvent.ModifierFlags` (caps lock, numeric pad,
    /// left-vs-right device bits, `.maskNonCoalesced`) is noise.
    static let recognizedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]

    /// Left and right are how you use a Mac; middle is paste in a terminal and
    /// close-tab in a browser. Only the two side buttons may be bound.
    static let bindableMouseButtons: ClosedRange<Int> = 3...4

    // MARK: Convenience constructors

    static func keyCombo(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HotkeyBinding {
        .keyCombo(keyCode: keyCode, modifiers: modifiers.intersection(recognizedModifiers).rawValue)
    }

    static func modifiersOnly(_ modifiers: NSEvent.ModifierFlags) -> HotkeyBinding {
        .modifiersOnly(modifiers: modifiers.intersection(recognizedModifiers).rawValue)
    }

    // MARK: Accessors

    /// `.mouseButton` deliberately reports an empty set rather than being absent:
    /// callers that reason about modifier *subsets* must never see it, which is
    /// why `HotkeyConflictChecker` switches on the case instead of on this.
    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .keyCombo(_, let modifiers), .modifiersOnly(let modifiers):
            NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.recognizedModifiers)
        case .mouseButton:
            []
        }
    }

    var keyCode: UInt16? {
        if case .keyCombo(let keyCode, _) = self { return keyCode }
        return nil
    }

    var isModifiersOnly: Bool {
        if case .modifiersOnly = self { return true }
        return false
    }

    /// Not `!isModifiersOnly`. A mouse binding is neither a hold nor a combo, and
    /// the places that partition bindings — the match table's Carbon slots and
    /// `HotkeyBindingStore.syncCarbonRegistrations` — must not misfile it as one.
    var isKeyCombo: Bool {
        if case .keyCombo = self { return true }
        return false
    }

    var mouseButtonNumber: Int? {
        if case .mouseButton(let number) = self { return number }
        return nil
    }

    /// Holds and mouse buttons are matched in the event tap, and only the tap
    /// needs Input Monitoring. A combo-only setup works with zero permissions.
    var requiresInputMonitoring: Bool { isModifiersOnly || mouseButtonNumber != nil }

    /// "⌃⌥", "⌥Space", "fn", "Mouse 4". Hand-rolled rather than reusing
    /// `KeyboardShortcuts.Shortcut.description`, which is `@MainActor`.
    var displayString: String {
        switch self {
        case .modifiersOnly:
            modifierFlags.hotkeyGlyphs
        case .keyCombo(let keyCode, _):
            modifierFlags.hotkeyGlyphs + HotkeyBinding.keyLabel(for: keyCode)
        case .mouseButton(let number):
            // Button 3 is what everyone calls "Mouse 4".
            "Mouse \(number + 1)"
        }
    }
}

// MARK: - Modifier glyphs

extension NSEvent.ModifierFlags {
    /// Apple's canonical ordering is ⌃⌥⇧⌘, with fn ahead of it.
    var hotkeyGlyphs: String {
        var glyphs = ""
        if contains(.function) { glyphs += "fn" }
        if contains(.control) { glyphs += "⌃" }
        if contains(.option) { glyphs += "⌥" }
        if contains(.shift) { glyphs += "⇧" }
        if contains(.command) { glyphs += "⌘" }
        return glyphs
    }
}

// MARK: - Key labels

extension HotkeyBinding {
    /// A virtual key code is a *position* on the keyboard, not a character —
    /// keyCode 12 is Q on QWERTY and A on AZERTY. This map names the QWERTY
    /// position, which is what every macOS app shows. Layout-aware naming
    /// would need `UCKeyTranslate`; not worth it for a shortcut label.
    static func keyLabel(for keyCode: UInt16) -> String {
        keyLabels[keyCode] ?? "Key \(keyCode)"
    }

    /// Function keys are the one case where a bare, modifier-less combo is
    /// legitimate — F5 alone is a normal shortcut, "S" alone is not.
    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    private static let functionKeyCodes: Set<UInt16> = [
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4),
        UInt16(kVK_F5), UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8),
        UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        UInt16(kVK_F13), UInt16(kVK_F14), UInt16(kVK_F15), UInt16(kVK_F16),
        UInt16(kVK_F17), UInt16(kVK_F18), UInt16(kVK_F19), UInt16(kVK_F20),
    ]

    private static let keyLabels: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",

        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",

        UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/",
        UInt16(kVK_ANSI_Grave): "`",

        UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋", UInt16(kVK_Help): "Help",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",

        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",

        UInt16(kVK_ANSI_Keypad0): "Keypad 0", UInt16(kVK_ANSI_Keypad1): "Keypad 1",
        UInt16(kVK_ANSI_Keypad2): "Keypad 2", UInt16(kVK_ANSI_Keypad3): "Keypad 3",
        UInt16(kVK_ANSI_Keypad4): "Keypad 4", UInt16(kVK_ANSI_Keypad5): "Keypad 5",
        UInt16(kVK_ANSI_Keypad6): "Keypad 6", UInt16(kVK_ANSI_Keypad7): "Keypad 7",
        UInt16(kVK_ANSI_Keypad8): "Keypad 8", UInt16(kVK_ANSI_Keypad9): "Keypad 9",
        UInt16(kVK_ANSI_KeypadClear): "Keypad Clear", UInt16(kVK_ANSI_KeypadDecimal): "Keypad .",
        UInt16(kVK_ANSI_KeypadDivide): "Keypad /", UInt16(kVK_ANSI_KeypadEnter): "Keypad ↩",
        UInt16(kVK_ANSI_KeypadEquals): "Keypad =", UInt16(kVK_ANSI_KeypadMinus): "Keypad -",
        UInt16(kVK_ANSI_KeypadMultiply): "Keypad *", UInt16(kVK_ANSI_KeypadPlus): "Keypad +",
    ]
}
