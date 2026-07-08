//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  Local speech-to-text via Aatish's Whisper setup (WhisperKit CoreML,
//  large-v3 turbo). Batch provider: buffers push-to-talk audio while the
//  key is held, then hands one WAV to the persistent whisper-stt-helper
//  process on key-up — same helper pattern as KokoroTTSProvider. Audio
//  never leaves the machine.
//
//  The helper binary is built from the standalone STT helper SwiftPM
//  package — the app project itself has no WhisperKit dependency) and
//  installed to ~/Library/Application Support/a3b-buddy/stt/.
//

import AVFoundation
import Foundation

struct WhisperKitTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    /// Same variant as Aatish's Whisper.app; already cached on disk.
    static let modelVariantName = "openai_whisper-large-v3-v20240930_626MB"

    private static var helperBinaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/a3b-buddy/stt/whisper-stt-helper")
    }

    private static var modelFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml/\(modelVariantName)")
    }

    let displayName = "Whisper (local)"
    let requiresSpeechRecognitionPermission = false

    /// One helper process shared across all sessions. Created eagerly so the
    /// CoreML model loads during app startup, not on the first utterance.
    private let helperClient: WhisperSTTHelperClient?

    init() {
        if Self.checkOnDiskSetupExists() {
            let helperClient = WhisperSTTHelperClient(helperBinaryURL: Self.helperBinaryURL)
            helperClient.spawnIfNeeded()
            self.helperClient = helperClient
        } else {
            self.helperClient = nil
        }
    }

    var isConfigured: Bool {
        helperClient != nil
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Whisper STT is not set up. Expected helper at \(Self.helperBinaryURL.path) and model at \(Self.modelFolderURL.path)."
    }

    private static func checkOnDiskSetupExists() -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: helperBinaryURL.path) else {
            print("🎙️ WhisperSTT: helper binary missing at \(helperBinaryURL.path)")
            return false
        }
        guard fileManager.fileExists(atPath: modelFolderURL.path) else {
            print("🎙️ WhisperSTT: model folder missing at \(modelFolderURL.path)")
            return false
        }
        return true
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let helperClient else {
            throw WhisperKitTranscriptionProviderError(
                message: unavailableExplanation ?? "Whisper STT is not set up."
            )
        }

        return WhisperKitTranscriptionSession(
            helperClient: helperClient,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

// MARK: - Session (buffer on key-down, transcribe on key-up)

private final class WhisperKitTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// Transcription runs ~1.6s for a 5s utterance on the M4; 10s leaves
    /// headroom for long questions before the dictation manager gives up.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 10.0

    private static let targetSampleRate = 16_000

    private let helperClient: WhisperSTTHelperClient
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.a3b.whisper.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        helperClient: WhisperSTTHelperClient,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.helperClient = helperClient
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        print("STT_START")
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionTask?.cancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        if bufferedPCM16AudioData.isEmpty {
            deliverFinalTranscript("")
            return
        }

        // Whisper hallucinates phrases like "thank you" when handed silence,
        // so a press-and-release with no speech must never reach the model.
        // The gate is deliberately loose: macOS auto-gain starts quiet when the
        // mic first wakes, so real first utterances can measure low. Only hard
        // silence is dropped here; quiet-but-suspicious transcripts are handled
        // after transcription instead.
        let measuredRMSLevel = Self.measureRMSLevel(of: bufferedPCM16AudioData)
        let sampleCount = bufferedPCM16AudioData.count / MemoryLayout<Int16>.size
        let audioDurationSeconds = Double(sampleCount) / Double(Self.targetSampleRate)
        guard audioDurationSeconds >= Self.minimumSpeechDurationSeconds,
              measuredRMSLevel >= Self.hardSilenceRMSLevel else {
            print("🎙️ WhisperSTT: skipping transcription — audio is silent or too short (\(String(format: "%.2f", audioDurationSeconds))s, rms \(String(format: "%.4f", measuredRMSLevel)))")
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try await helperClient.transcribe(wavAudioData: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            // Quiet audio that decodes to a stock Whisper hallucination phrase
            // was almost certainly silence — drop it. Loud audio is always
            // trusted, so genuinely saying "thank you" still works.
            if measuredRMSLevel < Self.confidentSpeechRMSLevel,
               Self.checkTranscriptIsLikelyHallucination(transcriptText) {
                print("🎙️ WhisperSTT: dropping likely hallucination on quiet audio (rms \(String(format: "%.4f", measuredRMSLevel))): \"\(transcriptText)\"")
                deliverFinalTranscript("")
                return
            }

            print("STT_FINAL \(transcriptText)")
            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("🎙️ WhisperSTT: ❌ transcription failed (\(wavAudioData.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    /// Minimum audio needed before we bother transcribing — shorter than any
    /// spoken word is treated as an accidental tap.
    private static let minimumSpeechDurationSeconds = 0.25
    /// RMS ≈ -54 dBFS. Even auto-gain-cold first utterances land above this;
    /// only a truly silent room falls below it.
    private static let hardSilenceRMSLevel: Float = 0.002
    /// RMS ≈ -38 dBFS. Above this the audio clearly contains speech and the
    /// transcript is always trusted, hallucination-shaped or not.
    private static let confidentSpeechRMSLevel: Float = 0.012

    /// Whisper's stock outputs for silence/noise — artifacts of its
    /// YouTube-caption training data.
    private static let knownSilenceHallucinationPhrases: Set<String> = [
        "thank you", "thanks", "thank you for watching", "thanks for watching",
        "thank you so much for watching", "you", "bye", "so", "uh", "um"
    ]

    private static func measureRMSLevel(of pcm16AudioData: Data) -> Float {
        let sampleCount = pcm16AudioData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        var summedSquares = 0.0
        pcm16AudioData.withUnsafeBytes { rawAudioBuffer in
            for audioSample in rawAudioBuffer.bindMemory(to: Int16.self) {
                let normalizedSampleLevel = Float(audioSample) / Float(Int16.max)
                summedSquares += Double(normalizedSampleLevel * normalizedSampleLevel)
            }
        }

        return Float((summedSquares / Double(sampleCount)).squareRoot())
    }

    private static func checkTranscriptIsLikelyHallucination(_ transcriptText: String) -> Bool {
        let normalizedTranscript = transcriptText
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return normalizedTranscript.isEmpty
            || knownSilenceHallucinationPhrases.contains(normalizedTranscript)
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        // Do NOT call cancel() here. cancel() enqueues a block that strongly
        // captures self, and retaining self while it is deallocating is a
        // Swift runtime fatal error (this crashed on every quick
        // press-and-release of the push-to-talk shortcut). The buffered audio
        // is freed with the instance; only the in-flight task needs stopping.
        transcriptionTask?.cancel()
    }
}

// MARK: - Helper process client

/// Owns the persistent whisper-stt-helper process and the line-delimited
/// JSON protocol with it. Thread-safe: all mutable state is confined to
/// `stateQueue` because sessions call in from audio/dispatch threads.
final class WhisperSTTHelperClient: @unchecked Sendable {
    private static let transcriptionTimeoutSeconds: UInt64 = 30

    private let helperBinaryURL: URL
    private let stateQueue = DispatchQueue(label: "com.a3b.whisper.helper-client")

    private var helperProcess: Process?
    private var helperStdinPipe: Pipe?
    private var pendingResponseContinuations: [Int: CheckedContinuation<String, Error>] = [:]
    private var nextRequestID = 0
    private var stdoutLineBuffer = Data()

    init(helperBinaryURL: URL) {
        self.helperBinaryURL = helperBinaryURL
    }

    func spawnIfNeeded() {
        stateQueue.async {
            self.spawnLockedIfNeeded()
        }
    }

    /// Writes the WAV to a temp file, asks the helper to transcribe it, and
    /// returns the final text. Times out rather than hanging push-to-talk.
    func transcribe(wavAudioData: Data) async throws -> String {
        let wavFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("a3b-stt-\(UUID().uuidString).wav")
        try wavAudioData.write(to: wavFileURL)
        defer { try? FileManager.default.removeItem(at: wavFileURL) }

        let requestID: Int = stateQueue.sync {
            spawnLockedIfNeeded()
            let assignedRequestID = nextRequestID
            nextRequestID += 1
            return assignedRequestID
        }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "id": requestID,
            "wav": wavFileURL.path,
        ])

        let timeoutWatchdogTask = Task {
            try await Task.sleep(nanoseconds: Self.transcriptionTimeoutSeconds * 1_000_000_000)
            self.resumePendingContinuation(forRequestID: requestID, with: .failure(
                WhisperKitTranscriptionProviderError(message: "Whisper transcription timed out")
            ))
        }
        defer { timeoutWatchdogTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                guard let stdinFileHandle = self.helperStdinPipe?.fileHandleForWriting else {
                    continuation.resume(throwing: WhisperKitTranscriptionProviderError(
                        message: "Whisper helper is not running"
                    ))
                    return
                }
                self.pendingResponseContinuations[requestID] = continuation
                stdinFileHandle.write(requestBody)
                stdinFileHandle.write(Data("\n".utf8))
            }
        }
    }

    /// Must be called on `stateQueue`.
    private func spawnLockedIfNeeded() {
        guard helperProcess?.isRunning != true else { return }

        let process = Process()
        process.executableURL = helperBinaryURL

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let chunk = fileHandle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.stateQueue.async {
                self.consumeHelperStdoutLocked(chunk)
            }
        }

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                self.handleHelperTerminationLocked()
            }
        }

        do {
            try process.run()
            helperProcess = process
            helperStdinPipe = stdinPipe
            print("🎙️ WhisperSTT: helper spawned, model \(WhisperKitTranscriptionProvider.modelVariantName)")
        } catch {
            print("🎙️ WhisperSTT: ❌ failed to spawn helper: \(error.localizedDescription)")
        }
    }

    /// Must be called on `stateQueue`.
    private func consumeHelperStdoutLocked(_ chunk: Data) {
        stdoutLineBuffer.append(chunk)

        while let newlineIndex = stdoutLineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = Data(stdoutLineBuffer.prefix(upTo: newlineIndex))
            stdoutLineBuffer.removeSubrange(...newlineIndex)

            guard let response = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if response["ready"] as? Bool == true {
                print("🎙️ WhisperSTT: model loaded")
                continue
            }

            guard let requestID = response["id"] as? Int else {
                if let helperErrorDescription = response["error"] as? String {
                    print("🎙️ WhisperSTT: helper error: \(helperErrorDescription)")
                }
                continue
            }

            if let transcriptText = response["text"] as? String {
                let transcribeSeconds = response["transcribe_seconds"] as? Double ?? 0
                print("🎙️ WhisperSTT: transcribed in \(transcribeSeconds)s")
                resumePendingContinuationLocked(forRequestID: requestID, with: .success(transcriptText))
            } else {
                let helperErrorDescription = response["error"] as? String ?? "unknown helper error"
                resumePendingContinuationLocked(forRequestID: requestID, with: .failure(
                    WhisperKitTranscriptionProviderError(message: helperErrorDescription)
                ))
            }
        }
    }

    /// Must be called on `stateQueue`.
    private func handleHelperTerminationLocked() {
        print("⚠️ WhisperSTT: helper exited")
        helperProcess = nil
        helperStdinPipe = nil
        let terminationError = WhisperKitTranscriptionProviderError(
            message: "Whisper helper process exited"
        )
        for requestID in Array(pendingResponseContinuations.keys) {
            resumePendingContinuationLocked(forRequestID: requestID, with: .failure(terminationError))
        }
    }

    private func resumePendingContinuation(forRequestID requestID: Int, with result: Result<String, Error>) {
        stateQueue.async {
            self.resumePendingContinuationLocked(forRequestID: requestID, with: result)
        }
    }

    /// Must be called on `stateQueue`. Resuming twice is impossible — the
    /// continuation is removed from the table before resuming.
    private func resumePendingContinuationLocked(forRequestID requestID: Int, with result: Result<String, Error>) {
        guard let continuation = pendingResponseContinuations.removeValue(forKey: requestID) else { return }
        continuation.resume(with: result)
    }

    deinit {
        helperProcess?.terminate()
    }
}
