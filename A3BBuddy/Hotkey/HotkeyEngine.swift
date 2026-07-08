//
//  HotkeyEngine.swift
//  Buddy — flexible hotkeys
//
//  One listen-only CGEventTap for the whole app, replacing the two that used to
//  race each other. Turns raw input into a `HotkeyEvent` stream that
//  `HotkeyManager` (dictation) and `GlobalPushToTalkShortcutMonitor` (talk to
//  Buddy) subscribe to. Neither adapter owns any input code any more.
//
//  Division of labour:
//
//    HotkeyStateMachine   what the events *mean*. Pure, exhaustively tested.
//    HotkeyEventSource    where they come from. CGEventTap + NSEvent monitors.
//    HotkeyEngine         this file. Timers, Carbon registration, the store
//                         subscription, and the tap's lifecycle.
//
//  Everything the engine does differently per feature is read from
//  `HotkeyFeature` — `supersetPolicy`, `cancelsOnOtherKeyDown`, `cancelsOnMouseDown`,
//  `cancelsOnEscape`. Nothing here branches on `.dictation` vs `.pushToTalk`.
//
//  ## Permissions
//
//  TCC admits a listen-only tap on **either** Accessibility or Input Monitoring,
//  per process. So the tap belongs to the engine and to nothing else: it is created
//  when some binding is a bare-modifier hold, and destroyed when none is. Whether a
//  *feature* is currently listening — push-to-talk needs Accessibility for the
//  cursor overlay — is the adapter's business, not the tap's. That distinction is
//  why `CompanionManager`'s 1.5-second Accessibility poller can no longer rip the
//  tap out from under dictation on a loop.
//

import AppKit
import Combine
import KeyboardShortcuts

@MainActor
final class HotkeyEngine {
    static let shared = HotkeyEngine(store: .shared)

    /// How long a hold that is a strict prefix of another hold waits before it
    /// commits. Dormant with the shipped ⌃⇧ / ⌃⌥ defaults — disjoint sets, neither
    /// a prefix of the other — but `HotkeyConflictChecker` only *warns* about
    /// prefix-overlapping holds, so a user can deliberately create one.
    static let graceInterval: TimeInterval = 0.2

    /// `PassthroughSubject` drops anything sent before a subscriber exists, which
    /// is exactly why `start()` must run after both adapters have subscribed.
    let events = PassthroughSubject<HotkeyEvent, Never>()

    /// False when no hold is bound (combo-only setups need no permission at all)
    /// or when the grant is missing. Settings shows its CTA off this.
    @Published private(set) var isEventTapActive = false

    private let tapSource: HotkeyEventSource
    private let localSource: HotkeyEventSource?
    private let graceInterval: TimeInterval
    private let schedule: HotkeySchedule

    private var machine: HotkeyStateMachine
    private var graceTimers: [HotkeyFeature: HotkeyCancellable] = [:]
    private var storeSubscription: AnyCancellable?

    private var isRunning = false
    private var isSuspended = false
    private var didRegisterCombos = false

    // MARK: Init

    /// The real graph. Not default arguments: a default argument is evaluated in
    /// the *caller's* isolation, and `CGEventTapSource()` is `@MainActor`.
    convenience init(store: HotkeyBindingStore) {
        self.init(
            store: store,
            tapSource: CGEventTapSource(),
            localSource: LocalMonitorSource(),
            graceInterval: Self.graceInterval,
            schedule: mainQueueSchedule
        )
    }

    init(
        store: HotkeyBindingStore,
        tapSource: HotkeyEventSource,
        localSource: HotkeyEventSource?,
        graceInterval: TimeInterval,
        schedule: @escaping HotkeySchedule
    ) {
        self.tapSource = tapSource
        self.localSource = localSource
        self.graceInterval = graceInterval
        self.schedule = schedule
        machine = HotkeyStateMachine(table: HotkeyMatchTable(bindings: store.bindings))

        tapSource.onEvent = { [weak self] event in self?.handle(event) ?? .pass }
        localSource?.onEvent = { [weak self] event in self?.handle(event) ?? .pass }

        // `@Published` delivers on `willSet`, so the store's own property is still
        // the old value here — use the value it hands us.
        storeSubscription = store.$bindings
            .dropFirst()
            .sink { [weak self] newBindings in self?.applyBindings(newBindings) }
    }

    // MARK: Lifecycle

    /// Idempotent. Call from `applicationDidFinishLaunching`, **after** both
    /// adapters exist — see `events`.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        registerComboHandlersIfNeeded()
        localSource?.enable()
        refreshEventTap()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        emit(machine.terminateAll(reason: .monitoringStopped))
        localSource?.disable()
        tapSource.disable()
        isEventTapActive = false
    }

    /// Stops matching without touching the tap, and unregisters the Carbon combos,
    /// so the Settings hotkey recorder can capture ⌘⇧D — or a bare ⌃⇧ — instead of
    /// firing whatever currently owns it. Recreating the tap on every recorder
    /// focus change is how a tap starts looking flaky; don't.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        KeyboardShortcuts.disable(HotkeyFeature.allCases.flatMap(\.comboShortcutNames))
        emit(machine.terminateAll(reason: .monitoringStopped))
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        KeyboardShortcuts.enable(HotkeyFeature.allCases.flatMap(\.comboShortcutNames))
    }

    // MARK: Queries the adapters need

    func isHeld(_ feature: HotkeyFeature) -> Bool {
        machine.isHeld(feature)
    }

    /// Ends `feature`'s session without waiting for a key-up that may never come —
    /// push-to-talk losing Accessibility, mid-hold.
    func releaseIfHeld(_ feature: HotkeyFeature, reason: HotkeyCancelReason) {
        emit(machine.releaseIfHeld(feature, reason: reason))
    }

    /// Mirrors `HotkeyManager.isActive`. Only while a session is live does Esc get
    /// swallowed inside Buddy's own windows instead of reaching the responder chain.
    func setEscapeCancelsActiveSession(_ isActive: Bool, for feature: HotkeyFeature) {
        machine.setEscapeCancelsActiveSession(isActive, for: feature)
    }

    // MARK: Raw input → state machine

    private func handle(_ raw: HotkeyRawEvent) -> HotkeyEventDisposition {
        guard isRunning, !isSuspended else { return .pass }

        let outcome: HotkeyStateMachine.Outcome
        switch raw {
        case .flags(let modifiers): outcome = machine.flagsChanged(modifiers)
        case .keyDown(let keyCode): outcome = machine.keyDown(keyCode)
        case .mouseDown: outcome = machine.mouseDown()
        }

        emit(outcome)
        return outcome.consumesEvent ? .consume : .pass
    }

    /// Cancel timers first, then dispatch, then arm new ones: an adapter reacting
    /// to `.disarmed` must not be racing a deadline that is about to `.pressed`.
    private func emit(_ outcome: HotkeyStateMachine.Outcome) {
        for feature in outcome.cancelGrace {
            graceTimers.removeValue(forKey: feature)?.cancel()
        }

        for event in outcome.events {
            events.send(event)
        }

        for request in outcome.scheduleGrace {
            graceTimers[request.feature]?.cancel()
            graceTimers[request.feature] = schedule(graceInterval) { [weak self] in
                self?.graceElapsed(request.feature, request.binding)
            }
        }
    }

    private func graceElapsed(_ feature: HotkeyFeature, _ binding: HotkeyBinding) {
        graceTimers.removeValue(forKey: feature)
        guard isRunning, !isSuspended else { return }
        emit(machine.graceElapsed(feature, binding))
    }

    // MARK: Bindings

    private func applyBindings(_ bindings: [HotkeyFeature: [HotkeyBinding]]) {
        emit(machine.setTable(HotkeyMatchTable(bindings: bindings)))
        refreshEventTap()
    }

    /// The tap exists exactly when some binding is a bare-modifier hold. `enable()`
    /// is idempotent, so a rebind that keeps at least one hold never touches it.
    private func refreshEventTap() {
        guard isRunning else { return }
        if machine.table.needsEventTap {
            isEventTapActive = tapSource.enable()
        } else {
            tapSource.disable()
            isEventTapActive = false
        }
    }

    // MARK: Carbon combos

    /// `KeyboardShortcuts`' handler list is append-only — a handler can never be
    /// removed — so this registers exactly once, and the engine is the app's sole
    /// registrar. A duplicate registration anywhere would double-fire `keyDown()`.
    private func registerComboHandlersIfNeeded() {
        guard !didRegisterCombos else { return }
        didRegisterCombos = true

        for feature in HotkeyFeature.allCases {
            for (slot, name) in feature.comboShortcutNames.enumerated() {
                KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                    self?.handleCombo(feature, slot: slot, isDown: true)
                }
                KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                    self?.handleCombo(feature, slot: slot, isDown: false)
                }
            }
        }
    }

    private func handleCombo(_ feature: HotkeyFeature, slot: Int, isDown: Bool) {
        guard isRunning, !isSuspended else { return }
        emit(isDown
            ? machine.comboKeyDown(feature, slot: slot)
            : machine.comboKeyUp(feature, slot: slot))
    }
}

// MARK: - Convenience

extension Publisher where Output == HotkeyEvent, Failure == Never {
    /// `engine.events.forFeature(.dictation)`
    func forFeature(_ feature: HotkeyFeature) -> AnyPublisher<HotkeyEvent, Never> {
        filter { $0.feature == feature }.eraseToAnyPublisher()
    }
}
