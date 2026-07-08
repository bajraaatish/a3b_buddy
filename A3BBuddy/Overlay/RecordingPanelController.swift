//
//  RecordingPanelController.swift
//  Whisper — Workstream B
//
//  Hosts PillView in a non-activating NSPanel so focus NEVER leaves the
//  target text field. Panel appears for recording/transcribing, vanishes
//  otherwise — no idle presence, ever.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class RecordingPanelController<Engine: DictationEngine> {
    private let engine: Engine
    private let controls: RecordingControls
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var lockCancellable: AnyCancellable?

    init(engine: Engine, controls: RecordingControls) {
        self.engine = engine
        self.controls = controls
        // objectWillChange fires pre-mutation; hop to the next runloop tick to read the new state.
        cancellable = engine.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sync() }
        }
        // Hands-free is also state-gated (see `currentLayout`), so a lock
        // toggle can change panel size/hit-testing even with no engine-state change.
        lockCancellable = controls.$isHandsFreeLocked.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sync() }
        }
    }

    /// Same `(engine.state, controls.isHandsFreeLocked)` collapse `PillView` uses
    /// for its own layout switch — single source of truth, so the panel's size
    /// and hit-testing can never drift from what's actually drawn.
    private var currentLayout: PillView<Engine>.Layout {
        PillView<Engine>.layout(state: engine.state, isHandsFreeLocked: controls.isHandsFreeLocked)
    }

    /// Only the hands-free ✕/✓ row is clickable; every other layout (including
    /// transcribing, even if the lock flag hasn't reset yet) stays click-through.
    private var acceptsMouseEvents: Bool {
        if case .recording(handsFree: true) = currentLayout { return true }
        return false
    }

    private func sync() {
        switch engine.state {
        case .recording, .transcribing:
            show()
        case .idle, .failed:
            hide()
        }
    }

    private func show() {
        let size = PillView<Engine>.size(for: currentLayout)
        let clickable = acceptsMouseEvents
        if panel == nil {
            panel = makePanel(size: size, clickable: clickable)
        }
        guard let panel else { return }
        if panel.isVisible {
            // Already on screen (e.g. hands-free toggling mid-recording) — grow/shrink in place.
            resize(panel, to: size)
        } else {
            // Coming from hidden — re-anchor on the current screen. Covers a
            // display change (e.g. external monitor unplugged) while the pill
            // was hidden, same as the original always-reposition-on-show behavior.
            placeCentered(panel, size: size)
        }
        panel.ignoresMouseEvents = !clickable
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless() // never makeKey — focus must stay in the target app
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(size: CGSize, clickable: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // PillView draws its own soft shadow
        panel.ignoresMouseEvents = !clickable
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PillView(engine: engine, controls: controls))
        placeCentered(panel, size: size)
        return panel
    }

    /// Grows/shrinks the panel for the hands-free ✕/✓ row while it's already
    /// visible, re-anchored on its current center — `PillView.panelSize` is
    /// the only place width is decided, so this never hand-rolls its own numbers.
    private func resize(_ panel: NSPanel, to size: CGSize) {
        guard panel.frame.size != size else { return }
        let frame = NSRect(
            x: panel.frame.midX - size.width / 2,
            y: panel.frame.minY,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true, animate: true)
    }

    /// Bottom-center of the screen with the keyboard focus, just above the Dock.
    private func placeCentered(_ panel: NSPanel, size: CGSize) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.minY + 16,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true, animate: false)
    }
}
