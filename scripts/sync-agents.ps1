# sync-agents.ps1
# Per-project xcopy + model-tier injection for the SDD Engineering Team plugin.
#
# Problem this solves: VS Code Agent-mode model selection is per-workspace, and
# frontmatter `model:` values must be the exact qualified picker string (e.g.
# "GLM-4.7 (myproject) (customendpoint)"), not a raw model id. A single
# shared user-level plugin can't carry different per-project model names, so
# each consuming project gets its OWN copy of the persona agent files, with
# the {{MODEL_FLAGSHIP}} / {{MODEL_CHEAP}} placeholders in this plugin's
# source agents resolved to that project's qualified names.
#
# Idempotent: safe to re-run on every plugin update — it always copies fresh
# from the plugin source and re-injects the two placeholders; it never reads
# or merges against whatever is already in the target (the plugin source is
# the single source of truth, per V2-Plan-Revisions.md §7 "Name drift").
#
# Usage:
#   pwsh -File scripts/sync-agents.ps1 `
#     -TargetRoot "C:\code\myproject" `
#     -ProjectTag "myproject" `
#     -FlagshipModel "GLM-5.2 (myproject) (customendpoint)" `
#     -CheapModel "GLM-4.7 (myproject) (customendpoint)"
#
# Optional footprint switches (default: persona agents only):
#   -IncludeSpeckit   also copies agents/speckit/* (the speckit.* glue agents)
#   -IncludeSkills    also copies skills/*
#   -IncludeHooks     also copies hooks/hooks.json (REQUIRES -IncludeScripts
#                     if you also want the referenced no-op-guard.js to land
#                     at ${CLAUDE_PLUGIN_ROOT}/scripts/no-op-guard.js)
#   -IncludeMcp       also copies .mcp.json (NOTE: does not inject secrets —
#                     the target's own env vars / .vscode/settings.json still
#                     supply ${ZAI_API_KEY} etc. at runtime)
#   -IncludeScripts   also copies scripts/* — REQUIRED for any consumer that
#                     runs the Stage-7 dashboard (pm-dashboard-loop.ps1 is
#                     referenced by the orchestrator + project-manager
#                     personas via ${CLAUDE_PLUGIN_ROOT}/scripts/... and
#                     will be unresolvable at runtime without this). Also
#                     ships no-op-guard.js (referenced by hooks.json) and
#                     the dashboard's Pester regression suite.

param(
    [Parameter(Mandatory = $true)]
    [string]$TargetRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProjectTag,

    [Parameter(Mandatory = $true)]
    [string]$FlagshipModel,

    [Parameter(Mandatory = $true)]
    [string]$CheapModel,

    [switch]$IncludeSpeckit,
    [switch]$IncludeSkills,
    [switch]$IncludeHooks,
    [switch]$IncludeMcp,
    [switch]$IncludeScripts,

    # -WhatIf-style dry run: report what would change, write nothing.
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$pluginRoot = Split-Path -Parent $PSScriptRoot
$sourceAgentsDir = Join-Path $pluginRoot "agents"

if (-not (Test-Path $sourceAgentsDir)) {
    throw "Plugin source agents dir not found: $sourceAgentsDir (expected scripts/ to be a sibling of agents/)"
}
if (-not (Test-Path $TargetRoot)) {
    throw "Target project root not found: $TargetRoot"
}

# Sanity: qualified model names should reference the project tag and the
# customendpoint vendor, per V2-Plan-Revisions.md §3. This is a soft warning,
# not a hard failure — some deployments may use a different vendor/format.
foreach ($pair in @(@{ Label = "FlagshipModel"; Value = $FlagshipModel }, @{ Label = "CheapModel"; Value = $CheapModel })) {
    if ($pair.Value -notmatch [regex]::Escape($ProjectTag)) {
        Write-Host "WARNING: $($pair.Label) ('$($pair.Value)') does not contain ProjectTag ('$ProjectTag') — verify this is the correct qualified picker name for this project." -ForegroundColor Yellow
    }
    if ($pair.Value -notmatch '\(customendpoint\)\s*$') {
        Write-Host "WARNING: $($pair.Label) ('$($pair.Value)') does not end with '(customendpoint)' — VS Code frontmatter model refs must match the picker string verbatim." -ForegroundColor Yellow
    }
}

$targetAgentsDir = Join-Path $TargetRoot ".github\agents"

<#
    Copy-PersonaAgent

    Reads one plugin-source agent file, injects the two model-tier
    placeholders, and writes it to the target. Injection is a plain string
    replace — {{MODEL_FLAGSHIP}} / {{MODEL_CHEAP}} are literal tokens in the
    source frontmatter, never partial/regex matches, so this is safe and
    exact.
#>
function Copy-PersonaAgent($sourceFile, $destFile) {
    $content = Get-Content -Path $sourceFile -Raw -Encoding UTF8
    $injected = $content.Replace('{{MODEL_FLAGSHIP}}', $FlagshipModel).Replace('{{MODEL_CHEAP}}', $CheapModel)

    if ($DryRun) {
        Write-Host "  [dry-run] would write: $destFile"
        return
    }

    $destDir = Split-Path -Parent $destFile
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    # Atomic write: temp + rename, so a killed process never leaves a
    # half-written agent file in the target.
    $tempFile = "$destFile.tmp"
    $injected | Out-File -FilePath $tempFile -Encoding UTF8 -NoNewline
    Move-Item -Path $tempFile -Destination $destFile -Force
    Write-Host "  wrote: $destFile"
}

Write-Host "Syncing persona agents -> $targetAgentsDir"
Write-Host "  Project tag:     $ProjectTag"
Write-Host "  Flagship model:  $FlagshipModel"
Write-Host "  Cheap model:     $CheapModel"
Write-Host ""

# --- Required footprint: all persona agent files (agents/*.agent.md, NOT
# --- the agents/speckit/ subfolder, which is optional glue). Persona files
# --- are the ones that carry {{MODEL_FLAGSHIP}}/{{MODEL_CHEAP}} placeholders.
$personaFiles = Get-ChildItem -Path $sourceAgentsDir -Filter "*.agent.md" -File
if ($personaFiles.Count -eq 0) {
    throw "No persona agent files found in $sourceAgentsDir"
}
foreach ($f in $personaFiles) {
    Copy-PersonaAgent -sourceFile $f.FullName -destFile (Join-Path $targetAgentsDir $f.Name)
}

# --- Optional: speckit glue agents (no model placeholders to inject; they
# --- declare no `model:` field and inherit from the invoking persona). Plain
# --- copy, still atomic.
if ($IncludeSpeckit) {
    $sourceSpeckitDir = Join-Path $sourceAgentsDir "speckit"
    $targetSpeckitDir = Join-Path $targetAgentsDir "speckit"
    if (Test-Path $sourceSpeckitDir) {
        Write-Host ""
        Write-Host "Syncing speckit agents -> $targetSpeckitDir"
        Get-ChildItem -Path $sourceSpeckitDir -Filter "*.agent.md" -File | ForEach-Object {
            $dest = Join-Path $targetSpeckitDir $_.Name
            if ($DryRun) {
                Write-Host "  [dry-run] would copy: $dest"
            } else {
                if (-not (Test-Path $targetSpeckitDir)) { New-Item -ItemType Directory -Path $targetSpeckitDir -Force | Out-Null }
                Copy-Item -Path $_.FullName -Destination $dest -Force
                Write-Host "  wrote: $dest"
            }
        }
    }
}

# --- Optional: scripts/  (dashboard + no-op-guard + Pester tests).
# --- Copy each top-level file from the plugin's scripts/ dir to the target's
# --- .github/scripts/.  Plain copy, no model placeholders to inject. We do
# --- NOT recursively copy the directory itself (avoids creating an empty
# --- .github/scripts/scripts/ if some future refactor adds a subdir) — we
# --- enumerate files explicitly. Excludes this sync-agents.ps1 itself, since
# --- it is plugin-internal plumbing and not part of the runtime footprint
# --- referenced by personas, hooks, or skills.
if ($IncludeScripts) {
    $sourceScriptsDir = Join-Path $pluginRoot "scripts"
    $targetScriptsDir = Join-Path $TargetRoot ".github\scripts"
    if (Test-Path $sourceScriptsDir) {
        Write-Host ""
        Write-Host "Syncing scripts -> $targetScriptsDir"
        if (-not (Test-Path $targetScriptsDir)) { New-Item -ItemType Directory -Path $targetScriptsDir -Force | Out-Null }
        Get-ChildItem -Path $sourceScriptsDir -File | Where-Object { $_.Name -ne "sync-agents.ps1" } | ForEach-Object {
            $dest = Join-Path $targetScriptsDir $_.Name
            if ($DryRun) {
                Write-Host "  [dry-run] would copy: $dest"
            } else {
                Copy-Item -Path $_.FullName -Destination $dest -Force
                Write-Host "  wrote: $dest"
            }
        }
    }
}

# --- Optional: skills/
if ($IncludeSkills) {
    $sourceSkillsDir = Join-Path $pluginRoot "skills"
    $targetSkillsDir = Join-Path $TargetRoot ".github\skills"
    if (Test-Path $sourceSkillsDir) {
        Write-Host ""
        Write-Host "Syncing skills -> $targetSkillsDir"
        if ($DryRun) {
            Write-Host "  [dry-run] would mirror: $sourceSkillsDir -> $targetSkillsDir"
        } else {
            if (-not (Test-Path $targetSkillsDir)) { New-Item -ItemType Directory -Path $targetSkillsDir -Force | Out-Null }
            Copy-Item -Path (Join-Path $sourceSkillsDir "*") -Destination $targetSkillsDir -Recurse -Force
            Write-Host "  mirrored skills/"
        }
    }
}

# --- Optional: hooks/hooks.json
# --- NOTE: hooks.json references ${CLAUDE_PLUGIN_ROOT}/scripts/no-op-guard.js
# --- at runtime. That node script will be unresolvable unless the consumer
# --- also passes -IncludeScripts (or otherwise installs no-op-guard.js at
# --- <plugin-root>/scripts/). We warn here rather than hard-fail because
# --- some consumers may supply no-op-guard.js from a different source.
if ($IncludeHooks) {
    $sourceHooks = Join-Path $pluginRoot "hooks\hooks.json"
    $targetHooksDir = Join-Path $TargetRoot ".github\hooks"
    if (Test-Path $sourceHooks) {
        Write-Host ""
        if (-not $IncludeScripts) {
            Write-Host "WARNING: -IncludeHooks without -IncludeScripts — hooks.json references" -ForegroundColor Yellow
            Write-Host "         `${CLAUDE_PLUGIN_ROOT}/scripts/no-op-guard.js which will not exist at runtime" -ForegroundColor Yellow
            Write-Host "         unless no-op-guard.js is supplied separately. Recommend also passing -IncludeScripts." -ForegroundColor Yellow
        }
        $dest = Join-Path $targetHooksDir "hooks.json"
        if ($DryRun) {
            Write-Host "  [dry-run] would copy: $dest"
        } else {
            if (-not (Test-Path $targetHooksDir)) { New-Item -ItemType Directory -Path $targetHooksDir -Force | Out-Null }
            Copy-Item -Path $sourceHooks -Destination $dest -Force
            Write-Host "  wrote: $dest"
        }
    }
}

# --- Optional: .mcp.json (copied as-is; secrets still come from the
# --- target's own env / .vscode settings at runtime — this script never
# --- writes a secret value into the target).
if ($IncludeMcp) {
    $sourceMcp = Join-Path $pluginRoot ".mcp.json"
    $targetMcp = Join-Path $TargetRoot ".mcp.json"
    if (Test-Path $sourceMcp) {
        Write-Host ""
        if ($DryRun) {
            Write-Host "  [dry-run] would copy: $targetMcp"
        } else {
            Copy-Item -Path $sourceMcp -Destination $targetMcp -Force
            Write-Host "  wrote: $targetMcp"
        }
    }
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run complete. No files written."
} else {
    Write-Host "Sync complete."
}
