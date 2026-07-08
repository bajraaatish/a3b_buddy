//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while a3b-buddy is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import KeyboardShortcuts

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private enum ActiveShortcutSource {
        case keyboardShortcut
        case modifierOnly
    }

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var defaultsObserver: NSObjectProtocol?
    private var isMonitoringEnabled = false
    private var activeShortcutSource: ActiveShortcutSource?
    private var cachedKeyboardShortcut: KeyboardShortcuts.Shortcut?
    private var cachedModifierOnlyShortcut = ModifierOnlyShortcut.controlOption

    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    init() {
        cacheConfiguredShortcuts()
        registerKeyboardShortcutHandlers()
        watchConfiguredShortcuts()
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        stop()
    }

    func start() {
        isMonitoringEnabled = true
        cacheConfiguredShortcuts()
        installModifierOnlyEventTapIfNeeded()
    }

    func stop() {
        isMonitoringEnabled = false
        releasePressedShortcutIfNeeded()
        removeModifierOnlyEventTap()
    }

    private func registerKeyboardShortcutHandlers() {
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            DispatchQueue.main.async {
                self?.handleKeyboardShortcutPressed()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            DispatchQueue.main.async {
                self?.handleKeyboardShortcutReleased()
            }
        }
    }

    private func watchConfiguredShortcuts() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfiguredShortcutsChanged()
        }
    }

    private func handleConfiguredShortcutsChanged() {
        let keyboardShortcut = currentKeyboardShortcut
        let modifierOnlyShortcut = currentModifierOnlyShortcut
        let didChange = keyboardShortcut != cachedKeyboardShortcut
            || modifierOnlyShortcut != cachedModifierOnlyShortcut

        guard didChange else { return }

        cachedKeyboardShortcut = keyboardShortcut
        cachedModifierOnlyShortcut = modifierOnlyShortcut

        releasePressedShortcutIfNeeded()

        guard isMonitoringEnabled else { return }

        if modifierOnlyShortcut == .off {
            removeModifierOnlyEventTap()
        } else {
            installModifierOnlyEventTapIfNeeded()
        }
    }

    private func cacheConfiguredShortcuts() {
        cachedKeyboardShortcut = currentKeyboardShortcut
        cachedModifierOnlyShortcut = currentModifierOnlyShortcut
    }

    private var currentKeyboardShortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: .pushToTalk)
    }

    private var currentModifierOnlyShortcut: ModifierOnlyShortcut {
        ModifierOnlyShortcut.current(for: PrefKey.pushToTalkModifierOnlyShortcut, default: .controlOption)
    }

    private func installModifierOnlyEventTapIfNeeded() {
        // If the event tap is already running, don't restart it. Restarting
        // resets isShortcutCurrentlyPressed, which would kill the waveform
        // overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard currentModifierOnlyShortcut != .off else {
            removeModifierOnlyEventTap()
            return
        }

        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    private func removeModifierOnlyEventTap() {
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isMonitoringEnabled else {
            return Unmanaged.passUnretained(event)
        }

        if eventType == .flagsChanged {
            handleModifierOnlyFlagsChanged(modifierFlags(from: event.flags))
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyboardShortcutPressed() {
        guard isMonitoringEnabled else { return }
        publishShortcutPressed(from: .keyboardShortcut)
    }

    private func handleKeyboardShortcutReleased() {
        guard isMonitoringEnabled else { return }
        publishShortcutReleased(from: .keyboardShortcut)
    }

    private func handleModifierOnlyFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags) {
        switch currentModifierOnlyShortcut.matchState(in: modifierFlags) {
        case .off, .released, .superset:
            publishShortcutReleased(from: .modifierOnly)
        case .exact:
            publishShortcutPressed(from: .modifierOnly)
        }
    }

    private func publishShortcutPressed(from source: ActiveShortcutSource) {
        guard activeShortcutSource == nil else { return }

        activeShortcutSource = source
        isShortcutCurrentlyPressed = true
        shortcutTransitionPublisher.send(.pressed)
    }

    private func publishShortcutReleased(from source: ActiveShortcutSource) {
        guard activeShortcutSource == source else { return }

        activeShortcutSource = nil
        isShortcutCurrentlyPressed = false
        shortcutTransitionPublisher.send(.released)
    }

    private func releasePressedShortcutIfNeeded() {
        guard activeShortcutSource != nil else {
            isShortcutCurrentlyPressed = false
            return
        }

        activeShortcutSource = nil
        isShortcutCurrentlyPressed = false
        shortcutTransitionPublisher.send(.released)
    }

    private func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }
}
