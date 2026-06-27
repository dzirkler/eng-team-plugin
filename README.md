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
machine — just open the project. The personas will appear in the agent
dropdown (Agent mode), and `/speckit.*` slash commands become available.

## Install (marketplace — for distributing to teammates or other machines)

See *Distributing the plugin* at the bottom of this README.

## Bundle layout

| Path | Contents |
|------|----------|
| `plugin.json` | Plugin manifest (name, pointers to folders below) |
| `agents/` | 8 persona agents (`*.agent.md`) + `speckit/` subdir with 11 pipeline agents |
| `skills/` | 14 markdown skills (one `SKILL.md` per directory) |
| `commands/` | 16 slash-command stubs (`speckit.*.prompt.md`) |
| `hooks.json` | Runtime guardrail hooks |
| `.mcp.json` | MCP server config (token-tracker, etc.) |
| `scripts/` | Helper scripts (e.g. `no-op-guard.js`) |

## Optional integrations

### Token-tracker MCP (optional)

The orchestrator persona references a `token-tracker` MCP service that
records LLM token spend per feature/branch-gated effort against an
engineer-hour estimate (a tokens-per-engineer-hour ROI metric). This is
**entirely optional**. If you do not run a `token-tracker` MCP server in
your deployment:

- The plugin works without it. The orchestrator's session-bracketing calls
  (`current_session`, `start_session`, `close_session`) will be no-ops or
  fail silently; no other capability depends on them.
- Replace every `<your-team>` placeholder (used in the orchestrator's
  templates and the team-id field of the token-tracker calls) with your
  actual team identifier if you wire one up.
- The `.mcp.json` shipped with this plugin is a stub; you may edit/replace
  it with your own MCP server config.

### Vision MCP (optional)

The `vision-mcp` skill assumes a configured image-understanding MCP server.
The skill text uses placeholder names like `vision-mcp` for the server and
shows `GLM-4.6V` / `zai-vision` as example provider names — replace them
with whatever your deployment actually uses (Claude with vision, GPT-4o,
Gemini, etc.). The skill's value is the *workflow* (browser-screenshot →
specific MCP tool), not any single provider.

## What the plugin expects your repo to provide

This plugin does not ship the SDD workflow's data files — your consuming
repo is expected to provide (or grow them over time):

- `.github/SDD_DELEGATION_CHART.md` — Stage → Persona → Subagent map (referenced by personas)
- `specs/<NNN>-<slug>/` — feature spec directories, growing per feature (the SDD format)
- `.specify/` — Spec Kit project root (`.specify/memory/constitution.md`, `.specify/scripts/`, templates)
- `.github/status/` — optional live-dashboard status JSONs (consumed by the Stage-7 dashboard protocol if you wire up a dashboard script)
- `.github/knowledge/<role>/` — optional role-history dir referenced by persona "Load Project Knowledge" steps
- `.github/conversations/{YYYY-MM-DD}/` — optional conversation-log dir (see the `conversation-logger` skill)

The plugin's agents reference these as relative paths; they are valid in any
consuming repo that adopts the SDD/spec-kit layout. Files that don't exist
yet are simply skipped (the persona skills say "if the knowledge directory
does not yet exist, skip this step and proceed").

## Slash commands shipped

`/speckit.constitution`, `/speckit.specify`, `/speckit.clarify`,
`/speckit.plan`, `/speckit.tasks`, `/speckit.analyze`, `/speckit.implement`,
`/speckit.checklist`, `/speckit.converge`, `/speckit.taskstoissues`,
`/speckit.agent-context.update`, plus 6 git helpers (`/speckit.git.commit`,
`/speckit.git.feature`, `/speckit.git.initialize`, `/speckit.git.remote`,
`/speckit.git.validate`).

## Frontmatter convention

Every `*.agent.md`, `*.prompt.md`, and `SKILL.md` file in this plugin carries
a `pluginSource: sdd-engineering-team` field in its YAML frontmatter. This is
provenance metadata — it helps you identify which files came from this plugin
versus your own repo-scoped customizations when diffing or upgrading.

## Known caveats

1. **Command stubs are minimal.** The 16 `commands/*.prompt.md` files are
   3-line shells (`---/agent: speckit.X/---`). They depend on the plugin
   host resolving `agent:` references to invoke the matching agent
   definition. If slash commands don't fire as expected, replace each stub
   with inline prompt text (the matching `speckit/*.agent.md` body is the
   source of truth and can be lifted verbatim into the prompt file).

2. **Hook persona detection is best-effort.** The runtime guard script
   (`scripts/no-op-guard.js`) blocks `Edit`/`Write` for the orchestrator,
   debugger, and QA analyst personas — but only when it can identify the
   active persona. Currently it checks `SDD_PERSONA` env var or the hook
   event's `session.persona` field; if neither is exposed, it falls back
   to "allow" rather than risk spurious blocks. Set `SDD_GUARD_DEBUG=1`
   to log every event to `plugin/.sdd-guard.log` while tuning behaviour.

3. **MCP env vars don't auto-load from `.env`.** `${MEM0_API_KEY}`,
   `${ZAI_API_KEY}` must come from the user's shell env or VS Code's
   `terminal.integrated.env.*` setting. Plugins don't read consuming-repo
   `.env` files.

4. **Tokens / dashboard script.** The Stage-7 dashboard launch protocol
   expects a `<your-dashboard-loop-script>` consuming repo supplies. The
   plugin does not ship one — see the project-manager skill for the
   contract.

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
