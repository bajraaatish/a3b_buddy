# a3b-buddy — Clicky Fork Guide

Step-by-step build plan for Claude Code. Fork of [farzaa/clicky](https://github.com/farzaa/clicky) (MIT, skeleton already cloned into `./clicky`). Goal: a screen-aware AI buddy that runs entirely on Aatish's existing Claude subscription, with local voice, hardened privacy, and a3b branding.

---

## 1. Research summary

**What Clicky is.** Viral macOS menu bar app (5k stars) by Farza Majeed. A blue animated companion lives next to your cursor, sees your screen, listens via push-to-talk, talks back, and points at UI elements. Built in 8 weeks. Open-sourced a day after the demo hit ~3M views.

**Stock pipeline:**

```
Push-to-talk (ctrl+option, CGEvent tap)
  → mic audio → AssemblyAI websocket (STT)        [PAID API]
  → transcript + ScreenCaptureKit screenshot
  → Cloudflare Worker proxy → Claude API (SSE)     [PAID API]
  → response text → ElevenLabs TTS                 [PAID API]
  → [POINT:x,y:label:screenN] tags → cursor overlay animates to target
```

**What we change (the Conductor principle):** [Conductor](https://www.conductor.build/) charges nothing for AI because it wraps the user's own Claude Code login. We do the same — replace the paid API brain with the Claude Agent SDK / headless Claude Code riding Aatish's Max subscription, replace paid voice APIs with local alternatives, delete the Cloudflare Worker entirely.

| Stock Clicky | a3b-buddy | Cost |
|---|---|---|
| Anthropic API via Worker | Claude Agent SDK / `claude -p` (subscription auth) | $0 |
| AssemblyAI streaming STT | Aatish's own STT project (via existing provider protocol); Apple Speech fallback already built in | $0 |
| ElevenLabs TTS | `AVSpeechSynthesizer` (built-in); Kokoro local TTS later if quality matters | $0 |
| Cloudflare Worker + API keys | Deleted — nothing to proxy | $0 |
| PostHog analytics | Deleted — privacy | $0 |

**Key codebase facts (from `clicky/CLAUDE.md` — read it in full before touching code):**

- Menu-bar-only app (`LSUIElement=true`), SwiftUI + AppKit bridging, MVVM, `@MainActor` everywhere.
- `CompanionManager.swift` (~1026 lines) is the central state machine — every swap wires through it.
- STT is **already pluggable**: `BuddyTranscriptionProvider.swift` protocol + factory, provider chosen by `VoiceTranscriptionProvider` key in Info.plist (AssemblyAI / OpenAI / Apple Speech). Aatish's STT becomes a fourth provider conforming to this protocol.
- TTS is NOT pluggable — `ElevenLabsTTSClient.swift` is called directly from `CompanionManager`. Introduce a `BuddyTTSProvider` protocol mirroring the transcription one.
- `ClaudeAPI.swift` (~291 lines) is the streaming SSE client to swap for the Agent SDK.
- **CRITICAL: never run `xcodebuild` from the terminal.** It invalidates TCC permissions (screen recording, accessibility, mic). Build only via Xcode (Cmd+R). This constrains the verification loop — see §3.
- Known non-blocking warnings (Swift 6 concurrency, deprecated onChange) — do NOT fix them.
- The `leanring-buddy` typo in scheme/directory names is intentional. Do not rename.
- Code style: clarity over cleverness, long descriptive names, no single-char variables. Follow `clicky/CLAUDE.md` conventions exactly.

---

## 2. Prerequisites

- macOS 14.2+ (ScreenCaptureKit requirement)
- Xcode 15+ with a signing team configured (free personal team is fine)
- Claude Code installed and logged in with the Max plan (`claude --version` works, `claude -p "hi"` returns a response)
- Aatish's STT project source available locally (path to be provided when Phase 3 starts)

No Cloudflare account. No API keys. That is the point.

---

## 3. Verification loop protocol (applies to EVERY phase)

Claude Code must never declare a phase done because "the code looks right." Every phase ends with a DO → VERIFY → FIX loop:

```
LOOP (max 5 iterations per phase):
  1. DO        — implement the step.
  2. VERIFY    — run every check in the phase's "Exit criteria" table.
                 Checks must produce observable evidence: command output,
                 a screenshot file, a pixel-sample value, a log line.
                 Never substitute reasoning for evidence.
  3. EVALUATE  — all criteria pass → phase complete, commit, move on.
                 Any criterion fails → diagnose from the evidence,
                 fix the specific failure, go to 2 (not 1 — don't rebuild
                 the world, fix the failing thing).
  4. STUCK     — if the same criterion fails 3 times in a row, or 5
                 iterations are exhausted: STOP. Report what was tried,
                 what the evidence shows, and ask Aatish. Do not mark done.
```

**How to verify when terminal builds are forbidden:**

- **Build checks:** ask Aatish to hit Cmd+R in Xcode, or use `xcodebuild -scheme leanring-buddy build -dry-run` for syntax-level checks only — never a real terminal build of the app target. For pure-logic Swift files, compile them standalone with `swiftc -parse` to catch errors without touching the app bundle.
- **Runtime checks:** the app must be running (launched by Aatish via Xcode). Then Claude Code verifies from outside: `screencapture -x /tmp/verify.png` + read the image, check process with `pgrep`, read app logs via `log stream --predicate 'process == "leanring-buddy"' --timeout 10s`.
- **Visual checks:** use the pixel-check script (§4). Screenshot → measure → compare against numeric tolerance. A human-looking judgment ("seems centered") is not a pass — only numbers within tolerance pass.
- **Audio checks:** TTS/STT can't be heard by Claude Code. Verify via logs (add temporary log lines: transcript text received, TTS playback started/finished with duration) plus Aatish confirming audibly. Log evidence + human confirmation = pass.

**Evidence rule:** every VERIFY step writes its evidence into `verification/phase-N/` (screenshots, log excerpts, script output). If the folder is empty, the phase is not verified.

---

## 4. Visual verification script

Create `scripts/verify_visual.py` in the fork root at Phase 0. Used by all visual exit criteria.

```python
#!/usr/bin/env python3
"""Pixel-level verification for a3b-buddy UI checks.

Usage:
  python3 verify_visual.py center   <image> <expected_x_frac> <expected_y_frac> <tol_px>
  python3 verify_visual.py color    <image> <x> <y> <expected_hex> <tolerance>
  python3 verify_visual.py present  <image> <template_image> <min_confidence>

Exit code 0 = PASS, 1 = FAIL. Prints measured values either way.
"""
import sys
from PIL import Image

def find_content_bbox(img, bg_tolerance=12):
    """Bounding box of non-background pixels (background = corner color)."""
    rgb = img.convert("RGB")
    corner = rgb.getpixel((0, 0))
    w, h = rgb.size
    xs, ys = [], []
    px = rgb.load()
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            p = px[x, y]
            if any(abs(p[i] - corner[i]) > bg_tolerance for i in range(3)):
                xs.append(x); ys.append(y)
    if not xs:
        return None
    return (min(xs), min(ys), max(xs), max(ys))

def cmd_center(image_path, ex_frac, ey_frac, tol_px):
    img = Image.open(image_path)
    bbox = find_content_bbox(img)
    if bbox is None:
        print("FAIL: no content found in image"); return 1
    cx = (bbox[0] + bbox[2]) / 2
    cy = (bbox[1] + bbox[3]) / 2
    tx = img.width * float(ex_frac)
    ty = img.height * float(ey_frac)
    dx, dy = abs(cx - tx), abs(cy - ty)
    ok = dx <= float(tol_px) and dy <= float(tol_px)
    print(f"content center=({cx:.0f},{cy:.0f}) target=({tx:.0f},{ty:.0f}) "
          f"offset=({dx:.0f},{dy:.0f}) tol={tol_px} -> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1

def cmd_color(image_path, x, y, expected_hex, tolerance):
    img = Image.open(image_path).convert("RGB")
    p = img.getpixel((int(x), int(y)))
    e = expected_hex.lstrip("#")
    exp = tuple(int(e[i:i+2], 16) for i in (0, 2, 4))
    diff = max(abs(p[i] - exp[i]) for i in range(3))
    ok = diff <= int(tolerance)
    print(f"pixel({x},{y})=#{p[0]:02x}{p[1]:02x}{p[2]:02x} expected=#{e} "
          f"maxdiff={diff} tol={tolerance} -> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1

def cmd_present(image_path, template_path, min_conf):
    # Simple presence check: template's average color appears in image region scan.
    # For robust matching install opencv-python and use cv2.matchTemplate.
    try:
        import cv2, numpy as np
        img = cv2.imread(image_path); tpl = cv2.imread(template_path)
        res = cv2.matchTemplate(img, tpl, cv2.TM_CCOEFF_NORMED)
        conf = float(res.max())
        ok = conf >= float(min_conf)
        print(f"template match confidence={conf:.3f} min={min_conf} -> {'PASS' if ok else 'FAIL'}")
        return 0 if ok else 1
    except ImportError:
        print("FAIL: install opencv-python for template matching "
              "(pip3 install opencv-python --break-system-packages)")
        return 1

if __name__ == "__main__":
    cmd = sys.argv[1]
    fn = {"center": cmd_center, "color": cmd_color, "present": cmd_present}[cmd]
    sys.exit(fn(*sys.argv[2:]))
```

**a3b brand values — FILL IN FROM BRAND BRIEF before Phase 5:**

```
A3B_PRIMARY_HEX   = "#______"   # from a3b brand brief
A3B_SECONDARY_HEX = "#______"
A3B_BG_HEX        = "#______"
A3B_LOGO_FILE     = "assets/a3b-logo.png"   # exact logo asset, export from brand files
COLOR_TOLERANCE   = 8            # per-channel; rendering/AA wiggle room
CENTER_TOLERANCE  = 4            # px
```

---

## 5. Phases

Work on a branch per phase (`feature/phase-N-name`). Commit only after the phase's exit criteria all pass. One swap at a time — the app must stay runnable after every phase.

---

### Phase 0 — Stock build runs

**Goal:** unmodified Clicky builds and runs locally, so every later failure is definitely ours.

Steps:

1. Read `clicky/CLAUDE.md` end to end.
2. `open clicky/leanring-buddy.xcodeproj`; Aatish sets signing team, hits Cmd+R.
3. The app requires a Worker URL for full function — but for Phase 0 we only verify it launches and the panel opens. The three API calls may fail; that's expected and fine (we're deleting them anyway). If launch itself hard-fails without a reachable Worker, stub the Worker URLs to `http://localhost:9999` and confirm graceful failure.
4. Create `scripts/verify_visual.py` (§4) and `verification/` folder structure.

Exit criteria:

| # | Criterion | Check | Evidence |
|---|---|---|---|
| 0.1 | App builds | Xcode build succeeds (Aatish reports; screenshot of "Build Succeeded") | `verification/phase-0/build.png` |
| 0.2 | App running, no dock icon | `pgrep -f leanring-buddy` returns PID; menu bar icon visible in `screencapture -x` | `phase-0/menubar.png` |
| 0.3 | Panel opens | Aatish clicks menu bar icon; screenshot shows panel | `phase-0/panel.png` |
| 0.4 | Verify script works | `python3 scripts/verify_visual.py color phase-0/panel.png 10 10 <sampled_hex> 8` exits 0 | script output in `phase-0/notes.md` |

---

### Phase 1 — TTS swap (easiest, do first)

**Goal:** ElevenLabs replaced with local speech. Zero network for voice output.

Steps:

1. Define `BuddyTTSProvider` protocol (mirror the transcription provider pattern): `speak(text:) async`, `stop()`, `isPlaying: Bool` published.
2. Implement `AppleSpeechTTSProvider` using `AVSpeechSynthesizer`. Pick the best available voice: prefer premium/enhanced installed voices (`AVSpeechSynthesisVoice.speechVoices()` filtered by quality), fall back to default. Log the chosen voice name at startup.
3. Refactor `CompanionManager.swift` to call the protocol instead of `ElevenLabsTTSClient` directly. Keep the ElevenLabs class conforming to the protocol but unused (delete in Phase 4).
4. Preserve the `isPlaying` behavior — transient cursor mode depends on it for fade-out scheduling.
5. Add temporary log lines: `TTS_START <char_count>`, `TTS_END <seconds>`.

Exit criteria:

| # | Criterion | Check | Evidence |
|---|---|---|---|
| 1.1 | Builds clean | Xcode build succeeds | `phase-1/build.png` |
| 1.2 | Speech is audible and local | Trigger a response; `log stream` shows `TTS_START`/`TTS_END`; Aatish confirms audio; `nettop`/no request to elevenlabs domains during playback | `phase-1/tts-log.txt` |
| 1.3 | Cursor fade still works | Transient mode: cursor fades ~1s after TTS_END (screen recording or two timed screenshots) | `phase-1/fade-before.png`, `fade-after.png` |
| 1.4 | No regression | Phase 0 criteria 0.2–0.3 still pass | `phase-1/regression.md` |

---### Phase 2 — Brain swap (hardest, do while energy is high)

**Goal:** Claude API via Worker replaced by the user's Claude subscription. No API key anywhere.

Approach — two options, try A first:

- **Option A (preferred): Claude Agent SDK.** Swift app shells out to a small local helper (Node or the `claude` binary directly) using headless mode: `claude -p "<prompt>" --output-format stream-json` with the screenshot passed as an attached image file. Subscription auth is handled by the existing Claude Code login — nothing stored in the app.
- **Option B (fallback): local HTTP bridge.** Tiny local Node server wrapping the Agent SDK, exposing one `/chat` route the Swift app calls exactly like it called the Worker (minimal Swift changes — repoint `ClaudeAPI.swift` at `localhost`). More moving parts, but nearly drop-in.

Steps:

1. Prototype OUTSIDE the app first: from the fork root, run `claude -p` with a saved screenshot and a "describe this screen, then give one [POINT:x,y:label:screen1] tag" prompt. Confirm: image input works, output contains a POINT tag, latency measured. Record findings in `verification/phase-2/prototype.md`. **Do not touch Swift until this works.**
2. Port Clicky's system prompt (find it in `CompanionManager.swift` / `ClaudeAPI.swift`) so POINT-tag behavior is preserved verbatim.
3. Replace `ClaudeAPI.swift`'s transport: new `SubscriptionClaudeProvider` that spawns the subprocess (or calls the local bridge), streams output, and feeds the existing SSE-parsing → UI pipeline. Map stream-json events to the same delegate callbacks the old SSE parser produced — the rest of the app should not know anything changed.
4. Latency will be worse than raw API. Wire the existing "processing" state to a visible thinking animation immediately on submit (buddy pulse). Perceived latency is a design problem — Aatish's territory; flag for Phase 5 polish.
5. Handle failure modes: `claude` binary missing → panel shows "Claude Code not found" with install hint; not logged in → "Run `claude` in terminal to log in."

Exit criteria:

| # | Criterion | Check | Evidence |
|---|---|---|---|
| 2.1 | Prototype proven | Saved transcript of `claude -p` call with image → response includes valid POINT tag; latency logged | `phase-2/prototype.md` |
| 2.2 | Builds clean | Xcode build succeeds | `phase-2/build.png` |
| 2.3 | End-to-end works | Push-to-talk → spoken question about visible screen → correct spoken answer. Logs show: transcript in, subprocess spawned, stream events, TTS out | `phase-2/e2e-log.txt` |
| 2.4 | Pointing works | Ask "point at the Apple menu" → cursor animates to top-left; screenshot during animation shows buddy within 50px of target | `phase-2/point.png` + verify_visual output |
| 2.5 | No API keys in repo | `grep -ri "sk-ant\|api_key\|apikey" --include="*.swift" --include="*.plist" clicky/` returns nothing sensitive | `phase-2/keyscan.txt` |
| 2.6 | Streaming feels alive | First streamed token visible in overlay < 5s after key-up (log timestamps) | `phase-2/latency.txt` |

---

### Phase 3 — STT swap (Aatish's project)

**Goal:** AssemblyAI replaced by Aatish's own speech-to-text.

Steps:

1. Aatish provides the STT project path + a one-paragraph description of its interface (streaming or batch? Swift/Python/other? input format?). **Ask before starting.**
2. Read `BuddyTranscriptionProvider.swift` — the protocol and factory. Add `AatishSTTProvider` as a new case, selected via `VoiceTranscriptionProvider` in Info.plist.
3. If his STT is streaming: wire partial results to the live waveform/transcript UI like AssemblyAI's websocket did. If batch-only: buffer on key-down, transcribe on key-up (the `OpenAIAudioTranscriptionProvider` is the pattern to copy — it already does buffer-and-upload).
4. Audio format: mic buffers arrive via `AVAudioEngine`; `BuddyAudioConversionSupport.swift` already converts to PCM16 mono and builds WAV — reuse it.
5. Set Apple Speech as automatic fallback if the custom provider fails to initialize.
6. Temporary logs: `STT_START`, `STT_PARTIAL <text>`, `STT_FINAL <text>`.

Exit criteria:

| # | Criterion | Check | Evidence |
|---|---|---|---|
| 3.1 | Builds clean | Xcode build | `phase-3/build.png` |
| 3.2 | Transcription accurate | Aatish speaks 5 scripted test phrases (include "a3b", "ProRes", "DaVinci Resolve"); logged STT_FINAL matches ≥ 4/5 word-for-word (proper nouns may vary) | `phase-3/transcripts.txt` |
| 3.3 | Fully offline voice | Wi-Fi off → push-to-talk still transcribes (logs show STT_FINAL); only the Claude call fails | `phase-3/offline-log.txt` |
| 3.4 | Fallback works | Force custom provider init failure → Apple Speech takes over, logged | `phase-3/fallback-log.txt` |
| 3.5 | No regression | Phase 2 end-to-end (2.3) still passes | `phase-3/regression.md` |

---

### Phase 4 — Privacy hardening + de-Farza

**Goal:** nothing leaves the machine except the Claude call. User always knows when a frame is captured.

Steps:

1. **Delete:** `worker/` directory, `ClickyAnalytics.swift` + all PostHog references, `ElevenLabsTTSClient.swift`, `AssemblyAIStreamingTranscriptionProvider.swift`, `OpenAIAPI.swift`, `OpenAIAudioTranscriptionProvider.swift`, appcast.xml (Sparkle update feed points at Farza's server). Remove dead Info.plist keys.
2. **Window-only capture mode.** `CompanionScreenCaptureUtility.swift` uses ScreenCaptureKit — add a mode capturing only the frontmost window (`SCContentFilter` with desktop-independent window) instead of full displays. Panel toggle: "Full screen / Active window only". Default: active window.
3. **Exclusion list.** Before capture, check frontmost app bundle ID against a blocklist (1Password, Bitwarden, Keychain Access, banking apps, Messages — user-editable array in a plist/JSON). If blocked: capture skipped, buddy says so, nothing sent.
4. **Capture indicator.** Buddy flashes a distinct color pulse the exact moment a screenshot is taken. Non-negotiable, not toggleable.
5. **Local audit log.** Every sent screenshot saved to `~/Library/Application Support/a3b-buddy/sent-frames/` with timestamp. Panel button: "Open sent-frames folder". Auto-prune > 30 days.

Exit criteria:

| # | Criterion | Check | Evidence |
|---|---|---|---|
| 4.1 | Zero third-party calls | `nettop -P -L 1` while doing a full interaction: connections only to Anthropic (via claude subprocess) and localhost | `phase-4/nettop.txt` |
| 4.2 | Deleted code gone | `grep -ri "posthog\|elevenlabs\|assemblyai\|workers.dev" clicky/ --include="*.swift" --include="*.plist" --include="*.ts"` → empty | `phase-4/grep.txt` |
| 4.3 | Window-only works | Two monitors / two windows open; ask buddy "what do you see" → answer references only frontmost window content | `phase-4/window-only.md` |
| 4.4 | Exclusion blocks | Open Keychain Access frontmost → push-to-talk → logs show CAPTURE_BLOCKED, no frame in sent-frames | `phase-4/blocked-log.txt` |
| 4.5 | Audit trail | After 3 interactions, sent-frames contains exactly 3 timestamped images (or fewer if blocked) | `phase-4/ls-frames.txt` |
| 4.6 | Indicator fires | Screen recording of interaction shows flash at capture moment | `phase-4/indicator.mov` |

---

### Phase 5 — a3b rebrand + polish

**Goal:** it looks like an a3b product, not a Clicky clone. This is where Aatish leads and Claude Code assists.

Steps:

1. Fill in brand constants (§4) from the a3b brand brief. Export exact logo PNG at 1x/2x into `assets/`.
2. Rebrand `DesignSystem.swift` (`DS.Colors` etc.) to a3b palette. All UI reads from DS tokens already — change tokens, not views.
3. Replace the blue cursor buddy with an a3b-designed companion (Aatish designs the asset/animation; Claude Code wires it in). Buddy states to design: idle, listening, thinking, speaking, pointing, capture-flash.
4. Panel: a3b logo centered in header, brand type if licensing allows bundling.
5. Rename user-facing strings to a3b-buddy (bundle display name only — NOT the scheme/directory, per upstream warning).
6. MIT attribution: keep Farza's LICENSE, add NOTICE crediting Clicky.

Exit criteria (the ones Aatish asked for, exactly):

| # | Criterion | Check | Evidence |
|---|---|---|---|
| 5.1 | Logo centered | Panel screenshot cropped to header → `verify_visual.py center header.png 0.5 0.5 4` exits 0 | `phase-5/logo-center.txt` |
| 5.2 | Logo is the exact asset | `verify_visual.py present panel.png assets/a3b-logo.png 0.9` exits 0 | `phase-5/logo-match.txt` |
| 5.3 | Colors match brand | Sample 5 defined points (panel bg, accent button, buddy body, text, header) → each `verify_visual.py color ... <brand_hex> 8` exits 0. All 5 must pass — 4/5 is a FAIL, fix and re-loop | `phase-5/colors.txt` |
| 5.4 | All buddy states render | Screenshot each of the 6 states, visually distinct (different template-match against each other < 0.95 confidence) | `phase-5/states/*.png` |
| 5.5 | No Clicky branding visible | grep UI strings + screenshot review: no "Clicky" user-facing | `phase-5/branding.txt` |
| 5.6 | Full regression | Phases 1–4 key criteria re-run (1.2, 2.3, 2.4, 3.2, 4.1, 4.4) | `phase-5/regression.md` |

---

## 6. Feature verification template (for everything after the fork)

Every new feature request gets this treatment before work starts:

```
FEATURE: <name>
ACCEPTANCE CRITERIA (write BEFORE coding, each one machine-checkable):
  - AC1: <observable behavior> — verified by <command / script / screenshot check>
  - AC2: ...
LOOP: implement → run all ACs → any fail: fix that failure, re-run → all pass: done.
STUCK RULE: same AC fails 3x → stop, report evidence, ask.
NEVER: mark done on "should work now". Evidence or it didn't happen.
```

---

## 7. Kickoff prompt (paste into Claude Code)

```
Read FORK-GUIDE.md in this directory, then clicky/CLAUDE.md.

We are executing the fork plan phase by phase. Rules:
- Follow the verification loop protocol in §3 strictly. Evidence into
  verification/phase-N/ for every exit criterion. No evidence = not done.
- Never run xcodebuild against the app target from the terminal (TCC).
  When a build is needed, ask me to Cmd+R in Xcode and report the result.
- One phase per branch. Commit only when all exit criteria pass.
- Follow clicky/CLAUDE.md code conventions exactly.

Start with Phase 0.
```

---

## 8. Sources

- Clicky repo: https://github.com/farzaa/clicky (MIT)
- Clicky story/stack: https://www.tbpndigest.com/story/2026-06-10/hey-clicky-founder-farza-majeed-built-a-voice-controlled-ai-desktop-agent-in-8-weeks-now-using-claude-4-by-default
- XDA hands-on: https://www.xda-developers.com/someone-built-tiny-ai-that-lives-next-to-your-cursor-the-most-useful-thing-ive-tried-this-year/
- Conductor (subscription-auth precedent): https://www.conductor.build/ · https://www.ycombinator.com/launches/OHk-conductor-run-a-bunch-of-claude-codes-in-parallel
- Claude Code headless/SDK docs: https://docs.claude.com/en/docs/claude-code
- Note: subscription auth is per-user. Personal use: fine. Distributing later: each user logs in with their own plan (Conductor's model).
