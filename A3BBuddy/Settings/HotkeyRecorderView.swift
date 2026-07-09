//
//  HotkeyRecorderView.swift
//  Buddy - flexible hotkeys
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorderFeedback: Equatable {
    enum Severity: Equatable {
        case warning
        case blocking
    }

    let message: String
    let severity: Severity

    init?(_ conflict: HotkeyConflict) {
        guard let message = conflict.message else { return nil }
        self.message = message
        self.severity = conflict.isBlocking ? .blocking : .warning
    }
}

@MainActor
struct HotkeyRecorderView: NSViewRepresentable {
    let store: HotkeyBindingStore
    let feature: HotkeyFeature
    let slot: Int
    let binding: HotkeyBinding?
    let placeholder: String
    let onFeedback: (HotkeyRecorderFeedback?) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        HotkeyRecorderNSView(
            store: store,
            feature: feature,
            slot: slot,
            binding: binding,
            placeholder: placeholder,
            onFeedback: onFeedback
        )
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.configure(
            store: store,
            feature: feature,
            slot: slot,
            binding: binding,
            placeholder: placeholder,
            onFeedback: onFeedback
        )
    }
}

@MainActor
final class HotkeyRecorderNSView: NSView {
    private var store: HotkeyBindingStore
    private var feature: HotkeyFeature
    private var slot: Int
    private var binding: HotkeyBinding?
    private var placeholder: String
    private var onFeedback: (HotkeyRecorderFeedback?) -> Void

    /// Single choke point for the engine gate. Without it, recording a bare ⌃⇧
    /// starts a dictation behind the Settings window, and recording ⌘⇧D fires
    /// whatever owns that combo — Carbon consumes the key before any responder
    /// sees it. `suspend()` stops matching and unregisters the combos; it
    /// deliberately leaves the event tap alone.
    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            needsDisplay = true
            if isRecording {
                HotkeyEngine.shared.suspend()
            } else {
                HotkeyEngine.shared.resume()
            }
        }
    }
    private var maximalModifierSet = NSEvent.ModifierFlags()
    private var sawKeyDownDuringRecording = false
    private var windowCloseObserver: NSObjectProtocol?

    init(
        store: HotkeyBindingStore,
        feature: HotkeyFeature,
        slot: Int,
        binding: HotkeyBinding?,
        placeholder: String,
        onFeedback: @escaping (HotkeyRecorderFeedback?) -> Void
    ) {
        self.store = store
        self.feature = feature
        self.slot = slot
        self.binding = binding
        self.placeholder = placeholder
        self.onFeedback = onFeedback
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 124, height: 30) }

    func configure(
        store: HotkeyBindingStore,
        feature: HotkeyFeature,
        slot: Int,
        binding: HotkeyBinding?,
        placeholder: String,
        onFeedback: @escaping (HotkeyRecorderFeedback?) -> Void
    ) {
        self.store = store
        self.feature = feature
        self.slot = slot
        self.binding = binding
        self.placeholder = placeholder
        self.onFeedback = onFeedback
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    /// The side buttons. Left- and right-click keep their normal jobs — clicking
    /// the field is how you start recording in the first place — so they arrive
    /// here only as `otherMouseDown`, never as a candidate binding.
    /// `commit` runs the conflict checker, so an unbindable button beeps.
    override func otherMouseDown(with event: NSEvent) {
        guard isRecording else {
            super.otherMouseDown(with: event)
            return
        }
        commit(.mouseButton(number: event.buttonNumber))
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            cancelRecording()
        }
        return super.resignFirstResponder()
    }

    /// Closing the Settings window while recording must not strand the engine in
    /// `suspend()` — every hotkey would stay dead until relaunch. `orderOut` does
    /// not change the first responder, so `resignFirstResponder` never fires, and
    /// the window is `isReleasedWhenClosed = false` so the view survives too.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        guard let window else {
            if isRecording { cancelRecording() }
            return
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.cancelRecording()
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }

        let currentModifiers = event.modifierFlags.intersection(HotkeyBinding.recognizedModifiers)
        if !currentModifiers.isEmpty {
            maximalModifierSet.formUnion(currentModifiers)
            publishFeedback(for: .modifiersOnly(maximalModifierSet))
            needsDisplay = true
            return
        }

        guard !maximalModifierSet.isEmpty, !sawKeyDownDuringRecording else { return }
        commit(.modifiersOnly(maximalModifierSet))
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        captureKeyDown(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        captureKeyDown(event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            NSColor.separatorColor.setStroke()
        }

        path.lineWidth = isRecording ? 1.5 : 1
        path.fill()
        path.stroke()

        let title = displayTitle
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: binding == nil && !isRecording ? .regular : .medium),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]

        let textRect = bounds.insetBy(dx: 8, dy: 6)
        title.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private var displayTitle: String {
        if isRecording {
            guard !maximalModifierSet.isEmpty else { return "Record..." }
            return maximalModifierSet.hotkeyGlyphs + "..."
        }
        return binding?.displayString ?? placeholder
    }

    private var textColor: NSColor {
        if isRecording {
            return .controlAccentColor
        }
        if binding == nil {
            return .secondaryLabelColor
        }
        return .labelColor
    }

    private func beginRecording() {
        isRecording = true
        maximalModifierSet = []
        sawKeyDownDuringRecording = false
        onFeedback(nil)
    }

    private func cancelRecording() {
        isRecording = false
        maximalModifierSet = []
        sawKeyDownDuringRecording = false
        onFeedback(nil)
    }

    private func captureKeyDown(_ event: NSEvent) {
        let keyCode = UInt16(event.keyCode)

        switch keyCode {
        case UInt16(kVK_Escape):
            cancelRecording()
        case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
            store.setBinding(nil, at: slot, for: feature)
            cancelRecording()
        default:
            sawKeyDownDuringRecording = true
            let modifiers = event.modifierFlags.intersection(HotkeyBinding.recognizedModifiers)
            maximalModifierSet.formUnion(modifiers)
            let candidate = HotkeyBinding.keyCombo(keyCode: keyCode, modifiers: modifiers)
            commit(candidate)
        }
    }

    private func commit(_ candidate: HotkeyBinding) {
        let conflict = HotkeyConflictChecker.evaluate(
            candidate,
            for: feature,
            slot: slot,
            against: store.bindings
        )

        publishFeedback(conflict)

        if conflict.isBlocking {
            NSSound.beep()
            maximalModifierSet = []
            sawKeyDownDuringRecording = false
            isRecording = true
            return
        }

        store.setBinding(candidate, at: slot, for: feature)
        isRecording = false
        maximalModifierSet = []
        sawKeyDownDuringRecording = false
    }

    private func publishFeedback(for candidate: HotkeyBinding) {
        let conflict = HotkeyConflictChecker.evaluate(
            candidate,
            for: feature,
            slot: slot,
            against: store.bindings
        )
        publishFeedback(conflict)
    }

    private func publishFeedback(_ conflict: HotkeyConflict) {
        onFeedback(HotkeyRecorderFeedback(conflict))
    }
}
