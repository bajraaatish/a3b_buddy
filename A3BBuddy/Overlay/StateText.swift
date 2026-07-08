//
//  StateText.swift
//  Whisper — Workstream B
//
//  User-facing wording for every DictationState and DictationError.
//

import Foundation

extension DictationState {
    var menuLabel: String {
        switch self {
        case .idle: "Ready"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        case .failed(let error): error.shortLabel
        }
    }
}

extension DictationError {
    var shortLabel: String {
        switch self {
        case .micDenied: "Microphone access denied"
        case .accessibilityDenied: "Accessibility access denied"
        case .modelNotReady: "Speech model not ready"
        case .transcriptionFailed: "Transcription failed"
        case .insertionFailed: "Couldn't insert text"
        }
    }

    var recovery: String {
        switch self {
        case .micDenied:
            "Allow the microphone in System Settings → Privacy & Security → Microphone."
        case .accessibilityDenied:
            "Allow Whisper in System Settings → Privacy & Security → Accessibility so it can type for you."
        case .modelNotReady:
            "The speech model is still downloading. Try again in a moment."
        case .transcriptionFailed:
            "Nothing intelligible was heard. Try again a little closer to the mic."
        case .insertionFailed:
            "Your text is on the clipboard — press ⌘V to paste it."
        }
    }
}
