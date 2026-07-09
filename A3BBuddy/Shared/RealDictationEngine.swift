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
    /// When the mic actually opened, if it opened before the press was committed.
    private var armedAt: Date?

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
                // This fires on *every* defaults write, not just the model key,
                // so bail unless the wanted variant is neither loaded nor already
                // downloading. Otherwise toggling any pref mid-download spawns a
                // task per keystroke.
                let wanted = Self.selectedVariant().whisperKitName
                guard wanted != self.transcriber.loadedVariant,
                      wanted != self.transcriber.requestedVariant else { return }
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

    /// Opens the microphone the instant a dictation hold goes down, before the
    /// hotkey engine has decided whether it is a real press or the prefix of a
    /// chord (⌃ on the way to ⌃⌥). `AudioRecorder` has no ring buffer — samples
    /// accumulate only from `start()` — so without this a grace window would eat
    /// the first 200 ms of speech.
    ///
    /// Deliberately silent: no cue, no pill, no state change. And it never prompts
    /// for mic access — a permission sheet triggered by holding a modifier is
    /// hostile. The prompt still comes from `startRecording()`.
    ///
    /// Concrete, not a `DictationEngine` requirement: `Shared/Contracts.swift` is frozen.
    func prewarmRecording() {
        guard case .idle = state, !recorder.isRecording, Permissions.micStatus == .authorized else { return }
        captureTargetApp()
        let mic = UserDefaults.standard.string(forKey: PrefKey.preferredMicID) ?? ""
        try? recorder.start(preferredDeviceUID: mic)
        armedAt = recorder.isRecording ? .now : nil
    }

    /// The hold lost its race with a longer chord. Throw the warm-up away — but
    /// only if it never became a real recording. Synchronous on purpose: the
    /// engine emits `disarmed` before the winner's `pressed`, so the two
    /// `AVAudioEngine`s never contend for the input node.
    func discardPrewarm() {
        guard case .idle = state, recorder.isRecording else { return }
        recorder.cancel()
        audioLevel = 0
        armedAt = nil
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
        armedAt = nil
        failResetTask?.cancel()
        state = .idle
    }

    // MARK: Internals

    private func beginCapture() {
        guard case .idle = state else { return }

        if !recorder.isRecording {
            captureTargetApp()
            let mic = UserDefaults.standard.string(forKey: PrefKey.preferredMicID) ?? ""
            do {
                try recorder.start(preferredDeviceUID: mic)
            } catch {
                NSLog("Whisper: audio capture failed to start — \(error)")
                armedAt = nil
                fail(.micDenied)
                return
            }
        }

        playCue(.start)
        // Backdated to when the mic actually opened, so the pill's elapsed timer
        // matches the audio. `stopAndTranscribe`'s duration is sample-derived
        // either way — the grace window's 200 ms of speech is kept, not dropped.
        state = .recording(startedAt: armedAt ?? .now)
        armedAt = nil
    }

    /// The target app is where you *spoke*, not wherever focus drifted to by the
    /// time transcription finished. Captured at arm time when there was one.
    private func captureTargetApp() {
        let front = NSWorkspace.shared.frontmostApplication
        target = (front?.bundleIdentifier ?? "unknown", front?.localizedName ?? "Unknown")
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

    /// Same click, quieter and bass-boosted; the stop cue is the start cue
    /// played in reverse, so one asset gives two related-but-distinct sounds.
    private static let startCueURL = Bundle.main.url(forResource: "select-click", withExtension: "wav")
    private static let stopCueURL = Bundle.main.url(forResource: "select-click-release", withExtension: "wav")

    private func playCue(_ cue: Cue) {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: PrefKey.soundCues) == nil
            ? true
            : defaults.bool(forKey: PrefKey.soundCues)
        guard enabled else { return }
        guard let url = cue == .start ? Self.startCueURL : Self.stopCueURL else { return }
        NSSound(contentsOf: url, byReference: true)?.play()
    }
}
