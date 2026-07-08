//
//  WhisperMenuBridge.swift
//  a3b Buddy — integration layer
//
//  Hands the Whisper dictation feature's menu actions to the Clicky menu bar
//  panel, which is the app's single status item after the merge. Built by
//  the AppDelegate; consumed by CompanionPanelView.
//

import Foundation

@MainActor
struct WhisperMenuBridge {
    /// The live dictation engine, observed by the panel for status display.
    let engine: ActiveEngine
    let hasTranscripts: () -> Bool
    let openMainWindow: () -> Void
    let pasteLastTranscript: () -> Void
    let openSettings: () -> Void
}
