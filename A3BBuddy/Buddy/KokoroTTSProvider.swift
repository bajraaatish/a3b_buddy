//
//  KokoroTTSProvider.swift
//  leanring-buddy
//
//  Local neural text-to-speech via the Kokoro-82M ONNX model. Spawns the
//  bundled kokoro_tts_helper.py once (persistent, so the model loads a
//  single time), sends it text over line-delimited JSON, and plays the
//  returned WAV through AVAudioPlayer. Audio never leaves the machine.
//
//  Aatish picked this over AppleSpeechTTSProvider for voice quality;
//  Apple Speech remains the automatic fallback when the Kokoro setup
//  (model files + python venv) is missing — see BuddyTTSProviderFactory.
//

import AVFoundation
import Foundation

@MainActor
final class KokoroTTSProvider: NSObject, BuddyTTSProvider {
    let displayName = "Kokoro (local)"

    /// Voice embedding name inside voices-v1.0.bin. Aatish approved af_heart
    /// (2026-07-06); other candidates: af_bella, am_michael, bm_george.
    static let selectedVoiceName = "af_heart"

    /// How long speak(_:) waits for the helper to synthesize before failing.
    /// Generation on the M4 runs ~2s for a sentence; 30s covers a cold model
    /// load on first utterance plus a long response.
    private static let synthesisTimeoutSeconds: UInt64 = 30

    private let helperScriptURL: URL
    private let pythonInterpreterURL: URL

    private var helperProcess: Process?
    private var helperStdinPipe: Pipe?

    /// Continuations waiting on helper stdout, keyed by request id.
    private var pendingResponseContinuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var nextRequestID = 0
    private var stdoutLineBuffer = Data()

    /// Kept alive so audio finishes even if the caller drops its reference.
    private var audioPlayer: AVAudioPlayer?
    private var playbackStartDate: Date?

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Returns a provider only when the on-disk Kokoro setup exists —
    /// model weights, voice embeddings, python venv, and the helper script.
    static func makeIfAvailable() -> KokoroTTSProvider? {
        let ttsDirectoryURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/a3b-buddy/tts")

        let pythonInterpreterURL = ttsDirectoryURL.appendingPathComponent("venv/bin/python")
        let requiredFileURLs = [
            pythonInterpreterURL,
            ttsDirectoryURL.appendingPathComponent("kokoro-v1.0.onnx"),
            ttsDirectoryURL.appendingPathComponent("voices-v1.0.bin"),
        ]
        for requiredFileURL in requiredFileURLs {
            guard FileManager.default.fileExists(atPath: requiredFileURL.path) else {
                print("🔊 KokoroTTS: missing \(requiredFileURL.path), not available")
                return nil
            }
        }

        // Prefer the copy bundled with the app; fall back to the one
        // installed next to the model files.
        let helperScriptURL = Bundle.main.url(forResource: "kokoro_tts_helper", withExtension: "py")
            ?? ttsDirectoryURL.appendingPathComponent("kokoro_tts_helper.py")
        guard FileManager.default.fileExists(atPath: helperScriptURL.path) else {
            print("🔊 KokoroTTS: helper script not found, not available")
            return nil
        }

        return KokoroTTSProvider(
            helperScriptURL: helperScriptURL,
            pythonInterpreterURL: pythonInterpreterURL
        )
    }

    private init(helperScriptURL: URL, pythonInterpreterURL: URL) {
        self.helperScriptURL = helperScriptURL
        self.pythonInterpreterURL = pythonInterpreterURL
        super.init()
        // Spawn eagerly so the ~310MB model loads during app startup rather
        // than adding ~1.5s to the first spoken response. speak(_:) respawns
        // if the helper has died in the meantime.
        try? spawnHelper()
    }

    /// Synthesizes `text` and starts playback. Returns once audio is playing
    /// (not when it finishes) — same contract as the other providers.
    func speak(_ text: String) async throws {
        stopPlayback()

        let wavFileURL = try await synthesizeToWavFile(text)

        let player = try AVAudioPlayer(contentsOf: wavFileURL)
        player.delegate = self
        audioPlayer = player
        playbackStartDate = Date()
        print("TTS_START \(text.count)")
        player.play()
    }

    func stopPlayback() {
        guard let audioPlayer else { return }
        audioPlayer.stop()
        self.audioPlayer = nil
        playbackStartDate = nil
    }

    // MARK: - Helper process

    private func synthesizeToWavFile(_ text: String) async throws -> URL {
        if helperProcess?.isRunning != true {
            try spawnHelper()
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let requestBody = try JSONSerialization.data(withJSONObject: ["id": requestID, "text": text])
        helperStdinPipe?.fileHandleForWriting.write(requestBody)
        helperStdinPipe?.fileHandleForWriting.write(Data("\n".utf8))

        return try await withResponseTimeout(requestID: requestID)
    }

    private func spawnHelper() throws {
        let process = Process()
        process.executableURL = pythonInterpreterURL
        process.arguments = [helperScriptURL.path]

        var environment = ProcessInfo.processInfo.environment
        environment["A3B_KOKORO_VOICE"] = Self.selectedVoiceName
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let chunk = fileHandle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeHelperStdout(chunk)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleHelperTermination()
            }
        }

        try process.run()
        helperProcess = process
        helperStdinPipe = stdinPipe
        print("🔊 KokoroTTS: helper spawned, voice = \(Self.selectedVoiceName)")
    }

    private func consumeHelperStdout(_ chunk: Data) {
        stdoutLineBuffer.append(chunk)

        while let newlineIndex = stdoutLineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutLineBuffer.prefix(upTo: newlineIndex)
            stdoutLineBuffer.removeSubrange(...newlineIndex)

            guard let response = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else {
                continue
            }

            if response["ready"] as? Bool == true {
                // Model finished loading. No handshake needed — requests sent
                // earlier queue in the stdin pipe until the helper reads them.
                print("🔊 KokoroTTS: model loaded")
                continue
            }

            guard let requestID = response["id"] as? Int else { continue }

            if let wavPath = response["wav"] as? String {
                let generationSeconds = response["generation_seconds"] as? Double ?? 0
                print("🔊 KokoroTTS: generated \(response["audio_seconds"] as? Double ?? 0)s audio in \(generationSeconds)s")
                resumePendingContinuation(forRequestID: requestID, with: .success(URL(fileURLWithPath: wavPath)))
            } else {
                let helperErrorDescription = response["error"] as? String ?? "unknown helper error"
                resumePendingContinuation(forRequestID: requestID, with: .failure(NSError(
                    domain: "KokoroTTS", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: helperErrorDescription]
                )))
            }
        }
    }

    private func handleHelperTermination() {
        print("⚠️ KokoroTTS: helper exited")
        helperProcess = nil
        helperStdinPipe = nil
        let terminationError = NSError(
            domain: "KokoroTTS", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Kokoro helper process exited"]
        )
        for requestID in Array(pendingResponseContinuations.keys) {
            resumePendingContinuation(forRequestID: requestID, with: .failure(terminationError))
        }
    }

    private func withResponseTimeout(requestID: Int) async throws -> URL {
        // Watchdog fails the pending continuation if the helper never
        // answers. Cancelled the moment the response resumes us; resuming
        // an already-removed continuation is a no-op either way.
        let timeoutWatchdogTask = Task {
            try await Task.sleep(nanoseconds: Self.synthesisTimeoutSeconds * 1_000_000_000)
            resumePendingContinuation(forRequestID: requestID, with: .failure(NSError(
                domain: "KokoroTTS", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Kokoro synthesis timed out"]
            )))
        }
        defer { timeoutWatchdogTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponseContinuations[requestID] = continuation
        }
    }

    private func resumePendingContinuation(forRequestID requestID: Int, with result: Result<URL, Error>) {
        guard let continuation = pendingResponseContinuations.removeValue(forKey: requestID) else { return }
        continuation.resume(with: result)
    }
}

extension KokoroTTSProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if let playbackStartDate = self.playbackStartDate {
                let playbackDurationSeconds = Date().timeIntervalSince(playbackStartDate)
                print("TTS_END \(String(format: "%.2f", playbackDurationSeconds)) (finished)")
            }
            self.playbackStartDate = nil
            self.audioPlayer = nil
        }
    }
}
