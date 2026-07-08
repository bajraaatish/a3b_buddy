//
//  RealDictationEngine.swift
//  Whisper — Workstream A
//
//  Composes AudioRecorder + TranscriptionService + TextInserter into the
//  DictationEngine contract. The mock's drop-in replacement: AppDelegate's
//  `ActiveEngine` typealias is the only line that changes at integration.
//

import AppKit
import AVFoundation
import Combine

@MainActor
final class RealDictationEngine: ObservableObject, DictationEngine {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var audioLevel: Float = 0

    /// Exposed so the menu bar's "Paste last transcript" reuses the paste path.
    let inserter = TextInserter()

    private let recorder = AudioRecorder()
    private let transcriber = TranscriptionService()
    private var target: (bundleID: String, name: String) = ("", "")
    private var failResetTask: Task<Void, Never>?
    private var prefObserver: NSObjectProtocol?

    init() {
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.audioLevel = level }
        }
    }

    // MARK: Model lifecycle

    /// Call once at launch: downloads/loads the selected model (progress goes
    /// out via .engineStatus) and reloads whenever Settings switches variants.
    func prepare() async {
        try? await transcriber.prepare(variant: Self.selectedVariant().whisperKitName)
        watchModelPref()
    }

    private static func selectedVariant() -> ModelVariant {
        ModelVariant(rawValue: UserDefaults.standard.string(forKey: PrefKey.modelVariant) ?? "") ?? .turbo
    }

    private func watchModelPref() {
        guard prefObserver == nil else { return }
        prefObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wanted = Self.selectedVariant().whisperKitName
                guard wanted != self.transcriber.loadedVariant else { return }
                Task { try? await self.transcriber.prepare(variant: wanted) }
            }
        }
    }

    // MARK: DictationEngine

    func startRecording() {
        guard case .idle = state else { return }
        switch Permissions.micStatus {
        case .authorized:
            beginCapture()
        case .notDetermined:
            Task { @MainActor in
                if await Permissions.requestMic() { self.beginCapture() } else { self.fail(.micDenied) }
            }
        default:
            fail(.micDenied)
        }
    }

    func stopAndTranscribe() async -> DictationResult? {
        guard case .recording = state else { return nil }
        playCue(.stop)
        state = .transcribing
        let samples = recorder.stop()
        audioLevel = 0

        // Honest duration: what the mic actually captured, not wall-clock.
        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        guard duration >= 0.3 else {
            state = .idle
            return nil
        }
        guard transcriber.isReady else {
            fail(.modelNotReady)
            return nil
        }

        let text: String
        do {
            text = try await transcriber.transcribe(samples)
        } catch {
            fail(.transcriptionFailed)
            return nil
        }
        guard !text.isEmpty else {
            state = .idle
            return nil
        }

        let outcome = inserter.insert(text)
        if outcome == .failed {
            fail(.insertionFailed)
        } else {
            state = .idle
        }
        // Logged even when paste fell back to the clipboard — the words were spoken.
        return DictationResult(
            text: text,
            duration: duration,
            targetAppBundleID: target.bundleID,
            targetAppName: target.name
        )
    }

    func cancel() {
        recorder.cancel()
        audioLevel = 0
        failResetTask?.cancel()
        state = .idle
    }

    // MARK: Internals

    private func beginCapture() {
        guard case .idle = state else { return }
        // Captured at record-start (rule: target app is where you spoke, not
        // wherever focus drifted by transcription time).
        let front = NSWorkspace.shared.frontmostApplication
        target = (front?.bundleIdentifier ?? "unknown", front?.localizedName ?? "Unknown")

        let mic = UserDefaults.standard.string(forKey: PrefKey.preferredMicID) ?? ""
        do {
            try recorder.start(preferredDeviceUID: mic)
        } catch {
            NSLog("Whisper: audio capture failed to start — \(error)")
            fail(.micDenied)
            return
        }
        playCue(.start)
        state = .recording(startedAt: .now)
    }

    /// Failure shows on the pill briefly, then the engine returns to idle so
    /// the pill dismisses and the next dictation can start.
    private func fail(_ error: DictationError) {
        state = .failed(error)
        failResetTask?.cancel()
        failResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, case .failed = self.state else { return }
            self.state = .idle
        }
    }

    private enum Cue { case start, stop }

    private func playCue(_ cue: Cue) {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: PrefKey.soundCues) == nil
            ? true
            : defaults.bool(forKey: PrefKey.soundCues)
        guard enabled else { return }
        NSSound(named: cue == .start ? "Tink" : "Pop")?.play()
    }
}
