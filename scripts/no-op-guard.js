#!/usr/bin/env node
/**
 * no-op-guard.js — runtime guardrail hook for the sdd-engineering-team plugin.
 *
 * Invoked by hooks.json at PreToolUse / Stop / SubagentStop events.
 * Reads the Claude Code hook event JSON from stdin and decides whether to block
 * based on the guard mode passed as argv[2].
 *
 * Contract (Claude Code hook protocol):
 *   exit 0  → allow / proceed silently
 *   exit 2  → block; stderr is shown to the agent as the denial reason
 *
 * This is a deliberate fallback: the persona files themselves instruct the
 * orchestrator not to use edit/write/bash, the hooks are a safety net so a
 * model that "forgets" gets a hard block instead of silently editing files.
 *
 * Set SDD_GUARD_DEBUG=1 to log every event to .sdd-guard.log (in the plugin
 * dir) for debugging without affecting behavior.
 */
"use strict";

const fs = require("fs");
const path = require("path");

const mode = process.argv[2] || "unknown";

// Read hook event JSON from stdin. The agent runtime passes tool_name,
// tool_input, session info, etc. on a single line of JSON.
let rawStdin = "";
try {
  rawStdin = fs.readFileSync(0, "utf8");
} catch (e) {
  // No stdin? Not running under a hook runtime. Treat as no-op.
  console.error("[sdd-guard] no stdin — running standalone, allowing.");
  process.exit(0);
}

let event = {};
try { event = JSON.parse(rawStdin || "{}"); } catch (e) { event = {}; }

// Best-effort debug log. Never breaks agent flow.
if (process.env.SDD_GUARD_DEBUG === "1") {
  try {
    const logPath = path.join(__dirname, "..", ".sdd-guard.log");
    fs.appendFileSync(logPath, `[${new Date().toISOString()}] mode=${mode} event=${rawStdin}\n`);
  } catch (_) { /* ignore */ }
}

// Helpers ----------------------------------------------------------------

function allow() { process.exit(0); }

function block(reason) {
  // stderr is surfaced to the agent by the hook runtime on exit 2.
  console.error(reason);
  process.exit(2);
}

// ── orchestrator-no-edit ────────────────────────────────────────────────
// The orchestrator coordinates and delegates only — never edits files.
if (mode === "orchestrator") {
  // Best-effort: detect the active agent. Claude Code hook events expose the
  // current session/agent via `session_id` + `cwd` at minimum; the active
  // persona is not always exposed. We rely on agent self-identification by
  // having the persona files set SDD_PERSONA env via the project. When we
  // cannot determine the persona, we fall back to allow to avoid spurious
  // blocks during normal user-driven chat.
  const persona = process.env.SDD_PERSONA || event.session?.persona;
  if (persona === "orchestrator") {
    block("Orchestrator cannot use this tool directly. Delegate to the appropriate specialist agent (full-stack-engineer, debugger, or qa-analyst).");
  }
  allow();
}

// ── debugger-no-edit ────────────────────────────────────────────────────
if (mode === "debugger") {
  const persona = process.env.SDD_PERSONA || event.session?.persona;
  if (persona === "debugger") {
    block("Debugger cannot implement fixes. Produce a diagnosis report and hand off to the Engineer.");
  }
  allow();
}

// ── qa-analyst-no-edit ───────────────────────────────────────────────────
if (mode === "qa-analyst") {
  const persona = process.env.SDD_PERSONA || event.session?.persona;
  if (persona === "qa-analyst") {
    block("QA Analyst validates the application in the browser. To fix issues found, delegate to the Engineer.");
  }
  allow();
}

// ── session-end / subagent-stop ────────────────────────────────────────
// Advisory hooks. These would ideally warn if memory.add wasn't called, but
// the hook protocol doesn't expose the tool-call history. Default to a no-op
// log; the persona files carry the behavioural rule.
if (mode === "session-end" || mode === "subagent-stop") {
  allow();
}

allow();
