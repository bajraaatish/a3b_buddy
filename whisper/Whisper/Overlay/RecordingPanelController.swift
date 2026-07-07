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
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    init(engine: Engine) {
        self.engine = engine
        // objectWillChange fires pre-mutation; hop to the next runloop tick to read the new state.
        cancellable = engine.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sync() }
        }
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
        if panel == nil {
            panel = makePanel()
        }
        guard let panel, !panel.isVisible else { return }
        position(panel)
        panel.orderFrontRegardless() // never makeKey — focus must stay in the target app
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
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
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PillView(engine: engine))
        return panel
    }

    /// Bottom-center of the screen with the keyboard focus, just above the Dock.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 16
        ))
    }
}
