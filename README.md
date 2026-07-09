# SDD Engineering Team — Sync-distributed SDD team plugin

A reusable VS Code Agent plugin that ships a Spec-Driven Development (SDD)
engineering team: one orchestrator plus seven specialist personas (Product,
Project, Full-Stack Engineer, Quality Engineer, QA Analyst, Debugger, UX
Designer) and the 11-agent `speckit.*` SDD-generation pipeline.

> **Distribution model.** This plugin is **distributed via the
> `scripts/sync-agents.ps1` sync script**, not installed as a Claude-format
> plugin. Consumer repos end up with copies of the agents / skills / scripts
> / hooks under their own `.github/` tree, with model-tier placeholders
> resolved and hook paths expanded to absolute consumer-specific paths.
> The legacy `.claude-plugin/` manifest was removed 2026-07-08 when the team
> confirmed all consumers use the sync model and none enable Claude-plugin
> variable expansion in hook command execution (the `${CLAUDE_PLUGIN_ROOT}`
> token was silently failing to expand, producing `Cannot find module
> 'D:\scripts\...'` errors).

> **Relationship to Spec Kit:** This plugin **does not bundle** GitHub
> [Spec Kit](https://github.com/github/spec-kit). It ships:
> - the 7 persona agents (orchestrator, Engineer, PM, etc.)
> - 11 glue agent definitions (`speckit.specify`, `speckit.plan`, …) that
>   **call into** a separately-installed Spec Kit
> - a `spec-kit` skill documenting how agents discover/use the CLI
>
> To use the SDD workflow you must also, per consuming repo:
> 1. Install the `specify` CLI: `uv tool install specify-cli --from git+https://github.com/github/spec-kit.git`
> 2. Initialize the repo: `specify init . --ai claude` (creates `.specify/`,
>    `scripts/`, `templates/`)
>
> Without Spec Kit installed, the personas still work for non-SDD tasks
> (debugging, bug fixes, code review, browser validation). Only the
> `speckit.*` SDD-generation chain breaks (its step 1 calls
> `.specify/scripts/powershell/check-prerequisites.ps1`, which won't exist).

## Install (sync to consumer repo)

Clone this repo anywhere, then run the sync script against each consuming
repo. Model-tier placeholders get resolved per-consumer at sync time:

```powershell
pwsh -File <this-repo>/scripts/sync-agents.ps1 `
  -TargetRoot "D:\code\<consumer-repo>" `
  -ProjectTag "<consumer-tag>" `
  -FlagshipModel "<flagship picker name> (customendpoint)" `
  -CheapModel "<cheap picker name> (customendpoint)" `
  -IncludeHooks
```

`-IncludeHooks` auto-enables `-IncludeScripts` (every hook invokes a node
script under `.github/scripts/`). Other optional switches:
`-IncludeSpeckit` (11 speckit glue agents), `-IncludeSkills`, `-IncludeMcp`.

The consuming repo ends up with:
- `.github/agents/*.agent.md` — 8 personas with model placeholders resolved
- `.github/agents/speckit/*.agent.md` — 11 pipeline agents (if `-IncludeSpeckit`)
- `.github/hooks/hooks.json` — guard hooks with `{{SCRIPTS_DIR}}` expanded
- `.github/scripts/*.js`, `*.ps1` — guard scripts + dashboard (sync'd as-is)
- `.github/skills/` — skills (if `-IncludeSkills`)
- `.mcp.json` — MCP config (if `-IncludeMcp`)

Idempotent: re-running over an existing sync overwrites with fresh source.

## Bundle layout

See *Install (sync to consumer repo)* above for distribution. Source layout:

| Path | Contents |
|------|----------|
| `agents/` | 8 persona agents (`*.agent.md`) + `speckit/` subdir with 11 pipeline agents |
| `skills/` | 14 markdown skills (one `SKILL.md` per directory) |
| `hooks/hooks.json` | Runtime guardrail hooks — paths use the `{{SCRIPTS_DIR}}` token, expanded at sync time (`-IncludeHooks`) to the consumer's absolute `.github/scripts/` dir. See *Two-Layer Receipt Enforcement* below. |
| `.mcp.json` | MCP server config (zai-vision, zai-web-search, playwright) |
| `scripts/` | Helper scripts (`no-op-guard.js`, `speckit-receipt-guard.js`, `pm-dashboard-loop.ps1`, `.Tests.ps1`, `sync-agents.ps1`) |

## Two-Layer Receipt Enforcement (spec-028 hardening)

This plugin enforces the speckit-provenance discipline at TWO layers — the
cognitive layer (persona + orchestrator judgement) is the outer defenence;
the runtime layer (PreToolUse hook) is the inner safety net. Spec-028 showed
that the cognitive layer alone is unreliable: a frozen subagent dispatch + a
well-intentioned persona + a permissive orchestrator produced hand-authored
artifacts indistinguishable from real speckit output and required full
Bracket 1+2 rollback.

**Outer layer (cognitive):** every persona with SDD-stage ownership (`PdM`,
`senior-engineer`, `quality-engineer`, `implementation-engineer`) carries a
refuse-and-escalate clause telling it to NEVER hand-author a speckit
artifact, even if the orchestrator authorizes it. The orchestrator then
verifies the receipt marker on every accepted artifact before recording a
stage complete (see `orchestrator.agent.md` → *Provenance Verification*).

**Inner layer (runtime):** `scripts/speckit-receipt-guard.js` runs at
`PreToolUse` on `edit|write` against any path matching `specs/*/<artifact>`
where `<artifact>` ∈ {`spec.md`, `clarifications.md`, `analyze-report.md`,
`plan.md`, `tasks.md`, `research.md`, `data-model.md`, `quickstart.md`,
`review-log.md`}. If the new file content does not begin with a valid
`<!-- speckit:stage=... -->` receipt line, the write is blocked with exit 2
and the deny reason directs the persona to the legitimate fallback path.
`design-brief.md` is excluded — UX Designer produces that one directly.

**Revision protocol:** legitimate in-place edits to an already-receipted
artifact (e.g. folding in independent-reviewer findings) keep the receipt
line at head-of-file with an updated `generated_at`, and append a new entry
to `<feature_dir>/.speckit-provenance.json` (with an optional `reason`
field). See `orchestrator.agent.md` → *Revision Receipts*.

To debug the guard, set `SDD_GUARD_DEBUG=1` and read `.sdd-guard.log` in the
plugin root.

## Optional integrations

### Token-tracker MCP (optional)

The orchestrator persona references a `token-tracker` MCP service that
records LLM token spend per feature/branch-gated effort against an
engineer-hour estimate (a tokens-per-engineer-hour ROI metric). This is
**entirely optional**. If you do not run a `token-tracker` MCP server in
your deployment:

- The plugin works without it. When `SDD_TEAM_ID` is unset OR the
  `token-tracker` MCP tools aren't registered, the orchestrator skips
  all `current_session` / `start_session` / `close_session` calls. No
  other capability depends on them.
- To enable attribution, set `SDD_TEAM_ID` in your `.vscode/settings.json`
  (or user settings.json for cross-repo use):
  ```jsonc
  "terminal.integrated.env.windows": { "SDD_TEAM_ID": "your-team-name" }
  ```
  The orchestrator reads this env var at every token-tracker call. No
  hardcoded team ID anywhere in the plugin.
- The `.mcp.json` shipped with this plugin is a stub; you may edit/replace
  it with your own MCP server config.

### Vision MCP (optional)

The `vision-mcp` skill assumes a configured image-understanding MCP server.
The skill text uses placeholder names like `vision-mcp` for the server and
shows `GLM-4.6V` / `zai-vision` as example provider names — replace them
with whatever your deployment actually uses (Claude with vision, GPT-4o,
Gemini, etc.). The skill's value is the *workflow* (browser-screenshot →
specific MCP tool), not any single provider.

### Dashboard script (shipped)

The Stage-7 live dashboard is rendered by `scripts/pm-dashboard-loop.ps1`
(alongside its Pester regression suite, `scripts/pm-dashboard-loop.Tests.ps1`).
Both ship inside the plugin so the dashboard lifecycle is self-contained —
no separate checkout required.

- **Run it with `-RepoRoot`** when the cwd-at-launch isn't the consuming
  repo root. This is the norm whenever the script is invoked from the
  plugin's install location (its own parent-of-parent is the plugin root,
  not your consumer repo). Resolution order: `-RepoRoot` param →
  `SDD_REPO_ROOT` env var → cwd.
- **Run `-SelfTest` once per feature kickoff** to validate that the
  feature's `tasks.md` parses and that its task count reconciles against
  `feature.json.initialTaskCount`. Exits 0 on success, 2 on empty parse
  (format drift), 3 on count mismatch.
- **One-liner from chat or terminal** (after sync to the consumer repo):
  ```powershell
  pwsh -NoProfile -File .github/scripts/pm-dashboard-loop.ps1 -SelfTest -RepoRoot .
  ```
  The path is the consumer's in-repo copy under `.github/scripts/`, not a
  plugin install location. Always pass `-RepoRoot` if cwd at launch might
  differ from the consumer repo root.

The orchestrator and project-manager personas reference the script via the
in-repo path `.github/scripts/pm-dashboard-loop.ps1`, resolved against the
workspace root.

## What the plugin expects your repo to provide

This plugin does not ship the SDD workflow's data files — your consuming
repo is expected to provide (or grow them over time):

- `.github/SDD_DELEGATION_CHART.md` — Stage → Persona → Subagent map (referenced by personas)
- `specs/<NNN>-<slug>/` — feature spec directories, growing per feature (the SDD format)
- `.specify/` — Spec Kit project root (`.specify/memory/constitution.md`, `.specify/scripts/`, templates)
- `.github/status/` — live-dashboard status JSONs (consumed by the Stage-7 dashboard script shipped with this plugin)
- `.github/knowledge/<role>/` — optional role-history dir referenced by persona "Load Project Knowledge" steps
- `.github/conversations/{YYYY-MM-DD}/` — optional conversation-log dir (see the `conversation-logger` skill)

The plugin's agents reference these as relative paths; they are valid in any
consuming repo that adopts the SDD/spec-kit layout. Files that don't exist
yet are simply skipped (the persona skills say "if the knowledge directory
does not yet exist, skip this step and proceed").

## Frontmatter convention

Every `*.agent.md` and `SKILL.md` file in this plugin carries
a `pluginSource: sdd-engineering-team` field in its YAML frontmatter. This is
provenance metadata — it helps you identify which files came from this plugin
versus your own repo-scoped customizations when diffing or upgrading.

## Known caveats

1. **Hook persona detection is best-effort.** The runtime guard script
   (`scripts/no-op-guard.js`) blocks `Edit`/`Write` for the orchestrator,
   debugger, and QA analyst personas — but only when it can identify the
   active persona. Currently it checks `SDD_PERSONA` env var or the hook
   event's `session.persona` field; if neither is exposed, it falls back
   to "allow" rather than risk spurious blocks. Set `SDD_GUARD_DEBUG=1`
   to log every event to `plugin/.sdd-guard.log` while tuning behaviour.

3. **MCP env vars don't auto-load from `.env`.** `${ZAI_API_KEY}`
   must come from the user's shell env or VS Code's
   `terminal.integrated.env.*` setting. Plugins don't read consuming-repo
   `.env` files.

4. **Token-tracker team ID (optional, env var).** The orchestrator persona
   attributes token spend via a `token-tracker` MCP service. Each consumer
   sets their own team identifier via the `SDD_TEAM_ID` env var
   (`.vscode/settings.json` → `terminal.integrated.env.<os>`):
   ```jsonc
   "terminal.integrated.env.windows": { "SDD_TEAM_ID": "your-team-name" }
   ```
   If `SDD_TEAM_ID` is unset, the orchestrator skips `token-tracker` calls
   (treats the service as unavailable) — the rest of the workflow is
   unaffected.

5. **Dashboard script lives in the consumer repo.** `scripts/pm-dashboard-loop.ps1`
   (plus its Pester regression tests) is sync'd to the consumer's
   `.github/scripts/` directory by `-IncludeScripts`. The orchestrator and
   PM personas invoke it via the in-repo path
   `.github/scripts/pm-dashboard-loop.ps1`. Pass your consuming repo's path
   via `-RepoRoot` if the cwd-at-launch differs.

## Distributing updates

To roll a new plugin source change out to existing consumer repos, re-run
the sync script from step *Install (sync to consumer repo)* against each
consumer repo. The sync is idempotent — it always overwrites from the
plugin source, so there is no incremental-merge risk and no in-place
consumer-side state that needs preserving. Bump the version in the
commit message of the plugin repo so consumers can see what landed when.

## License

MIT — see `plugin.json`.
