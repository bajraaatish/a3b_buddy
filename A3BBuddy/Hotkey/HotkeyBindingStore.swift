//
//  HotkeyBindingStore.swift
//  Buddy — flexible hotkeys
//
//  The single source of truth for what triggers what. Owns persistence
//  (JSON arrays in UserDefaults) and the write-through to Carbon.
//
//  Write-through matters: `.keyCombo` bindings are registered with
//  `RegisterEventHotKey` via KeyboardShortcuts, because Carbon *consumes* the
//  key event and a listen-only CGEventTap can't. `.modifiersOnly` bindings get
//  no Carbon registration at all — HotkeyEngine matches those in the tap.
//  Every save reconciles both sides.
//

import AppKit
import Carbon.HIToolbox
import Combine
import KeyboardShortcuts

/// The Carbon side of a save, behind a protocol.
///
/// `KeyboardShortcuts.setShortcut` hardcodes `UserDefaults.standard` and calls
/// `RegisterEventHotKey` immediately. Without this seam a test that constructs
/// `HotkeyBindingStore(defaults: someTestSuite)` would still overwrite the
/// developer's real `KeyboardShortcuts_*` keys and register live system-wide
/// hotkeys. Tests inject `NullCarbonRegistrar`.
/// Only the requirement is `@MainActor`, not the protocol — annotating the
/// protocol infers `@MainActor` onto the conforming type, which would make
/// `KeyboardShortcutsCarbonRegistrar()` unusable as a default argument (default
/// args are evaluated in the caller's nonisolated context).
protocol HotkeyCarbonRegistrar: Sendable {
    @MainActor func setCombo(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name)
}

struct KeyboardShortcutsCarbonRegistrar: HotkeyCarbonRegistrar {
    @MainActor func setCombo(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.setShortcut(shortcut, for: name)
    }
}

/// Tests inject this so `swift test` never registers a live system-wide hotkey.
struct NullCarbonRegistrar: HotkeyCarbonRegistrar {
    @MainActor func setCombo(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {}
}

@MainActor
final class HotkeyBindingStore: ObservableObject {
    static let shared = HotkeyBindingStore()

    @Published private(set) var bindings: [HotkeyFeature: [HotkeyBinding]] = [:]

    private let defaults: UserDefaults
    private let carbon: HotkeyCarbonRegistrar

    init(
        defaults: UserDefaults = .standard,
        carbon: HotkeyCarbonRegistrar = KeyboardShortcutsCarbonRegistrar(),
        runningMigration: Bool = true
    ) {
        self.defaults = defaults
        self.carbon = carbon
        if runningMigration {
            HotkeyMigration.runIfNeeded(defaults: defaults)
        }
        for feature in HotkeyFeature.allCases {
            bindings[feature] = Self.read(from: feature.defaultsKey, in: defaults) ?? feature.defaultBindings
        }
        for feature in HotkeyFeature.allCases {
            syncCarbonRegistrations(for: feature)
        }
    }

    // MARK: Reading

    func bindings(for feature: HotkeyFeature) -> [HotkeyBinding] {
        bindings[feature] ?? []
    }

    func binding(at slot: Int, for feature: HotkeyFeature) -> HotkeyBinding? {
        let list = bindings(for: feature)
        return slot < list.count ? list[slot] : nil
    }

    /// True when any binding anywhere is a bare-modifier hold — the only
    /// reason this app needs Input Monitoring.
    var needsInputMonitoring: Bool {
        HotkeyFeature.allCases.contains { feature in
            bindings(for: feature).contains(where: \.requiresInputMonitoring)
        }
    }

    // MARK: Writing

    func setBindings(_ newBindings: [HotkeyBinding], for feature: HotkeyFeature) {
        let trimmed = Array(newBindings.prefix(feature.maxBindings))
        guard bindings[feature] != trimmed else { return }
        bindings[feature] = trimmed
        Self.write(trimmed, to: feature.defaultsKey, in: defaults)
        syncCarbonRegistrations(for: feature)
    }

    /// `nil` removes the slot. A slot past the end appends, up to `maxBindings`.
    func setBinding(_ binding: HotkeyBinding?, at slot: Int, for feature: HotkeyFeature) {
        var list = bindings(for: feature)
        switch (binding, slot < list.count) {
        case (let binding?, true): list[slot] = binding
        case (let binding?, false): list.append(binding)
        case (nil, true): list.remove(at: slot)
        case (nil, false): return
        }
        setBindings(list, for: feature)
    }

    func resetToDefaults() {
        for feature in HotkeyFeature.allCases {
            setBindings(feature.defaultBindings, for: feature)
        }
    }

    // MARK: Carbon reconciliation

    /// Combos are assigned to `KeyboardShortcuts.Name`s in the order they
    /// appear among *combos*, not by binding slot. So a feature whose primary
    /// is a bare hold and whose alternate is ⌥Space still registers ⌥Space
    /// against the feature's first Name — which is the one existing listeners
    /// (`HotkeyManager`'s `onKeyDown(for: .dictation)`) are subscribed to.
    private func syncCarbonRegistrations(for feature: HotkeyFeature) {
        let names = feature.comboShortcutNames
        var nameIndex = 0

        for binding in bindings(for: feature) {
            guard case .keyCombo(let keyCode, _) = binding, nameIndex < names.count else { continue }
            carbon.setCombo(
                .init(KeyboardShortcuts.Key(rawValue: Int(keyCode)), modifiers: binding.modifierFlags),
                for: names[nameIndex]
            )
            nameIndex += 1
        }

        // Anything left over held a combo that's since been removed.
        for unusedName in names[nameIndex...] {
            carbon.setCombo(nil, for: unusedName)
        }
    }

    // MARK: Persistence

    /// Shared with HotkeyMigration, which writes before any store exists.
    /// `nonisolated` because a `static func` on a `@MainActor` class would
    /// otherwise be MainActor-isolated, and migration's helpers are not.
    nonisolated static func write(_ bindings: [HotkeyBinding], to key: String, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(bindings) else {
            NSLog("Whisper: could not encode hotkey bindings for \(key)")
            return
        }
        defaults.set(data, forKey: key)
    }

    nonisolated static func read(from key: String, in defaults: UserDefaults) -> [HotkeyBinding]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([HotkeyBinding].self, from: data)
    }
}
