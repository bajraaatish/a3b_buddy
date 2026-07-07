//
//  HotkeyManager.swift
//  Whisper — Workstream A
//
//  Primary trigger: hold a bare modifier (Settings → Dictation picks which;
//  default ⌃ Control) — press to record, release to transcribe, double-tap
//  to lock hands-free, tap to stop. The KeyboardShortcuts combo still works
//  and drives the same state machine. Esc cancels. 5-minute hard stop.
//
//  Seeing a bare modifier in *other* apps requires a listen-only CGEventTap,
//  which macOS gates behind Input Monitoring (not Accessibility). If the tap
//  can't be created, NSEvent global monitors are installed as a best-effort
//  fallback and Settings shows the grant button.
//
//  The hold key doubles as a shortcut modifier everywhere, so an unlocked
//  hold is cancelled the moment any other key, modifier, or click joins in
//  (⌃C, ⌃-click, ⌃⌘F…) — the shortcut passes through untouched. A locked
//  session only ends via tap or Esc, so you can Cmd+Tab between fields
//  while dictating hands-free.
//

import AppKit
import KeyboardShortcuts

@MainActor
final class HotkeyManager {
    var onStartRecording: () -> Void = {}
    var onStopAndTranscribe: () -> Void = {}
    var onCancel: () -> Void = {}

    /// A press shorter than this is a "tap"; a second tap within the same
    /// window locks hands-free recording.
    private let tapWindow: TimeInterval = 0.35
    private let maxDuration: TimeInterval = 5 * 60

    private var isActive = false
    private var isLocked = false
    private var pressStartedAt: Date?
    private var tapDeadline: Date?
    private var maxDurationTimer: Timer?

    // Bare hold-key tracking
    private var holdKeyDown = false
    private var holdSessionActive = false

    // Event sources
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var fallbackMonitors: [Any] = []
    private var localMonitors: [Any] = []

    init() {
        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in self?.keyDown() }
        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in self?.keyUp() }
        installLocalMonitors()
        startGlobalListening()
        watchHoldKeyPref()
    }

    // MARK: Global listening (CGEventTap, NSEvent fallback)

    private func startGlobalListening() {
        guard HoldKey.current != .off else { return }
        guard eventTap == nil else { return }

        if Permissions.inputMonitoringGranted {
            createEventTap()
        } else {
            Permissions.requestInputMonitoring()
            // Grant applies after relaunch; still try, then fall back.
            createEventTap()
        }
        if eventTap == nil {
            installFallbackMonitors()
        }
    }

    private func createEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // Listen-only tap on the main run loop → main thread.
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { manager.handleTapEvent(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Whisper: event tap unavailable (Input Monitoring not granted?) — using fallback monitors")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapRunLoopSource = source
        removeFallbackMonitors()
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        case .flagsChanged:
            handleFlagsChanged(modifierFlags(from: event.flags))
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            _ = handleCancelKey(keyCode)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handleCancelClick()
        default:
            break
        }
    }

    private func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var mods: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { mods.insert(.control) }
        if flags.contains(.maskCommand) { mods.insert(.command) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskShift) { mods.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { mods.insert(.function) }
        return mods
    }

    /// NSEvent-based best effort when the tap can't be created. May stay
    /// silent outside the app until Input Monitoring is granted + relaunch.
    private func installFallbackMonitors() {
        guard fallbackMonitors.isEmpty else { return }
        if let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor in self?.handleFlagsChanged(flags) }
        }) {
            fallbackMonitors.append(flags)
        }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            Task { @MainActor in _ = self?.handleCancelKey(keyCode) }
        }) {
            fallbackMonitors.append(keys)
        }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let mouse = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            Task { @MainActor in self?.handleCancelClick() }
        }) {
            fallbackMonitors.append(mouse)
        }
    }

    private func removeFallbackMonitors() {
        fallbackMonitors.forEach(NSEvent.removeMonitor)
        fallbackMonitors.removeAll()
    }

    /// Local monitors keep everything working inside Whisper's own windows
    /// even with no permissions at all, and let us consume Esc there.
    private func installLocalMonitors() {
        if let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.handleFlagsChanged(flags) }
            return event
        }) {
            localMonitors.append(flags)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            let consume = MainActor.assumeIsolated { self?.handleCancelKey(keyCode) ?? false }
            return consume ? nil : event
        }) {
            localMonitors.append(keys)
        }
    }

    /// Settings can change the hold key (or turn it off) at runtime.
    private func watchHoldKeyPref() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if HoldKey.current == .off {
                    self.holdKeyDown = false
                } else if self.eventTap == nil {
                    self.startGlobalListening()
                }
            }
        }
    }

    // MARK: Bare hold-key state

    private func handleFlagsChanged(_ raw: NSEvent.ModifierFlags) {
        guard let holdFlag = HoldKey.current.flag else { return }
        let mods = raw.intersection([.control, .command, .option, .shift, .function])
        let holdAlone = mods == holdFlag

        if holdAlone, !holdKeyDown {
            holdKeyDown = true
            holdPressed()
        } else if !mods.contains(holdFlag), holdKeyDown {
            holdKeyDown = false
            holdReleased()
        } else if holdKeyDown, !holdAlone {
            // Another modifier joined mid-hold — it's a shortcut, not dictation.
            holdKeyDown = false
            if holdSessionActive, !isLocked { cancel() }
        }
    }

    private func holdPressed() {
        let wasActive = isActive
        keyDown()
        if !wasActive, isActive { holdSessionActive = true }
    }

    private func holdReleased() {
        guard holdSessionActive else { return }
        keyUp()
    }

    // MARK: Key handling (shared by the hold key and the combo shortcut)

    private func keyDown() {
        if isLocked {
            finish()
            return
        }
        if isActive, let deadline = tapDeadline, Date.now < deadline {
            // Second tap inside the window → hands-free lock.
            isLocked = true
            tapDeadline = nil
            return
        }
        guard !isActive else { return }
        isActive = true
        pressStartedAt = .now
        tapDeadline = nil
        startMaxDurationTimer()
        onStartRecording()
    }

    private func keyUp() {
        guard isActive, !isLocked else { return }
        let held = Date.now.timeIntervalSince(pressStartedAt ?? .now)
        if held < tapWindow {
            // Might be the first half of a double-tap: keep recording briefly.
            let deadline = Date.now.addingTimeInterval(tapWindow)
            tapDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + tapWindow) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isActive, !self.isLocked, self.tapDeadline == deadline else { return }
                    self.finish()
                }
            }
        } else {
            finish()
        }
    }

    private func finish() {
        guard isActive else { return }
        reset()
        onStopAndTranscribe()
    }

    private func cancel() {
        guard isActive else { return }
        reset()
        onCancel()
    }

    private func reset() {
        isActive = false
        isLocked = false
        holdSessionActive = false
        tapDeadline = nil
        pressStartedAt = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    // MARK: Cancel triggers

    /// Returns true when the event should be consumed (Esc inside our windows).
    private func handleCancelKey(_ keyCode: UInt16) -> Bool {
        let escKeyCode: UInt16 = 53
        guard isActive else { return false }
        if keyCode == escKeyCode {
            cancel()
            return true
        }
        if holdSessionActive, !isLocked {
            cancel()  // hold-key shortcut (⌃C etc.) — let it pass through untouched
        }
        return false
    }

    private func handleCancelClick() {
        guard isActive, holdSessionActive, !isLocked else { return }
        cancel()  // e.g. Ctrl+click = right-click
    }

    // MARK: Runaway guard

    private func startMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.finish() }
        }
    }
}
