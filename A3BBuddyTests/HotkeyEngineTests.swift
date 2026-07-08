//
//  HotkeyEngineTests.swift
//  A3BBuddyTests — flexible hotkeys
//
//  The shell around `HotkeyStateMachine`: tap lifecycle, live rebind, the grace
//  deadline, Esc consumption. A `FakeEventSource` stands in for the CGEventTap and
//  a `ManualScheduler` for `DispatchQueue.main.asyncAfter`, so nothing here needs
//  a TCC grant, an event tap, an app launch, or `Task.sleep`.
//
//  `NullCarbonRegistrar` keeps the store from registering live system-wide hotkeys
//  and clobbering the developer's real `KeyboardShortcuts_*` defaults —
//  `KeyboardShortcuts.setShortcut` hardcodes `UserDefaults.standard`.
//

import AppKit
import Carbon.HIToolbox
import Combine
import Testing
@testable import A3BBuddy

// MARK: - Doubles

@MainActor
private final class FakeEventSource: HotkeyEventSource {
    var onEvent: ((HotkeyRawEvent) -> HotkeyEventDisposition)?

    private(set) var enableCount = 0
    private(set) var disableCount = 0
    private(set) var isEnabled = false
    var resyncFlags: NSEvent.ModifierFlags = []

    func enable() -> Bool {
        enableCount += 1
        isEnabled = true
        return true
    }

    func disable() {
        if isEnabled { disableCount += 1 }
        isEnabled = false
    }

    func currentFlags() -> NSEvent.ModifierFlags { resyncFlags }

    @discardableResult
    func send(_ event: HotkeyRawEvent) -> HotkeyEventDisposition {
        onEvent?(event) ?? .pass
    }
}

/// The tap never comes up — no Input Monitoring, no Accessibility.
@MainActor
private final class DeniedEventSource: HotkeyEventSource {
    var onEvent: ((HotkeyRawEvent) -> HotkeyEventDisposition)?
    func enable() -> Bool { false }
    func disable() {}
    func currentFlags() -> NSEvent.ModifierFlags { [] }
}

/// Stands in for `DispatchQueue.main.asyncAfter`. The grace deadline becomes a
/// method call, so no test ever sleeps.
@MainActor
private final class ManualScheduler {
    private struct Pending {
        let id: Int
        let work: @MainActor () -> Void
    }

    private var pending: [Pending] = []
    private var nextID = 0

    private(set) var scheduleCount = 0
    var pendingCount: Int { pending.count }

    func makeSchedule() -> HotkeySchedule {
        { [weak self] _, work in
            guard let self else { return NoopCancellable() }
            self.scheduleCount += 1
            let id = self.nextID
            self.nextID += 1
            self.pending.append(Pending(id: id, work: work))
            return ManualToken(id: id, scheduler: self)
        }
    }

    /// Fires every outstanding deadline, exactly as if 200 ms had elapsed.
    func fireAll() {
        let due = pending
        pending.removeAll()
        for item in due { item.work() }
    }

    fileprivate func cancel(id: Int) {
        pending.removeAll { $0.id == id }
    }
}

private final class ManualToken: HotkeyCancellable {
    private let id: Int
    private weak var scheduler: ManualScheduler?

    init(id: Int, scheduler: ManualScheduler) {
        self.id = id
        self.scheduler = scheduler
    }

    func cancel() {
        let id = self.id
        let scheduler = self.scheduler
        MainActor.assumeIsolated { scheduler?.cancel(id: id) }
    }
}

private final class NoopCancellable: HotkeyCancellable {
    func cancel() {}
}

// MARK: - Fixtures

private let ctrl = HotkeyBinding.modifiersOnly(.control)
private let ctrlOption = HotkeyBinding.modifiersOnly([.control, .option])
private let ctrlShift = HotkeyBinding.modifiersOnly([.control, .shift])
private let optionShift = HotkeyBinding.modifiersOnly([.option, .shift])
private let cmdShiftD = HotkeyBinding.keyCombo(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift])

private let escape = UInt16(kVK_Escape)
private let keyC = UInt16(kVK_ANSI_C)

@MainActor
private struct Harness {
    let store: HotkeyBindingStore
    let tap: FakeEventSource
    let scheduler: ManualScheduler
    let engine: HotkeyEngine
    let recorder: EventRecorder

    /// A scratch defaults domain, so nothing here touches the real app's bindings.
    init(
        label: String,
        dictation: [HotkeyBinding] = [ctrlShift],
        pushToTalk: [HotkeyBinding] = [ctrlOption],
        // Not `= FakeEventSource()`: a default argument is evaluated in the
        // caller's isolation, and `HotkeyEventSource` is `@MainActor`.
        tap injectedTap: FakeEventSource? = nil
    ) {
        let tap = injectedTap ?? FakeEventSource()
        let suite = "HotkeyEngineTests.\(label)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        HotkeyBindingStore.write(dictation, to: PrefKey.dictationBinding, in: defaults)
        HotkeyBindingStore.write(pushToTalk, to: PrefKey.pushToTalkBinding, in: defaults)

        store = HotkeyBindingStore(defaults: defaults, carbon: NullCarbonRegistrar(), runningMigration: false)
        self.tap = tap
        scheduler = ManualScheduler()
        engine = HotkeyEngine(
            store: store,
            tapSource: tap,
            localSource: nil,
            graceInterval: HotkeyEngine.graceInterval,
            schedule: scheduler.makeSchedule()
        )
        recorder = EventRecorder(engine)
    }
}

@MainActor
private final class EventRecorder {
    private(set) var events: [HotkeyEvent] = []
    private var cancellable: AnyCancellable?

    init(_ engine: HotkeyEngine) {
        cancellable = engine.events.sink { [weak self] in self?.events.append($0) }
    }

    func drain() -> [HotkeyEvent] {
        defer { events.removeAll() }
        return events
    }
}

// MARK: - Tap lifecycle

@Suite @MainActor struct HotkeyEngineTapLifecycleTests {
    @Test func nothingIsDeliveredBeforeStart() {
        let h = Harness(label: #function)
        h.tap.send(.flags([.control, .shift]))
        #expect(h.recorder.drain().isEmpty)
        #expect(h.tap.enableCount == 0)
    }

    @Test func startCreatesTheTapExactlyOnce() {
        let h = Harness(label: #function)
        h.engine.start()
        h.engine.start()
        #expect(h.tap.enableCount == 1)
        #expect(h.engine.isEventTapActive)
    }

    /// A combo-only setup needs no permission at all, so it must not create a tap
    /// — and must not trigger the Input Monitoring prompt.
    @Test func comboOnlyBindingsNeverCreateATap() {
        let h = Harness(label: #function, dictation: [cmdShiftD], pushToTalk: [])
        h.engine.start()
        #expect(h.tap.enableCount == 0)
        #expect(!h.engine.isEventTapActive)
    }

    @Test func clearingEveryHoldDestroysTheTapAndRestoringOneRebuildsIt() {
        let h = Harness(label: #function)
        h.engine.start()
        #expect(h.engine.isEventTapActive)

        h.store.setBindings([cmdShiftD], for: .dictation)
        h.store.setBindings([], for: .pushToTalk)
        #expect(!h.engine.isEventTapActive)
        #expect(h.tap.disableCount == 1)

        h.store.setBindings([ctrlShift], for: .dictation)
        #expect(h.engine.isEventTapActive)
        #expect(h.tap.enableCount == 2)   // no relaunch
    }

    @Test func aRebindThatKeepsAHoldNeverTouchesTheTap() {
        let h = Harness(label: #function)
        h.engine.start()
        h.store.setBindings([optionShift], for: .dictation)
        #expect(h.tap.enableCount == 1)
        #expect(h.tap.disableCount == 0)
    }

    @Test func aDeniedTapLeavesIsEventTapActiveFalse() {
        let h = Harness(label: #function, tap: FakeEventSource())
        let denied = DeniedEventSource()
        let engine = HotkeyEngine(
            store: h.store,
            tapSource: denied,
            localSource: nil,
            graceInterval: HotkeyEngine.graceInterval,
            schedule: h.scheduler.makeSchedule()
        )
        engine.start()
        #expect(!engine.isEventTapActive)
    }

    @Test func stopTearsDownAndTerminatesLiveSessions() {
        let h = Harness(label: #function)
        h.engine.start()
        h.tap.send(.flags([.control, .shift]))
        _ = h.recorder.drain()

        h.engine.stop()
        #expect(h.recorder.drain() == [.cancelled(.dictation, .monitoringStopped)])
        #expect(h.tap.disableCount == 1)
        #expect(!h.engine.isEventTapActive)

        // And the source is deaf afterwards.
        h.tap.send(.flags([.control, .shift]))
        #expect(h.recorder.drain().isEmpty)
    }
}

// MARK: - Matching through the engine

@Suite @MainActor struct HotkeyEngineMatchingTests {
    @Test func holdPressesAndReleases() {
        let h = Harness(label: #function)
        h.engine.start()

        h.tap.send(.flags([.control, .shift]))
        #expect(h.recorder.drain() == [.armed(.dictation), .pressed(.dictation, .modifierHold)])
        #expect(h.engine.isHeld(.dictation))

        h.tap.send(.flags([]))
        #expect(h.recorder.drain() == [.released(.dictation)])
        #expect(!h.engine.isHeld(.dictation))
    }

    @Test func typingAParagraphOfCapitalsRecordsNothing() {
        let h = Harness(label: #function)
        h.engine.start()
        for _ in 0 ..< 20 {
            h.tap.send(.flags([.shift]))
            h.tap.send(.keyDown(UInt16(kVK_ANSI_H)))
            h.tap.send(.flags([]))
        }
        #expect(h.recorder.drain().isEmpty)
    }

    @Test func controlCReachesTheAppUnderneath() {
        let h = Harness(label: #function)
        h.engine.start()
        h.tap.send(.flags([.control]))                 // ⌃ alone is nobody's binding
        #expect(h.tap.send(.keyDown(keyC)) == .pass)
        #expect(h.recorder.drain().isEmpty)
    }

    @Test func mouseDownCancelsDictationButNotPushToTalk() {
        let h = Harness(label: #function)
        h.engine.start()

        h.tap.send(.flags([.control, .option]))
        _ = h.recorder.drain()
        h.tap.send(.mouseDown)
        #expect(h.recorder.drain().isEmpty)
        #expect(h.engine.isHeld(.pushToTalk))
    }
}

// MARK: - Grace window

@Suite @MainActor struct HotkeyEngineGraceTests {
    @Test func ambiguousHoldWaitsForTheDeadline() {
        let h = Harness(label: #function, dictation: [ctrl])
        h.engine.start()

        h.tap.send(.flags([.control]))
        #expect(h.recorder.drain() == [.armed(.dictation)])
        #expect(h.scheduler.pendingCount == 1)

        h.scheduler.fireAll()
        #expect(h.recorder.drain() == [.pressed(.dictation, .modifierHold)])
    }

    @Test func aSupersetCancelsTheDeadlineBeforeItFires() {
        let h = Harness(label: #function, dictation: [ctrl])
        h.engine.start()

        h.tap.send(.flags([.control]))
        h.tap.send(.flags([.control, .option]))
        #expect(h.recorder.drain() == [
            .armed(.dictation),
            .disarmed(.dictation),
            .armed(.pushToTalk),
            .pressed(.pushToTalk, .modifierHold),
        ])
        #expect(h.scheduler.pendingCount == 0)

        h.scheduler.fireAll()   // nothing left to resurrect
        #expect(h.recorder.drain().isEmpty)
    }

    @Test func flushOnReleaseKeepsDoubleTapLockReachable() {
        let h = Harness(label: #function, dictation: [ctrl])
        h.engine.start()

        h.tap.send(.flags([.control]))
        h.tap.send(.flags([]))                 // released well inside the grace window
        #expect(h.recorder.drain() == [
            .armed(.dictation),
            .pressed(.dictation, .modifierHold),
            .released(.dictation),
        ])
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func rebindingCancelsAPendingDeadline() {
        let h = Harness(label: #function, dictation: [ctrl])
        h.engine.start()
        h.tap.send(.flags([.control]))
        _ = h.recorder.drain()

        h.store.setBindings([ctrlShift], for: .dictation)
        #expect(h.recorder.drain() == [.disarmed(.dictation)])
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func suspendKillsAPendingDeadlineWithoutDroppingTheTap() {
        let h = Harness(label: #function, dictation: [ctrl])
        h.engine.start()
        h.tap.send(.flags([.control]))
        _ = h.recorder.drain()

        h.engine.suspend()
        #expect(h.recorder.drain() == [.disarmed(.dictation)])
        #expect(h.tap.disableCount == 0)      // recreating the tap is how it goes flaky

        h.tap.send(.flags([.control]))        // the recorder is capturing; stay deaf
        #expect(h.recorder.drain().isEmpty)

        h.engine.resume()
        h.tap.send(.flags([.control]))
        #expect(h.recorder.drain() == [.armed(.dictation)])
    }
}

// MARK: - Live rebind

@Suite @MainActor struct HotkeyEngineRebindTests {
    @Test func rebindingIsLiveWithNoRestart() {
        let h = Harness(label: #function)
        h.engine.start()

        h.store.setBindings([optionShift], for: .dictation)
        _ = h.recorder.drain()

        h.tap.send(.flags([.control, .shift]))
        #expect(h.recorder.drain().isEmpty)

        h.tap.send(.flags([.option, .shift]))
        #expect(h.recorder.drain() == [.armed(.dictation), .pressed(.dictation, .modifierHold)])
    }

    /// Risk 6. Rebinding mid-hold must end the session, or the release no longer
    /// matches anything and the recorder runs to its 5-minute cap.
    @Test func rebindingWhileHeldCancelsCleanly() {
        let h = Harness(label: #function)
        h.engine.start()
        h.tap.send(.flags([.control, .shift]))
        _ = h.recorder.drain()

        h.store.setBindings([optionShift], for: .dictation)
        #expect(h.recorder.drain() == [.cancelled(.dictation, .bindingsChanged)])
        #expect(!h.engine.isHeld(.dictation))

        h.tap.send(.flags([]))   // the stale release goes nowhere
        #expect(h.recorder.drain().isEmpty)
    }
}

// MARK: - Escape

@Suite @MainActor struct HotkeyEngineEscapeTests {
    /// A listen-only tap can never consume; only `LocalMonitorSource` honours this.
    /// Inside Buddy's own windows Esc must stop at the recording it just ended.
    @Test func escapeIsConsumedOnlyWhileASessionIsActive() {
        let h = Harness(label: #function)
        h.engine.start()

        #expect(h.tap.send(.keyDown(escape)) == .pass)

        h.engine.setEscapeCancelsActiveSession(true, for: .dictation)
        #expect(h.tap.send(.keyDown(escape)) == .consume)

        h.engine.setEscapeCancelsActiveSession(false, for: .dictation)
        #expect(h.tap.send(.keyDown(escape)) == .pass)
    }

    @Test func escapeReachesAHandsFreeSessionThatHoldsNoModifier() {
        let h = Harness(label: #function)
        h.engine.start()
        h.engine.setEscapeCancelsActiveSession(true, for: .dictation)
        _ = h.recorder.drain()

        // No modifiers down: the machine's phase is `.idle` and yet Esc must land.
        h.tap.send(.keyDown(escape))
        #expect(h.recorder.drain() == [.escapePressed(.dictation)])
    }
}

// MARK: - Push-to-talk gating

@Suite @MainActor struct PushToTalkMonitorTests {
    @Test func monitorIsDeafUntilStarted() {
        let h = Harness(label: #function)
        let monitor = GlobalPushToTalkShortcutMonitor(engine: h.engine)
        var transitions: [BuddyPushToTalkShortcut.ShortcutTransition] = []
        let cancellable = monitor.shortcutTransitionPublisher.sink { transitions.append($0) }
        defer { cancellable.cancel() }

        h.engine.start()
        h.tap.send(.flags([.control, .option]))
        #expect(transitions.isEmpty)
        #expect(!monitor.isShortcutCurrentlyPressed)

        h.tap.send(.flags([]))
        monitor.start()
        h.tap.send(.flags([.control, .option]))
        #expect(transitions == [.pressed])
        #expect(monitor.isShortcutCurrentlyPressed)

        h.tap.send(.flags([]))
        #expect(transitions == [.pressed, .released])
    }

    /// The whole point of the unification: `CompanionManager`'s 1.5 s Accessibility
    /// poller calls `start()` on every tick. It must not disturb a live press, and
    /// it must never touch dictation's tap.
    @Test func repeatedStartDoesNotInterruptALivePress() {
        let h = Harness(label: #function)
        let monitor = GlobalPushToTalkShortcutMonitor(engine: h.engine)
        var transitions: [BuddyPushToTalkShortcut.ShortcutTransition] = []
        let cancellable = monitor.shortcutTransitionPublisher.sink { transitions.append($0) }
        defer { cancellable.cancel() }

        h.engine.start()
        monitor.start()
        h.tap.send(.flags([.control, .option]))

        for _ in 0 ..< 5 { monitor.start() }

        #expect(transitions == [.pressed])
        #expect(monitor.isShortcutCurrentlyPressed)
        #expect(h.tap.disableCount == 0)
        #expect(h.engine.isEventTapActive)
    }

    /// Revoking Accessibility stops push-to-talk. Dictation keeps working — the tap
    /// survives on Input Monitoring. This is the one thing the two-tap split gave
    /// away for free, and the one thing easiest to lose in the merge.
    @Test func stoppingPushToTalkLeavesDictationRecording() {
        let h = Harness(label: #function)
        let monitor = GlobalPushToTalkShortcutMonitor(engine: h.engine)
        var transitions: [BuddyPushToTalkShortcut.ShortcutTransition] = []
        let cancellable = monitor.shortcutTransitionPublisher.sink { transitions.append($0) }
        defer { cancellable.cancel() }

        h.engine.start()
        monitor.start()
        h.tap.send(.flags([.control, .option]))
        #expect(transitions == [.pressed])

        monitor.stop()
        #expect(transitions == [.pressed, .released])
        #expect(!monitor.isShortcutCurrentlyPressed)
        #expect(h.engine.isEventTapActive)

        _ = h.recorder.drain()
        h.tap.send(.flags([]))
        h.tap.send(.flags([.control, .shift]))
        #expect(h.recorder.drain() == [.armed(.dictation), .pressed(.dictation, .modifierHold)])
    }

    @Test func stopIsIdempotentAndPublishesNothingWhenNothingIsHeld() {
        let h = Harness(label: #function)
        let monitor = GlobalPushToTalkShortcutMonitor(engine: h.engine)
        var transitions: [BuddyPushToTalkShortcut.ShortcutTransition] = []
        let cancellable = monitor.shortcutTransitionPublisher.sink { transitions.append($0) }
        defer { cancellable.cancel() }

        h.engine.start()
        monitor.start()
        monitor.stop()
        monitor.stop()
        #expect(transitions.isEmpty)
    }
}
