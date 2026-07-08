//
//  SettingsView.swift
//  Whisper — Workstream B
//

import SwiftUI
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @AppStorage(PrefKey.modelVariant) private var modelVariant = ModelVariant.turbo.rawValue
    @AppStorage(PrefKey.preferredMicID) private var preferredMicID = ""
    @AppStorage(PrefKey.soundCues) private var soundCues = true
    @AppStorage(PrefKey.retention) private var retention = HistoryRetention.forever.rawValue

    @ObservedObject private var hotkeyStore = HotkeyBindingStore.shared

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var mics: [(id: String, name: String)] = []
    @State private var inputMonitoringGranted = Permissions.inputMonitoringGranted
    @State private var hotkeyFeedback: HotkeyRecorderFeedback?

    var body: some View {
        Form {
            Section("Hotkeys") {
                hotkeyFeatureGroup(.dictation)

                Divider()

                hotkeyFeatureGroup(.pushToTalk)

                if let hotkeyFeedback {
                    Label(hotkeyFeedback.message, systemImage: hotkeyFeedbackIcon(for: hotkeyFeedback))
                        .font(.caption)
                        .foregroundStyle(hotkeyFeedbackColor(for: hotkeyFeedback))
                }

                HStack {
                    Spacer()
                    Button("Reset all hotkeys") {
                        hotkeyStore.resetToDefaults()
                        hotkeyFeedback = nil
                    }
                    .pointerCursor()
                }

                if hotkeyStore.needsInputMonitoring, !inputMonitoringGranted {
                    LabeledContent("Input Monitoring") {
                        Button("Grant in System Settings...") {
                            Permissions.requestInputMonitoring()
                            Permissions.openInputMonitoringSettings()
                            inputMonitoringGranted = Permissions.inputMonitoringGranted
                        }
                        .pointerCursor()
                    }
                    Text("macOS needs Input Monitoring for modifier-only hotkeys in other apps. Grant it, then quit and reopen Buddy.")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

    private func hotkeyFeatureGroup(_ feature: HotkeyFeature) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.displayName)
                .font(.headline)

            ForEach(0..<feature.maxBindings, id: \.self) { slot in
                hotkeySlotRow(feature: feature, slot: slot)
            }
        }
        .padding(.vertical, 2)
    }

    private func hotkeySlotRow(feature: HotkeyFeature, slot: Int) -> some View {
        let binding = hotkeyStore.binding(at: slot, for: feature)

        return HStack(spacing: 8) {
            Text(slotLabel(for: slot))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            HotkeyRecorderView(
                store: hotkeyStore,
                feature: feature,
                slot: slot,
                binding: binding,
                placeholder: "Record...",
                onFeedback: { hotkeyFeedback = $0 }
            )
            .frame(width: 124, height: 30)

            Button {
                hotkeyStore.setBinding(nil, at: slot, for: feature)
                hotkeyFeedback = nil
            } label: {
                Image(systemName: "delete.left")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .disabled(binding == nil)
            .help("Clear \(feature.displayName.lowercased()) \(slotLabel(for: slot).lowercased()) hotkey")
            .accessibilityLabel("Clear \(feature.displayName) \(slotLabel(for: slot).lowercased()) hotkey")
            .pointerCursor(isEnabled: binding != nil)
        }
    }

    private func slotLabel(for slot: Int) -> String {
        slot == 0 ? "Primary" : "Alternate"
    }

    private func hotkeyFeedbackIcon(for feedback: HotkeyRecorderFeedback) -> String {
        switch feedback.severity {
        case .warning: "exclamationmark.triangle.fill"
        case .blocking: "xmark.octagon.fill"
        }
    }

    private func hotkeyFeedbackColor(for feedback: HotkeyRecorderFeedback) -> Color {
        switch feedback.severity {
        case .warning: .orange
        case .blocking: .red
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
