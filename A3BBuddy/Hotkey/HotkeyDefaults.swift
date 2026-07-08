//
//  HotkeyDefaults.swift
//  Buddy — flexible hotkeys
//
//  The key-value store the hotkey layer persists into, behind a protocol.
//
//  Tests used to pass a `UserDefaults(suiteName: UUID().uuidString)`. That looks
//  hermetic and isn't: every suite gets a real `~/Library/Preferences/<name>.plist`,
//  written by `cfprefsd` *asynchronously*, so `removePersistentDomain` in a
//  `defer` empties a file that has not been created yet and the flush lands
//  afterwards. One stray plist per test, forever.
//
//  `UserDefaults` already has every one of these methods with these exact
//  signatures, so the conformance is empty. Tests use `InMemoryHotkeyDefaults`
//  and touch no disk at all.
//

import Foundation

protocol HotkeyDefaults: AnyObject {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func integer(forKey key: String) -> Int
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: HotkeyDefaults {}

/// Test double. Mirrors `UserDefaults` semantics that the hotkey layer relies on:
/// `integer(forKey:)` is 0 when absent, and `set(nil, forKey:)` removes.
final class InMemoryHotkeyDefaults: HotkeyDefaults {
    private var storage: [String: Any]

    init(_ initial: [String: Any] = [:]) {
        storage = initial
    }

    func object(forKey key: String) -> Any? { storage[key] }
    func string(forKey key: String) -> String? { storage[key] as? String }
    func data(forKey key: String) -> Data? { storage[key] as? Data }
    func integer(forKey key: String) -> Int { storage[key] as? Int ?? 0 }

    func set(_ value: Any?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}
