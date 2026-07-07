//
//  WhisperApp.swift
//  Whisper
//
//  Created by Aatish Bajracharya on 5/7/2026.
//

import SwiftUI

@main
struct WhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                engine: app.engine,
                store: app.store,
                onPasteLast: { app.pasteLastTranscript() }
            )
            #if DEBUG
            Divider()
            Button("Demo Dictation (records 3 s)") { app.demoDictation() }
            #endif
        } label: {
            MenuBarLabel(engine: app.engine)
        }

        Window("Whisper", id: WindowID.main) {
            MainWindowView(store: app.store, stats: app.stats)
        }
        .defaultSize(width: 860, height: 600)

        Settings {
            SettingsView()
        }
    }
}

/// Menu bar icon that tracks engine state.
private struct MenuBarLabel<Engine: DictationEngine>: View {
    @ObservedObject var engine: Engine

    var body: some View {
        Image(systemName: icon)
    }

    private var icon: String {
        switch engine.state {
        case .idle: "mic.fill"
        case .recording: "waveform"
        case .transcribing: "ellipsis"
        case .failed: "mic.slash.fill"
        }
    }
}
