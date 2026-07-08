//
//  AppleSpeechTTSProvider.swift
//  leanring-buddy
//
//  Local text-to-speech provider backed by AVSpeechSynthesizer. Replaces
//  the old network TTS path so voice output never leaves the machine.
//

import AVFoundation
import Foundation

@MainActor
final class AppleSpeechTTSProvider: NSObject, BuddyTTSProvider {
    let displayName = "Apple Speech"

    private let speechSynthesizer = AVSpeechSynthesizer()

    /// The best installed voice for the user's language, chosen once at
    /// startup: premium quality first, then enhanced, then the system default.
    private let selectedSynthesisVoice: AVSpeechSynthesisVoice?

    /// Tracked via delegate callbacks instead of reading
    /// `speechSynthesizer.isSpeaking`, so the value flips to true synchronously
    /// inside `speak(_:)` — CompanionManager's transient-hide loop may poll it
    /// immediately after `speak(_:)` returns.
    private(set) var isPlaying: Bool = false

    /// When the current utterance started; used for the TTS_END duration log.
    private var playbackStartDate: Date?

    override init() {
        selectedSynthesisVoice = Self.bestAvailableSynthesisVoice()
        super.init()
        speechSynthesizer.delegate = self
        let chosenVoiceDescription = selectedSynthesisVoice
            .map { "\($0.name) (\($0.language))" } ?? "system default"
        print("🔊 AppleSpeechTTS: voice = \(chosenVoiceDescription)")
    }

    /// Begins speaking `text`. Returns once the utterance is enqueued and
    /// `isPlaying` is true — audio starts within milliseconds. Never actually
    /// throws; `throws` is kept for protocol compatibility with network
    /// providers.
    func speak(_ text: String) async throws {
        stopPlayback()

        let utterance = AVSpeechUtterance(string: text)
        if let selectedSynthesisVoice {
            utterance.voice = selectedSynthesisVoice
        }

        playbackStartDate = Date()
        isPlaying = true
        print("TTS_START \(text.count)")
        speechSynthesizer.speak(utterance)
    }

    func stopPlayback() {
        guard isPlaying || speechSynthesizer.isSpeaking else { return }
        speechSynthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        playbackStartDate = nil
    }

    private func markPlaybackFinished(reason: String) {
        guard isPlaying else { return }
        isPlaying = false
        if let playbackStartDate {
            let playbackDurationSeconds = Date().timeIntervalSince(playbackStartDate)
            print("TTS_END \(String(format: "%.2f", playbackDurationSeconds)) (\(reason))")
        }
        playbackStartDate = nil
    }

    /// Picks the highest-quality installed voice for the current language.
    /// Premium and enhanced voices are the ones users download in
    /// System Settings → Accessibility → Spoken Content.
    private static func bestAvailableSynthesisVoice() -> AVSpeechSynthesisVoice? {
        let currentLanguageCode = AVSpeechSynthesisVoice.currentLanguageCode()
        let voicesForCurrentLanguage = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == currentLanguageCode }

        if let premiumVoice = voicesForCurrentLanguage.first(where: { $0.quality == .premium }) {
            return premiumVoice
        }
        if let enhancedVoice = voicesForCurrentLanguage.first(where: { $0.quality == .enhanced }) {
            return enhancedVoice
        }
        return AVSpeechSynthesisVoice(language: currentLanguageCode)
    }
}

// AVSpeechSynthesizer may call its delegate off the main actor, so each
// callback hops back to @MainActor before touching provider state.
extension AppleSpeechTTSProvider: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.markPlaybackFinished(reason: "finished")
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.markPlaybackFinished(reason: "cancelled")
        }
    }
}
