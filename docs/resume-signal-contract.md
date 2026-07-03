# Resume-Signal Contract (Quota-Block Layer 2 / Layer 3)

This document is the interface contract between the two halves of quota-block
recovery that are **not** implemented in this plugin:

- **Layer 2 (reset-time capture)** — external, non-LLM code (an inference
  proxy such as LiteLLM, or a harness wrapper process) that observes a
  quota-exhaustion API response, reads the reset timestamp, and writes the
  signal file described below.
- **Layer 3 (wait & relaunch)** — `scripts/pm-dashboard-loop.ps1
  -ResumeSupervisor`, which polls for the signal, waits until reset time
  (+ buffer), and surfaces a one-click resume.

Full design background: `docs/temp/Quota-Block-Resilience-Plan.md` (§2–§6).
This file documents only the **contract** so Layer 2 can be implemented
independently, in whatever proxy/wrapper a deployment uses, without needing
to read the whole plan.

## Why this exists

A hard quota block (an HTTP response carrying a known future reset time, as
opposed to a transient 429) ends an LLM session with **no further turns**.
Nothing that requires reasoning — deciding what to do, writing a manifest,
setting a status — can happen at block time. So:

- The agent side (Layer 1, implemented in `agents/implementation-engineer.agent.md`)
  only ever writes durable state **during normal successful work** — one git
  commit + `tasks.md` `[X]` mark + status file per completed task, before the
  next task starts. There is no "I got blocked" write from the agent.
- The signal below is written entirely by code that observes the API
  response — never by an agent, never inferred from agent output.

## Signal file

**Default location:** `.specify/state/resume-signal.json`, relative to the
consumer repo root. (Configurable via `pm-dashboard-loop.ps1 -ResumeSignalPath`.)

```json
{
  "feature": "042-example-feature",
  "branch": "feature/042-example-feature",
  "reason": "blocked-quota",
  "reset_at": "2026-07-03T19:30:00Z",
  "created_at": "2026-07-03T14:30:00Z",
  "resume_command": "<harness-specific relaunch invocation>"
}
```

| Field | Type | Meaning |
|-------|------|---------|
| `feature` | string | Human-readable feature/effort name, for display only. |
| `branch` | string | The git branch the blocked run was working on. |
| `reason` | string | Always `"blocked-quota"` for this contract; reserved for future distinct reasons. |
| `reset_at` | string (ISO 8601, UTC, `Z` suffix) | When the quota window resets, as reported by the API/provider. |
| `created_at` | string (ISO 8601, UTC, `Z` suffix) | When Layer 2 observed the block and wrote this file. |
| `resume_command` | string | The exact harness-specific invocation to relaunch the run (e.g. a `claude -p "..."` headless invocation for V3, or a script-wrapper command for V2). |

**Deliberately absent:** `tasks_completed`, `task_in_flight`, or any other
progress field. Progress is never something the agent (or Layer 2) reports at
block time — it is always reconstructible from `tasks.md` `[X]` marks + `git
log` by the resuming session (Layer 2b, see below). Adding progress fields
here would be redundant at best and a source of drift at worst.

### Writer responsibilities (Layer 2 — not implemented in this plugin)

Whatever component sits in the call path (LiteLLM proxy hook, or the harness
wrapper process that launched the LLM run) is responsible for:

1. Distinguishing a **hard quota block** (carries a reset timestamp) from a
   **transient 429** (short/implicit backoff — retried by the harness as
   today; must NOT write this file).
2. Writing the JSON file above, atomically (temp file + rename), the moment
   the block is detected.
3. Attributing the block to the correct `feature` / `branch` — typically via
   whatever session/attribution context the proxy already tracks (e.g. the
   token-tracker session, if running).

### Reader responsibilities (Layer 3 — implemented here)

`scripts/pm-dashboard-loop.ps1 -ResumeSupervisor`:

1. Polls for the signal file (absence is the normal, expected state).
2. Once present, sleeps until `reset_at` + `-ResumeBufferSeconds` (default
   120s — clock skew / quota-release lag buffer, open item from the
   resilience plan §9) has elapsed.
3. Writes `.github/status/resume-ready.json` (default location, configurable
   via `-ResumeReadyFile`) containing the same fields plus `surfaced_at`, and
   prints a console banner with the `resume_command`.
4. Optionally (`-ResumeOpenRepo`) best-effort opens the repo in VS Code
   (`code <repo>`) so a human has a one-click path back in. Never fatal if
   `code` isn't on PATH.
5. Never relaunches the LLM itself. Actually invoking `resume_command` is
   either a scheduled headless invocation (V3 — see the resilience plan §6)
   or a human clicking through the surfaced notification (V2).

Run example:

```powershell
pwsh -NoProfile -File scripts/pm-dashboard-loop.ps1 `
  -ResumeSupervisor `
  -RepoRoot "C:\code\myproject" `
  -ResumeOpenRepo
```

## Resume behavior on relaunch (Layer 2b — implemented in `implementation-engineer.agent.md`)

Whatever relaunches the run (scheduled headless invocation, or a human
running `resume_command`) re-enters a fresh session with quota restored. The
very first thing `implementation-engineer` does — unconditionally, on every
launch, not just after a suspected block — is:

1. `git reset --hard` to the last clean commit (discards any partial,
   uncommitted work from a task that was interrupted before its Layer 1
   atomic commit landed).
2. Read `tasks.md` and resume from the first non-`[X]` task.

This is idempotent and git-anchored: safe to run whether or not a block
actually occurred, and safe to run more than once if the resume-ready signal
fires twice. See `agents/implementation-engineer.agent.md` → *Resilience
Protocol* for the full agent-side text.

## What this plugin does NOT implement

Per the resilience plan's scope split, this plugin ships Layer 1
(durability), Layer 2b (resume behavior), and Layer 3 (the wait/relaunch
supervisor script). It does **not** ship:

- The inference proxy or harness wrapper that detects the block and writes
  `resume-signal.json` (Layer 2) — that lives in your deployment's LiteLLM
  proxy configuration or launch wrapper, outside this repo.
- Any change to `speckit.implement` or other SpecKit-defined agents — SpecKit
  stays untouched; `implementation-engineer` wraps and scopes it via
  `$ARGUMENTS`, never patches it.
