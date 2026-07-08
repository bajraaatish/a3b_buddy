//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
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

    private enum ShortcutSource {
        case keyboardShortcutsRecorder
        case modifierOnlyEventTap
    }

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var shortcutDefaultsObserver: NSObjectProtocol?
    private var activeShortcutSource: ShortcutSource?
    private var isMonitoring = false
    private var observedKeyboardShortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk)
    private var observedModifierOnlyShortcut = ModifierOnlyShortcut.current(
        for: PrefKey.pushToTalkModifierOnlyShortcut,
        default: .controlOption
    )
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    init() {
        installKeyboardShortcutsHandlers()
        watchShortcutDefaults()
    }

    deinit {
        stop()
        if let shortcutDefaultsObserver {
            NotificationCenter.default.removeObserver(shortcutDefaultsObserver)
        }
    }

    func start() {
        isMonitoring = true

        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
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

    func stop() {
        isMonitoring = false
        isShortcutCurrentlyPressed = false
        activeShortcutSource = nil

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func installKeyboardShortcutsHandlers() {
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            DispatchQueue.main.async {
                self?.handleKeyboardShortcutTransition(.pressed)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            DispatchQueue.main.async {
                self?.handleKeyboardShortcutTransition(.released)
            }
        }
    }

    private func watchShortcutDefaults() {
        shortcutDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            let keyboardShortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk)
            let modifierOnlyShortcut = ModifierOnlyShortcut.current(
                for: PrefKey.pushToTalkModifierOnlyShortcut,
                default: .controlOption
            )
            let shortcutChanged = keyboardShortcut != self.observedKeyboardShortcut
                || modifierOnlyShortcut != self.observedModifierOnlyShortcut

            guard shortcutChanged else { return }

            if let activeShortcutSource = self.activeShortcutSource {
                self.publish(.released, source: activeShortcutSource)
            }

            self.observedKeyboardShortcut = keyboardShortcut
            self.observedModifierOnlyShortcut = modifierOnlyShortcut

            if self.isMonitoring, self.globalEventTap == nil {
                self.start()
            }
        }
    }

    private func handleKeyboardShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        guard isMonitoring else { return }

        publish(transition, source: .keyboardShortcutsRecorder)
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

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: activeShortcutSource == .modifierOnlyEventTap && isShortcutCurrentlyPressed
        )

        publish(shortcutTransition, source: .modifierOnlyEventTap)

        return Unmanaged.passUnretained(event)
    }

    private func publish(
        _ shortcutTransition: BuddyPushToTalkShortcut.ShortcutTransition,
        source: ShortcutSource
    ) {
        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            guard !isShortcutCurrentlyPressed else { return }
            activeShortcutSource = source
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            guard isShortcutCurrentlyPressed, activeShortcutSource == source else { return }
            activeShortcutSource = nil
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }
    }
}
