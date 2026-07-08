//
//  AppDelegate.swift
//  a3b Buddy — integration layer
//
//  Owns the whole object graph for both halves of the app:
//    Whisper  — dictation engine, history store, stats, pill panel, onboarding
//    Clicky   — companion manager, menu bar panel, cursor overlay
//
//  This is the merge point of what used to be two separate `@main`s
//  (`WhisperApp` + `leanring_buddyApp`/`CompanionAppDelegate`).
//

import AppKit
import SwiftUI

typealias ActiveEngine = RealDictationEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = ActiveEngine()

    /// Declared before `hotkeys` on purpose: constructing the store runs
    /// HotkeyMigration, which must finish before HotkeyManager touches the
    /// `KeyboardShortcuts.Name` statics. Stored properties initialize in
    /// declaration order.
    let hotkeyBindings = HotkeyBindingStore.shared

    private let hotkeys = HotkeyManager()

    let store: any DictationStore = {
        do {
            return try SwiftDataStore()
        } catch {
            // App still works for the session; history just won't persist.
            NSLog("a3b Buddy: SwiftData container failed (\(error)) — using in-memory store")
            return MockDictationStore(seeded: false)
        }
    }()

    private(set) lazy var stats: any StatsProviding = StatsCalculator(
        records: { [store] in (try? store.all()) ?? [] }
    )

    private var panelController: RecordingPanelController<ActiveEngine>?
    private var onboardingWindow: NSWindow?

    // MARK: Clicky (companion)

    let companionManager = CompanionManager()
    private var menuBarPanelManager: MenuBarPanelManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Clicky reads this to make its tooltips appear instantly.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        // The main window is AppKit-owned; hand it the object graph.
        MainWindowController.shared.makeContentView = { [store, stats] in
            AnyView(MainWindowView(store: store, stats: stats))
        }

        // Whisper
        panelController = RecordingPanelController(engine: engine)
        applyRetention()
        refreshHasTranscripts()
        wireHotkeys()
        Task { await engine.prepare() }

        // Clicky — the single menu bar item lives here.
        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }

        if !UserDefaults.standard.bool(forKey: PrefKey.hasOnboarded) {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    // MARK: Menu bar panel actions (Whisper half)

    func openMainWindow() {
        MainWindowController.shared.show()
    }

    func openSettings() {
        SettingsWindowController.shared.show()
    }

    /// Cached, not computed. The menu bar panel reads this from its `body`, and
    /// the panel re-renders on every audio-power-level tick while Clicky is
    /// listening — a SwiftData fetch there would run dozens of times a second.
    private(set) var hasTranscripts = false

    private func refreshHasTranscripts() {
        hasTranscripts = !((try? store.all())?.isEmpty ?? true)
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
        hasTranscripts = true
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
        window.title = "Welcome to a3b Buddy"
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
