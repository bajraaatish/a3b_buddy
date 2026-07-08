//
//  RecordingControls.swift
//  Buddy — Whisper dictation
//
//  Bridges the hands-free lock state and the pill's ✕/✓ buttons between the
//  hotkey layer and the recording pill. The pill is generic over the engine
//  and `Shared/Contracts.swift` is frozen, so the lock flag and the two
//  button actions ride on this small observable instead of the
//  DictationEngine protocol.
//
//  Wiring (done in AppDelegate):
//    HotkeyManager.onLockChange → controls.isHandsFreeLocked
//    controls.onCancel          → HotkeyManager.cancelFromButton()  (✕)
//    controls.onConfirm         → HotkeyManager.confirmFromButton() (✓)
//
//  RecordingPanelController observes `isHandsFreeLocked` to enable mouse
//  events on the pill only while locked (so ✕/✓ are clickable); the rest of
//  the time the panel stays click-through and never steals focus.
//

import Combine
import Foundation

@MainActor
final class RecordingControls: ObservableObject {
    /// True while dictation is in double-tap hands-free lock. Drives whether
    /// the pill shows its ✕/✓ buttons and whether the panel takes mouse input.
    @Published var isHandsFreeLocked = false

    /// ✕ — discard the in-progress recording.
    var onCancel: () -> Void = {}

    /// ✓ — stop recording and transcribe.
    var onConfirm: () -> Void = {}
}
