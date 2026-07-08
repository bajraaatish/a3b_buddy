//
//  AppDelegate.swift
//  a3b Buddy — integration layer
//
//  Owns both feature graphs after the Whisper + a3b-buddy merge:
//  - Whisper dictation: engine, store, stats, pill panel, onboarding.
//    ActiveEngine is the one line that flips from mock to real.
//  - a3b-buddy companion: CompanionManager pipeline plus MenuBarPanelManager,
//    which provides the app's single menu bar status item. The companion is
//    fully local — WhisperKit STT helper, the `claude` CLI brain, and local
//    TTS — so there is no Cloudflare Worker, Sparkle, or analytics here.
//
//  The Whisper history/insights window is created here as a plain NSWindow
//  (same pattern as the onboarding window) because the menu bar panel —
//  AppKit, outside any SwiftUI scene — is now what opens it.
//

import AppKit
import ServiceManagement
import SwiftUI

typealias ActiveEngine = RealDictationEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: Whisper dictation graph

    let engine = ActiveEngine()

    /// Declared before `hotkeys` on purpose: constructing the store runs
    /// HotkeyMigration, which must finish before anything touches the
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
    private let recordingControls = RecordingControls()
    private var onboardingWindow: NSWindow?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    // MARK: a3b-buddy companion graph

    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Whisper launch work
        panelController = RecordingPanelController(engine: engine, controls: recordingControls)
        applyRetention()
        wireHotkeys()
        // Both adapters subscribe in their own init, and both are stored properties,
        // so they are live by now. `HotkeyEngine.events` is a PassthroughSubject and
        // drops anything sent before a subscriber exists — start it after, not in init.
        HotkeyEngine.shared.start()
        Task { await engine.prepare() }

        // Companion launch work (from the former CompanionAppDelegate)
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
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

        if !UserDefaults.standard.bool(forKey: PrefKey.hasOnboarded) {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    // MARK: Menu bar bridge (Whisper actions inside the companion panel)

    private func makeWhisperMenuBridge() -> WhisperMenuBridge {
        WhisperMenuBridge(
            engine: engine,
            hasTranscripts: { [store] in !(((try? store.all()) ?? []).isEmpty) },
            openMainWindow: { [weak self] in self?.openMainWindow() },
            pasteLastTranscript: { [weak self] in self?.pasteLastTranscript() },
            openSettings: { [weak self] in self?.openSettingsWindow() }
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
        // Hands-free lock ↔ the recording pill's ✕/✓ buttons.
        hotkeys.onLockChange = { [weak self] locked in
            self?.recordingControls.isHandsFreeLocked = locked
        }
        recordingControls.onCancel = { [weak self] in self?.hotkeys.cancelFromButton() }
        recordingControls.onConfirm = { [weak self] in self?.hotkeys.confirmFromButton() }

        // The engine reports `armed` the instant a dictation trigger goes down, before
        // it knows whether it's a press or the prefix of a chord (⌃ on the way to ⌃⌥).
        // AudioRecorder has no ring buffer — samples accumulate only from start() — so
        // the mic opens here. Silently: no pill, no cue, no state change.
        hotkeys.onArm = { [weak self] in self?.engine.prewarmRecording() }
        hotkeys.onDisarm = { [weak self] in self?.engine.discardPrewarm() }
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

    /// Opens dictation Settings. A plain NSWindow, for the same reason
    /// `openMainWindow()` is one.
    ///
    /// This used to be `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, …)`,
    /// which never opened anything. `sendAction(to: nil)` resolves its target by
    /// walking the key window's responder chain — and we are an LSUIElement app
    /// being clicked from a `.nonactivatingPanel`, so there is no key window and
    /// the app is not active. The action found no target and silently returned
    /// false. Activating afterwards was too late. (The selector itself is alive
    /// and well on macOS 26; the call site was the bug.)
    ///
    /// Hosting the view ourselves also gets the hotkey recorder a window that can
    /// become key, which a non-activating panel never can.
    func openSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Buddy Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the Whisper history/insights window. Hosted as a plain NSWindow
    /// (not a SwiftUI Window scene) so the AppKit menu bar panel can open it.
    func openMainWindow() {
        if mainWindow == nil {
            let view = MainWindowView(store: store, stats: stats)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Buddy"
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

    // MARK: Login item

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
        window.title = "Welcome to Buddy"
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
