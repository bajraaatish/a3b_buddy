//
//  AppDelegate.swift
//  a3b Buddy — integration layer
//
//  Owns both feature graphs after the Whisper + Clicky merge:
//  - Whisper dictation: engine, store, stats, pill panel, onboarding.
//    ActiveEngine is the one line that flips from mock to real.
//  - Clicky companion: CompanionManager pipeline plus MenuBarPanelManager,
//    which provides the app's single menu bar status item.
//
//  The Whisper history/insights window is created here as a plain NSWindow
//  (same pattern as the onboarding window) because the menu bar panel —
//  AppKit, outside any SwiftUI scene — is now what opens it.
//

import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

typealias ActiveEngine = RealDictationEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: Whisper dictation graph

    let engine = ActiveEngine()
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
    private var mainWindow: NSWindow?

    // MARK: Clicky companion graph

    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Whisper launch work
        panelController = RecordingPanelController(engine: engine)
        applyRetention()
        wireHotkeys()
        Task { await engine.prepare() }

        // Clicky launch work (from the former CompanionAppDelegate)
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()
        menuBarPanelManager = MenuBarPanelManager(
            companionManager: companionManager,
            whisperBridge: makeWhisperMenuBridge()
        )
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()

        if !UserDefaults.standard.bool(forKey: PrefKey.hasOnboarded) {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    // MARK: Menu bar bridge (Whisper actions inside the Clicky panel)

    private func makeWhisperMenuBridge() -> WhisperMenuBridge {
        WhisperMenuBridge(
            engine: engine,
            hasTranscripts: { [store] in !(((try? store.all()) ?? []).isEmpty) },
            openMainWindow: { [weak self] in self?.openMainWindow() },
            pasteLastTranscript: { [weak self] in self?.pasteLastTranscript() },
            openSettings: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        )
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

    /// Opens the Whisper history/insights window. Hosted as a plain NSWindow
    /// (not a SwiftUI Window scene) so the AppKit menu bar panel can open it.
    func openMainWindow() {
        if mainWindow == nil {
            let view = MainWindowView(store: store, stats: stats)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "a3b Buddy"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true) // LSUIElement apps open windows behind others otherwise
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

    // MARK: Login item (from Clicky)

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 a3b Buddy: Registered as login item")
            } catch {
                print("⚠️ a3b Buddy: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ a3b Buddy: Sparkle updater failed to start: \(error)")
        }
    }

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
