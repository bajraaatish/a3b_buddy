# AUDIT wiring request — RESOLVED

## HotkeyBindingStore concurrency build error — fixed differently

AUDIT observed this mid-edit, while the foreman was adding the
`HotkeyCarbonRegistrar` seam:

```
A3BBuddy/Hotkey/HotkeyBindingStore.swift:55:41: error: call to main
actor-isolated initializer 'init()' in a synchronous nonisolated context
```

Correct diagnosis: `KeyboardShortcutsCarbonRegistrar` was `@MainActor`, and
default parameter expressions are evaluated in the *caller's* context.

AUDIT proposed `carbon: HotkeyCarbonRegistrar? = nil` plus
`?? KeyboardShortcutsCarbonRegistrar()` in the init body. That works, but it
makes the parameter optional for a reason the reader can't see, and pushes a
`nil` sentinel through the public API.

**Landed instead:** annotate the *requirement*, not the type. Marking the
protocol `@MainActor` infers `@MainActor` onto every conforming type, which is
what isolated the struct's implicit `init()`. Moving the annotation to the
single method leaves the conformers non-isolated and usable as default
arguments:

```swift
protocol HotkeyCarbonRegistrar: Sendable {
    @MainActor func setCombo(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name)
}

struct KeyboardShortcutsCarbonRegistrar: HotkeyCarbonRegistrar {
    @MainActor func setCombo(...) { KeyboardShortcuts.setShortcut(shortcut, for: name) }
}
```

`xcodebuild test … -only-testing:A3BBuddyTests` → **TEST SUCCEEDED**, all suites.

## Stale-copy sweep — applied

Everything in §1 of `v3-audit-report.md` is now dynamic, reading
`HotkeyBindingStore.shared.primaryDisplayString(for: .pushToTalk)`:

- `Buddy/CompanionPanelView.swift` — `Text("Hold \(pushToTalkGlyphs) to talk.")`,
  with `@ObservedObject private var hotkeyStore` so it re-renders on rebind.
- `Buddy/CompanionManager.swift` — `startOnboardingPromptStream()`. Verified the
  string is *typed on screen*, not spoken, so glyphs (`⌃⌥`) are correct rather
  than a spoken word form.
- `Buddy/OverlayWindow.swift` — comment updated.
- `CLAUDE.md` — hotkey section rewritten.

This also closes item 5 of `gpt-1.md`.

## Still open for FOREMAN at W2

- Delete `Hotkey/HotkeyBindingBridge.swift` and `ModifierOnlyShortcut` once
  `HotkeyEngine` lands.
- Decide the `.failed` pill state question (§4 of `v3-audit-report.md`):
  `RealDictationEngine.swift:150-151` claims failure shows on the pill, but
  `RecordingPanelController.swift:37-42` orders the panel out on `.failed`, so
  the state is unreachable. Either give the pill a fifth state or delete the
  comment.
