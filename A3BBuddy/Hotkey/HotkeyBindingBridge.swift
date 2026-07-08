//
//  HotkeyBindingBridge.swift
//  Buddy — flexible hotkeys
//
//  TEMPORARY. Delete this file when HotkeyEngine lands.
//
//  Settings now edits `HotkeyBindingStore` (which persists `hotkey.dictation` /
//  `hotkey.pushToTalk`), but the two matchers that actually watch the keyboard —
//  `HotkeyManager` and `GlobalPushToTalkShortcutMonitor` — still read the legacy
//  `ModifierOnlyShortcut` defaults keys. Without this bridge the Settings screen
//  edits values nothing reads, and rebinding a hotkey silently does nothing:
//  precisely the bug this whole wave exists to fix.
//
//  So: give the old matchers a new source. They keep their exact/superset
//  matching, their suppression latch, and their tap lifecycle. Only the *lookup*
//  changes. `HotkeyEngine` will replace both matchers outright, and this file
//  goes with them.
//
//  Only the FIRST modifier-only binding is honoured — the old matchers can hold
//  exactly one. Combo bindings are unaffected: `HotkeyBindingStore` already
//  write-throughs those to Carbon via `KeyboardShortcuts.Name`, which both
//  matchers already subscribe to.
//

import AppKit

extension ModifierOnlyShortcut {
    /// The bare-modifier hold this feature is currently bound to, or `.off` when
    /// the user has cleared it (or bound only a combo).
    ///
    /// Reads the store, not UserDefaults directly, so an in-flight Settings edit
    /// is visible immediately. Store writes go through `UserDefaults.set`, which
    /// posts `didChangeNotification` — the signal both matchers already use to
    /// re-read and re-arm their taps, so live rebind keeps working.
    @MainActor
    static func fromBindings(_ feature: HotkeyFeature, fallback: ModifierOnlyShortcut) -> ModifierOnlyShortcut {
        let store = HotkeyBindingStore.shared
        guard store.bindings[feature] != nil else { return fallback } // store not yet populated
        guard let hold = store.bindings(for: feature).first(where: \.isModifiersOnly) else { return .off }
        return ModifierOnlyShortcut(flags: hold.modifierFlags) ?? fallback
    }
}
