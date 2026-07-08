//
//  HotkeyManager.swift
//  Buddy — dictation trigger
//
//  The dictation half of `HotkeyEngine`'s output, and nothing else. Whatever the
//  user bound to Dictation in Settings — a bare ⌃⇧ hold, ⌘⇧D, `fn` — arrives here
//  as `armed` / `pressed` / `released` / `cancelled`. This file owns only what
//  happens next:
//
//    armed                     → warm the microphone. No pill, no cue, no state change.
//    press, release            → record, then transcribe
//    press, release, press     → hands-free lock (both taps inside `tapWindow`)
//    press while locked        → stop and transcribe
//    cancelled                 → discard, unless locked
//    Esc                       → discard, locked or not
//    5 minutes                 → stop and transcribe
//
//  `cancelled` is how ⌃C reaches the app underneath untouched: the engine sees the
//  hold grow into a superset, or another key go down mid-hold, and says so. A
//  *locked* session ignores it — you can Cmd+Tab between fields while dictating
//  hands-free — so only Esc and the pill's ✕/✓ end one.
//

import AppKit
import Combine

@MainActor
final class HotkeyManager {
    var onStartRecording: () -> Void = {}
    var onStopAndTranscribe: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Fired when hands-free lock engages/disengages, so the recording pill can
    /// show its ✕/✓ buttons and its panel can accept mouse events while locked.
    var onLockChange: (Bool) -> Void = { _ in }

    /// Fired the instant a dictation trigger goes down, before the engine has
    /// decided whether it is a press or the prefix of a chord. Warm the mic; show
    /// nothing. `onDisarm` undoes it when the chord wins.
    var onArm: () -> Void = {}
    var onDisarm: () -> Void = {}

    /// A press shorter than this is a "tap"; a second tap within the same
    /// window locks hands-free recording.
    private let tapWindow: TimeInterval = 0.35
    private let maxDuration: TimeInterval = 5 * 60

    /// Mirrored into the engine so Esc is swallowed inside Buddy's own windows
    /// exactly while there is a session for it to end.
    private var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            engine.setEscapeCancelsActiveSession(isActive, for: .dictation)
        }
    }
    private var isLocked = false {
        didSet {
            if isLocked != oldValue { onLockChange(isLocked) }
        }
    }
    private var pressStartedAt: Date?
    private var tapDeadline: Date?
    /// `DispatchWorkItem`, not `Timer`: a `Timer` runs in `.default` run-loop mode
    /// and would silently never fire with a menu open or a window being resized.
    private var maxDurationTimer: DispatchWorkItem?

    private let engine: HotkeyEngine
    private var cancellables = Set<AnyCancellable>()

    init(engine: HotkeyEngine = .shared) {
        self.engine = engine
        engine.events
            .forFeature(.dictation)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // MARK: Engine → state machine

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .armed:
            onArm()
        case .disarmed:
            onDisarm()
        case .pressed:
            keyDown()
        case .released:
            keyUp()
        case .cancelled:
            // A locked hands-free session ignores superset / other-key / mouse-down.
            guard !isLocked else { return }
            cancel()
        case .escapePressed:
            // Honoured even when locked. The one cancel that outranks the lock.
            cancel()
        }
    }

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

    // MARK: Hands-free pill buttons

    /// ✕ in the hands-free pill — discard the in-progress recording.
    func cancelFromButton() {
        cancel()
    }

    /// ✓ in the hands-free pill — stop recording and transcribe.
    func confirmFromButton() {
        finish()
    }

    private func reset() {
        isActive = false
        isLocked = false
        tapDeadline = nil
        pressStartedAt = nil
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
    }

    // MARK: Runaway guard

    private func startMaxDurationTimer() {
        maxDurationTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        maxDurationTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration, execute: timer)
    }
}
