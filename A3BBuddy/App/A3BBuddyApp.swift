//
//  A3BBuddyApp.swift
//  a3b Buddy
//
//  Created by Aatish Bajracharya on 5/7/2026.
//
//  Single app entry for the merged Whisper (dictation) + Clicky (companion)
//  app. The app lives entirely in the menu bar: Clicky's MenuBarPanelManager
//  owns the one status item, and the Whisper history/insights window is
//  opened on demand by the AppDelegate. The Settings scene hosts Whisper's
//  dictation settings.
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
