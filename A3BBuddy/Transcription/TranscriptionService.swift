//
//  TranscriptionService.swift
//  Whisper — Workstream A
//
//  WhisperKit wrapper: downloads the model with progress (posted via
//  .engineStatus for the menu bar), loads it, transcribes 16 kHz Float32.
//

import Foundation
import WhisperKit

@MainActor
final class TranscriptionService {
    private var whisperKit: WhisperKit?
    private(set) var loadedVariant: String?
    private var prepareTask: Task<Void, Error>?

    var isReady: Bool { whisperKit != nil }

    /// Downloads (if needed) and loads the given WhisperKit variant, e.g.
    /// `openai_whisper-large-v3-v20240930_626MB`. Safe to call repeatedly —
    /// concurrent calls share one in-flight load; switching variants reloads.
    func prepare(variant: String) async throws {
        if loadedVariant == variant, whisperKit != nil { return }
        if let running = prepareTask {
            running.cancel()
            _ = try? await running.value
        }

        let task = Task { [weak self] in
            guard let self else { return }

            if let old = self.whisperKit {
                await old.unloadModels()
                self.whisperKit = nil
                self.loadedVariant = nil
            }

            Self.postStatus("Downloading model…")
            let folder = try await WhisperKit.download(variant: variant, progressCallback: { progress in
                let pct = Int(progress.fractionCompleted * 100)
                Task { @MainActor in
                    Self.postStatus("Downloading model… \(pct)%")
                }
            })
            try Task.checkCancellation()

            Self.postStatus("Loading model…")
            let config = WhisperKitConfig(
                model: variant,
                modelFolder: folder.path,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            try Task.checkCancellation()

            self.whisperKit = kit
            self.loadedVariant = variant
            Self.postStatus(nil)
        }
        prepareTask = task
        defer { if prepareTask == task { prepareTask = nil } }
        do {
            try await task.value
        } catch {
            Self.postStatus("Model failed to load")
            throw error
        }
    }

    /// `samples` must be 16 kHz mono Float32 (AudioRecorder's output).
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let whisperKit else { throw DictationError.modelNotReady }
        let options = DecodingOptions(
            task: .transcribe,
            temperature: 0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func postStatus(_ status: String?) {
        NotificationCenter.default.post(
            name: .engineStatus,
            object: nil,
            userInfo: status.map { ["status": $0] } ?? [:]
        )
    }
}
