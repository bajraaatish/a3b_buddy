//
//  WhisperApp.swift
//  a3b Buddy
//
//  Created by Aatish Bajracharya on 5/7/2026.
//
//  There is deliberately no `MenuBarExtra` and no `Window` scene here.
//
//  The single menu bar surface is Clicky's `NSStatusItem` + floating panel
//  (`MenuBarPanelManager`), created by the AppDelegate. Its SwiftUI content is
//  hosted in an `NSHostingView` *outside* the Scene graph, which means
//  `@Environment(\.openWindow)` silently no-ops in there and `SettingsLink` has
//  no scene to route to. So both real windows — the main history/insights
//  window and Settings — are owned by AppKit window controllers that anything
//  can reach.
//
//  SwiftUI still requires at least one scene. `Settings` is the cheapest one,
//  and it buys a working ⌘, whenever one of our windows is key.
//

import SwiftUI

@main
struct A3BBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
