//
//  Notifications.swift
//  Whisper — shared, additive (Contracts.swift stays frozen)
//

import Foundation

extension Notification.Name {
    /// Posted after a dictation is saved so History/Insights refetch.
    static let dictationDidSave = Notification.Name("whisper.dictationDidSave")
    /// Posted by the engine with a human-readable status line for the menu bar
    /// (e.g. "Downloading model… 42%"). userInfo["status"] = String?.
    static let engineStatus = Notification.Name("whisper.engineStatus")
}
