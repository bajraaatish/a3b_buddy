//
//  BuddyTTSProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for text-to-speech backends, mirroring the
//  BuddyTranscriptionProvider pattern. CompanionManager speaks through
//  this protocol so TTS engines can be swapped without touching the
//  state machine.
//

import Foundation

@MainActor
protocol BuddyTTSProvider: AnyObject {
    var displayName: String { get }

    /// True while synthesized audio is audibly playing. CompanionManager
    /// polls this to schedule the transient cursor fade-out after speech ends.
    var isPlaying: Bool { get }

    /// Begins speaking `text`. Returns once playback has started — NOT when
    /// it finishes. CompanionManager relies on this to switch the cursor from
    /// the processing spinner to the responding state at audio start.
    func speak(_ text: String) async throws

    /// Stops any in-progress playback immediately.
    func stopPlayback()
}

enum BuddyTTSProviderFactory {
    /// Kokoro (local neural TTS) is the default — Aatish rejected Apple
    /// Speech on voice quality (2026-07-06). Apple Speech is the automatic
    /// fallback when the Kokoro on-disk setup is missing, mirroring the
    /// transcription factory's fallback chain.
    @MainActor
    static func makeDefaultProvider() -> any BuddyTTSProvider {
        if let kokoroProvider = KokoroTTSProvider.makeIfAvailable() {
            print("🔊 TTS: using \(kokoroProvider.displayName)")
            return kokoroProvider
        }

        let fallbackProvider = AppleSpeechTTSProvider()
        print("⚠️ TTS: Kokoro unavailable, falling back to \(fallbackProvider.displayName)")
        return fallbackProvider
    }
}
