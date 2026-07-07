# a3b-buddy — Multi-Agent Orchestration Plan

Companion to `FORK-GUIDE.md` (which holds the full phase details and exit criteria — this file only assigns WHO does WHAT, in what order, and how they avoid stepping on each other). Conductor-style: each agent runs in its own isolated git worktree, works its assignment, and results are reviewed and merged in a fixed order.

Agents: **FABLE-1**, **FABLE-2** (Claude Fable 5 — via Claude Code, Max subscription), **GPT-1**, **GPT-2** (GPT 5.5 — via Codex CLI, ChatGPT subscription).

---

## 1. Roster and ownership

| Agent | Role | Owns (exclusive write access) | Phases |
|---|---|---|---|
| **FABLE-1** | Foreman + Brain | `CompanionManager.swift`, `ClaudeAPI.swift` → `SubscriptionClaudeProvider`, `leanring_buddyApp.swift`, merges | Phase 0, Phase 2, all integration reviews |
| **FABLE-2** | Voice | `BuddyTTSProvider` (new), `AppleSpeechTTSProvider` (new), `AatishSTTProvider` (new), `BuddyTranscriptionProvider.swift`, `BuddyDictationManager.swift`, `BuddyAudioConversionSupport.swift` | Phase 1, Phase 3 |
| **GPT-1** | Privacy + Infra | `CompanionScreenCaptureUtility.swift`, exclusion-list module (new), audit-log module (new), deletions list, `scripts/` | Phase 4 |
| **GPT-2** | Brand + QA | `DesignSystem.swift`, `CompanionPanelView.swift`, `OverlayWindow.swift` buddy visuals, `assets/`, `verification/` audits | Phase 5, continuous QA |

**Hard rule — the CompanionManager bottleneck.** `CompanionManager.swift` is the central state machine and every phase touches it. Only FABLE-1 edits it. All other agents write their code behind a protocol, then file a **wiring request**: a short spec in `verification/wiring-requests/<agent>-<feature>.md` saying "call my `X` here instead of `Y`, signature is `Z`." FABLE-1 applies wiring requests during merge. This kills 90% of merge conflicts before they exist.

**Worktrees.** One per agent, Conductor-style:

```
git worktree add ../a3b-fable1 feature/brain
git worktree add ../a3b-fable2 feature/voice
git worktree add ../a3b-gpt1   feature/privacy
git worktree add ../a3b-gpt2   feature/brand
```

---

## 2. Waves (what runs in parallel, what blocks what)

```
WAVE 0  (sequential — everyone blocked until done)
  FABLE-1: Phase 0 — stock build runs, verify script in place
      │
WAVE 1  (parallel ─ 4 agents at once)
  FABLE-1: Phase 2 prototype — prove `claude -p` + screenshot + POINT tag
           OUTSIDE the app first (§Phase 2 step 1). Then Swift transport.
  FABLE-2: Phase 1 — TTS provider protocol + AppleSpeechTTSProvider.
           Files wiring request; does NOT touch CompanionManager.
  GPT-1:   Phase 4 prep (non-code) — full deletion audit (every PostHog/
           ElevenLabs/AssemblyAI/Worker reference, file+line), blocklist
           design, audit-log design. Output: phase-4-plan.md. Plus: build
           the nettop/grep verification scripts in scripts/.
  GPT-2:   QA scaffolding — test verify_visual.py against real screenshots,
           write regression-runner checklist, prep brand asset specs
           (waits on Aatish for hexes + logo export).
      │
MERGE 1 (FABLE-1 merges, in this order: Phase 1 → Phase 2)
  After each merge: GPT-2 runs regression per FORK-GUIDE exit criteria.
      │
WAVE 2  (parallel ─ 3 lanes)
  FABLE-2: Phase 3 — AatishSTTProvider (needs Aatish's STT project path).
  GPT-1:   Phase 4 execution — deletions, window-only capture, exclusion
           list, capture indicator*, audit log.
           *indicator visual = buddy flash: implement hook + placeholder,
            GPT-2 designs final flash in Phase 5.
  GPT-2:   Phase 5 groundwork — DS token swap to a3b palette, asset
           integration, buddy state designs (Aatish supplies designs).
      │
MERGE 2 (FABLE-1: Phase 3 → Phase 4)
      │
WAVE 3  (single lane + review)
  GPT-2:   Phase 5 final — logo centering, color verification loops,
           buddy states, de-Clicky branding pass.
  FABLE-1: reviews everything, runs full-regression list (5.6).
      │
MERGE 3 → main. Ship v0.1 to Aatish.
```

Anything in the same wave may run simultaneously. An agent never starts a phase whose upstream merge hasn't landed.

---

## 3. Rules binding ALL agents

1. **Verification loop is law.** Every task follows FORK-GUIDE §3: DO → VERIFY against the exit-criteria table → fix the specific failure → re-verify. Max 5 iterations; same criterion failing 3× → STOP and report. Evidence in `verification/phase-N/` or it didn't happen. Never declare done from reasoning — only from evidence (screenshot, pixel-check exit code, log line, grep output).
2. **Never run `xcodebuild` against the app target from a terminal** (TCC permission wipe — see FORK-GUIDE §3). Builds happen via Aatish pressing Cmd+R; agents request a build and wait for the result.
3. **Stay in your lane.** Only touch files you own (§1 table). Need a change in someone else's file → wiring request, not an edit.
4. **Follow `clicky/CLAUDE.md` conventions** — long clear names, clarity over cleverness, don't fix the known warnings, don't rename the leanring typo.
5. **Commit format:** `[<AGENT>][phase-N] <what>` — e.g. `[FABLE-2][phase-1] Add AppleSpeechTTSProvider behind BuddyTTSProvider protocol`.
6. **Status file.** Each agent maintains `verification/status/<agent>.md`: current task, blocked-on, last evidence produced. Aatish reads these instead of asking around.

---

## 4. Per-agent kickoff prompts

### FABLE-1 (paste into Claude Code, worktree `a3b-fable1`)

```
You are FABLE-1, foreman and brain-swap owner for the a3b-buddy project.
Read AGENT-PLAN.md, then FORK-GUIDE.md, then clicky/CLAUDE.md.

Your assignments: Phase 0 now; Phase 2 in Wave 1; you apply all wiring
requests and perform all merges in the order defined in AGENT-PLAN §2.

You are the ONLY agent allowed to edit CompanionManager.swift.

Follow the verification loop protocol (FORK-GUIDE §3) strictly — evidence
into verification/phase-N/, never claim done without it. Never run
xcodebuild from the terminal; ask Aatish to Cmd+R and report.

Start Phase 0.
```

### FABLE-2 (paste into Claude Code, worktree `a3b-fable2`)

```
You are FABLE-2, voice owner for the a3b-buddy project.
Read AGENT-PLAN.md, then FORK-GUIDE.md, then clicky/CLAUDE.md.

Your assignments: Phase 1 (TTS swap) in Wave 1, Phase 3 (STT swap —
Aatish's own STT project) in Wave 2. You own the provider/dictation
files listed in AGENT-PLAN §1 and nothing else. Any change needed in
CompanionManager.swift goes into a wiring request at
verification/wiring-requests/fable2-<feature>.md.

Verification loop per FORK-GUIDE §3. Audio checks = log evidence
(TTS_START/TTS_END, STT_FINAL) plus Aatish's audible confirmation.
No terminal xcodebuild.

Wait for FABLE-1 to complete Phase 0, then start Phase 1.
```

### GPT-1 (paste into Codex CLI, worktree `a3b-gpt1`)

```
You are GPT-1, privacy and infrastructure owner for the a3b-buddy project.
Read AGENT-PLAN.md, then FORK-GUIDE.md, then clicky/CLAUDE.md.

Wave 1 (start after Phase 0 merges): NON-CODE prep only —
1. Deletion audit: every reference to PostHog, ElevenLabs, AssemblyAI,
   OpenAI API, Cloudflare Worker, Sparkle appcast across the repo,
   as file+line list in verification/phase-4/deletion-audit.md.
2. Design docs: exclusion blocklist format, audit-log layout.
3. Build verification tooling in scripts/: network-check script wrapping
   nettop, grep-based key/branding scanners.

Wave 2: execute Phase 4 per FORK-GUIDE — deletions, window-only
ScreenCaptureKit capture, exclusion list, capture-indicator hook,
sent-frames audit log.

You own CompanionScreenCaptureUtility.swift and the new privacy modules.
CompanionManager changes = wiring requests only. Verification loop per
FORK-GUIDE §3; evidence or it didn't happen. No terminal xcodebuild.
```

### GPT-2 (paste into Codex CLI, worktree `a3b-gpt2`)

```
You are GPT-2, brand and QA owner for the a3b-buddy project.
Read AGENT-PLAN.md, then FORK-GUIDE.md, then clicky/CLAUDE.md.

Continuous duty: after every merge FABLE-1 lands, run the regression
checks named in the merged phase's exit criteria and file results in
verification/regressions/. A failed regression blocks the next merge —
report it loudly in verification/status/gpt2.md.

Wave 1: test scripts/verify_visual.py against real screenshots, write
the regression-runner checklist, and prepare brand asset specs. Ask
Aatish for: a3b hex values (FORK-GUIDE §4 placeholders) and logo
exports at 1x/2x.

Wave 2–3: execute Phase 5 — DS token swap, logo centered (±4px,
verify_visual center), exact-logo template match, 5-point color
verification (ALL five must pass — 4/5 is a fail), six buddy states,
de-Clicky branding pass. Aatish designs; you wire and verify.

You own DesignSystem.swift, CompanionPanelView.swift, overlay visuals,
assets/. Verification loop per FORK-GUIDE §3. No terminal xcodebuild.
```

---

## 5. Aatish's touchpoints (the only human-blocking items)

| When | What only you can do |
|---|---|
| Wave 0 + every build check | Cmd+R in Xcode, report result / screenshot |
| Wave 1 | Give GPT-2 the a3b brand hexes + logo exports; confirm TTS audio audibly |
| Wave 2 | Give FABLE-2 your STT project path + interface description; speak the 5 test phrases; design buddy states + capture-flash |
| Every merge | Skim FABLE-1's merge summary; veto anything off-brand |

---

## 6. Failure and escalation

- Agent stuck (3× same failure): writes a STUCK report in its status file with evidence, stops. FABLE-1 triages — reassigns, descopes, or escalates to Aatish.
- Merge conflict despite lanes: FABLE-1 resolves; the agent whose code lost re-verifies its exit criteria on the merged result.
- Regression found by GPT-2: merge frozen, owning agent fixes forward in its worktree, re-merge.
- Disagreement between agents on approach: FABLE-1 decides; if it affects brand/UX, Aatish decides.
