//
//  HotkeyEventSource.swift
//  Buddy — flexible hotkeys
//
//  The seam between `HotkeyStateMachine` (pure) and macOS input (not). Two real
//  sources, both feeding the same handler:
//
//    CGEventTapSource   one listen-only `.cgSessionEventTap`, the whole system.
//    LocalMonitorSource `NSEvent` monitors, Buddy's own windows only — and the
//                       only one that can *consume* an event, which is how Esc
//                       stops propagating once it has ended a recording.
//
//  TCC admits a listen-only keyboard tap on **either** Accessibility or Input
//  Monitoring, per process rather than per tap. `tapCreate` returning nil is the
//  only authoritative answer.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum HotkeyRawEvent: Equatable {
    case flags(NSEvent.ModifierFlags)
    case keyDown(UInt16)
    case mouseDown
}

enum HotkeyEventDisposition {
    case pass
    case consume
}

@MainActor
protocol HotkeyEventSource: AnyObject {
    var onEvent: ((HotkeyRawEvent) -> HotkeyEventDisposition)? { get set }
    /// `false` ⇒ TCC denied, or `tapCreate` returned nil. Idempotent.
    @discardableResult func enable() -> Bool
    func disable()
    /// The modifiers physically down right now. Used to resync after macOS
    /// disables the tap mid-hold, which silently eats the matching key-up.
    func currentFlags() -> NSEvent.ModifierFlags
}

/// Both sources map `CGEventFlags` / `NSEvent.ModifierFlags` through this, so
/// caps lock, the numeric-pad bit, the left/right device bits and
/// `.maskNonCoalesced` never reach the match table.
private func recognized(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
    var modifiers: NSEvent.ModifierFlags = []
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    if flags.contains(.maskCommand) { modifiers.insert(.command) }
    if flags.contains(.maskAlternate) { modifiers.insert(.option) }
    if flags.contains(.maskShift) { modifiers.insert(.shift) }
    if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
    return modifiers
}

// MARK: - CGEventTap

@MainActor
final class CGEventTapSource: HotkeyEventSource {
    var onEvent: ((HotkeyRawEvent) -> HotkeyEventDisposition)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isActive: Bool { eventTap != nil }

    @discardableResult
    func enable() -> Bool {
        guard eventTap == nil else { return true }

        if !Permissions.eventTapPermitted {
            // Shows the system prompt once; macOS only applies the grant after a
            // relaunch. Try anyway — `tapCreate` is the authority, not the check.
            Permissions.requestInputMonitoring()
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // The run-loop source is on CFRunLoopGetMain(), so this is the main thread.
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let source = Unmanaged<CGEventTapSource>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { source.handle(type: type, event: event) }
            // Listen-only: the disposition is not ours to honour.
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
            NSLog("Buddy: hotkey event tap unavailable — grant Input Monitoring, then relaunch.")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            NSLog("Buddy: hotkey event tap run-loop source unavailable.")
            return false
        }

        // `.commonModes`, not `.defaultMode`: the tap must keep firing while a menu
        // is tracking or a window is being live-resized.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func disable() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    func currentFlags() -> NSEvent.ModifierFlags {
        recognized(CGEventSource.flagsState(.combinedSessionState))
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS kills a tap that stalls the event stream, and again on the
            // user's "disable input events" panic key. Both are recoverable — but
            // events dropped while it was off may include the key-up that would
            // have ended a hold, so resync the modifier state on the way back.
            guard let eventTap else { return }
            CGEvent.tapEnable(tap: eventTap, enable: true)
            _ = onEvent?(.flags(currentFlags()))

        case .flagsChanged:
            _ = onEvent?(.flags(recognized(event.flags)))

        case .keyDown:
            _ = onEvent?(.keyDown(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))))

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            _ = onEvent?(.mouseDown)

        default:
            break
        }
    }
}

// MARK: - Local monitors

/// Keeps holds working inside Buddy's own windows with no permission at all, and
/// swallows Esc there so ending a recording doesn't also dismiss whatever is
/// behind the pill. When the tap is also running every event arrives twice; the
/// state machine treats the second as a duplicate and does nothing.
@MainActor
final class LocalMonitorSource: HotkeyEventSource {
    var onEvent: ((HotkeyRawEvent) -> HotkeyEventDisposition)?

    private var monitors: [Any] = []

    @discardableResult
    func enable() -> Bool {
        guard monitors.isEmpty else { return true }

        if let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let modifiers = event.modifierFlags
            MainActor.assumeIsolated { _ = self?.onEvent?(.flags(modifiers)) }
            return event
        }) {
            monitors.append(flags)
        }

        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            let disposition = MainActor.assumeIsolated { self?.onEvent?(.keyDown(keyCode)) ?? .pass }
            return disposition == .consume ? nil : event
        }) {
            monitors.append(keys)
        }

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let mouse = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.onEvent?(.mouseDown) }
            return event
        }) {
            monitors.append(mouse)
        }

        return true
    }

    func disable() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func currentFlags() -> NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection(HotkeyBinding.recognizedModifiers)
    }
}

// MARK: - Grace-window timer

protocol HotkeyCancellable: AnyObject {
    func cancel()
}

typealias HotkeySchedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> HotkeyCancellable

/// `DispatchQueue.main.asyncAfter`, never `Timer.scheduledTimer`: a `Timer` runs
/// in `.default` run-loop mode and stalls during menu tracking and live window
/// resize, while the tap's source is in `.commonModes`. A `Timer`-backed grace
/// window would simply never fire with a menu open.
@MainActor
func mainQueueSchedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> HotkeyCancellable {
    let item = DispatchWorkItem { MainActor.assumeIsolated(work) }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    return DispatchWorkItemCancellable(item)
}

final class DispatchWorkItemCancellable: HotkeyCancellable {
    private let item: DispatchWorkItem

    init(_ item: DispatchWorkItem) { self.item = item }

    /// A no-op once the item is already running. What actually keeps a superseded
    /// press dead is `HotkeyStateMachine.graceElapsed`, which fires only while the
    /// feature is still `.pending` on that exact binding.
    func cancel() { item.cancel() }
}
