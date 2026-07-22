# Act 2 — Design: Live 3-Agent Parallel Role-Play

> Audience: IT Head, Architect, Project Managers.
> Source of truth: real opencode session transcripts captured from the 3 workspaces
> (`docs/demo/captures/iss{501,502,504}_final.jsonl`), replayed with the same
> method as Act 1.

---

## 1. The story Act 2 tells

Act 1 showed **one** issue going through the *pipeline* (discover → build → mask → image → env).
Act 2 shows **three** issues going through the *agent* simultaneously — the moment
the pipeline pays off: a human files a bug, and three autonomous agents light up
in parallel, each exploring, diagnosing, fixing, and opening a PR, with **no human
in the loop** until review.

The beat the audience must walk away with:
> *"One PM opened three GitHub issues. Three workspaces came up on their own.
> Three agents read the bug, explored the code, wrote a fix, and opened PRs —
> all at the same time, on isolated copies of a real (masked) production DB.
> A BA then tested all three fixes live. Total hands-on time for the team: ~2 minutes."*

---

## 2. The three scenarios (real issues, real transcripts)

| Column | Issue | Title | Role-play hat | Transcript | Outcome |
|---|---|---|---|---|---|
| A | **#501** | participant transfer: single transfer cancels whole group | **Dev** | `iss501_final.jsonl` (422 rec, 4 sessions) | PR #505 opened |
| B | **#502** | Google Calendar resync issue | **BA** | `iss502_final.jsonl` (171 rec, 3 sessions) | explored, diagnosed |
| C | **#504** | Financial entity enforcing (zero-amount) | **Tech Lead** | `iss504_final.jsonl` (69 rec, 2 sessions) | brainstormed, explored |

All three are **real** GitHub issues in `IshaFoundationIT/prs-backend`, driven by
the real webhook → `issue_to_env` → Coder → opencode pipeline fixed earlier this
session. The transcripts are the actual opencode SQLite session history extracted
from each workspace — not dramatized.

> Honest framing for the audience: #501 reached a merged-ready PR; #502 and #504
> reached the explore/diagnose phase (the 1h wall-clock cap is the cost guard).
> This is the **real** shape of autonomous agent runs — some finish, some need a
> second pass — and we show it as-is. The replay makes the *process* legible
> regardless of outcome.

---

## 3. The role-play frame

The presenter (you) plays **PM**. Three audience volunteers sit at the front:

- **BA** (column B) — owns the acceptance test for #502's feature.
- **Dev** (column A) — owns the code fix for #501.
- **Tech Lead** (column C) — owns the architecture call for #504.

The role-play is **on-rails**: each volunteer presses one button per beat and
reads a cue card. The agent transcript does the actual "work" on screen. The
volunteer is the *human face* of that column, not the one typing code.

---

## 4. Stage view — 3 columns, top → bottom timeline

Single screen, three equal columns (A | B | C), each a vertical terminal that
replays one agent's transcript. A shared beat-rail across the top shows where
all three agents are in the unified phase model. A global timer counts up.

```
┌─────────────────────────────────────────────────────────────────────┐
│  odoo-synth  ACT 2 · 3 AGENTS IN PARALLEL   ⏱ 00:42   [▶ Play] [⏸]  │
│  ● BOOT  ● EXPLORE  ○ DIAGNOSE  ○ FIX  ○ VERIFY  ○ PR              │ ← beat rail
├───────────────────┬───────────────────┬───────────────────────────────┤
│ A · #501  Dev     │ B · #502  BA      │ C · #504  Tech Lead          │
│ iss-501 ws        │ iss-502 ws        │ iss-504 ws                   │
│ ▌ read CONTEXT   │ ▌ read CONTEXT   │ ▌ read CONTEXT              │
│ ▌ skill sys-debug │ ▌ skill brainstorm│ ▌ skill brainstorm          │
│ ▌ todo: 6 phases │ ▌ grep calendar   │ ▌ todo: 4 phases            │
│ ▌ @explore ×3    │ ▌ @explore ×2    │ ▌ @explore ×1               │
│ ▌ grep transfer.. │ ▌ read sync.py   │ ▌ grep financial_entity..   │
│   …               │   …               │   …                          │
│ [▶ Continue]      │ [▶ Continue]      │ [▶ Continue]                 │
└───────────────────┴───────────────────┴───────────────────────────────┘
```

### 4.1 Unified beat model (the 6 phases)

Derived from the agents' **own `todowrite` plans** in the transcripts (so it's
real, not invented):

| # | Beat | What the audience sees | Map to transcript |
|---|---|---|---|
| 1 | **BOOT** | workspace comes up; agent reads `AGENT_CONTEXT.md` + `AGENT.md` | `read` of AGENT_CONTEXT, session-start |
| 2 | **EXPLORE** | agent invokes a skill (systematic-debugging / brainstorming), writes its phase plan, dispatches `@explore` subagents | `skill` + `todowrite` + `task` (subagent) sessions |
| 3 | **DIAGNOSE** | agent greps & reads the real addon code, reasons about root cause | `grep` + `read` + `reasoning` parts in build session |
| 4 | **FIX** | agent edits the model file(s) | `edit`/`str_replace`/`write` tool calls |
| 5 | **VERIFY** | agent restarts Odoo, runs the test / chrome-shot | `bash` (odoo restart, pytest, chrome-shot) |
| 6 | **PR** | agent commits, pushes, opens PR via `gh` | `bash` (`git commit`, `gh pr create`) + final text with PR URL |

Each beat's content is pulled straight from the JSONL records of that type.
Beats 4–6 are present in #501 (reaches PR); #502/#504 visibly stop at beat 2–3
(the rail shows them "waiting" / "needs second pass" — honest).

### 4.2 Per-column pacing (pause-after-each-beat, like Act 1)

Same control philosophy as Act 1: **the presenter drives the pace.**
- Each column has its own **▶ Continue** button (the volunteer presses it).
- A global **Play All** auto-advances all three in lockstep for the climax.
- Speed control (1.6× / 1× / 0.6×) like Act 1.
- When a column finishes its transcript, it shows a **terminal card** with the
  real outcome: ✅ PR #505 (A), 🔍 diagnosed, ready for fix pass (B), 🧠
  brainstormed, awaiting approval (C).

---

## 5. Replay engine — same method as Act 1

Act 1 replayed `discover/build/mask` log lines into a terminal typewriter.
Act 2 replays **opencode session JSONL** into three terminals, but the renderer
is the same primitive: a queue of typed lines with delay + color classes.

### 5.1 Transcript → typed lines transform

For each column, we pre-process its `issNNN_final.jsonl` into an ordered list of
**render lines**, one per meaningful record, grouped by beat:

```
line = {
  beat:   1..6,                 // from a beat classifier (see 5.2)
  cls:    'prompt'|'ok'|'info'|'mut'|'tool'|'reason'|'warn',
  text:   "read  prs/models/event_registration.py",
  delay:  ms                    // per-line typing delay
}
```

Mapping (record → render line):
- `session-start` (build)  → `info` "● session: Fix participant transfer bug #501"
- `session-start` (explore)→ `mut` "  └ @explore subagent: Explore transfer code in PRS"
- `text` (role=user)       → `prompt` the task (shown once at BOOT)
- `text` (role=assistant)  → `ok` the assistant's narration (truncated to ~1 line)
- `reasoning`              → `reason` (dim, italic) the agent's thinking
- `tool: read/grep/glob`   → `tool` "read  <path>" / "grep  <pattern>"
- `tool: task`             → `info` "→ @explore subagent dispatched"
- `tool: skill`            → `info` "✦ skill: systematic-debugging"
- `tool: todowrite`        → `ok` "☐ plan: 6 phases written" (render the phases as a mini checklist)
- `tool: edit/str_replace` → `ok` "edit  <path>  (+12 −3)"
- `tool: bash`             → `tool` "$ <command>" + first line of output
- `step-finish` with PR    → `ok` "✅ PR #505 opened: fix/participant-transfer-…"

### 5.2 Beat classifier

A record's beat is inferred from its tool + position:
- BOOT: records before the first `skill`/`todowrite`
- EXPLORE: from `skill`/`todowrite` through the last `task` (subagent dispatch)
- DIAGNOSE: `grep`/`read`/`reasoning` in the build session after subagents return
- FIX: first `edit`/`write`/`str_replace`
- VERIFY: `bash` containing `odoo`/`pytest`/`chrome`
- PR: `bash` containing `git commit`/`gh pr create`, or text with a PR URL

This is deterministic and runs once at load; the result is a per-column
`{beat, lines[]}` array the renderer consumes.

---

## 6. The climax — live BA test (real, not replayed)

After all three columns reach their outcome card, the screen transitions to the
**live test** phase (this part is genuinely live, like Act 1's live env create):

1. The BA volunteer opens the three real Odoo env URLs (from the env store) in
   the browser — the same masked-prod-DB workspaces the agents ran in.
2. BA walks the one acceptance script (§7) against #501's fix live.
3. The PR diff (#505) is shown side-by-side on screen as the "what the agent
   changed" reveal.

> This is the only live-risk moment in Act 2. Fallback: a pre-recorded
> chrome-shot of the same test passing, cued if the live env is slow.

---

## 7. BA acceptance script (for #501, the PR-completed one)

Single scenario, ~90 seconds, reads from a cue card:

1. Log in to the #501 env (admin / [from AGENT_CONTEXT]).
2. Group Registrations → open a group booking with 3 siblings (A, B, C).
3. Transfer participant A to a new target.
4. **Assert:** only A is cancelled; B and C stay confirmed. (The bug cancelled all three.)
5. **Assert:** target A has a Sale Order even for zero amount. (The bug skipped SO creation.)
6. Pass ✅.

#502 and #504 acceptance is lighter (BA confirms the *symptom* is understood
from the agent's diagnosis card; full test deferred to the fix pass).

---

## 8. Reliability — on-rails + fallback

- **On-rails:** the replay is deterministic (typed lines from JSONL). No live
  agent runs during the demo — the agents already ran; we replay them. Zero
  risk of an agent hang mid-demo.
- **Fallback clip:** a pre-recorded screencast of the full 3-column replay +
  live BA test, cued on `F` key, in case the page or network hiccups.
- **Live env fallback:** if the BA's live env is slow/unavailable, switch to
  the pre-recorded chrome-shot of the same acceptance script passing.

---

## 9. Cue cards (presenter + 3 volunteers)

**Presenter (PM):**
- Act 2 open: "Three issues. Three workspaces. Three agents. No waiting in a queue."
- Beat 1 (BOOT): "All three read their assignment. Same context file, same masked DB."
- Beat 2 (EXPLORE): "They don't guess — they plan, then dispatch explorer subagents."
- Beat 3 (DIAGNOSE): "Now they're reading *our actual code*. Look at the grep paths."
- Beat 6 (PR) / outcome: "Column A opened PR #505. B and C diagnosed and are ready for a fix pass — that's the real shape of autonomous work."
- Climax: "BA, please test A's fix live."

**Dev (col A):** presses Continue after each beat; at FIX, says one line: "It edited `event_registration.py` — the partial-cancel invariant."
**BA (col B):** presses Continue; at climax, runs the §7 script.
**Tech Lead (col C):** presses Continue; at EXPLOSE, notes: "It used the brainstorming skill before touching code."

---

## 10. File plan

| File | Purpose | Status |
|---|---|---|
| `docs/demo/act2.html` | the 3-column stage view + replay engine | **to build** |
| `docs/demo/captures/iss{501,502,504}_final.jsonl` | replay source (real) | ✅ captured |
| `docs/demo/captures/extract_opencode_session.py` | DB → JSONL extractor | ✅ done |
| `docs/demo/captures/act2_bake.py` | JSONL → render-lines + beat classifier (§5) | **to build** |
| `docs/demo/captures/iss{501,502,504}.json` | baked render-lines per column | **to build** |
| `docs/demo/act2_fallback.mp4` | director's-cut screencast | **to record** |

---

## 11. Build order

1. **`act2_bake.py`** — read the 3 `_final.jsonl`, classify beats, emit 3
   compact `issNNN.json` render-line files (drop tool outputs to keep size sane).
2. **`act2.html`** — 3-column shell: beat rail, 3 terminals, per-column Continue,
   global Play/speed, outcome cards. Same CSS tokens as `act1.html`.
3. **Wire the replay engine** to the baked JSON (queue + typewriter, reused from
   Act 1's renderer).
4. **Live-test transition** — env-URL panel + PR-diff iframe for #505.
5. **Record fallback clip** once the page is polished.
6. **Pre-show checklist** (envs up, transcripts baked, fallback cued, BA script printed).

---

## 12. What's intentionally NOT shown

- The `-u all` upgrade step — removed entirely (per decision).
- Agent failures/timeout as "bugs" — framed honestly as the real shape of
  autonomous runs; the pipeline re-runs cleanly on reopen.
- Merge — we never merge during the demo (PRs stay open for review).
