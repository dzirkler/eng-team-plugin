# SDD Delegation Chart — Canonical Reference

> **Scope**: This chart is the canonical source of truth for *who delegates what* across the Spec-Driven Development stages. Every persona file references it. If a behavior in this chart conflicts with a persona agent file, THIS CHART WINS — open a PR to fix the persona file.

> **Last updated**: 2026-07-06 (realignment: constitution → project-scoped; provenance receipts mandatory)

---

## 1. SDD Stage → Owner → Subagent

| # | Stage | Owner persona | Generation delegated to | Artifact path | Scope |
|---|-------|---------------|-------------------------|---------------|-------|
| — | **Project Bootstrap** (one-time, not per-feature) | `product-manager` | `speckit.constitution` | `.specify/memory/constitution.md` | **project** |
| 1 | **Specify** | `product-manager` | `speckit.specify` | `specs/<NNN-slug>/spec.md` | feature |
| 2 | **Clarify** | `product-manager` (+ `ux-designer` for UX questions) | `speckit.clarify` | `specs/<NNN-slug>/clarifications.md` (answers folded into `spec.md`) | feature |
| 3 | **Design Brief** (UI features only) | `ux-designer` | (UX Designer authors directly — NOT an SDD speckit subagent) | `specs/<NNN-slug>/design-brief.md` | feature |
| 4 | **Plan** | `senior-engineer` | `speckit.plan` | `specs/<NNN-slug>/plan.md` (+ `research.md`, `data-model.md`, `contracts/`, `quickstart.md`) | feature |
| 5 | **Tasks** | `senior-engineer` | `speckit.tasks` | `specs/<NNN-slug>/tasks.md` | feature |
| 6 | **Analyze** | `product-manager` | `speckit.analyze` (+ PdM six-point codebase + provenance check) | `specs/<NNN-slug>/analyze-report.md` | feature |
| 7 | **Checklist** (pre-Checkpoint 2) | `quality-engineer` | `speckit.checklist` | `specs/<NNN-slug>/checklists/*.md` | feature |
| 8 | **Independent Review** | Orchestrator (loop) | `independent-reviewer` (leaf agent — findings only) | `specs/<NNN-slug>/review-log.md` | feature |
| 9 | **Implement** | `implementation-engineer` | `speckit.implement` | source tree (per-task atomic commits) | feature |

> **Stage removed from this project: `speckit.taskstoissues`.** Not used. Task tracking lives in `tasks.md` `[X]` marks + PM dashboard + the draft PR. The subagent definition is retained at `agents/speckit/taskstoissues.agent.md` for spec-kit framework compatibility but is not part of the workflow. Owner decision 2026-07-07.

### HITL Checkpoints (pause points in the workflow)

| Checkpoint | When | Required approvals |
|------------|------|---------------------|
| **Checkpoint 1** | After Stage 2 (Clarify) | Human approver answers clarification questions |
| **Checkpoint 2** | After Stage 8 (Independent Review) | Human approver signs off on spec/plan/tasks/analyze/review-log |
| **Checkpoint 3** | After Stage 10 + Retrospective | Human approver signs off on implementation, QE verdict, retrospective |

---

## 2. The Two-Hop Rule

Every SDD generation artifact flows through a persona gate:

```
Orchestrator → Persona (owns gate) → speckit subagent (generates artifact)
```

- **Persona owns the gate**: feasibility review, coverage check, six-point codebase + provenance check, presentation to human approver. The persona reviews the subagent's output and either accepts or re-dispatches with sharper instructions.
- **Subagent owns generation**: runs the speckit template resolution pipeline, fills placeholders, validates output. NEVER the persona.
- **Persona NEVER writes the artifact itself** to "save a step" — that collapses the gate.
- **Persona NEVER accepts a subagent artifact unseen** — that also collapses the gate.
- **No chain-on**: speckit subagents declare `handoffs:` to siblings in their own files; the persona intercepts and re-dispatches through its gate rather than letting the subagent drive the whole chain.

If the persona cannot get a clean artifact from the subagent, it re-dispatches with sharper instructions or escalates to the orchestrator.

---

## 3. Project-Bootstrap Rule (Constitution)

Constitution is **NOT a per-feature stage**. It is a one-time project-bootstrap.

### When to run `speckit.constitution`

1. First SDD kickoff to a repository that has no `.specify/memory/constitution.md`.
2. Owner-approved governance amendment (rare — typically a separate governance PR).

### When NOT to run it

- **Never inside a feature branch**.
- **Never silently as part of Bracket 1**. If a feature's work surfaces a constitutional concern, the agent must surface it to the owner at the next HITL checkpoint — not unilaterally rewrite the constitution.
- **Never to "fix" a perceived principle violation** spotted mid-feature. File it as a findings item, escalate separately.

### Spotting per-feature constitution abuse (orchestrator + independent-reviewer)

If Stage 7 analyze or Stage 8 independent review notes that `.specify/memory/constitution.md` was rewritten as part of a feature branch (without an explicit owner-approved amendment PR), this is a CRITICAL process violation requiring rollback before Checkpoint 2.

---

## 4. Provenance Receipt (mandatory for all speckit-generated artifacts)

Every artifact produced by a `speckit.*` subagent MUST carry a provenance receipt. The orchestrator greps for it; absence means the stage did not run through speckit (hand-authored violation).

### Receipt format — HTML comment at artifact's first line

```markdown
<!-- speckit:stage=<STAGE> | persona=<PARENT_PERSONA> | spec=<NNN-slug> | generated_at=<ISO 8601 UTC> | cli_version=<specify --version or "subagent"> -->
```

| Field | Values |
|-------|--------|
| `stage` | `constitution` \| `specify` \| `clarify` \| `plan` \| `tasks` \| `analyze` \| `checklist` \| `implement` \| `taskstoissues` |
| `persona` | `product-manager` \| `senior-engineer` \| `implementation-engineer` \| `quality-engineer` \| `project-manager` \| `human` (if owner ran the slash command directly) |
| `spec` | `<NNN-slug>` for feature artifacts; `project` for constitution |
| `generated_at` | ISO 8601 with `Z` suffix |
| `cli_version` | `specify --version` output; `subagent` if unavailable |

### Sidecar ledger

`specs/<NNN-slug>/.speckit-provenance.json` accumulates one entry per stage execution:

```json
[
  {
    "stage": "specify",
    "persona": "product-manager",
    "spec": "029-essence-model",
    "generated_at": "2026-07-06T14:22:31Z",
    "cli_version": "0.12.5",
    "artifact_path": "specs/029-essence-model/spec.md"
  }
]
```

JSON array; append-only; atomic write (temp + rename).

### Orchestrator verification gate (mandatory)

Before accepting any persona's "stage complete" claim, the orchestrator MUST:

1. Read the first 3 lines of the artifact — confirm the receipt HTML comment is present.
2. Read the sidecar ledger — confirm an entry exists for this stage.
3. Cross-check that the receipt's `persona` field matches who was dispatched.
4. If ANY of the above fail: REJECT the stage. Re-dispatch the persona with explicit instruction to delegate to the speckit subagent. Failure on second try → escalate to owner for slash-command fallback.

Persona self-report is NOT sufficient. Past incidents (spec-028) have shown personas claiming stages complete while hand-authoring artifacts. The receipt is the ground truth; the persona is self-report.

---

## 5. Fallback on speckit subagent freeze/failure

If a `speckit.*` subagent dispatch freezes or fails:

1. Persona reports the freeze to orchestrator with the subagent's last output.
2. Orchestrator confirms the freeze is real (not just slow). One retry with sharper instructions is acceptable.
3. If retry fails: **escalate to owner** — never authorize the persona to hand-author, never hand-author itself.
4. Owner runs `/speckit.<stage>` directly in a fresh IDE session. The resulting artifact carries a receipt marker; orchestrator commits it.
5. At NO POINT does persona or orchestrator hand-author the artifact.

**Forbidden dispatch language** (anti-pattern from spec-028):
- "If `speckit.plan` is unavailable or freezes, produce plan.md directly using the structure below."
- "If the subagent fails, hand-author the artifact using the template."

Past freeze history gives NO permission to bypass speckit. The slash-command fallback IS still speckit — just owner-side instead of subagent-side.

---

## 6. Persona refusal contract

Every persona owning a gate MUST refuse orchestrator dispatches that instruct hand-authoring. The refusal message format is codified in each persona's `.agent.md` under `## Forbidden: Hand-Authoring SDD Artifacts`. Personas do not comply with hand-author instructions — they push back and request a corrected dispatch or escalation.

---

## 7. Orchestration checkpoints — process-adherence line

At every HITL checkpoint presentation, the orchestrator prepends:

> Process adherence: ✅ N/N feature stages ran via speckit subagents. Provenance ledger: `<path>`. Constitution: project-scoped (`.specify/memory/constitution.md`), not run per-feature.

If the orchestrator cannot truthfully print that line, it halts and remediates BEFORE surfacing the checkpoint to the human approver.

---

## References

- [github/spec-kit README](https://github.com/github/spec-kit#-development-phases) — canonical SDD process (constitution created at project init, not per-feature)
- `agents/orchestrator.agent.md` → `## Project-Bootstrap Pre-Flight`, `## Forbidden: Hand-Authoring SDD Artifacts`, `### Provenance Verification`
- `agents/<persona>.agent.md` → per-persona `## Forbidden: Hand-Authoring SDD Artifacts` sections
- User memory: `direct-slash-command-is-legitimate-fallback.md` (spec-028 incident record)
