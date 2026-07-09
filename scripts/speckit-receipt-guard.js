#!/usr/bin/env node
/**
 * speckit-receipt-guard.js — HARD enforcement hook for speckit provenance.
 *
 * Complement to no-op-guard.js. The persona .md files instruct agents to
 * delegate artifact generation to speckit.* subagents (never hand-author);
 * this hook is the safety net so that a model which "forgets" gets a hard
 * block at Write/Edit time instead of silently producing an unreceipted
 * artifact that downstream stages then trust.
 *
 * INVOKED from hooks.json at PreToolUse on `write` | `edit` tools when the
 * target file path is under `specs/` and matches a known speckit-artifact
 * filename (see ARTIFACT_BASENAMES).
 *
 * CONTRACT (Claude Code hook protocol):
 *   exit 0  → allow / proceed silently
 *   exit 2  → block; stderr is surfaced to the agent as the denial reason
 *
 * RULE (what it checks):
 *   For a write/edit that targets an artifact path:
 *     - The full NEW content of the file must BEGIN with an HTML comment of
 *       the form:
 *         <!-- speckit:stage=<stage> | persona=<owner> | spec=<...> |
 *              generated_at=<iso8601> | cli_version=<...> -->
 *     - We DO NOT validate the field values here (the persona + orchestrator
 *       do that via the ledger check). We only enforce PRESENCE of the line
 *       so a persona cannot write the file without speckit having produced
 *       (or revised) it.
 *     - For `edit` operations (patch semantics, not full-file write): we
 *       cannot inspect the resulting file without applying the patch, so we
 *       take a conservative rule — if the patch ADDS OR REPLACES the receipt
 *       line itself as the first line, we inspect the new content. Otherwise
 *       we ALLOW (an in-place edit to an already-receipted file is a normal
 *       revision; the revision-receipt protocol is documented at the persona
 *       layer). This matches the provenance model: initial generation =
 *       speckit (receipt at head); revision of a speckit artifact = persona
 *       updates generated_at + appends ledger entry, also leaving the
 *       receipt at head.
 *
 * ENV VARS
 *   SDD_GUARD_DEBUG=1   append every decision event to .sdd-guard.log
 *
 * IMPORTANT — does NOT enforce:
 *   - ledger consistency (orchestrator-side, runs separately)
 *   - field value semantics (PdM six-point check #6)
 *   - design-brief.md provenance — it is NOT a speckit artifact (ux-designer
 *     produces it directly). Explicitly excluded from ARTIFACT_BASENAMES.
 *
 * FAILURE MODE this catches:
 *   spec-028 mode — persona hand-authors plan.md/tasks.md while the speckit
 *   subagent dispatch is frozen; without this hook, the file lands and every
 *   downstream stage trusts it. With this hook, the write of unreceipted
 *   content is REJECTED at PreToolUse; the persona is forced back onto the
 *   legitimate fallback path (owner-side /speckit.<stage>).
 */
"use strict";

const fs = require("fs");
const path = require("path");

const mode = "speckit-receipt";

// Read hook event JSON from stdin. May contain tool_name, tool_input (with
// filePath / content / newString), session info, etc.
let rawStdin = "";
try {
  rawStdin = fs.readFileSync(0, "utf8");
} catch (e) {
  console.error("[speckit-receipt] no stdin — standalone, allowing.");
  process.exit(0);
}

let event = {};
try { event = JSON.parse(rawStdin || "{}"); } catch (e) { event = {}; }

// Best-effort debug log. Never breaks flow.
if (process.env.SDD_GUARD_DEBUG === "1") {
  try {
    const logPath = path.join(__dirname, "..", ".sdd-guard.log");
    fs.appendFileSync(logPath, `[${new Date().toISOString()}] mode=${mode} event=${rawStdin}\n`);
  } catch (_) { /* ignore */ }
}

// ── helpers ─────────────────────────────────────────────────────────────
function allow() { process.exit(0); }
function block(reason) { console.error(reason); process.exit(2); }

// Receipt line regex — tolerant of field order + whitespace, anchors to start
// of file content. Matches both initial-generation receipts AND revision-
// receipt updates (we don't distinguish at this layer).
const RECEIPT_RE = /^\s*<!--\s*speckit:stage=[^|]+\|\s*persona=[^|]+\|\s*spec=[^|]+/m;

// Basenames must match the canonical speckit-artifact list per
// orchestrator.agent.md → "Provenance Verification" and the SDD delegation
// chart. design-brief.md INTENTIONALLY excluded — it is produced directly by
// ux-designer, NOT by a speckit subagent.
const ARTIFACT_BASENAMES = new Set([
  "spec.md",
  "clarifications.md",
  "analyze-report.md",
  "plan.md",
  "tasks.md",
  "research.md",
  "data-model.md",
  "quickstart.md",
  "review-log.md",
]);

// ── resolve target path ─────────────────────────────────────────────────
// Works across tool surfaces: Write usually supplies `filePath` + `content`;
// Edit usually supplies `filePath` + `oldString`/`newString`. Some shims use
// `file_path` / `path` instead.
const toolInput = event.tool_input || {};
const filePath =
  toolInput.filePath || toolInput.file_path || toolInput.path || "";

if (!filePath) {
  // No resolvable path → not a file-content mutation we care about.
  allow();
}

// Only enforce under specs/. Constitution is project-scoped
// (.specify/memory/constitution.md) and is also speckit-generated, but
// writing to it is a project-bootstrap governance action that the PdM rules
// gate separately; matching it here would block legitimate amendments that
// run via /speckit.constitution.
//
// Match either `/specs/` (absolute) or `specs/` at start / after the drive
// root on Windows (e.g. `d:\code\repo\specs\029\plan.md` → forward-slashed
// becomes `d:/code/repo/specs/029/plan.md`, contains `/specs/`; a bare
// relative `specs/029/plan.md` also matches the regex below).
const normalized = String(filePath).replace(/\\/g, "/");
if (!/(^|\/)specs\//.test(normalized)) {
  allow();
}

// Only enforce the well-known artifact basenames. Anything else under
// specs/ (sidecar JSON, contacts/*.yaml, new section files) is free to be
// edited normally.
const basename = path.basename(normalized);
if (!ARTIFACT_BASENAMES.has(basename)) {
  allow();
}

// ── inspect content for the receipt line ────────────────────────────────
// For `write` we inspect the full new content. For `edit` we ONLY enforce
// when the patch is the first line — i.e., the agent is restoring or
// replacing the receipt — so that a normal in-place revision of an existing
// receipted file (which already passes this check by virtue of having a
// receipt at head from when speckit wrote it) does not get blocked. The
// stand-alone edit of body content on an already-receipted file is permitted;
// the revision-receipt protocol guarantees the resulting head-of-file is
// still the receipt the persona updated.
const toolName = (event.tool_name || "").toLowerCase();
const isNewFileWrite =
  toolName === "write" ||
  toolName === "create_file" ||
  toolName === "createfile";

if (isNewFileWrite) {
  const content = typeof toolInput.content === "string" ? toolInput.content : "";
  if (!RECEIPT_RE.test(content)) {
    block(
      `[speckit-receipt] REJECTED — new-file write to speckit artifact \`${basename}\` at ` +
      `${filePath} is missing the provenance receipt marker.\n` +
      `Speckit artifacts MUST begin with an HTML comment marker of the form:\n` +
      `  <!-- speckit:stage=<stage> | persona=<owner> | spec=<...> | ` +
      `generated_at=<iso8601> | cli_version=<...> -->\n` +
      `This rule is the spec-028 hard-enforcement fallback. If you are a ` +
      `persona gate: do NOT write \`${basename}\` yourself — re-dispatch ` +
      `speckit.${guessStage(basename)} with sharper context, or escalate to ` +
      `the owner for the /speckit.${guessStage(basename)} slash-command ` +
      `fallback on a confirmed freeze. See orchestrator.agent.md → ` +
      `"Forbidden: Hand-Authoring SDD Artifacts".`
    );
  }
  allow();
}

// For `edit` — we only block when the patch presents a NEW head-of-file and
// that new head is un-receipted. An edit that mutates body content while the
// original file's first line was a valid receipt is permitted: subsequent
// reads of the file still find a receipt at the head (the patch didn't touch
// line 1). The revising persona is expected to update generated_at on the
// existing receipt line as part of the revision (not the guard's job here).
if (toolName === "edit" || toolName === "replace_string_in_file") {
  const newString =
    typeof toolInput.newString === "string"
      ? toolInput.newString
      : (typeof toolInput.new_string === "string" ? toolInput.new_string : "");

  // If the patch is introducing/appending the receipt as the first content,
  // require it to be receipted. Heuristic: the patch's content starts at
  // what looks like a document head (blank-ish or starts with `<!--`).
  // Otherwise allow — this is a body edit on a file that already passed
  // the check at write time.
  const looksLikeDocumentHead =
    newString.trimStart().startsWith("<!--") ||
    newString.trimStart().startsWith("#");

  if (looksLikeDocumentHead && !RECEIPT_RE.test(newString)) {
    block(
      `[speckit-receipt] REJECTED — edit to speckit artifact \`${basename}\` ` +
      `at ${filePath} introduces a head-of-file without a provenance receipt.\n` +
      `If this is a body-only revision, ensure line 1 remains the existing ` +
      `speckit receipt marker (and update generated_at per the ` +
      `revision-receipt protocol). If you are producing this file's content ` +
      `yourself rather than via speckit.${guessStage(basename)}, STOP — ` +
      `delegate generation to speckit.${guessStage(basename)} instead. See ` +
      `orchestrator.agent.md → "Forbidden: Hand-Authoring SDD Artifacts".`
    );
  }
  allow();
}

// Unknown tool that targets an artifact path: fail-open (the persona files
// already forbid silent file-writing by hand; a mismatched tool surface is
// not the threat we are blocking here).
allow();

// ── stage guess for error messages ──────────────────────────────────────
// Reverse map of ARTIFACT_BASENAMES → stage. Best-effort; defaults to
// "plan" as a stand-in. Used ONLY to make the deny reason actionable.
function guessStage(base) {
  switch (base) {
    case "spec.md":           return "specify";
    case "clarifications.md": return "clarify";
    case "analyze-report.md": return "analyze";
    case "plan.md":           return "plan";
    case "tasks.md":          return "tasks";
    case "review-log.md":     return "review";
    // research.md, data-model.md, quickstart.md are Phase-1 outputs of
    // speckit.plan; route errors to "plan" as the owning stage.
    default:                  return "plan";
  }
}
