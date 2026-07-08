//
//  AppWindowControllers.swift
//  a3b Buddy
//
//  AppKit-owned windows. The menu bar panel is an NSHostingView living outside
//  SwiftUI's Scene graph, so it can't use `openWindow` or `SettingsLink` to
//  reach a `Window`/`Settings` scene. These controllers can be called from
//  anywhere — the panel, the AppDelegate, a SwiftUI view.
//
//  `NSApp.activate(ignoringOtherApps:)` is not optional here: with
//  `LSUIElement = YES` our windows open behind whatever app is frontmost.
//

import AppKit
import SwiftUI

/// The history + insights window. One instance, reused.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    /// Injected by the AppDelegate at launch — the controller has no way to
    /// reach the object graph on its own.
    var makeContentView: (@MainActor () -> AnyView)?

    func show() {
        if window == nil {
            guard let makeContentView else {
                NSLog("a3b Buddy: MainWindowController used before the AppDelegate wired it")
                return
            }
            let created = NSWindow(contentViewController: NSHostingController(rootView: makeContentView()))
            created.title = "a3b Buddy"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 860, height: 600))
            created.isReleasedWhenClosed = false
            created.setFrameAutosaveName("a3b-buddy-main")
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Settings. Currently hosts the pre-merge `SettingsView`; the tabbed
/// `SettingsRootView` replaces that content in the hotkeys work.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            created.title = "Settings"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.tabbingMode = .disallowed
            created.setFrameAutosaveName("a3b-buddy-settings")
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
