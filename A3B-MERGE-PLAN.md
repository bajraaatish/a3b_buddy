# a3b Buddy — Merge & Feature Plan (Agent Orchestration)

Scope of this plan (separate from `AGENT-PLAN.md`, which covers the older fork work):

1. Merge Whisper + Clicky into ONE app named **a3b Buddy** (one Xcode project, one target, one logo, one menu bar icon).
2. Whisper's main window (insights + history) stays exactly as-is. Clicky stays menu-bar-driven as-is.
3. **Flexible hotkeys** — user-selectable hotkey for Whisper dictation AND Clicky push-to-talk, independently.
4. **Cosmetic** — the cursor-following triangle gets a subtle glow so the wine color is visible.

---

## 1. Roster — 3 agents

| Agent | Model | Why this model | Owns |
|---|---|---|---|
| **FABLE-1** (Foreman) | Claude Fable 5 via Claude Code | Largest context + best at cross-cutting refactors and Xcode project surgery. Also reviews and merges everyone's work. | Project merge, app shell, naming/branding, all merges |
| **GPT-1** | GPT 5.5 via Codex CLI | Strong at focused, well-specified subsystem work with clear API contracts. | Hotkey system (both features) |
| **FLASH-1** | Gemini 3 Flash | Trivial, file-isolated cosmetic task — cheapest capable model wins. | Triangle glow in `OverlayWindow.swift` |

Worktrees, Conductor-style (one per agent, FABLE-1 works on `main`):

```
git worktree add ../a3b-hotkeys feature/hotkeys
git worktree add ../a3b-glow    feature/glow
```

**Hard rule:** only FABLE-1 edits the `.xcodeproj`, `Info.plist`, and app-entry files (`WhisperApp.swift`, `AppDelegate.swift`, `leanring_buddyApp.swift`). GPT-1 and FLASH-1 write code + a short wiring note (`verification/wiring-requests/<agent>.md`); FABLE-1 wires at merge time.

---

## 2. Waves

```
WAVE 0 (FABLE-1, sequential — blocks GPT-1)
  Phase A: project merge → one app "a3b Buddy" that builds & runs both features

WAVE 1 (parallel)
  GPT-1:   Phase B — flexible hotkeys (branches from post-merge main)
  FLASH-1: Phase C — triangle glow (file-isolated; may start immediately,
           rebases onto post-merge main before handoff)

MERGE (FABLE-1)
  Order: C (tiny, low-risk) → B. Regression check after each.
```

---

## 3. Phase A — Project merge (FABLE-1, Claude Fable 5)

**Goal:** one Xcode project, one target, launches as "a3b Buddy", runs Whisper dictation and Clicky companion simultaneously. No more running Clicky from Xcode.

**Base = the Whisper project** (`whisper/Whisper.xcodeproj`). It's already a working distributable app with the window + menu bar structure we want to keep. Clicky's sources move IN.

Directions — enough to start, agent handles the rest:

- Rename target/product/scheme to `a3b Buddy`; new bundle id (suggest `com.a3b.buddy`); display name "a3b Buddy". Whisper's existing app icon is fine as placeholder — Aatish supplies the final a3b logo asset.
- Move `clicky/leanring-buddy/*.swift` + assets into the Whisper project under a `Buddy/` group. Add Clicky's SPM deps to the merged project: **Sparkle**, **posthog-ios**. (Keep both for now — pruning analytics is out of scope.)
- **App entry:** keep `WhisperApp` as `@main` (rename to `A3BBuddyApp`). Fold `CompanionAppDelegate`'s launch work (MenuBarPanelManager, CompanionManager.start(), Sparkle, analytics) into Whisper's `AppDelegate`. Delete Clicky's `@main` and its empty Settings scene.
- **One menu bar icon.** Whisper uses SwiftUI `MenuBarExtra`; Clicky uses an `NSStatusItem` + floating panel (`MenuBarPanelManager`). Pick ONE: recommend keeping Clicky's `MenuBarPanelManager` panel as the single status item and adding Whisper's menu actions (open main window, paste last transcript, engine state) into that panel — Clicky's panel is the richer surface. If that fights the SwiftUI lifecycle, fallback: keep `MenuBarExtra` and open Clicky's panel from it.
- Whisper's `Window` scene (insights/history) stays untouched and reachable from the menu bar.
- **Info.plist merge:** union of all usage strings — mic, speech recognition, screen capture, accessibility, input monitoring. Whisper is NOT `LSUIElement`-only today; keep whisper's dock/window behavior.
- **Collision sweep before building:** duplicate type names across the two codebases (both have design-system/overlay/audio helpers — e.g. check `DesignSystem`, waveform/overlay views, audio conversion utils). Rename Clicky-side dupes with a `Buddy` prefix.
- Entitlements: union of both (`leanring-buddy.entitlements` + Whisper's).
- Old `whisper/` and `clicky/` folder split disappears — final layout: one project at repo root (or keep `app/`), `scripts/`, `verification/` intact.

**Exit criteria:** `xcodebuild` clean build; app launches once; menu bar icon present; Whisper dictation works with its current hotkey; Clicky push-to-talk works with its current hotkey; main window opens with history/insights; no duplicate menu bar icons.

---

## 4. Phase B — Flexible hotkeys (GPT-1, GPT 5.5)

**Goal:** user can assign ANY hotkey to Whisper dictation and ANY hotkey to Clicky push-to-talk, independently, from Settings. No hardcoded shortcuts anywhere.

Current state (read these first):

- Whisper already uses `sindresorhus/KeyboardShortcuts` with a recorder (`ShortcutNames.swift`: `.dictation`) PLUS a bare-modifier hold system via CGEventTap (`Hotkey/HotkeyManager.swift`). This is the good pattern — reuse it.
- Clicky's shortcut is hardcoded: `GlobalPushToTalkShortcutMonitor.swift` + `BuddyPushToTalkShortcut` (ctrl+option). No user configuration. This is what gets replaced.

Directions:

- Add `KeyboardShortcuts.Name.pushToTalk` alongside `.dictation`.
- Refactor `GlobalPushToTalkShortcutMonitor` to read the user-configured shortcut instead of the hardcoded combo. Preserve its press/release transition semantics (`shortcutTransitionPublisher`, `isShortcutCurrentlyPressed`) — CompanionManager depends on them.
- Support BOTH shortcut styles for each feature: normal combos (via KeyboardShortcuts) and modifier-only holds (via the CGEventTap pattern — generalize Whisper's `HotkeyManager` bare-modifier logic rather than duplicating it; KeyboardShortcuts alone can't record modifier-only).
- Settings UI: a "Hotkeys" section with two recorders — "Dictation (Whisper)" and "Push-to-talk (Clicky)". Conflict guard: same shortcut on both → inline warning, refuse to save.
- Persist via KeyboardShortcuts' own storage (UserDefaults). Live rebind — no app restart.
- Do NOT edit CompanionManager, app entry, or the project file. Ship a wiring note for anything that must be hooked at init.

**Exit criteria:** assign an arbitrary combo to each feature → both trigger correctly; modifier-only hold still works for dictation; changing a hotkey takes effect immediately; conflict warning works; defaults preserved on fresh install.

---

## 5. Phase C — Triangle glow (FLASH-1, Gemini 3 Flash)

**Goal:** the cursor-following triangle (wine colored, hard to see) gets a subtle glow for visibility.

- File: `OverlayWindow.swift` (post-merge: `Buddy/OverlayWindow.swift`) — `Triangle` shape + `BlueCursorView`.
- Keep the wine color. Add a soft outer glow: layered `.shadow(color:radius:)` (2–3 stacked shadows, tight→wide, wine color at low opacity ~0.3–0.6) or a blurred duplicate of the shape behind it. "Slight" glow — visible on dark AND light backgrounds, not neon.
- Must not affect hit-testing, the spring-follow animation, or multi-screen behavior. Diff stays inside this one file.

**Exit criteria:** triangle clearly visible on light and dark backgrounds; no animation jank; single-file diff.

---

## 6. Merge & QA (FABLE-1)

1. Merge C first (trivial), run app, eyeball glow on both backgrounds.
2. Merge B, apply GPT-1's wiring note, full regression:
   - dictation record → transcribe → insert
   - push-to-talk → companion responds, triangle follows cursor
   - rebind both hotkeys, relaunch, bindings persist
   - main window: history + insights intact
   - one menu bar icon, correct app name everywhere (menu bar tooltip, About, Activity Monitor)
3. Tag `v0.1-merged` on green.

## 7. What Aatish supplies

- Final a3b logo / app icon export (until then, Whisper icon stays).
- Quick visual sign-off on the glow (one screenshot from FLASH-1 is enough).
- Decision only if FABLE-1 hits the MenuBarExtra-vs-panel fallback (§3) — otherwise agents don't ask.
