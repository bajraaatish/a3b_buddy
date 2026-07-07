//
//  TextInserter.swift
//  Whisper — Workstream A
//
//  Clipboard save → write transcript → synthetic ⌘V → restore clipboard.
//  Secure input fields (passwords, Secure Keyboard Entry) block synthetic
//  paste — detected up front; text stays on the clipboard + notification.
//

import AppKit
import Carbon.HIToolbox
import UserNotifications

@MainActor
final class TextInserter {
    enum Outcome {
        case pasted
        /// Paste impossible (secure input / no Accessibility) — transcript
        /// left on the clipboard and the user was notified.
        case clipboardFallback
        case failed
    }

    /// Delay before restoring the old clipboard — the target app needs time
    /// to service the ⌘V first.
    private let restoreDelay: TimeInterval = 0.4

    @discardableResult
    func insert(_ text: String) -> Outcome {
        guard !text.isEmpty else { return .failed }

        let saved = snapshotPasteboard()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if IsSecureEventInputEnabled() {
            notify(title: "Copied to clipboard",
                   body: "Secure input is active, so Whisper couldn't paste. Press ⌘V to insert.")
            return .clipboardFallback
        }
        guard Permissions.accessibilityGranted else {
            notify(title: "Copied to clipboard",
                   body: "Grant Accessibility in System Settings so Whisper can paste for you.")
            return .clipboardFallback
        }
        guard postCommandV() else {
            notify(title: "Copied to clipboard",
                   body: "Paste didn't go through. Press ⌘V to insert.")
            return .clipboardFallback
        }

        // Restore what the user had on the clipboard before we borrowed it.
        Task { [restoreDelay] in
            try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
            restorePasteboard(saved)
        }
        return .pasted
    }

    /// Menu bar "Paste last transcript" — same paste path, but the transcript
    /// intentionally stays on the clipboard (no restore).
    func pasteToFrontmostApp(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if !IsSecureEventInputEnabled(), Permissions.accessibilityGranted {
            _ = postCommandV()
        }
    }

    // MARK: ⌘V

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: Clipboard snapshot/restore

    private func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
    }

    private func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: User notification (fallback path)

    private func notify(title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
