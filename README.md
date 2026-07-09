# SDD Engineering Team — VS Code Agent Plugin

A reusable VS Code Agent Plugin that ships a Spec-Driven Development (SDD)
engineering team: one orchestrator plus seven specialist personas (Product,
Project, Full-Stack Engineer, Quality Engineer, QA Analyst, Debugger, UX
Designer) and the 11-agent `speckit.*` SDD-generation pipeline.

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

## Install (local path — recommended for single-developer use)

The plugin currently lives at `<this-repo>/plugin/`. Register it once at
VS Code **user level** so every repo you open picks it up:

```jsonc
// Append to: C:\Users\<you>\AppData\Roaming\Code\User\settings.json
// (macOS: ~/Library/Application Support/Code/User/settings.json)
// (Linux: ~/.config/Code/User/settings.json)
{
  "chat.plugins.enabled": true,
  "chat.pluginLocations": {
    "<absolute-path-to-this-repo>/plugin": true
  }
}
```

Reload VS Code → Extensions view (`Ctrl+Shift+X`) → search `@agentPlugins`
→ you should see `sdd-engineering-team` listed → enable if not already.

To use in a new project repo, no further setup is needed on the same
machine — just open the project. The 8 personas + 11 `speckit.*` pipeline
agents will appear in the agent dropdown (Agent mode). The orchestrator
invokes the speckit agents as subagents; you can also pick any speckit
agent directly from the dropdown for ad-hoc work.

## Install (marketplace — for distributing to teammates or other machines)

See *Distributing the plugin* at the bottom of this README.

## Bundle layout

This plugin uses the **Claude format** (`.claude-plugin/plugin.json` at the
format-specific manifest location) so VS Code expands the `${CLAUDE_PLUGIN_ROOT}`
token in hook commands and MCP server config. Without that, plugin-provided
hooks can't reference their own scripts portably.

| Path | Contents |
|------|----------|
| `.claude-plugin/plugin.json` | Plugin manifest (name, pointers to folders below) |
| `agents/` | 8 persona agents (`*.agent.md`) + `speckit/` subdir with 11 pipeline agents |
| `skills/` | 14 markdown skills (one `SKILL.md` per directory) |
| `hooks/hooks.json` | Runtime guardrail hooks (Claude-format location) — see *Two-Layer Receipt Enforcement* below |
| `.mcp.json` | MCP server config (zai-vision, zai-web-search, playwright) |
| `scripts/` | Helper scripts (`no-op-guard.js`, `speckit-receipt-guard.js`, `pm-dashboard-loop.ps1`, `.Tests.ps1`) |

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
- **One-liner from chat or terminal:**
  ```powershell
  pwsh -NoProfile -File ${CLAUDE_PLUGIN_ROOT}/scripts/pm-dashboard-loop.ps1 -SelfTest -RepoRoot .
  ```
  (When invoked through a Claude-format plugin hook, `${CLAUDE_PLUGIN_ROOT}`
  is set automatically; for ad-hoc PowerShell calls, substitute the
  absolute path to the plugin's `scripts/` directory.)

The orchestrator and project-manager personas reference the script via
`${CLAUDE_PLUGIN_ROOT}/scripts/pm-dashboard-loop.ps1`, which both VS Code
and Claude Code expand to the plugin's install location at runtime.

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

5. **Dashboard script ships with the plugin.** `scripts/pm-dashboard-loop.ps1`
   (plus its Pester regression tests) lives in the plugin. The orchestrator
   and PM personas reference it via the `${CLAUDE_PLUGIN_ROOT}` token, which
   VS Code expands at runtime to the plugin's install location. Pass your
   consuming repo's path via `-RepoRoot` if the cwd-at-launch differs.

## Distributing the plugin

When you're ready to share with teammates or other machines:

1. **Move `plugin/` to its own Git repo.** From this repo's root:
   ```powershell
   # Create new repo D:\code\eng-team-plugin
   git mv plugin D:\code\eng-team-plugin\
   cd D:\code\eng-team-plugin
   git init && git add . && git commit -m "Initial plugin"
   git remote add origin git@github.com:<you>/eng-team-plugin.git
   git push -u origin main
   ```

2. **Add a marketplace catalog.** Two options:

   - **Bundled marketplace (simplest):** create
     `.claude-plugin/marketplace.json` in the same repo with `source: "./"`
     pointing at the plugin root. Consumers install with:
     ```
     /plugin marketplace add <you>/eng-team-plugin
     /plugin install sdd-engineering-team@<you>-eng-team-plugin
     ```

   - **Separate marketplace repo:** create a second repo (e.g.
     `<you>/copilot-plugins`) whose `.claude-plugin/marketplace.json`
     references `eng-team-plugin` as a `github` source. Lets you ship
     multiple plugins from one marketplace.

3. **Update `plugin.json` `version`** on every meaningful change so the
   auto-updater picks it up.

4. **Remove the local `chat.pluginLocations` entry** from your user
   settings (since you'll install from the marketplace instead).

> The plugin format is the same one VS Code, GitHub Copilot CLI, and
> Claude Code share — the same `eng-team-plugin` repo works across all
> three tools without modification.

## License

MIT — see `plugin.json`.
