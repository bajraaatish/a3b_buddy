# Buddy v2 — Task Division for Agents

Status: the merge is **done and working**. One local macOS menu-bar app (`com.a3b.buddy`,
branch `merge-clicky-whisper-plan`): Whisper dictation (WhisperKit, hold **Shift**) +
Buddy companion (wine cursor, `claude` CLI brain, local STT/TTS, push-to-talk **⌃⌥**).
No Cloudflare Worker, no Sparkle/PostHog, no Farza.

This plan splits the next five asks across agents. **Read this whole file before starting your task.**

---

## 0. Roster

| Agent | Model / CLI | Owns |
|---|---|---|
| **FABLE-1** (foreman) | Claude Code (me) | Rename (task 1), lock-state exposure hook, all merges + stability (task 5). Sole editor of `.xcodeproj`, `Info.plist`, `*.entitlements`, `A3BBuddy/App/*`, `A3BBuddy/Buddy/CompanionManager.swift`. |
| **GPT-1** | Codex CLI | Flexible hotkeys for both features (task 2). |
| **Agent-Pill** | Claude Code | Whisper pill redesign to match the reference images (task 4). |
| **Agent-Glow** | Claude Code | Increase the buddy cursor glow (task 3). Small, single file. |

Worktrees (one per non-foreman agent; FABLE-1 works on `merge-clicky-whisper-plan`):

```
git worktree add ../buddy-hotkeys  feature/flexible-hotkeys
git worktree add ../buddy-pill      feature/whisper-pill-ui
git worktree add ../buddy-glow      feature/cursor-glow
```

---

## 1. Hard rules (all agents)

1. **Do NOT run `xcodebuild` against the user's installed app or Xcode's DerivedData** — it kills the TCC permission grants. Compile-check only with an unsigned throwaway build:
   `xcodebuild -project A3BBuddy.xcodeproj -scheme "a3b Buddy" -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/<yourname>-dd CODE_SIGNING_ALLOWED=NO build`
   Delete the temp dir after. The user builds/runs with Cmd+R.
2. **Only FABLE-1** edits `.xcodeproj`, `Info.plist`, `A3BBuddy.entitlements`, `A3BBuddy/App/*` (A3BBuddyApp, AppDelegate, WhisperMenuBridge), and `A3BBuddy/Buddy/CompanionManager.swift`. If your task needs a change there, write a note in `verification/wiring-requests/<agent>.md` and FABLE-1 wires it at merge time.
3. `A3BBuddy/Shared/Contracts.swift` is **frozen**. Need a protocol change? Stop and ask FABLE-1 — do not edit it.
4. **Do NOT rename the literal `"a3b-buddy"`** where it is a filesystem path — `~/Library/Application Support/a3b-buddy/` holds the STT/TTS helpers (`CompanionCapturePrivacySupport.swift`, `BuddyDictationManager.swift`, helper providers). Renaming it breaks the local pipeline. That literal is off-limits to the rename task.
5. **Do NOT change the bundle id** `com.a3b.buddy`. Changing it re-triggers every macOS permission prompt. The rename is display-name + UI-copy only.
6. Keep both features working with their current defaults after every merge. New capability is layered on top, never a replacement.
7. All buttons show a pointer cursor on hover (`.pointerCursor()` from `Buddy/DesignSystem.swift`).
8. Don't fix the known non-blocking warnings (Swift 6 concurrency; deprecated `onChange` in `OverlayWindow.swift`).

---

## 2. Waves & merge order

```
WAVE 0 (FABLE-1, blocks Agent-Pill)
  1a. Rename → "Buddy"
  1b. Expose hands-free lock state + cancel/confirm actions to the pill
      (small surface Agent-Pill builds against — see task 4)

WAVE 1 (parallel)
  GPT-1       task 2  flexible hotkeys        (branches from post-wave-0 main)
  Agent-Pill   task 4  whisper pill UI          (needs the lock surface from 1b)
  Agent-Glow task 3  cursor glow              (file-isolated; may start immediately)

MERGE (FABLE-1), order low-risk → high-risk:
  glow → pill → hotkeys.  Unsigned build + eyeball after each.

WAVE 2 (FABLE-1)
  task 5  stability & smoothness pass, then tag v0.2
```

---

## 3. Task 1 — Rename to "Buddy" (FABLE-1)

User-visible name becomes **"Buddy"** everywhere. Internal identifiers (module `A3BBuddy`, folder `A3BBuddy/`, `A3BBuddy.xcodeproj`, bundle id `com.a3b.buddy`) stay — churning them buys nothing and risks the grant reset.

- `INFOPLIST_KEY_CFBundleDisplayName` (both Debug/Release) → `Buddy`.
- UI copy: `CompanionPanelView.swift` ("Hi, I'm a3b-buddy." → "Hi, I'm Buddy.", "…meet a3b-buddy." , "Quit a3b-buddy", accessibilityLabel), `AppDelegate.swift` window titles ("a3b Buddy" → "Buddy", "Welcome to a3b Buddy" → "Welcome to Buddy").
- Leave asset keys `a3b-logo` / `a3b-menu-icon` as-is (internal image names).
- **Do NOT touch** the `"a3b-buddy"` support-dir path literals (rule 4).

Exit: app launches as "Buddy" (menu tooltip, About, window titles, panel copy); helpers still resolve; no permission re-prompt.

---

## 4. Task 2 — Flexible hotkeys, both features (GPT-1)

**Goal:** from one Settings screen, the user can bind **any** hotkey to Whisper dictation and **any** hotkey to Buddy push-to-talk, independently. Both a normal combo (e.g. ⌃⌥D) and a modifier-only hold (e.g. hold fn) must be supported, with a conflict guard so the two can't collide.

Current state (read first):
- Whisper: `A3BBuddy/Hotkey/ShortcutNames.swift` (`.dictation` combo, default ⌥Space), `A3BBuddy/Hotkey/HotkeyManager.swift` (bare-modifier hold via listen-only CGEventTap; default now `.shift`), `A3BBuddy/Settings/Prefs.swift` (`ModifierOnlyShortcut`), `A3BBuddy/Settings/SettingsView.swift` (has a working "Dictation modifier hold" picker).
- Buddy: `A3BBuddy/Buddy/GlobalPushToTalkShortcutMonitor.swift` + `BuddyPushToTalkShortcut` in `BuddyDictationManager.swift` — currently a **hardcoded** `ShortcutOption.controlOption`. `SettingsView.swift` already renders a "Push-to-talk modifier hold" picker writing `PrefKey.pushToTalkModifierOnlyShortcut`, but **the companion ignores it** — wiring that through is the core of this task.
- `KeyboardShortcuts` (sindresorhus) is already an SPM dep and drives the recordable combos.

Directions:
- Make `GlobalPushToTalkShortcutMonitor` read the user's configured shortcut (combo via `KeyboardShortcuts.Name.pushToTalk`, already declared; and/or modifier-only via `PrefKey.pushToTalkModifierOnlyShortcut`) instead of the hardcoded combo. Preserve its `shortcutTransitionPublisher` / `isShortcutCurrentlyPressed` press/release semantics — `CompanionManager` depends on them (do not edit CompanionManager; ship a wiring note if init needs a hook).
- Whisper already reads its config; make sure both features share one clean modifier-only-hold implementation rather than two copies (generalize `HotkeyManager`'s bare-modifier logic; `KeyboardShortcuts` alone can't record modifier-only).
- Settings UI: one "Hotkeys" section, two recorders — "Dictation (Whisper)" and "Push-to-talk (Buddy)" — each accepting a combo or a modifier-hold. Conflict guard: same binding on both → inline warning, refuse to save. Live rebind, no restart. Persist via `KeyboardShortcuts` storage + UserDefaults.
- Two listen-only CGEventTaps coexist today. If you unify them into one shared tap dispatching to both features, even better — but not required; correctness + no-conflict first.

Do NOT edit `CompanionManager.swift`, `App/*`, or the project file — wiring notes to `verification/wiring-requests/gpt-1.md`.

Exit: bind an arbitrary combo to each feature → both fire; a modifier-only hold works for each; changing a binding is live; conflict warning works; stock defaults (dictation hold Shift, push-to-talk ⌃⌥) preserved on fresh install.

---

## 5. Task 3 — Increase the cursor glow (Agent-Glow)

**Goal:** the wine triangle that follows the cursor glows more — clearly visible on light AND dark backgrounds, still tasteful (not neon).

- File: `A3BBuddy/Buddy/OverlayWindow.swift` only. The triangle is `DS.Colors.overlayCursorWine`; its glow is layered `.shadow(color:radius:)` (see ~lines 174–233, 265–278, 693). Increase the glow — more/wider stacked shadows, higher low-opacity spread — keep the wine color.
- Must not affect hit-testing, the spring-follow animation, the waveform/spinner states, or multi-screen behavior. Diff stays in this one file.

Exit: triangle clearly readable on white and black backgrounds; no animation jank; single-file diff. Post one before/after screenshot.

---

## 6. Task 4 — Whisper pill UI to match references (Agent-Pill)

**Goal:** rebuild the floating dictation pill to match the four reference images **exactly**. Files: `A3BBuddy/Overlay/PillView.swift` (main), `A3BBuddy/Overlay/StateText.swift` if needed. The pill only ever appears while recording/transcribing (never idle).

Reference images (committed): `docs/reference/whisper-pill/`
- `1-holding-hotkey.png` — dark rounded capsule, centered animated **dots** (waveform at rest). State: **recording, held** (hotkey down, not locked).
- `2-talking.png` — same capsule, centered **waveform bars** (EQ style, white). State: **recording with audio** (same view as #1, just audio-driven — dots when silent, bars when talking; the existing `barHeight` has a silence floor that already does this).
- `3-hands-free.png` — capsule with a left **✕ (cancel)** button, center dots/waveform, right **✓ (confirm)** button. State: **hands-free locked** (double-tap lock). The ✕ cancels, ✓ stops+transcribes.
- `4-loading.png` — capsule with center dots + a right-side **spinner**. State: **transcribing**.

Match the exact look: pill shape/size, dark fill, dot/bar styling, the ✕/✓ button treatment, spinner. Use `Buddy/DesignSystem.swift` tokens where they fit for consistency.

**Integration surface (DONE — wave 0 landed it):** `A3BBuddy/Overlay/RecordingControls.swift` is an `@ObservableObject` already passed into `PillView(engine:controls:)`:
- `controls.isHandsFreeLocked: Bool` — true during double-tap hands-free; drives whether the ✕/✓ buttons show.
- `controls.onCancel()` — wire the ✕ button to this (discards the recording).
- `controls.onConfirm()` — wire the ✓ button to this (stops + transcribes).
The hosting panel already flips `ignoresMouseEvents` off only while locked, so your ✕/✓ are clickable exactly when shown and never steal focus otherwise. Just build the four visual states in `PillView.swift` against `engine.state` + `controls`. Do **not** edit `Contracts.swift`, `HotkeyManager.swift`, `App/*`, `RecordingControls.swift`, or `CompanionManager.swift` — if you need more from the surface, note it in `verification/wiring-requests/agent-pill.md`.

Exit: all four states render pixel-close to the references; ✕/✓ work in hands-free; pill still shows only while recording/transcribing; `#Preview`s for each state.

---

## 7. Task 5 — Stable & smooth (FABLE-1)

After merges: full regression + polish.
- Dictation: hold Shift → record → transcribe → paste; hands-free double-tap → ✕/✓; history + insights intact.
- Buddy: push-to-talk → local STT → `claude` CLI reply → TTS → cursor points; glow visible.
- Rebind both hotkeys (task 2), relaunch, bindings persist, no conflict.
- One menu bar icon; name is "Buddy" everywhere; no idle pill; no permission re-prompt loop.
- Smooth: no dropped first-syllable on record, no pill flicker, no mic contention between the two features.
- Tag `v0.2` on green.

---

## 8. Wiring-request protocol

Non-foreman agents that need an entry/project/CompanionManager change drop `verification/wiring-requests/<agent>.md`: what to wire, where (file:symbol), why, how to verify. FABLE-1 applies these at merge time.
