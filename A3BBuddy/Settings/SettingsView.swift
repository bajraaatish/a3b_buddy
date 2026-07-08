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
    @AppStorage(PrefKey.dictationModifierOnlyShortcut) private var dictationModifierOnlyShortcut = ModifierOnlyShortcut.off.rawValue
    @AppStorage(PrefKey.pushToTalkModifierOnlyShortcut) private var pushToTalkModifierOnlyShortcut = ModifierOnlyShortcut.controlOption.rawValue

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var mics: [(id: String, name: String)] = []
    @State private var inputMonitoringGranted = Permissions.inputMonitoringGranted
    @State private var acceptedDictationShortcut: KeyboardShortcuts.Shortcut?
    @State private var acceptedPushToTalkShortcut: KeyboardShortcuts.Shortcut?
    @State private var acceptedDictationModifierOnlyShortcut = ModifierOnlyShortcut.off.rawValue
    @State private var acceptedPushToTalkModifierOnlyShortcut = ModifierOnlyShortcut.controlOption.rawValue
    @State private var hotkeyConflictMessage: String?
    @State private var isResolvingHotkeyConflict = false

    private enum HotkeyOwner {
        case dictation
        case pushToTalk
    }

    var body: some View {
        Form {
            Section("Hotkeys") {
                KeyboardShortcuts.Recorder("Dictation (Whisper)", name: .dictation)

                Picker("Dictation modifier hold", selection: $dictationModifierOnlyShortcut) {
                    ForEach(ModifierOnlyShortcut.allCases) { shortcut in
                        Text(shortcut.displayName).tag(shortcut.rawValue)
                    }
                }

                Text(dictationHotkeyHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                KeyboardShortcuts.Recorder("Push-to-talk (Clicky)", name: .pushToTalk)

                Picker("Push-to-talk modifier hold", selection: $pushToTalkModifierOnlyShortcut) {
                    ForEach(ModifierOnlyShortcut.allCases) { shortcut in
                        Text(shortcut.displayName).tag(shortcut.rawValue)
                    }
                }

                Text(pushToTalkHotkeyHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let hotkeyConflictMessage {
                    Text(hotkeyConflictMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if needsInputMonitoringForModifierOnlyHotkeys, !inputMonitoringGranted {
                    LabeledContent("Input Monitoring") {
                        Button("Grant in System Settings...") {
                            Permissions.requestInputMonitoring()
                            Permissions.openInputMonitoringSettings()
                        }
                    }
                    Text("macOS needs Input Monitoring for modifier-only hotkeys in other apps. Grant it, then quit and reopen a3b Buddy.")
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
        .onAppear {
            cacheAcceptedKeyboardShortcuts()
            cacheAcceptedModifierOnlyShortcuts()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            enforceKeyboardShortcutConflicts()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inputMonitoringGranted = Permissions.inputMonitoringGranted
        }
        .onChange(of: dictationModifierOnlyShortcut) { _, _ in
            enforceModifierOnlyShortcutConflicts(changed: .dictation)
        }
        .onChange(of: pushToTalkModifierOnlyShortcut) { _, _ in
            enforceModifierOnlyShortcutConflicts(changed: .pushToTalk)
        }
    }

    private var selectedDictationModifierOnlyShortcut: ModifierOnlyShortcut {
        ModifierOnlyShortcut(rawValue: dictationModifierOnlyShortcut) ?? .off
    }

    private var selectedPushToTalkModifierOnlyShortcut: ModifierOnlyShortcut {
        ModifierOnlyShortcut(rawValue: pushToTalkModifierOnlyShortcut) ?? .controlOption
    }

    private var needsInputMonitoringForModifierOnlyHotkeys: Bool {
        selectedDictationModifierOnlyShortcut != .off || selectedPushToTalkModifierOnlyShortcut != .off
    }

    private var dictationHotkeyHelpText: String {
        let shortcut = selectedDictationModifierOnlyShortcut
        guard shortcut != .off else {
            return "Hold the dictation combo to record, release to insert. Double-tap to lock hands-free; Esc cancels."
        }

        return "Hold \(shortcut.symbol) to record, release to insert. Double-tap to lock hands-free; Esc cancels. Shortcuts using extra keys cancel the hold."
    }

    private var pushToTalkHotkeyHelpText: String {
        let shortcut = selectedPushToTalkModifierOnlyShortcut
        guard shortcut != .off else {
            return "Hold the push-to-talk combo to talk to Clicky, release to send."
        }

        return "Hold \(shortcut.symbol) to talk to Clicky, release to send."
    }

    private func cacheAcceptedKeyboardShortcuts() {
        acceptedDictationShortcut = KeyboardShortcuts.getShortcut(for: .dictation)
        acceptedPushToTalkShortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk)
    }

    private func cacheAcceptedModifierOnlyShortcuts() {
        acceptedDictationModifierOnlyShortcut = dictationModifierOnlyShortcut
        acceptedPushToTalkModifierOnlyShortcut = pushToTalkModifierOnlyShortcut
    }

    private func enforceKeyboardShortcutConflicts() {
        guard !isResolvingHotkeyConflict else { return }

        let dictationShortcut = KeyboardShortcuts.getShortcut(for: .dictation)
        let pushToTalkShortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk)
        let keyboardShortcutChanged = dictationShortcut != acceptedDictationShortcut
            || pushToTalkShortcut != acceptedPushToTalkShortcut

        guard let dictationShortcut,
              let pushToTalkShortcut,
              dictationShortcut == pushToTalkShortcut else {
            if keyboardShortcutChanged {
                hotkeyConflictMessage = nil
            }
            cacheAcceptedKeyboardShortcuts()
            return
        }

        let changedOwner: HotkeyOwner = dictationShortcut != acceptedDictationShortcut
            ? .dictation
            : .pushToTalk

        isResolvingHotkeyConflict = true
        switch changedOwner {
        case .dictation:
            KeyboardShortcuts.setShortcut(acceptedDictationShortcut, for: .dictation)
            hotkeyConflictMessage = "Push-to-talk (Clicky) already uses that shortcut. Choose a different combo for dictation."
        case .pushToTalk:
            KeyboardShortcuts.setShortcut(acceptedPushToTalkShortcut, for: .pushToTalk)
            hotkeyConflictMessage = "Dictation (Whisper) already uses that shortcut. Choose a different combo for push-to-talk."
        }
        isResolvingHotkeyConflict = false
        cacheAcceptedKeyboardShortcuts()
    }

    private func enforceModifierOnlyShortcutConflicts(changed owner: HotkeyOwner) {
        guard !isResolvingHotkeyConflict else { return }

        let dictationShortcut = selectedDictationModifierOnlyShortcut
        let pushToTalkShortcut = selectedPushToTalkModifierOnlyShortcut
        let modifierOnlyShortcutChanged = dictationModifierOnlyShortcut != acceptedDictationModifierOnlyShortcut
            || pushToTalkModifierOnlyShortcut != acceptedPushToTalkModifierOnlyShortcut

        guard dictationShortcut != .off,
              pushToTalkShortcut != .off,
              dictationShortcut == pushToTalkShortcut else {
            if modifierOnlyShortcutChanged {
                hotkeyConflictMessage = nil
            }
            cacheAcceptedModifierOnlyShortcuts()
            return
        }

        isResolvingHotkeyConflict = true
        switch owner {
        case .dictation:
            dictationModifierOnlyShortcut = acceptedDictationModifierOnlyShortcut
            hotkeyConflictMessage = "Push-to-talk (Clicky) already uses that modifier hold. Choose a different modifier hold for dictation."
        case .pushToTalk:
            pushToTalkModifierOnlyShortcut = acceptedPushToTalkModifierOnlyShortcut
            hotkeyConflictMessage = "Dictation (Whisper) already uses that modifier hold. Choose a different modifier hold for push-to-talk."
        }
        isResolvingHotkeyConflict = false
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
