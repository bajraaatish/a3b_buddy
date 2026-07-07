//
//  SettingsView.swift
//  Whisper — Workstream B
//

import SwiftUI
import AVFoundation
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @AppStorage(PrefKey.modelVariant) private var modelVariant = ModelVariant.turbo.rawValue
    @AppStorage(PrefKey.preferredMicID) private var preferredMicID = ""
    @AppStorage(PrefKey.soundCues) private var soundCues = true
    @AppStorage(PrefKey.retention) private var retention = HistoryRetention.forever.rawValue
    @AppStorage(PrefKey.holdKey) private var holdKey = HoldKey.control.rawValue

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var mics: [(id: String, name: String)] = []
    @State private var inputMonitoringGranted = Permissions.inputMonitoringGranted

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Hold-to-talk key", selection: $holdKey) {
                    ForEach(HoldKey.allCases) { key in
                        Text(key.displayName).tag(key.rawValue)
                    }
                }
                KeyboardShortcuts.Recorder("Backup combo", name: .dictation)

                if let key = HoldKey(rawValue: holdKey), key != .off {
                    if !inputMonitoringGranted {
                        LabeledContent("Input Monitoring") {
                            Button("Grant in System Settings…") {
                                Permissions.requestInputMonitoring()
                                Permissions.openInputMonitoringSettings()
                            }
                        }
                        Text("macOS needs Input Monitoring for Whisper to see the \(key.symbol) key in other apps. Grant it, then quit and reopen Whisper.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Hold \(key.symbol) to record, release to insert. Double-tap to lock hands-free; Esc cancels. \(key.symbol)-shortcuts (like \(key.symbol)C or \(key.symbol)-click) still work — they cancel the hold.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Hold the combo to record, release to insert. Double-tap to lock hands-free; Esc cancels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Speech model") {
                Picker("Model", selection: $modelVariant) {
                    ForEach(ModelVariant.allCases) { variant in
                        Text(variant.displayName).tag(variant.rawValue)
                    }
                }
                Text("Runs entirely on this Mac. A new model downloads on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input", selection: $preferredMicID) {
                    Text("System default").tag("")
                    ForEach(mics, id: \.id) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        applyLaunchAtLogin(enable)
                    }
                Toggle("Sound cues on start/stop", isOn: $soundCues)
                Picker("History", selection: $retention) {
                    ForEach(HistoryRetention.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .task { loadMics() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inputMonitoringGranted = Permissions.inputMonitoringGranted
        }
    }

    private func loadMics() {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        mics = discovered.map { ($0.uniqueID, $0.localizedName) }
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

#Preview {
    SettingsView()
}
