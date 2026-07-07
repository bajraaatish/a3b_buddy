//
//  ShortcutNames.swift
//  Whisper — Workstream A owns this; B's Settings renders the recorder for it.
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Hold to record, release to transcribe. Double-tap locks hands-free.
    static let dictation = Self("dictation", default: .init(.space, modifiers: [.option]))
}
