//
//  MenuBarContent.swift
//  Whisper — Workstream B
//

import SwiftUI

struct MenuBarContent<Engine: DictationEngine>: View {
    @ObservedObject var engine: Engine
    let store: any DictationStore
    let onPasteLast: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(engine.state.menuLabel)

        if case .failed(let error) = engine.state {
            Text(error.recovery)
        }

        Divider()

        Button("Open Whisper") {
            openWindow(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true) // LSUIElement apps open windows behind others otherwise
        }
        .keyboardShortcut("o")

        Button("Paste Last Transcript") {
            onPasteLast()
        }
        .disabled(((try? store.all()) ?? []).isEmpty)

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Whisper") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
}
