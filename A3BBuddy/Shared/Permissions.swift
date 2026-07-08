//
//  Permissions.swift
//  Whisper — Workstream A
//
//  Microphone + Accessibility checks, prompt flows, Settings deep-links.
//

import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid

enum Permissions {
    // MARK: Microphone

    static var micStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Triggers the system mic prompt if not yet determined.
    static func requestMic() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Accessibility (needed to post the synthetic ⌘V)

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system "grant Accessibility" dialog if not yet trusted.
    /// Returns current trust state (the grant itself happens in System Settings).
    @discardableResult
    static func promptAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Input Monitoring (needed to see the bare hold-key in other apps)

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system Input Monitoring prompt (once). macOS applies the
    /// grant to already-running apps only after a relaunch.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// TCC admits a listen-only keyboard event tap on **either** grant, and gates
    /// it per *process*, not per tap. Only `CGEvent.tapCreate` returning nil is
    /// authoritative; this is the check that decides whether to prompt first.
    static var eventTapPermitted: Bool {
        inputMonitoringGranted || accessibilityGranted
    }

    // MARK: System Settings deep-links

    static func openMicSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
