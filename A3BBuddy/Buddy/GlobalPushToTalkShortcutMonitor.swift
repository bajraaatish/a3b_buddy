//
//  GlobalPushToTalkShortcutMonitor.swift
//  a3b-buddy
//
//  The push-to-talk half of `HotkeyEngine`'s output. Whatever the user bound to
//  "Talk to Buddy" in Settings arrives here as `pressed` / `released` / `cancelled`
//  and leaves as the `ShortcutTransition` stream `CompanionManager` already reads.
//
//  `start()` / `stop()` are *delivery* gates, not tap lifecycles. `CompanionManager`
//  calls them from its 1.5-second Accessibility poller; under the old two-tap design
//  that tore an event tap down and rebuilt it on a loop, which is why this file used
//  to carry a "don't restart or you kill the waveform mid-press" hack. The tap now
//  belongs to `HotkeyEngine` and nothing here can touch it — so revoking
//  Accessibility stops push-to-talk while dictation keeps working.
//

import Combine
import Foundation

@MainActor
final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    private let engine: HotkeyEngine
    private var isEnabled = false
    private var cancellable: AnyCancellable?

    init(engine: HotkeyEngine = .shared) {
        self.engine = engine
        cancellable = engine.events
            .forFeature(.pushToTalk)
            .sink { [weak self] event in self?.handle(event) }
    }

    /// Idempotent — called every 1.5 s by `CompanionManager.refreshAllPermissions()`.
    /// Deliberately does not touch the event tap.
    func start() {
        isEnabled = true
    }

    func stop() {
        isEnabled = false
        // A hold in progress would never get its key-up delivered to us now.
        engine.releaseIfHeld(.pushToTalk, reason: .monitoringStopped)
        publishReleaseIfNeeded()
    }

    private func handle(_ event: HotkeyEvent) {
        guard isEnabled else { return }

        switch event {
        case .pressed:
            guard !isShortcutCurrentlyPressed else { return }
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)

        // `pushToTalk.supersetPolicy == .release`, so a stray ⇧ mid-utterance
        // arrives as `.released` and keeps what was captured. `.cancelled` reaches
        // us only from a rebind or a lost grant — end the utterance either way.
        case .released, .cancelled:
            publishReleaseIfNeeded()

        // Push-to-talk has no prewarm (its recorder starts async, behind provider
        // setup) and no Esc affordance — you are holding a key; letting go is it.
        case .armed, .disarmed, .escapePressed:
            break
        }
    }

    private func publishReleaseIfNeeded() {
        guard isShortcutCurrentlyPressed else { return }
        isShortcutCurrentlyPressed = false
        shortcutTransitionPublisher.send(.released)
    }
}
