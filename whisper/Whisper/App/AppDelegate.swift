//
//  AppDelegate.swift
//  Whisper — integration layer
//
//  Owns the object graph: engine, store, stats, pill panel, onboarding.
//  ActiveEngine is the one line that flips from mock to real when
//  Workstream A lands.
//

import AppKit
import SwiftUI

typealias ActiveEngine = RealDictationEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = ActiveEngine()
    private let hotkeys = HotkeyManager()

    let store: any DictationStore = {
        do {
            return try SwiftDataStore()
        } catch {
            // App still works for the session; history just won't persist.
            NSLog("Whisper: SwiftData container failed (\(error)) — using in-memory store")
            return MockDictationStore(seeded: false)
        }
    }()

    private(set) lazy var stats: any StatsProviding = StatsCalculator(
        records: { [store] in (try? store.all()) ?? [] }
    )

    private var panelController: RecordingPanelController<ActiveEngine>?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = RecordingPanelController(engine: engine)
        applyRetention()
        wireHotkeys()
        Task { await engine.prepare() }
        if !UserDefaults.standard.bool(forKey: PrefKey.hasOnboarded) {
            showOnboarding()
        }
    }

    // MARK: Hotkey → engine → store

    private func wireHotkeys() {
        hotkeys.onStartRecording = { [weak self] in
            self?.engine.startRecording()
        }
        hotkeys.onStopAndTranscribe = { [weak self] in
            Task { @MainActor in
                guard let self, let result = await self.engine.stopAndTranscribe() else { return }
                self.saveIfRetained(result)
            }
        }
        hotkeys.onCancel = { [weak self] in
            self?.engine.cancel()
        }
    }

    private func saveIfRetained(_ result: DictationResult) {
        let retention = HistoryRetention(
            rawValue: UserDefaults.standard.string(forKey: PrefKey.retention) ?? ""
        ) ?? .forever
        guard retention != .off else { return }
        try? store.save(result)
        NotificationCenter.default.post(name: .dictationDidSave, object: nil)
    }

    // MARK: Menu actions

    func pasteLastTranscript() {
        guard let last = (try? store.all())?.first else { return }
        engine.inserter.pasteToFrontmostApp(last.text)
    }

    #if DEBUG
    /// Debug helper: records the mic for 3 s and runs the full pipeline —
    /// pill, transcription, paste, history — without touching the hotkey.
    func demoDictation() {
        Task {
            engine.startRecording()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let result = await engine.stopAndTranscribe() {
                saveIfRetained(result)
            }
        }
    }
    #endif

    // MARK: Onboarding

    private func showOnboarding() {
        let view = OnboardingView(
            requestMic: { await Permissions.requestMic() },
            promptAccessibility: {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            },
            isAccessibilityTrusted: { Permissions.accessibilityGranted },
            onDone: { [weak self] in
                UserDefaults.standard.set(true, forKey: PrefKey.hasOnboarded)
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Whisper"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Retention (Phase 5)

    private func applyRetention() {
        let raw = UserDefaults.standard.string(forKey: PrefKey.retention) ?? ""
        guard let retention = HistoryRetention(rawValue: raw), retention == .thirtyDays,
              let sqlStore = store as? SwiftDataStore,
              let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now)
        else { return }
        try? sqlStore.purge(olderThan: cutoff)
    }
}
