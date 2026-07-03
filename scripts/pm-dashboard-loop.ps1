# pm-dashboard-loop.ps1
# Project Manager Dashboard Monitor — Phase 7 (Implement)
# Continuously renders .github/status/dashboard.html from feature.json + agent status files.
# Exits when all agents report "completed" or after timeout.

param(
    [int]$IntervalSeconds = 5,
    [int]$TimeoutMinutes = 120,
    [string]$StatusDir = ".github\status",
    [string]$OutputFile = ".github\status\dashboard.html",
    # -RepoRoot: the consumer repo root to resolve $StatusDir / $OutputFile
    # against. REQUIRED when the cwd-at-launch differs from the consumer repo
    # root, which is the norm when this script ships in a plugin (its own
    # parent-of-parent is the plugin install dir, NOT the consumer repo).
    # Resolution priority: -RepoRoot param > $env:SDD_REPO_ROOT > cwd.
    [string]$RepoRoot = $((if ($env:SDD_REPO_ROOT) { $env:SDD_REPO_ROOT } else { (Get-Location).Path })),
    # -SelfTest: parse the configured tasks.md (or -SelfTestTasksMd if given),
    # reconcile against feature.initialTaskCount (if present), and exit. Does
    # NOT start the dashboard loop. Returns exit code 0 on success, 2 if the
    # parse produced 0 tasks (a strong "tasks.md format drift" signal), 3 if
    # the parse disagrees with feature.initialTaskCount. Task-count
    # reconciliation at launch is load-bearing verification, not ceremony.
    [switch]$SelfTest,
    [string]$SelfTestTasksMd,

    # -ResumeSupervisor: Layer 3 (quota-block wake) — see
    # docs/resume-signal-contract.md and Quota-Block-Resilience-Plan.md §6.
    # Instead of rendering the dashboard, polls for a resume-signal.json
    # written by the (external, non-LLM) Layer 2 reset-time capture code,
    # waits until reset_at + buffer, then surfaces a one-click resume
    # (writes a ready-state file + best-effort opens the repo). Does NOT
    # itself relaunch the LLM — that stays a human (or scheduler) action.
    [switch]$ResumeSupervisor,
    # Path to the resume signal, relative to -RepoRoot unless rooted.
    # Matches the location proposed in Quota-Block-Resilience-Plan.md §4.
    [string]$ResumeSignalPath = ".specify\state\resume-signal.json",
    # Where the supervisor writes the "ready to resume" surface, relative to
    # -RepoRoot unless rooted. A dashboard/notifier can watch this file.
    [string]$ResumeReadyFile = ".github\status\resume-ready.json",
    # Clock-skew / quota-release-lag buffer added after reset_at before
    # surfacing resume-ready (open item in the resilience plan §9).
    [int]$ResumeBufferSeconds = 120,
    # Poll cadence while waiting for the signal to appear / for reset_at to pass.
    [int]$ResumePollSeconds = 30,
    # 0 = run indefinitely (true supervisor). Non-zero bounds the run for
    # ad-hoc/CI invocations.
    [int]$ResumeTimeoutMinutes = 0,
    # Best-effort: after surfacing resume-ready, try to open the repo in VS
    # Code (`code <RepoRoot>`) so the human has a one-click path in. Silently
    # skipped if `code` isn't on PATH — never fatal.
    [switch]$ResumeOpenRepo
)

$ErrorActionPreference = "Stop"
$startTime = Get-Date
$timeoutSeconds = $TimeoutMinutes * 60
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = if ($PSBoundParameters.ContainsKey('RepoRoot') -and $RepoRoot) { $RepoRoot } elseif ($env:SDD_REPO_ROOT) { $env:SDD_REPO_ROOT } else { (Get-Location).Path }
$statusDirFull = Join-Path $repoRoot $StatusDir
$outputFileFull = Join-Path $repoRoot $OutputFile
$agentsDir = Join-Path $statusDirFull "agents"

# Stale-inference threshold (design §3.3, Q4 = A): an agent with status=working
# and a currentTaskId set whose updatedAt is older than this many seconds has
# its current task reclassified from "in progress" to "stale" (⏸). Hardcoded
# at 5 minutes for v1; promote to feature.json if per-feature tuning is needed.
$script:StaleThresholdSeconds = 300

function Read-JsonFile($path) {
    if (Test-Path $path) {
        try {
            $raw = Get-Content $path -Raw -Encoding UTF8
            return $raw | ConvertFrom-Json
        } catch {
            return $null
        }
    }
    return $null
}

function Get-AgentStatuses($agentsDir) {
    $statuses = @()
    if (-not (Test-Path $agentsDir)) { return $statuses }
    $files = Get-ChildItem -Path $agentsDir -Filter "*.json" -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $data = Read-JsonFile $f.FullName
        if ($data) {
            $statuses += $data
        }
    }
    return $statuses
}

function Escape-Html($text) {
    if ($null -eq $text) { return "" }
    return $text.ToString().Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;").Replace("'", "&#39;")
}

<#
    Normalize-TaskId

    Flattens the messy in-the-wild task ID spellings to a single canonical
    form so cross-file references (tasks.md / agent status file / SCHEMA.md)
    align. Strips parens around suffixes:
        T012(a) -> T012a
        T012    -> T012
        T012b   -> T012b   (kept verbatim)

    Defensive: the parser normalises on read; agents are *also* required to
    write the normalised form (see SCHEMA.md "Agent Status File Schema — v2").
    Idempotent: re-running on an already-normalised ID returns it unchanged.
#>
function Normalize-TaskId($rawId) {
    if ([string]::IsNullOrWhiteSpace($rawId)) { return $null }
    $id = $rawId.Trim()
    # Match the core "T<digits>" then optionally capture a single-letter
    # suffix, optionally wrapped in parens. Anything else we leave alone.
    if ($id -match '^(T\d+)(?:\(([a-zA-Z0-9]+)\)|([a-zA-Z0-9]+))?$') {
        $base   = $matches[1]
        $suffix = $matches[2]
        if ([string]::IsNullOrEmpty($suffix)) { $suffix = $matches[3] }
        if ([string]::IsNullOrEmpty($suffix)) { return $base }
        return "$base$suffix"   # e.g. "T012" + "a"
    }
    return $id
}

<#
    Parse-TasksMd

    Parses a feature's tasks.md into the structure the Implementation
    Progress widget renders against:
        @{
            phases = @(
                @{ index = 1; name = "Config layer (foundation)"; tasks = @(
                    @{ id = "T001"; name = "Add STATUS_SYNC_* ..." },
                    ...
                )}
            )
        }

    Phase header recognition (per design §1.1; extended over time for
    in-the-wild header variants):
        "## Phase N: name"      colon-form      e.g. "## Phase 1: Foundational"
        "### Phase N (label)"   parenthesised-label form  e.g. "### Phase 1 (Foundation)"
        "### Theme N - name"    em-dash theme form (Hyphen accepted too) e.g. "### Theme 1 - Config layer"
        "## Theme N — name"     em-dash theme form (H2 variant)   e.g. "## Theme 1 — Config layer"
    An em-dash, hyphen, or colon is accepted between the number and the name
    to be robust against editor normalisation of punctuation.

    Task recognition — two forms coexist:
        "- **TXXX[(suffix)]** description"          bold bullet form
        "- [ ] **TXXX[(suffix)]** description"      checkbox bullet form (bold variant)
        "### TXXX [tags] description"               H3-header task form

    If neither header form is found, every recognised task is collected under
    a single synthetic phase named "Tasks" so the widget still renders.
#>
function Parse-TasksMd($path) {
    $result = @{ phases = @() }
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) {
        return $result
    }

    $lines = @()
    try {
        # Always read as UTF-8 — the script may be run under either Windows
        # PowerShell 5.1 or PowerShell 7+; explicit -Encoding UTF8 guarantees
        # em-dashes in headers parse correctly regardless of host edition.
        # (Windows PowerShell 5.1 is tolerated, but PowerShell 7+ is the
        # recommended runtime for full Unicode fidelity.)
        $lines = Get-Content -Path $path -Encoding UTF8
        if ($null -eq $lines) { $lines = @() }
    } catch {
        return $result
    }

    $currentPhase = $null
    # Section-boundary flag: when true, bullet lines are NOT treated as tasks
    # even if they look bolded. This covers the checkbox-style Dependencies
    # section where the same `### Theme N (label)` headers are reused to
    # organise DEPENDENCY prose (e.g. bullets like "T033 depends on T024…"),
    # not task definitions. Flips to $false on every recognised theme/phase
    # header inside the impl Tasks section; flips back to $true on any H2
    # header that isn't an implementation theme form.
    #
    # H1-header caveat: when tasks.md uses H1 phase headers (`# Phase N — name`)
    # AND uses `### TNNN …` task headers with a `## Phase sizing summary` H2
    # boundary between Conventions prose and the real task list, H1 phase
    # recognition is required or the H2 boundary silenced task collection
    # forever and the synthetic-phase fallback never fired (observed launch
    # hit exit-2 selftest -> 0/0 parse). Fix: extend the parser with H1 phase
    # recognition + H1 non-phase boundaries AND a defensive re-arm so a
    # recognised `### TNNN …` header re-enables collection regardless of the
    # boundary flag. All additions are strictly additive to prior behaviour.
    $collectingTasks = $true
    foreach ($line in $lines) {
        # --- H1 phase header: # Phase N — name (em-dash or hyphen).
        # --- Comes FIRST so H1 phase markers are authoritative task-section
        # --- openers.
        $h1PhaseMatch = [regex]::Match($line, '^#\s+Phase\s+(\d+)\s+[—-]\s+(.+?)\s*$')
        if ($h1PhaseMatch.Success) {
            $currentPhase = @{ index = [int]$h1PhaseMatch.Groups[1].Value; kind = "phase"; name = $h1PhaseMatch.Groups[2].Value.Trim(); tasks = @() }
            $result.phases += $currentPhase
            $collectingTasks = $true
            continue
        }
        # --- H1 boundary: any other H1 (`# Title`, `# Cross-phase confidence
        # --- summary`, `# Before:` etc) acts as a section boundary, identical
        # --- to non-impl H2. Stops the bullet matcher from picking up prose
        # --- callouts like "- **T007 is the integration pinch point.**"
        # --- after the last task header.
        if ($line -match '^#\s+') {
            $currentPhase = $null
            $collectingTasks = $false
            continue
        }
        # --- H2 boundary: implementation theme (## Theme N — name) or phase
        # --- (## Phase N: name — colon-form) → open it + enable task
        # --- collection. Any OTHER H2 → section boundary → STOP collecting.
        # H2 em-dash theme form:
        $h2ThemeMatch = [regex]::Match($line, '^##\s+Theme\s+(\d+)\s+[—-]\s+(.+?)\s*$')
        if ($h2ThemeMatch.Success) {
            $currentPhase = @{ index = [int]$h2ThemeMatch.Groups[1].Value; kind = "theme"; name = $h2ThemeMatch.Groups[2].Value.Trim(); tasks = @() }
            $result.phases += $currentPhase
            $collectingTasks = $true
            continue
        }
        # H2 phase form: ## Phase N: name (colon), ## Phase N：name (full-width colon),
        # ## Phase N — name (em-dash), or ## Phase N - name (hyphen). The em-dash/hyphen
        # variants are required because the comment historically claimed "tolerate
        # ## Phase N — name variants at H2 for robustness" but the regex only had colons
        # in the character class (spec 022-style headers returned 0 tasks; fixed here).
        $h2PhaseColonMatch = [regex]::Match($line, '^##\s+Phase\s+(\d+)\s*[:：—-]\s*(?:(.+?)\s*)?$')
        if ($h2PhaseColonMatch.Success) {
            $phaseName = if ($h2PhaseColonMatch.Groups[2].Success) { $h2PhaseColonMatch.Groups[2].Value.Trim() } else { "Phase $($h2PhaseColonMatch.Groups[1].Value)" }
            $currentPhase = @{ index = [int]$h2PhaseColonMatch.Groups[1].Value; kind = "phase"; name = $phaseName; tasks = @() }
            $result.phases += $currentPhase
            $collectingTasks = $true
            continue
        }
        if ($line -match '^##\s+') {
            # Non-theme/phase H2 (## Dependencies, ## Parallelization, ## Notes,
            # ## Acceptance Criteria, etc). This is a section boundary —
            # stop treating bullets as tasks until/unless the next impl
            # theme header re-opens one. Important for checkbox-style
            # Dependencies sections that reuse ### Theme N (label) headers to
            # organise dependency prose and would otherwise double-count.
            $currentPhase = $null
            $collectingTasks = $false
            continue
        }

        # ---- phase header detection (try em-dash theme form first, then parenthesised-label) ----
        # em-dash theme form:  ### Theme N - name       (em-dash or hyphen)
        $themeMatch = [regex]::Match($line, '^###\s+Theme\s+(\d+)\s+[—-]\s+(.+?)\s*$')
        if ($themeMatch.Success) {
            $currentPhase = @{ index = [int]$themeMatch.Groups[1].Value; kind = "theme"; name = $themeMatch.Groups[2].Value.Trim(); tasks = @() }
            $result.phases += $currentPhase
            $collectingTasks = $true
            continue
        }
        # parenthesised-label form:  ### Phase N (label)
        $phaseMatch = [regex]::Match($line, '^###\s+Phase\s+(\d+)\s*\(([^)]+)\)\s*$')
        if ($phaseMatch.Success) {
            $currentPhase = @{ index = [int]$phaseMatch.Groups[1].Value; kind = "phase"; name = $phaseMatch.Groups[2].Value.Trim(); tasks = @() }
            $result.phases += $currentPhase
            $collectingTasks = $true
            continue
        }

        # Skip bullet lines if we're inside a non-impl section (Dependencies
        # etc. — re-uses ### Theme N (label) headers and bolded T-id bullets
        # but they are NOT tasks). The `$collectingTasks` flag flips back on
        # when we re-enter an impl theme header above.
        #
        # Defensive re-arm: a tasks.md that uses H1 phase headers but has a
        # stray ## Conventions / Phase-sizing summary H2 BEFORE the first
        # phase header would otherwise silence task collection forever
        # (the `## Phase sizing summary` H2 flips this off, then
        # `# Phase 1 — ...` never arms it under the original logic because
        # H1 phase headers were unrecognised). Even with H1 recognition
        # added above, this defence guarantees that a recognised
        # `### TNNN …` task header reopens task collection.
        # NB: this ONLY fires for the canonical `### TNNN` form — prose
        # bullets in checkbox-style Dependencies sections still get skipped
        # because they don't match the H3-task regex below.
        if (-not $collectingTasks) {
            $probeTaskMatch = [regex]::Match($line, '^###\s+(T\d+(?:\([a-zA-Z0-9]+\)|[a-zA-Z0-9]?)?)\b')
            if ($probeTaskMatch.Success) {
                $collectingTasks = $true
            } else {
                continue
            }
        }

        # ---- H3 task header: ### TNNN [tags] description ----
        # The H3-header task form uses H3 headers as task definitions rather
        # than bullets. Also tolerate an optional `[tags]` group that the
        # author uses to mark story/priority/parallel-safe attributes. The
        # description is everything after the closing bracket-or-trailing-
        # tag; the Normalize-TaskId helper handles the (suffix) → suffix
        # flattening.
        $h3TaskMatch = [regex]::Match($line, '^###\s+(T\d+(?:\([a-zA-Z0-9]+\)|[a-zA-Z0-9]?)?)\b\s*(.*)$')
        if ($h3TaskMatch.Success) {
            $tid = Normalize-TaskId $h3TaskMatch.Groups[1].Value
            if ($null -ne $tid) {
                $rawName = $h3TaskMatch.Groups[2].Value.Trim()
                # Strip a leading "[tags]" group (e.g. "[All_ACs] [P] description")
                # so the parsed task name is the human-readable description only.
                $cleanName = [regex]::Replace($rawName, '^(?:\[[^\]]*\]\s*)+', '')
                if ($null -eq $currentPhase) {
                    $currentPhase = @{ index = 1; kind = "synthetic"; name = "Tasks"; tasks = @() }
                    $result.phases += $currentPhase
                }
                $currentPhase.tasks += @{ id = $tid; name = $cleanName }
            }
            continue
        }

        # ---- task bullet detection (plain OR boxed checkbox form) ----
        # Handles FOUR in-the-wild formats:
        #   - **T001** description            bold bullet form
        #   - [ ] **T012(a)** description     checkbox + bold bullet form
        #   - [x] T001 description            checkbox, no bold
        #   - [ ] T001 [P] [US1] description  checkbox, optional [tags]
        #                                    after the TXXX id
        # The `**: ` group is optional so both bold and unbold match. A
        # trailing tag cluster (e.g. "[P] [US1]") is stripped from the
        # description before storage so the parsed name is human-readable.
        $taskMatch = [regex]::Match($line, '^\s*-\s+(?:\[.\]\s+)?(?:\*\*)?(T\d+(?:\([a-zA-Z0-9]+\)|[a-zA-Z0-9]?)?)(?:\*\*)?\s+(.+?)\s*$')
        if ($taskMatch.Success) {
            $tid  = Normalize-TaskId $taskMatch.Groups[1].Value
            $rawName = $taskMatch.Groups[2].Value.Trim()
            # Strip a leading "[tag] [tag] ..." cluster that appears between
            # the TXXX id and the real description (checkbox bullet form).
            $tname = [regex]::Replace($rawName, '^(?:\[[^\]]*\]\s*)+', '')
            if ($null -ne $tid) {
                if ($null -eq $currentPhase) {
                    # No recognised phase header above us — initialise the
                    # synthetic fallback phase once, on first task seen.
                    $currentPhase = @{ index = 1; kind = "synthetic"; name = "Tasks"; tasks = @() }
                    $result.phases += $currentPhase
                }
                $currentPhase.tasks += @{ id = $tid; name = $tname }
            }
            continue
        }
    }

    return $result
}

<#
    Get-FeatureManifestVersion

    Returns the schema version declared on feature.json as a simple string:
        "feature-manifest-v2" -> "v2"
        "feature-manifest-v1" -> "v1"
        $null / missing / unrecognised -> "v1"   (backward-compat fallback)

    Per design §8.3: the manifest acts as the migration lever. v1 keeps
    rendering the old Milestone Progress + Phase Breakdown sections; v2
    renders the Implementation Progress widget.
#>
function Get-FeatureManifestVersion($feature) {
    if ($null -eq $feature) { return "v1" }
    $schema = $feature.'$schema'
    if ([string]::IsNullOrWhiteSpace($schema)) { return "v1" }
    if ($schema -eq "feature-manifest-v2") { return "v2" }
    if ($schema -eq "feature-manifest-v1") { return "v1" }
    # Unknown schema string -> be conservative, fall back to v1.
    return "v1"
}

<#
    Render-Symbol-Svg

    Returns the inline SVG markup for one of the five Implementation Progress
    task-state symbols. Used both inside the always-visible legend AND the
    per-task line. Sizes are 14x14 by default; legend callers may override.

    Symbols (design §5.1):
        not-started  grey ring           #9ca3af
        in-progress  blue spinning arc   #3b82f6   (animated via .task-spin class)
        complete     green checkmark     #10b981
        blocked      amber warning       #f59e0b
        stale        grey pause          #9ca3af   (dashboard-inferred)
#>
function Render-Symbol-Svg($symbol, [int]$size = 14) {
    switch ($symbol) {
        "not-started" {
            return "<svg viewBox=`"0 0 16 16`" width=`"$size`" height=`"$size`" aria-label=`"not started`"><circle cx=`"8`" cy=`"8`" r=`"6`" fill=`"none`" stroke=`"#9ca3af`" stroke-width=`"2`"/></svg>"
        }
        "in-progress" {
            return "<svg class=`"task-spin`" viewBox=`"0 0 16 16`" width=`"$size`" height=`"$size`" aria-label=`"in progress`"><path d=`"M8 2a6 6 0 1 0 6 6`" fill=`"none`" stroke=`"#3b82f6`" stroke-width=`"2`" stroke-linecap=`"round`"/><path d=`"M11 1l3 3-3 1z`" fill=`"#3b82f6`"/></svg>"
        }
        "complete" {
            return "<svg viewBox=`"0 0 16 16`" width=`"$size`" height=`"$size`" aria-label=`"complete`"><path d=`"M3 8l3.5 3.5L13 4.5`" fill=`"none`" stroke=`"#10b981`" stroke-width=`"2.5`" stroke-linecap=`"round`" stroke-linejoin=`"round`"/></svg>"
        }
        "blocked" {
            return "<svg viewBox=`"0 0 16 16`" width=`"$size`" height=`"$size`" aria-label=`"blocked`"><path d=`"M8 1l7 13H1z`" fill=`"#f59e0b`"/><rect x=`"7`" y=`"6`" width=`"2`" height=`"4`" fill=`"#1e293b`"/><rect x=`"7`" y=`"11.5`" width=`"2`" height=`"2`" fill=`"#1e293b`"/></svg>"
        }
        "stale" {
            return "<svg viewBox=`"0 0 16 16`" width=`"$size`" height=`"$size`" aria-label=`"stale`"><rect x=`"4`" y=`"3`" width=`"3`" height=`"10`" fill=`"#9ca3af`"/><rect x=`"9`" y=`"3`" width=`"3`" height=`"10`" fill=`"#9ca3af`"/></svg>"
        }
        default {
            return "<svg viewBox=`"0 0 16 16`" width=`"$size`" height=`"$size`"></svg>"
        }
    }
}

<#
    Resolve-TaskState

    Render-time status resolution for a single task ID against the agent
    overlay. Returns one of:
        complete    in-progress    stale    blocked    not-started

    (design §1.3) Computed strictly from agent-reported fields + the age of
    the most recent matching update. Does NOT read tasks.items[].

    Inputs:
        $taskId           normalised task ID (e.g. "T012a")
        $agentOverlays    agents[] (objects) with at least: status, currentTaskId,
                          currentTaskStartedAt, updatedAt, blockers, tasksCompleted
        $nowUtcIso        ISO-formatted UTC "now" reference for stale check

    Rules (in precedence order; first match wins):
        1. Some agent.status == "blocked" and currentTaskId == $taskId  -> blocked
        2. Some agent.status == "working" and currentTaskId == $taskId
           AND (now - agent.updatedAt) <= StaleThresholdSeconds          -> in-progress
        3. Same as #2 but (now - agent.updatedAt) >  StaleThresholdSeconds -> stale
        4. else                                                          -> not-started

    "Complete" is determined by the caller (union of tasksCompleted) and passed
    in; this function never returns "complete" itself.
#>
function Resolve-TaskState($taskId, $agentOverlays, $nowUtcIso) {
    $nowUtc = ConvertTo-UtcDateTime $nowUtcIso
    if ($null -eq $nowUtc) { $nowUtc = [DateTime]::UtcNow }

    $latestUpdate = $null

    foreach ($a in $agentOverlays) {
        # Normalise defensively; only re-run if non-empty.
        $ctid = $a.currentTaskId
        if (-not [string]::IsNullOrWhiteSpace($ctid)) { $ctid = Normalize-TaskId $ctid }
        if ($ctid -eq $taskId) {
            if ($a.status -eq "blocked") {
                # Blocked overrides everything else for this task.
                return "blocked"
            }
            if ($a.status -eq "working") {
                # Track the most-recent updatedAt among working agents on this task.
                $upd = ConvertTo-UtcDateTime $a.updatedAt
                if ($null -ne $upd -and ($null -eq $latestUpdate -or $upd -gt $latestUpdate)) {
                    $latestUpdate = $upd
                }
            }
        }
    }

    if ($null -ne $latestUpdate) {
        $ageSec = ($nowUtc - $latestUpdate).TotalSeconds
        if ($ageSec -le $script:StaleThresholdSeconds) {
            return "in-progress"
        } else {
            return "stale"
        }
    }

    return "not-started"
}

<#
    Get-AgentRoleBucket

    Maps a feature.json agent.role to one of three dashboard buckets used
    by the role-bucket sub-bars below the headline progress bar. Returns:
        "engineering" | "quality" | "qa" | "other"
    Only the first three drive sub-bars; "other" agents (PMs, orchestrators)
    are excluded because they don't own task-completion work in the same sense.
#>
function Get-AgentRoleBucket($role) {
    switch ($role) {
        "full-stack-engineer" { return "engineering" }
        "quality-engineer"    { return "quality" }
        "qa-analyst"          { return "qa" }
        default               { return "other" }
    }
}

<#
    Get-RoleBucketProgress

    Computes the per-role completion fraction used for sub-bars rendered
    beneath the headline Implementation Progress bar. Each role's bucket
    denominator = the UNION of that role's assigned task IDs across agents
    who belong to that bucket. The numerator = how many of those have been
    marked complete by SOME agent in the same bucket.

    This matters most for QE/QA: their assignedTaskIds intentionally overlap
    the engineers' assignments (QE validates every task an engineer ships),
    so a headline union across ALL agents reaches 100% before QE/QA sign
    off. Bucketing by role surfaces the trailing QE/QA pass separately from
    the engineering build.

    Returns @{
        engineering = @{ total=N; done=N; pct=N }
        quality     = @{ ... }
        qa          = @{ ... }
    }
#>
function Get-RoleBucketProgress($feature, $agentStatuses, $parsedTasks) {
    # $parsedTasks (optional, may be $null for v1 renders) lets buckets fall
    # back to the live-parsed task count when feature.agents[].assignedTaskIds
    # is empty — observed in past implementations where assignment happens at
    # dispatch time rather than at manifest-write time. Without this fallback
    # every bucket renders `0/N` even though agents are marking tasks complete.
    $liveTotal = 0
    if ($parsedTasks -and $parsedTasks.phases) {
        foreach ($p in $parsedTasks.phases) { $liveTotal += $p.tasks.Count }
    }

    $buckets = @{
        engineering = @{ total = 0; done = 0; emptyAssignment = $false; assigned = [System.Collections.Generic.HashSet[string]]::new(); doneIds = [System.Collections.Generic.HashSet[string]]::new() }
        quality     = @{ total = 0; done = 0; emptyAssignment = $false; assigned = [System.Collections.Generic.HashSet[string]]::new(); doneIds = [System.Collections.Generic.HashSet[string]]::new() }
        qa          = @{ total = 0; done = 0; emptyAssignment = $false; assigned = [System.Collections.Generic.HashSet[string]]::new(); doneIds = [System.Collections.Generic.HashSet[string]]::new() }
    }

    # Phase 1: derive per-bucket assigned sets from feature.agents[].
    if ($feature.agents) {
        foreach ($info in $feature.agents) {
            $bucket = Get-AgentRoleBucket $info.role
            if (-not $buckets.ContainsKey($bucket)) { continue }
            if ($info.assignedTaskIds) {
                foreach ($tid in $info.assignedTaskIds) {
                    $norm = Normalize-TaskId $tid
                    if (-not [string]::IsNullOrEmpty($norm)) {
                        [void]$buckets[$bucket].assigned.Add($norm)
                    }
                }
            }
        }
    }

    # Phase 2: per-bucket completed unions from agent overlays.
    # Use a lookup table keyed by agentId so we don't have to re-match twice.
    $infoByAgentId = @{}
    if ($feature.agents) {
        foreach ($info in $feature.agents) { $infoByAgentId[$info.agentId] = $info }
    }
    foreach ($a in $agentStatuses) {
        $info = $infoByAgentId[$a.agentId]
        if (-not $info) { continue }
        $bucket = Get-AgentRoleBucket $info.role
        if (-not $buckets.ContainsKey($bucket)) { continue }
        if ($a.tasksCompleted) {
            foreach ($tid in $a.tasksCompleted) {
                $norm = Normalize-TaskId $tid
                if (-not [string]::IsNullOrEmpty($norm)) {
                    [void]$buckets[$bucket].doneIds.Add($norm)
                }
            }
        }
    }

    # Phase 3: totals. Use the per-bucket assigned-union regardless of
    # whether every task was actually picked up by an agent in that bucket —
    # this reflects the manifest's stated scope for each role. If a bucket
    # has no assignments at all (e.g. quality-engineer not present for
    # this feature), it renders 0/0 and we skip it in the UI.
    #
    # Empty-assignment fallback (2026-06-23): if a bucket's assigned set is
    # empty AND we have a live-parsed count, fall back per-bucket:
    #   - engineering  → use full live total (engineers are the primary
    #                    implementers; this is the "dana's view" denominator)
    #   - quality / qa → leave total at 0; the role partition cannot be
    #                    reliably reconstructed from tasks.md alone. The UI
    #                    skips 0/0 buckets, so these simply disappear rather
    #                    than misleadingly showing `6 / 13`.
    foreach ($key in @('engineering', 'quality', 'qa')) {
        $b = $buckets[$key]
        $total = $b.assigned.Count
        $emptyAssignment = ($total -eq 0)
        if ($emptyAssignment -and $key -eq 'engineering' -and $liveTotal -gt 0) {
            $total = $liveTotal
        }
        # Numerator counts only done IDs that fall inside the bucket's
        # assigned scope. (Defense-in-depth: a stray ID outside the
        # manifest shouldn't inflate the count.) Also CAP at total so the
        # displayed percentage never exceeds 100% — agents may mark extras
        # (T033b, DOC-CONSISTENCY-PASS, …) that aren't real tasks; those
        # are silently dropped from the bucket numerator.
        # Empty-assignment continuation: when assigned is empty (no
        # manifest partition) but the bucket has done IDs, count them
        # raw so the engineering sub-bar reflects actual work done.
        $done = 0
        if ($emptyAssignment) {
            $done = $b.doneIds.Count
        } else {
            foreach ($id in $b.doneIds) {
                if ($b.assigned.Contains($id)) { $done++ }
            }
        }
        if ($total -gt 0 -and $done -gt $total) { $done = $total }
        $pct = 0
        if ($total -gt 0) { $pct = [math]::Round(($done / $total) * 100) }
        $buckets[$key] = @{ total = $total; done = $done; pct = $pct; emptyAssignment = $emptyAssignment }
    }

    return $buckets
}

<#
    Render-ImplementationProgress

    Renders the widget that replaces the v1 "Milestone Progress" + "Phase
    Breakdown" sections. Current layout (v2.1):

        [headline progress bar]  N / M tasks (P%)
        [3 role sub-bars: Engineering · QE · QA]   (only if those buckets are present in feature.agents)
        [always-visible 5-symbol legend]
        [theme/phase table — one row per parsed theme/phase:
            columns: # | Title | Done/Total | Progress bar | ✓ on complete]

    The per-task rows + the speculative "Wave" wrapper were dropped in a
    past implementation round because (a) the per-theme progress bar
    already communicates per-theme status more compactly than long task
    lists and (b) the Wave wrapper was a stub that always rendered all
    themes under a single hardcoded "Wave 1" div; real waves are visible
    in the agent cards (which show each agent's actual startedAt).

    Role sub-bars (approach b) keep the headline
    semantic of "task complete" unchanged but layer the trailing QE/QA
    validation pass on top. This means the headline can sit at 100% the
    moment the engineers ship while QE/QA trail visibly underneath —
    prompting a clear "engineering done, QE/QA pending" mental model.

    Inputs:
        $feature          feature.json object (v2 expected)
        $parsedTasks      result of Parse-TasksMd
        $agentOverlays    agents[]
        $nowUtcIso        ISO "now" (kept in signature for callers; not used
                          by the table view but reserved for future
                          per-task stale inference if per-task rows return)
        $completedUnion   HashSet[string] of normalised completed task IDs

    Returns HTML string. Caller is responsible for the surrounding section +
    CSS block.
#>
function Render-ImplementationProgress($feature, $parsedTasks, $agentOverlays, $nowUtcIso, $completedUnion) {
    $sb = [System.Text.StringBuilder]::new()

    # --- denominator: feature.initialTaskCount (frozen scope, design §2.1) ---
    # Missing initialTaskCount -> fall back to live-parsed count so we still
    # render SOMETHING sensible (design §8.3 "loader logs a warning").
    $initialTaskCount = 0
    if ($feature.initialTaskCount -and $feature.initialTaskCount -gt 0) {
        $initialTaskCount = [int]$feature.initialTaskCount
    } else {
        $liveCount = 0
        if ($parsedTasks.phases) {
            foreach ($p in $parsedTasks.phases) { $liveCount += $p.tasks.Count }
        }
        $initialTaskCount = $liveCount
        [void]$sb.Append("<!-- WARN: feature.initialTaskCount missing; falling back to live-parsed count ($liveCount) -->")
    }

    $completedCount = if ($completedUnion) { $completedUnion.Count } else { 0 }
    $pctComplete = 0
    if ($initialTaskCount -gt 0) {
        $pctComplete = [math]::Round(($completedCount / $initialTaskCount) * 100)
    }

    # --- headline progress bar ---
    [void]$sb.Append(@"
<div class="impl-progress-bar">
    <div class="impl-bar-track">
        <div class="impl-bar-fill" style="width:$pctComplete%"></div>
    </div>
    <div class="impl-bar-count"><strong>$completedCount / $initialTaskCount</strong> tasks ($pctComplete%)</div>
</div>
"@)

    # --- role-bucket sub-bars (approach b) ---
    # Rendered ONLY for buckets that have > 0 total (either via manifest
    # assignment or via the live-parsed fallback for the engineering bucket).
    # The bucket colours intentionally don't match the headline fill gradient
    # so the "one is engineering, the other two are validation" distinction
    # is glanceable. Each row is: [LABEL] [Track+Fill(%)] [done/total]
    $roleBuckets = Get-RoleBucketProgress -feature $feature -agentStatuses $agentOverlays -parsedTasks $parsedTasks
    $roleRows = [System.Text.StringBuilder]::new()
    $roleOrder = @( 'engineering', 'quality', 'qa' )
    $roleLabels = @{ engineering = 'Engineering'; quality = 'Quality Eng'; qa = 'QA Analyst' }
    $roleColors = @{ engineering = '#3b82f6'; quality = '#22c55e'; qa = '#a855f7' }
    foreach ($key in $roleOrder) {
        $b = $roleBuckets[$key]
        if (-not $b -or $b.total -le 0) { continue }
        $color = $roleColors[$key]
        $label = $roleLabels[$key]
        [void]$roleRows.Append(@"
<div class="role-row">
    <span class="role-label">$label</span>
    <div class="role-bar-track">
        <div class="role-bar-fill" style="width:$($b.pct)%;background:$color"></div>
    </div>
    <span class="role-count"><strong>$($b.done) / $($b.total)</strong> ($($b.pct)%)</span>
</div>
"@)
    }
    if ($roleRows.Length -gt 0) {
        [void]$sb.Append("<div class=`"impl-role-bars`">")
        [void]$sb.Append($roleRows.ToString())
        [void]$sb.Append("</div>")
    }

    # --- always-visible 5-symbol legend (design §5.2) ---
    [void]$sb.Append(@"
<div class="impl-legend">
    <span class="legend-item">$(Render-Symbol-Svg "not-started")<span class="legend-label">NOT STARTED</span></span>
    <span class="legend-item">$(Render-Symbol-Svg "in-progress")<span class="legend-label">IN PROGRESS</span></span>
    <span class="legend-item">$(Render-Symbol-Svg "complete")<span class="legend-label">COMPLETE</span></span>
    <span class="legend-item">$(Render-Symbol-Svg "blocked")<span class="legend-label">BLOCKED</span></span>
    <span class="legend-item">$(Render-Symbol-Svg "stale")<span class="legend-label">STALE (&gt;5M)</span></span>
</div>
"@)

    # --- theme/phase table ---
    # Replaces the old per-task nesting. One row per parsed theme/phase,
    # columns: kind+N | title | done/total | mini-bar | ✓ glyph on complete.
    # The Wave wrapper was dropped in a past revision: it was a hardcoded
    # stub that bundled every theme under a single "Wave 1" div; per-agent
    # timing is now visible in the agent grid (startedAt written at first
    # task start).
    if ($parsedTasks.phases -and $parsedTasks.phases.Count -gt 0) {
        [void]$sb.Append(@"
<div class="impl-theme-table-wrap">
    <table class="impl-theme-table">
        <thead>
            <tr>
                <th>#</th>
                <th>Title</th>
                <th>Done/Total</th>
                <th>Progress</th>
                <th>&#10003;</th>
            </tr>
        </thead>
        <tbody>
"@)
        foreach ($phase in $parsedTasks.phases) {
            $phaseTotal     = $phase.tasks.Count
            $phaseCompleted = 0
            foreach ($t in $phase.tasks) {
                if ($completedUnion -and $completedUnion.Contains($t.id)) { $phaseCompleted++ }
            }
            $phasePct = 0
            if ($phaseTotal -gt 0) { $phasePct = [math]::Round(($phaseCompleted / $phaseTotal) * 100) }
            $phaseColor = if ($phasePct -eq 100) { '#22c55e' } elseif ($phasePct -gt 0) { '#3b82f6' } else { '#334155' }
            $phaseGlyph = if ($phaseTotal -gt 0 -and $phaseCompleted -eq $phaseTotal) { '<span style="color:#22c55e">&#10003;</span>' } else { '' }
            # Preserve source wording: "Theme N" for the em-dash theme
            # form, "Phase N" for the colon / parenthesised-label forms,
            # "Tasks" for synthetic fallback. Title cell carries the full
            # header label so the row is self-describing.
            $kindLabel = switch ($phase.kind) {
                "theme"     { "Theme $($phase.index)" }
                "phase"     { "Phase $($phase.index)" }
                "synthetic" { "Tasks" }
                default     { "Phase $($phase.index)" }
            }
            $phaseTitleCell = $phase.name
            [void]$sb.Append(@"
            <tr>
                <td class="impl-theme-num">$kindLabel</td>
                <td class="impl-theme-title">$(Escape-Html $phaseTitleCell)</td>
                <td class="impl-theme-count">$phaseCompleted / $phaseTotal</td>
                <td class="impl-theme-bar-cell">
                    <div class="impl-mini-bar"><div class="impl-mini-fill" style="width:$phasePct%;background:$phaseColor"></div></div>
                </td>
                <td class="impl-theme-glyph">$phaseGlyph</td>
            </tr>
"@)
        }
        [void]$sb.Append("        </tbody>`n    </table>`n</div>")
    } else {
        # No tasks parsed at all -- show an empty-state hint.
        [void]$sb.Append('<div class="impl-empty">No themes/phases parsed. Confirm tasksMdPath points to a parseable tasks.md.</div>')
    }

    return $sb.ToString()
}

<#
    ConvertTo-UtcDateTime

    Robust UTC parser that handles BOTH raw ISO strings AND already-converted
    [DateTime] objects (which is what `ConvertFrom-Json` returns for any field
    matching the ISO 8601 datetime pattern). Without this guard, calling
    [DateTime]::Parse($alreadyADateTime).ToUniversalTime() double-converts:
    ConvertFrom-Json already gave us Kind=Utc, but Parse() reads its LOCAL
    string representation and re-applies the host's offset. The result is
    silently +N hours off (host TZ), producing negative elapsed / stale
    comparisons misclassifying 5-min-old updates as days old.

    Returns a [DateTime] with Kind=Utc, or $null on parse failure.
#>
function ConvertTo-UtcDateTime($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [DateTime]) {
        return $value.ToUniversalTime()
    }
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    try {
        return [DateTime]::Parse($value.ToString(), $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal).ToUniversalTime()
    } catch {
        return $null
    }
}

function Format-Elapsed($isoStart, $isoEnd) {
    try {
        # Defence-in-depth: normalise both sides to UTC. Host TZ offset cancels
        # on subtraction when both inputs share a format, but explicit UTC
        # removes any ambiguity if one side is local time mislabeled with a Z.
        # Use ConvertTo-UtcDateTime to avoid double-parsing values that came
        # from ConvertFrom-Json already-as-DateTime (PS quirk: re-Parse on a
        # DateTime object re-applies the host TZ offset).
        $start = ConvertTo-UtcDateTime $isoStart
        $end   = ConvertTo-UtcDateTime $isoEnd
        if ($null -eq $start -or $null -eq $end) { return "—" }
        $diff  = $end - $start
        # CLAMP negative deltas (writer-clock skew / future-dated startedAt)
        # to TimeSpan.Zero so we render "0m 0s" instead of "-288m -44s".
        if ($diff.TotalSeconds -lt 0) { $diff = [TimeSpan]::Zero }
        if ($diff.TotalDays -ge 1) {
            return "{0}d {1}h {2}m" -f [int]$diff.TotalDays, $diff.Hours, $diff.Minutes
        } elseif ($diff.TotalHours -ge 1) {
            return "{0}h {1}m {2}s" -f [int]$diff.TotalHours, $diff.Minutes, $diff.Seconds
        } else {
            return "{0}m {1}s" -f [int]$diff.TotalMinutes, $diff.Seconds
        }
    } catch {
        return "—"
    }
}

function Format-Relative($isoTime) {
    $t = ConvertTo-UtcDateTime $isoTime
    if ($null -eq $t) { return "—" }
    try {
        $now = [DateTime]::UtcNow
        $diff = $now - $t
        # Parity clamp with Format-Elapsed — slightly-future timestamps render
        # as "just now" rather than rolling absurd "0m ago" or worse.
        if ($diff.TotalSeconds -lt 0) { $diff = [TimeSpan]::Zero }
        if ($diff.TotalMinutes -lt 1) { return "just now" }
        if ($diff.TotalMinutes -lt 60) { return "{0}m ago" -f [int]$diff.TotalMinutes }
        if ($diff.TotalHours -lt 24) { return "{0}h ago" -f [int]$diff.TotalHours }
        return "{0}d ago" -f [int]$diff.TotalDays
    } catch {
        return "$isoTime"
    }
}

function Status-Color($status) {
    switch ($status) {
        "working"   { return "#3b82f6" }
        "completed" { return "#22c55e" }
        "blocked"   { return "#ef4444" }
        "idle"      { return "#94a3b8" }
        default     { return "#94a3b8" }
    }
}

function Status-Icon($status) {
    switch ($status) {
        "working"   { return "&#9203;" }
        "completed" { return "&#9989;" }
        "blocked"   { return "&#9940;" }
        "idle"      { return "&#9711;" }
        default     { return "&bull;" }
    }
}

function Task-Status-Color($status) {
    switch ($status) {
        "completed"   { return "#22c55e" }
        "in-progress" { return "#3b82f6" }
        "blocked"     { return "#ef4444" }
        "pending"     { return "#e2e8f0" }
        default       { return "#e2e8f0" }
    }
}

function Render-Dashboard($feature, $agentStatuses) {
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $nowDisplay = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss UTC")

    # Manifest version gates the v1 (Milestone + Phase table) vs v2
    # (Implementation Progress widget) render path. See design §8.3.
    $manifestVersion = Get-FeatureManifestVersion $feature

    # Render-time completed-task union across all agents (design §2.2).
    # Dedupes duplicates (e.g. same task ID in engineer-1 + qe-1
    # tasksCompleted). Used by BOTH v2 widget and v2-derived summary cards.
    $rawCompleted = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($a in $agentStatuses) {
        if ($a.tasksCompleted) {
            foreach ($tid in $a.tasksCompleted) {
                $norm = Normalize-TaskId $tid
                if (-not [string]::IsNullOrEmpty($norm)) {
                    [void]$rawCompleted.Add($norm)
                }
            }
        }
    }

    # v2: parse tasks.md EARLY so we can (a) filter the completed-union to
    # only IDs that actually appear in tasks.md (prevents stray extras like
    # "T033b", "DOC-CONSISTENCY-PASS" from inflating the headline % past
    # 100% and the QE/QA per-agent progress past their assigned denominator);
    # and (b) reuse the same parse for both the summary-card counts and the
    # v2 Implementation Progress widget (one parse per render).
    $parsedTasks = @{ phases = @() }
    if ($manifestVersion -eq "v2") {
        $tasksMdPath = $null
        if ($feature.tasksMdPath) {
            $tasksMdPath = Join-Path $repoRoot $feature.tasksMdPath
        }
        if ($tasksMdPath -and (Test-Path $tasksMdPath)) {
            $parsedTasks = Parse-TasksMd $tasksMdPath
        }
    }

    # Build the known-task-id set from parsed tasks (empty if v1 / no parse).
    # Any $rawCompleted entry NOT in this set is dropped from $completedUnion.
    # We keep the raw set around in case a future caller wants to surface the
    # "extras" count to the operator; for now we just don't credit them.
    $knownTaskIds = [System.Collections.Generic.HashSet[string]]::new()
    if ($parsedTasks.phases) {
        foreach ($p in $parsedTasks.phases) {
            foreach ($t in $p.tasks) {
                if (-not [string]::IsNullOrEmpty($t.id)) { [void]$knownTaskIds.Add($t.id) }
            }
        }
    }
    $completedUnion = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in $rawCompleted) {
        # If we have a parsed task set with at least one ID, gate on it;
        # otherwise (v1 or empty tasks.md) accept everything as before.
        if ($knownTaskIds.Count -eq 0 -or $knownTaskIds.Contains($id)) {
            [void]$completedUnion.Add($id)
        }
    }

    # Aggregate task progress
    $totalTasks = $feature.totalTasks
    $completedTasks = 0
    $inProgressTasks = 0
    $blockedTasks = 0
    $pendingTasks = 0

    # Build task status map from agent statuses first, feature.json as fallback
    $taskMap = @{}
    if ($feature.tasks) {
        foreach ($ft in $feature.tasks) {
            $taskMap[$ft.id] = @{ id = $ft.id; name = $ft.name; status = $ft.status; phase = $ft.phase; story = $ft.story; priority = $ft.priority }
        }
    }
    foreach ($agent in $agentStatuses) {
        if ($agent.tasks -and $agent.tasks.items) {
            foreach ($item in $agent.tasks.items) {
                $taskMap[$item.id] = @{ id = $item.id; name = $item.name; status = $item.status; phase = $null; story = $null; priority = $null }
            }
        }
    }

    # Count by status
    foreach ($key in $taskMap.Keys) {
        $t = $taskMap[$key]
        switch ($t.status) {
            "completed"   { $completedTasks++ }
            "in-progress" { $inProgressTasks++ }
            "blocked"     { $blockedTasks++ }
            "pending"     { $pendingTasks++ }
        }
    }

    # v2: recompute summary card values from the new overlay so the cards
    # at the top of the page agree with the Implementation Progress widget
    # below. (design §4.4 - "Summary Cards ... stay but are recomputed from
    # the new overlay".) v1 keeps the v1-derived counts above unchanged.
    if ($manifestVersion -eq "v2") {
        $completedTasks = if ($completedUnion) { $completedUnion.Count } else { 0 }
        $inProgressTasks = 0
        $blockedTasks = 0
        foreach ($a in $agentStatuses) {
            $hasCurrent = (-not [string]::IsNullOrWhiteSpace($a.currentTaskId))
            if ($a.status -eq "working" -and $hasCurrent) { $inProgressTasks++ }
            elseif ($a.status -eq "blocked" -and $hasCurrent) { $blockedTasks++ }
        }
        # Frozen-scope denominator replaces feature.totalTasks under v2.
        if ($feature.initialTaskCount -and $feature.initialTaskCount -gt 0) {
            $totalTasks = [int]$feature.initialTaskCount
        }
    }

    $pctComplete = 0
    if ($totalTasks -gt 0) { $pctComplete = [math]::Round(($completedTasks / $totalTasks) * 100) }

    # Agent count
    $totalAgents = $feature.agents.Count
    $completedAgents = ($agentStatuses | Where-Object { $_.status -eq "completed" }).Count
    $blockedAgents = ($agentStatuses | Where-Object { $_.status -eq "blocked" }).Count
    $workingAgents = ($agentStatuses | Where-Object { $_.status -eq "working" }).Count

    # HITL check
    $anyHitl = $false
    foreach ($agent in $agentStatuses) {
        if ($agent.hitlCheckpoint -eq $true) { $anyHitl = $true }
    }

    # Build agent cards
    $agentCardsHtml = [System.Text.StringBuilder]::new()
    foreach ($agentInfo in $feature.agents) {
        $agentStatus = $agentStatuses | Where-Object { $_.agentId -eq $agentInfo.agentId } | Select-Object -First 1
        $displayStatus = "idle"
        $taskTotal = 0
        $taskCompleted = 0
        $taskInProgress = 0
        $taskBlocked = 0
        $taskPending = 0
        $lastUpdate = "—"
        $elapsed = "—"
        $blockersHtml = ""

        if ($agentStatus) {
            $displayStatus = $agentStatus.status
            # Authoritative source is the v2 two-event protocol fields
            # (currentTaskId / currentTaskStartedAt / tasksCompleted). Fall
            # back to the legacy tasks.* aggregate ONLY if v2 fields are
            # missing entirely. Without this fallback some agents (e.g. QE)
            # end up showing 0/N because they filled tasksCompleted but
            # never touched the legacy tasks.items[].
            $hasV2Fields = ($agentStatus.tasksCompleted -ne $null) -or ($agentStatus.currentTaskId -ne $null)
            if ($hasV2Fields) {
                # Denominator: prefer the manifest's assignedTaskIds (frozen
                # scope), fall back to the legacy tasks.total, then the
                # live-parsed tasks.md count (added as a fallback for the
                # case where the manifest leaves assignedTaskIds empty until
                # dispatch time).
                if ($agentInfo.assignedTaskIds -and @($agentInfo.assignedTaskIds).Count -gt 0) {
                    $taskTotal = @($agentInfo.assignedTaskIds).Count
                } elseif ($agentStatus.tasks -and $agentStatus.tasks.total) {
                    $taskTotal = $agentStatus.tasks.total
                } elseif ($parsedTasks -and $parsedTasks.phases) {
                    # Last-resort: assume this agent owns the whole feature's
                    # task surface. Correct for the engineering primary
                    # implementer; overstates for QE/QA — but they typically
                    # populate tasks.total or assignedTaskIds, so reaching
                    # this branch for them is rare and still better than /0.
                    foreach ($p in $parsedTasks.phases) { $taskTotal += $p.tasks.Count }
                }
                # Numerator: count of normalised IDs in tasksCompleted (the
                # agent's view of "I am done with these"). De-duped to keep
                # the count honest if an agent ever re-appended.
                $seen = [System.Collections.Generic.HashSet[string]]::new()
                if ($agentStatus.tasksCompleted) {
                    foreach ($tid in $agentStatus.tasksCompleted) {
                        $norm = Normalize-TaskId $tid
                        if (-not [string]::IsNullOrEmpty($norm)) { [void]$seen.Add($norm) }
                    }
                }
                $taskCompleted = $seen.Count
                # Cap displayed numerator at the assigned denominator. Agents
                # may sometimes mark extra synthetic IDs complete (T033b,
                # DOC-CONSISTENCY-PASS…) that aren't in the tasks.md surface
                # — without this cap the card renders
                # impossible ratios like "13 / 5". The full raw count is
                # preserved in their JSON for record-keeping; we just display
                # the bounded value on the card. $rawCompletedCount tracks
                # the un-capped value so a future tooltip could say "5 / 5
                # (+8 extra)" if useful.
                $rawCompletedCount = $taskCompleted
                if ($taskTotal -gt 0 -and $taskCompleted -gt $taskTotal) {
                    $taskCompleted = $taskTotal
                }
                # In-progress: 1 if a current task is still in flight and the
                # agent is still working, else 0. Blocked supersedes in-progress.
                if ($displayStatus -eq 'blocked' -and -not [string]::IsNullOrWhiteSpace($agentStatus.currentTaskId)) {
                    $taskBlocked = 1
                } elseif ($displayStatus -eq 'working' -and -not [string]::IsNullOrWhiteSpace($agentStatus.currentTaskId)) {
                    $taskInProgress = 1
                }
                if ($taskTotal -gt 0) {
                    $taskPending = [math]::Max(0, $taskTotal - $taskCompleted - $taskInProgress - $taskBlocked)
                }
            } elseif ($agentStatus.tasks) {
                $taskTotal = $agentStatus.tasks.total
                $taskCompleted = $agentStatus.tasks.completed
                $taskInProgress = $agentStatus.tasks.inProgress
                $taskBlocked = $agentStatus.tasks.blocked
                $taskPending = $agentStatus.tasks.pending
            }
            $lastUpdate = Format-Relative $agentStatus.updatedAt
            if ($agentStatus.startedAt) {
                $endRef = if ($agentStatus.completedAt) { $agentStatus.completedAt } else { $now }
                # Seeded-startedAt safeguard: the PM pre-seeds every agent
                # file with `startedAt = stage launch`
                # at dashboard-launch. The agent protocol requires the agent
                # to overwrite this on its first task-start write, but if it
                # hasn't yet (or never does), the elapsed time would show the
                # whole stage length instead of the agent's actual work
                # duration. Detect the placeholder by comparing the agent's
                # startedAt to the feature's createdAt (UTC, second-precision
                # both sides) and render "—" with a hover title instead of a
                # misleading number. This makes late-stage starters (engineers
                # 2/3, QE, QA) clearly honest about "hasn't started yet"
                # instead of looking 8+ hours long.
                $seededStartedAt = $false
                if ($feature.createdAt) {
                    $agentStart = ConvertTo-UtcDateTime $agentStatus.startedAt
                    $stageStart = ConvertTo-UtcDateTime $feature.createdAt
                    if ($null -ne $agentStart -and $null -ne $stageStart) {
                        $driftSec = [math]::Abs(($agentStart - $stageStart).TotalSeconds)
                        # Allow < 60s of clock skew for "this is a seeded value".
                        if ($driftSec -lt 60) { $seededStartedAt = $true }
                    }
                }
                if ($seededStartedAt) {
                    $elapsed = "—"
                } else {
                    $elapsed = Format-Elapsed $agentStatus.startedAt $endRef
                }
            }
            # NOTES REMOVED: the agent-notes block was redesigned away from
            # the card. We still keep `notes` in the status JSON as a record
            # (QE sign-off notes live there for the Checkpoint-3 handoff); it
            # just doesn't render inline anymore.
            if ($agentStatus.blockers -and $agentStatus.blockers.Count -gt 0) {
                $blockersHtml = '<div class="blockers">'
                foreach ($b in $agentStatus.blockers) {
                    $blockersHtml += "<div>&#9888; " + (Escape-Html $b) + "</div>"
                }
                $blockersHtml += "</div>"
            }
        }

        $agentPct = 0
        if ($taskTotal -gt 0) { $agentPct = [math]::Round(($taskCompleted / $taskTotal) * 100) }
        $color = Status-Color $displayStatus
        $icon = Status-Icon $displayStatus
        $roleLabel = $agentInfo.displayName

        # Build task chips for this agent.
        # Priority: (1) legacy `tasks.items[]` if populated, OR (2) the
        # v2 two-event fields `tasksCompleted[]` + `currentTaskId` mapped
        # against the parsed `tasks.md` for names. Without fallback (2),
        # v2-protocol agents (which leave tasks.items[] empty) render no
        # chips at all — observed in past implementations.
        $taskChipsHtml = ""
        $chipIds = [System.Collections.Generic.HashSet[string]]::new()
        if ($agentStatus) {
            $taskChipsHtml = '<div class="task-chips">'
            # (1) Legacy aggregate form — when present (some agents populate
            # it) use it verbatim, including the .status field.
            if ($agentStatus.tasks -and $agentStatus.tasks.items) {
                foreach ($item in $agentStatus.tasks.items) {
                    $chipColor = Task-Status-Color $item.status
                    $chipTitle = Escape-Html "$($item.id): $($item.name)"
                    $taskChipsHtml += "<span class=""task-chip"" style=""background:$chipColor"" title=""$chipTitle"">$($item.id)</span>"
                    [void]$chipIds.Add($item.id)
                }
            }
            # (2) v2 fallback — render every tasksCompleted id as a complete
            # chip, plus the currentTaskId as an in-progress chip (if the
            # agent is still working). Names are looked up against the
            # dashboard-wide $taskMap (built earlier from feature.tasks +
            # legacy items); IDs not in the map degrade to "<id>" only.
            if ($agentStatus.tasksCompleted) {
                foreach ($tid in $agentStatus.tasksCompleted) {
                    $norm = Normalize-TaskId $tid
                    if (-not $norm -or $chipIds.Contains($norm)) { continue }
                    $chipName = if ($taskMap -and $taskMap.ContainsKey($norm)) { $taskMap[$norm].name } else { "" }
                    $chipTitle = if ($chipName) { Escape-Html "$norm : $chipName" } else { Escape-Html "$norm" }
                    $taskChipsHtml += "<span class=""task-chip"" style=""background:$(Task-Status-Color 'completed')"" title=""$chipTitle"">$norm</span>"
                    [void]$chipIds.Add($norm)
                }
            }
            if ($agentStatus.currentTaskId) {
                $norm = Normalize-TaskId $agentStatus.currentTaskId
                if ($norm -and -not $chipIds.Contains($norm)) {
                    $curStatus = if ($agentStatus.status -eq "blocked") { "blocked" } else { "in-progress" }
                    $chipName = if ($taskMap -and $taskMap.ContainsKey($norm)) { $taskMap[$norm].name } else { "" }
                    $chipTitle = if ($chipName) { Escape-Html "$norm : $chipName" } else { Escape-Html "$norm" }
                    $taskChipsHtml += "<span class=""task-chip"" style=""background:$(Task-Status-Color $curStatus)"" title=""$chipTitle"">$norm</span>"
                }
            }
            $taskChipsHtml += "</div>"
            # If neither branch emitted a chip, drop the empty wrapper so
            # we don't render a stray 0-height div with default CSS margins.
            if ($chipIds.Count -eq 0) { $taskChipsHtml = "" }
        }

        $hitlBadge = ""
        if ($agentStatus -and $agentStatus.hitlCheckpoint -eq $true) {
            $hitlBadge = '<span class="hitl-badge">&#9203; HITL CHECKPOINT</span>'
        }

        [void]$agentCardsHtml.Append(@"
        <div class="agent-card" style="border-left-color:$color">
            <div class="agent-header">
                <span class="agent-icon">$icon</span>
                <span class="agent-name">$(Escape-Html $roleLabel)</span>
                <span class="agent-id">$(Escape-Html $agentInfo.agentId)</span>
                <span class="agent-status-badge" style="background:$color">$(Escape-Html $displayStatus)</span>
                $hitlBadge
            </div>
            <div class="agent-stats">
                <div class="stat"><span class="stat-label">Progress</span><span class="stat-value">$taskCompleted / $taskTotal</span></div>
                <div class="stat"><span class="stat-label">In Progress</span><span class="stat-value">$taskInProgress</span></div>
                <div class="stat"><span class="stat-label">Blocked</span><span class="stat-value">$taskBlocked</span></div>
                <div class="stat"><span class="stat-label">Elapsed</span><span class="stat-value">$elapsed</span></div>
                <div class="stat"><span class="stat-label">Updated</span><span class="stat-value">$lastUpdate</span></div>
            </div>
            <div class="progress-bar"><div class="progress-fill" style="width:$agentPct%;background:$color"></div></div>
            $taskChipsHtml
            $blockersHtml
        </div>
"@)
    }

    # === v1 render path: Milestone Progress + Phase Breakdown ===
    # v2 path produces the new Implementation Progress widget instead.
    $milestonesHtml = [System.Text.StringBuilder]::new()
    $phasesHtml     = [System.Text.StringBuilder]::new()
    $implementationProgressHtml = ""

    if ($manifestVersion -eq "v1") {
        # --- v1: Build milestone progress ---
        if ($feature.milestones) {
            foreach ($ms in $feature.milestones) {
                $msCompleted = 0
                $msTotal = $ms.taskIds.Count
                foreach ($tid in $ms.taskIds) {
                    if ($taskMap.ContainsKey($tid) -and $taskMap[$tid].status -eq "completed") {
                        $msCompleted++
                    }
                }
                $msPct = 0
                if ($msTotal -gt 0) { $msPct = [math]::Round(($msCompleted / $msTotal) * 100) }
                $msColor = if ($msPct -eq 100) { "#22c55e" } elseif ($msPct -gt 0) { "#3b82f6" } else { "#e2e8f0" }
                $msStatusIcon = if ($msPct -eq 100) { "&#9989;" } elseif ($msPct -gt 0) { "&#9203;" } else { "&#9711;" }
                [void]$milestonesHtml.Append(@"
            <div class="milestone-item">
                <span class="milestone-icon">$msStatusIcon</span>
                <span class="milestone-id">$(Escape-Html $ms.id)</span>
                <span class="milestone-name">$(Escape-Html $ms.name)</span>
                <span class="milestone-count">$msCompleted / $msTotal</span>
                <div class="milestone-bar"><div class="milestone-fill" style="width:$msPct%;background:$msColor"></div></div>
            </div>
"@)
            }
        }

        # --- v1: Build phase table ---
        if ($feature.phases) {
            foreach ($ph in $feature.phases) {
                $phTasks = @()
                foreach ($v in $taskMap.Values) {
                    if ($v.phase -eq $ph.id) { $phTasks += $v }
                }
                $phTotal = ($phTasks | Measure-Object).Count
                $phCompleted = 0
                foreach ($pt in $phTasks) {
                    if ($pt.status -eq "completed") { $phCompleted++ }
                }
                $phPct = 0
                if ($phTotal -gt 0) { $phPct = [math]::Round(($phCompleted / $phTotal) * 100) }
                $phColor = if ($phPct -eq 100) { "#22c55e" } elseif ($phPct -gt 0) { "#3b82f6" } else { "#e2e8f0" }
                [void]$phasesHtml.Append(@"
            <tr>
                <td>Phase $($ph.id)</td>
                <td>$(Escape-Html $ph.name)</td>
                <td><span class="phase-priority">$($ph.priority)</span></td>
                <td>$phCompleted / $phTotal</td>
                <td><div class="mini-bar"><div class="mini-fill" style="width:$phPct%;background:$phColor"></div></div></td>
            </tr>
"@)
            }
        }
    } else {
        # --- v2: render the Implementation Progress widget ---
        # $parsedTasks was already built above (early-parse) so the
        # summary-card counts and the completedUnion filter use the same
        # surface as this widget. We just pass it through here.
        $implementationProgressHtml = Render-ImplementationProgress `
            -feature $feature `
            -parsedTasks $parsedTasks `
            -agentOverlays $agentStatuses `
            -nowUtcIso $now `
            -completedUnion $completedUnion
    }

    # HITL alert
    $hitlAlertHtml = ""
    if ($anyHitl) {
        $hitlAlertHtml = '<div class="hitl-alert">&#9203; <strong>HUMAN-IN-THE-LOOP CHECKPOINT</strong> — One or more agents are waiting for human review.</div>'
    }

    # Blocked alert
    $blockedAlertHtml = ""
    if ($blockedAgents -gt 0) {
        $blockedAlertHtml = "<div class=""blocked-alert"">&#9940; <strong>$blockedAgents AGENT(S) BLOCKED</strong> — Immediate attention required.</div>"
    }

    $dashboardHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dashboard — Feature $(if ($feature.featureId) { $feature.featureId } else { '—' }): $(Escape-Html $feature.featureName)</title>
    <meta http-equiv="refresh" content="5">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; padding: 20px; }
        .container { max-width: 1400px; margin: 0 auto; }
        .header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 24px; }
        .header h1 { font-size: 24px; color: #f1f5f9; margin-bottom: 4px; }
        .header .subtitle { font-size: 14px; color: #94a3b8; }
        .header .links a { color: #60a5fa; text-decoration: none; font-size: 13px; display: block; margin-top: 2px; }
        .header .links a:hover { text-decoration: underline; }
        .last-updated { text-align: right; font-size: 12px; color: #64748b; }
        .last-updated strong { color: #94a3b8; }

        .summary-cards { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 24px; }
        .summary-card { background: #1e293b; border-radius: 12px; padding: 20px; text-align: center; }
        .summary-card .number { font-size: 36px; font-weight: 700; margin-bottom: 4px; }
        .summary-card .label { font-size: 12px; color: #94a3b8; text-transform: uppercase; letter-spacing: 1px; }
        .summary-card.green .number { color: #22c55e; }
        .summary-card.blue .number { color: #3b82f6; }
        .summary-card.red .number { color: #ef4444; }
        .summary-card.gray .number { color: #94a3b8; }

        .alerts { margin-bottom: 16px; }
        .hitl-alert { background: #422006; border: 1px solid #a16207; border-radius: 8px; padding: 12px 16px; margin-bottom: 8px; color: #fbbf24; font-size: 14px; }
        .blocked-alert { background: #450a0a; border: 1px solid #dc2626; border-radius: 8px; padding: 12px 16px; margin-bottom: 8px; color: #fca5a5; font-size: 14px; }

        .overall-progress { background: #1e293b; border-radius: 12px; padding: 24px; margin-bottom: 24px; }
        .overall-progress .progress-label { display: flex; justify-content: space-between; margin-bottom: 8px; font-size: 14px; }
        .overall-progress .progress-bar { height: 24px; background: #334155; border-radius: 12px; overflow: hidden; }
        .overall-progress .progress-fill { height: 100%; border-radius: 12px; transition: width 0.5s; background: #3b82f6; }

        .section { margin-bottom: 24px; }
        .section h2 { font-size: 18px; color: #f1f5f9; margin-bottom: 12px; padding-bottom: 8px; border-bottom: 1px solid #334155; }

        .agent-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }
        .agent-card { background: #1e293b; border-radius: 12px; padding: 20px; border-left: 4px solid #3b82f6; }
        .agent-header { display: flex; align-items: center; gap: 8px; margin-bottom: 16px; flex-wrap: wrap; }
        .agent-icon { font-size: 20px; }
        .agent-name { font-size: 16px; font-weight: 600; color: #f1f5f9; }
        .agent-id { font-size: 12px; color: #64748b; background: #0f172a; padding: 2px 8px; border-radius: 4px; }
        .agent-status-badge { font-size: 11px; padding: 2px 10px; border-radius: 12px; color: white; text-transform: uppercase; font-weight: 600; }
        .hitl-badge { font-size: 10px; padding: 2px 8px; border-radius: 4px; background: #a16207; color: #fbbf24; font-weight: 700; }
        .agent-stats { display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px; margin-bottom: 12px; }
        .stat { text-align: center; }
        .stat-label { display: block; font-size: 10px; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; }
        .stat-value { display: block; font-size: 14px; font-weight: 600; color: #e2e8f0; }
        .agent-card .progress-bar { height: 6px; background: #334155; border-radius: 3px; overflow: hidden; margin-bottom: 12px; }
        .agent-card .progress-fill { height: 100%; border-radius: 3px; transition: width 0.5s; }
        .task-chips { display: flex; flex-wrap: wrap; gap: 3px; margin-bottom: 8px; }
        .task-chip { font-size: 9px; padding: 2px 6px; border-radius: 3px; color: #0f172a; font-weight: 600; cursor: help; }
        .blockers { margin-top: 8px; }
        .blockers div { font-size: 12px; color: #fca5a5; padding: 2px 0; }

        .milestones { background: #1e293b; border-radius: 12px; padding: 20px; }
        .milestone-item { display: grid; grid-template-columns: auto auto 1fr auto 200px; align-items: center; gap: 12px; padding: 10px 0; border-bottom: 1px solid #334155; }
        .milestone-item:last-child { border-bottom: none; }
        .milestone-icon { font-size: 18px; }
        .milestone-id { font-size: 12px; font-weight: 700; color: #60a5fa; width: 30px; }
        .milestone-name { font-size: 14px; color: #e2e8f0; }
        .milestone-count { font-size: 13px; color: #94a3b8; font-weight: 600; }
        .milestone-bar { height: 8px; background: #334155; border-radius: 4px; overflow: hidden; }
        .milestone-fill { height: 100%; border-radius: 4px; transition: width 0.5s; }

        .phase-table { width: 100%; border-collapse: collapse; }
        .phase-table th { text-align: left; font-size: 12px; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; padding: 8px 12px; border-bottom: 2px solid #334155; }
        .phase-table td { padding: 10px 12px; font-size: 13px; border-bottom: 1px solid #334155; }
        .phase-table tr:last-child td { border-bottom: none; }
        .phase-priority { font-size: 10px; font-weight: 700; padding: 1px 6px; border-radius: 3px; background: #334155; }
        .mini-bar { width: 100px; height: 6px; background: #334155; border-radius: 3px; overflow: hidden; }
        .mini-fill { height: 100%; border-radius: 3px; }

        .legend { display: flex; gap: 16px; margin-bottom: 16px; font-size: 12px; color: #94a3b8; }
        .legend-item { display: flex; align-items: center; gap: 4px; }
        .legend-dot { width: 10px; height: 10px; border-radius: 50%; }

        /* ===== Implementation Progress widget (v2, design §4/§5) ===== */
        @keyframes task-spin { from { transform: rotate(0); } to { transform: rotate(360deg); } }
        .task-spin { animation: task-spin 2s linear infinite; transform-origin: 50% 50%; }

        .impl-section { background: #1e293b; border-radius: 12px; padding: 24px; }

        .impl-progress-bar { display: flex; align-items: center; gap: 16px; margin-bottom: 12px; }
        .impl-bar-track { flex: 1; height: 20px; background: #334155; border-radius: 10px; overflow: hidden; }
        .impl-bar-fill { height: 100%; border-radius: 10px; transition: width 0.5s; background: linear-gradient(90deg, #3b82f6, #22c55e); }
        .impl-bar-count { font-size: 14px; color: #e2e8f0; white-space: nowrap; }

        /* ===== Role sub-bars (approach b) ===== */
        .impl-role-bars { display: flex; flex-direction: column; gap: 6px; padding: 10px 12px; margin-bottom: 12px; background: #0f172a; border-radius: 8px; }
        .role-row { display: grid; grid-template-columns: 110px 1fr 110px; align-items: center; gap: 12px; }
        .role-label { font-size: 11px; color: #cbd5e1; text-transform: uppercase; letter-spacing: 0.05em; }
        .role-bar-track { height: 10px; background: #334155; border-radius: 5px; overflow: hidden; }
        .role-bar-fill { height: 100%; border-radius: 5px; transition: width 0.5s; }
        .role-count { font-size: 12px; color: #e2e8f0; font-variant-numeric: tabular-nums; text-align: right; }

        .impl-legend { display: flex; flex-wrap: wrap; gap: 18px; padding: 10px 12px; margin-bottom: 16px; background: #0f172a; border-radius: 8px; }
        .impl-legend .legend-item { display: flex; align-items: center; gap: 6px; }
        .impl-legend .legend-label { text-transform: uppercase; font-size: 10px; letter-spacing: 0.05em; color: #94a3b8; }

        /* ===== Theme/phase table (replaced per-task lines + Wave stub) ===== */
        .impl-theme-table-wrap { margin-top: 4px; }
        .impl-theme-table { width: 100%; border-collapse: collapse; }
        .impl-theme-table th { text-align: left; font-size: 11px; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; padding: 8px 10px; border-bottom: 2px solid #334155; }
        .impl-theme-table td { padding: 10px 10px; font-size: 13px; border-bottom: 1px solid #334155; }
        .impl-theme-table tr:last-child td { border-bottom: none; }
        .impl-theme-num { font-size: 12px; font-weight: 700; color: #60a5fa; white-space: nowrap; }
        .impl-theme-title { color: #e2e8f0; }
        .impl-theme-count { font-variant-numeric: tabular-nums; color: #94a3b8; white-space: nowrap; }
        .impl-theme-bar-cell { min-width: 200px; }
        .impl-mini-bar { width: 100%; height: 8px; background: #334155; border-radius: 4px; overflow: hidden; }
        .impl-mini-fill { height: 100%; border-radius: 4px; transition: width 0.5s; }
        .impl-theme-glyph { text-align: center; width: 32px; }

        .impl-empty { padding: 16px; color: #94a3b8; font-style: italic; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div>
                <h1>&#128640; Feature $(if ($feature.featureId) { $feature.featureId } else { '—' }): $(Escape-Html $feature.featureName)</h1>
                <div class="subtitle">Phase 7 — Implement | $(Escape-Html $feature.branch)</div>
                <div class="links">
                    <a href="$(Escape-Html $feature.prUrl)" target="_blank">PR #$(if ($feature.prUrl -match '/pull/(\d+)') { $matches[1] } else { '—' })</a>
                    <a href="$(Escape-Html $feature.issueUrl)" target="_blank">Issue Tracker</a>
                </div>
            </div>
            <div class="last-updated">
                <strong>Live Dashboard</strong><br>
                Auto-refresh: 5s<br>
                $nowDisplay
            </div>
        </div>

        <div class="summary-cards">
            <div class="summary-card green">
                <div class="number">$completedTasks</div>
                <div class="label">Tasks Completed</div>
            </div>
            <div class="summary-card blue">
                <div class="number">$inProgressTasks</div>
                <div class="label">In Progress</div>
            </div>
            <div class="summary-card red">
                <div class="number">$blockedTasks</div>
                <div class="label">Blocked</div>
            </div>
            <div class="summary-card gray">
                <div class="number">$completedAgents / $totalAgents</div>
                <div class="label">Agents Done</div>
            </div>
        </div>

        $hitlAlertHtml
        $blockedAlertHtml

        $(if ($manifestVersion -ne "v2") {
            # v1 manifests have no Implementation Progress widget — keep the
            # standalone Overall Progress block as their primary headline.
            # v2 dropped this block: the Implementation Progress widget's
            # own headline bar (rendered below) now serves as overall view.
            @"
        <div class="overall-progress">
            <div class="progress-label">
                <span><strong>Overall Progress</strong></span>
                <span>$completedTasks / $totalTasks tasks ($pctComplete%)</span>
            </div>
            <div class="progress-bar"><div class="progress-fill" style="width:$pctComplete%"></div></div>
        </div>
"@
        })

        <div class="legend">
            <div class="legend-item"><div class="legend-dot" style="background:#22c55e"></div> Completed</div>
            <div class="legend-item"><div class="legend-dot" style="background:#3b82f6"></div> In Progress</div>
            <div class="legend-item"><div class="legend-dot" style="background:#ef4444"></div> Blocked</div>
            <div class="legend-item"><div class="legend-dot" style="background:#e2e8f0"></div> Pending</div>
        </div>

        $(if ($manifestVersion -eq "v2") {
            @"
        <div class="section">
            <h2>&#128203; Implementation Progress</h2>
            <div class="impl-section">
                $implementationProgressHtml
            </div>
        </div>
"@
        } else {
            @"
        <div class="section">
            <h2>&#127937; Milestone Progress</h2>
            <div class="milestones">
                $($milestonesHtml.ToString())
            </div>
        </div>

        <div class="section">
            <h2>&#128203; Phase Breakdown</h2>
            <table class="phase-table">
                <thead>
                    <tr>
                        <th>Phase</th>
                        <th>Name</th>
                        <th>Priority</th>
                        <th>Tasks</th>
                        <th>Progress</th>
                    </tr>
                </thead>
                <tbody>
                    $($phasesHtml.ToString())
                </tbody>
            </table>
        </div>
"@
        })

        <div class="section">
            <h2>&#129302; Agent Status</h2>
            <div class="agent-grid">
                $($agentCardsHtml.ToString())
            </div>
        </div>
    </div>
</body>
</html>
"@

    return $dashboardHtml
}

<#
    Resume-Supervisor (Layer 3 — Wait & Relaunch)

    Non-LLM watcher loop. Per Quota-Block-Resilience-Plan.md §2/§6, the LLM
    never waits and never reasons about a reset timestamp — that is this
    loop's whole job. It does three things, in order, repeating forever
    (unless -ResumeTimeoutMinutes bounds it):

      1. Poll for a resume-signal.json (written externally by the Layer 2
         reset-time capture — inference proxy or harness wrapper; NOT by
         this script and NOT by any agent). Absence is the normal state.
      2. Once found, sleep until reset_at + -ResumeBufferSeconds has passed.
      3. Surface "ready to resume": write -ResumeReadyFile with the
         resume_command + timing, print a console banner, and (if
         -ResumeOpenRepo) best-effort open the repo so a human has a
         one-click path back in.

    After surfacing, it deletes its own in-memory "armed" state and goes
    back to polling for the NEXT signal (a human or scheduler consuming the
    ready-file is expected to remove/replace resume-signal.json once the
    relaunch actually happens; if it's still present next poll, this loop
    treats it as the same still-unconsumed signal and re-surfaces rather
    than re-waiting from scratch — safe because surfacing is idempotent).
#>
function Invoke-ResumeSupervisor {
    param(
        [string]$SignalPathFull,
        [string]$ReadyFileFull,
        [int]$BufferSeconds,
        [int]$PollSeconds,
        [int]$TimeoutMinutes,
        [switch]$OpenRepo,
        [string]$RepoRootForOpen
    )

    Write-Host "Resume-Supervisor started (Layer 3 — quota-block wake)."
    Write-Host "  Watching:    $SignalPathFull"
    Write-Host "  Ready file:  $ReadyFileFull"
    Write-Host "  Buffer:      ${BufferSeconds}s after reset_at"
    Write-Host "  Poll every:  ${PollSeconds}s"
    if ($TimeoutMinutes -gt 0) { Write-Host "  Timeout:     ${TimeoutMinutes}m" } else { Write-Host "  Timeout:     none (runs indefinitely)" }
    Write-Host ""

    $startTime = Get-Date
    $timeoutSeconds = $TimeoutMinutes * 60
    $lastSurfacedSignature = $null

    while ($true) {
        if ($TimeoutMinutes -gt 0) {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if ($elapsed -gt $timeoutSeconds) {
                Write-Host "Resume-Supervisor timeout reached (${TimeoutMinutes}m). Exiting."
                return
            }
        }

        $signal = Read-JsonFile $SignalPathFull
        if (-not $signal) {
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        # Signature de-dupes repeated surfacing of the identical signal
        # (e.g. supervisor restarted after already surfacing once).
        $signature = "$($signal.feature)|$($signal.reset_at)|$($signal.created_at)"

        $resetAt = ConvertTo-UtcDateTime $signal.reset_at
        if (-not $resetAt) {
            Write-Host "WARNING: resume-signal.json found but reset_at is missing/unparseable. Ignoring until it's fixed." -ForegroundColor Yellow
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        $wakeAt = $resetAt.AddSeconds($BufferSeconds)
        $now = [DateTime]::UtcNow

        if ($now -lt $wakeAt) {
            $remaining = [int]([Math]::Ceiling(($wakeAt - $now).TotalSeconds))
            $ts = (Get-Date).ToUniversalTime().ToString("HH:mm:ss")
            Write-Host "[$ts] Blocked-quota signal for '$($signal.feature)' — reset_at=$($signal.reset_at), waking in ${remaining}s (buffer=${BufferSeconds}s)"
            Start-Sleep -Seconds ([Math]::Min($PollSeconds, [Math]::Max(1, $remaining)))
            continue
        }

        if ($signature -eq $lastSurfacedSignature -and (Test-Path $ReadyFileFull)) {
            # Already surfaced this exact signal and the ready-file still
            # exists (nobody has consumed/cleared it yet) — nothing new to do.
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        # --- Surface resume-ready ---
        $readyPayload = [ordered]@{
            feature         = $signal.feature
            branch          = $signal.branch
            reason          = $signal.reason
            reset_at        = $signal.reset_at
            created_at      = $signal.created_at
            resume_command  = $signal.resume_command
            surfaced_at     = (Get-Date).ToUniversalTime().ToString("o")
            bufferSeconds   = $BufferSeconds
        }
        $readyDir = Split-Path -Parent $ReadyFileFull
        if ($readyDir -and -not (Test-Path $readyDir)) { New-Item -ItemType Directory -Path $readyDir -Force | Out-Null }
        $tempReady = "$ReadyFileFull.tmp"
        ($readyPayload | ConvertTo-Json -Depth 5) | Out-File -FilePath $tempReady -Encoding UTF8 -NoNewline
        Move-Item -Path $tempReady -Destination $ReadyFileFull -Force

        Write-Host ""
        Write-Host "=== RESUME READY ===" -ForegroundColor Green
        Write-Host "  Feature:  $($signal.feature)"
        Write-Host "  Branch:   $($signal.branch)"
        Write-Host "  Reason:   $($signal.reason)"
        Write-Host "  reset_at: $($signal.reset_at) (+ ${BufferSeconds}s buffer elapsed)"
        Write-Host "  Command:  $($signal.resume_command)"
        Write-Host "  Ready file written: $ReadyFileFull"
        Write-Host "====================" -ForegroundColor Green
        Write-Host ""

        if ($OpenRepo) {
            try {
                $codeCmd = Get-Command "code" -ErrorAction SilentlyContinue
                if ($codeCmd) {
                    Start-Process -FilePath $codeCmd.Source -ArgumentList @($RepoRootForOpen) -ErrorAction Stop
                    Write-Host "Opened $RepoRootForOpen in VS Code."
                } else {
                    Write-Host "NOTE: 'code' CLI not found on PATH — skipping auto-open. Open the repo manually and run the resume_command above." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "NOTE: failed to auto-open VS Code ($($_.Exception.Message)) — open the repo manually." -ForegroundColor Yellow
            }
        }

        $lastSurfacedSignature = $signature
        Start-Sleep -Seconds $PollSeconds
    }
}

if ($ResumeSupervisor) {
    $signalFull = if ([System.IO.Path]::IsPathRooted($ResumeSignalPath)) { $ResumeSignalPath } else { Join-Path $repoRoot $ResumeSignalPath }
    $readyFull  = if ([System.IO.Path]::IsPathRooted($ResumeReadyFile)) { $ResumeReadyFile } else { Join-Path $repoRoot $ResumeReadyFile }
    Invoke-ResumeSupervisor -SignalPathFull $signalFull -ReadyFileFull $readyFull -BufferSeconds $ResumeBufferSeconds -PollSeconds $ResumePollSeconds -TimeoutMinutes $ResumeTimeoutMinutes -OpenRepo:$ResumeOpenRepo -RepoRootForOpen $repoRoot
    exit 0
}

# --- -SelfTest branch: parse the configured tasks.md and exit. Does NOT
# --- start the loop. Used by the PM Stage-7 launch as a verification gate:
# --- task-count reconciliation at launch is load-bearing, not ceremony.
if ($SelfTest) {
    Write-Host "=== pm-dashboard-loop.ps1 -SelfTest ===" -ForegroundColor Cyan

    # Resolve which tasks.md to parse: explicit param > feature.json path > fail.
    $tasksMdPath = $SelfTestTasksMd
    if ([string]::IsNullOrWhiteSpace($tasksMdPath)) {
        $feature = Read-JsonFile (Join-Path $statusDirFull "feature.json")
        if ($feature -and $feature.tasksMdPath) {
            $tasksMdPath = Join-Path $repoRoot $feature.tasksMdPath
        }
    } elseif (-not [System.IO.Path]::IsPathRooted($tasksMdPath)) {
        $tasksMdPath = Join-Path $repoRoot $tasksMdPath
    }

    if ([string]::IsNullOrWhiteSpace($tasksMdPath)) {
        Write-Host "FAIL: no tasks.md path. Pass -SelfTestTasksMd or create .github/status/feature.json with tasksMdPath." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $tasksMdPath)) {
        Write-Host "FAIL: tasks.md not found at $tasksMdPath" -ForegroundColor Red
        exit 1
    }

    $parsed = Parse-TasksMd $tasksMdPath
    $totalTasks = 0
    $allIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $parsed.phases) {
        Write-Host ("  Phase {0} ({1}) [{2}]: {3} tasks" -f $p.index, $p.name, $p.kind, $p.tasks.Count)
        $totalTasks += $p.tasks.Count
        foreach ($t in $p.tasks) {
            if (-not [string]::IsNullOrEmpty($t.id)) { [void]$allIds.Add($t.id) }
        }
    }
    Write-Host ""
    Write-Host ("Total phases:  {0}" -f $parsed.phases.Count)
    Write-Host ("Total tasks:   {0}" -f $totalTasks)
    Write-Host ("Unique IDs:    {0}" -f $allIds.Count)
    $dups = $parsed.phases | ForEach-Object { $_.tasks } | Group-Object -Property id | Where-Object { $_.Count -gt 1 }
    if ($dups) {
        Write-Host ("Duplicate IDs: {0}" -f (($dups | ForEach-Object { $_.Name }) -join ", "))
    }

    # EXIT 2 — parse failed entirely (no phases / no tasks). Detects the
    # format-drift regression class (a tasks.md whose header conventions the
    # parser doesn't recognise silently produces empty renders).
    if ($parsed.phases.Count -eq 0 -or $totalTasks -eq 0) {
        Write-Host ""
        Write-Host "FAIL: parser recognised 0 phases or 0 tasks — tasks.md format drift?" -ForegroundColor Red
        Write-Host "      Inspect: header conventions supported: ## Phase N:, ### Phase N (label)," -ForegroundColor Yellow
        Write-Host "      ## Theme N — name, ### Theme N — name, ### TNNN [tags] desc," -ForegroundColor Yellow
        Write-Host "      - **TNNN** desc, - [ ] **TNNN** desc, - [ ] TNNN [tags] desc." -ForegroundColor Yellow
        exit 2
    }

    # EXIT 3 — reconciliation: does the parse agree with feature.initialTaskCount?
    # The manifest value is the dashboard's frozen-scope denominator; the parse
    # is the truth on disk. Mismatch → either the manifest is stale or the
    # parser missed/duplicated tasks. Either way, the PM must reconcile before
    # dispatching engineers.
    $feature = Read-JsonFile (Join-Path $statusDirFull "feature.json")
    if ($feature -and $feature.initialTaskCount) {
        $manifestCount = [int]$feature.initialTaskCount
        if ($manifestCount -ne $totalTasks) {
            Write-Host ""
            Write-Host ("FAIL: feature.initialTaskCount={0} but parser found {1} tasks" -f $manifestCount, $totalTasks) -ForegroundColor Red
            Write-Host "      Reconcile feature.json (or update tasks.md) before launching engineers." -ForegroundColor Yellow
            exit 3
        } else {
            Write-Host ("OK: feature.initialTaskCount={0} matches parsed task count." -f $manifestCount) -ForegroundColor Green
        }
    } else {
        Write-Host "OK: feature.json had no initialTaskCount to reconcile against (parsing-only run)." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "PASS: parser self-test ok." -ForegroundColor Green
    exit 0
}

# Main loop
Write-Host "PM Dashboard Monitor started."
Write-Host "  Status dir: $statusDirFull"
Write-Host "  Output:     $outputFileFull"
Write-Host "  Interval:   ${IntervalSeconds}s"
Write-Host "  Timeout:    ${TimeoutMinutes}m"
Write-Host ""

while ($true) {
    $elapsed = ((Get-Date) - $startTime).TotalSeconds

    if ($elapsed -gt $timeoutSeconds) {
        Write-Host "Timeout reached ($TimeoutMinutes min). Exiting."
        break
    }

    $feature = Read-JsonFile (Join-Path $statusDirFull "feature.json")
    if (-not $feature) {
        Write-Host "WARNING: feature.json not found. Waiting..."
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }

    $agentStatuses = Get-AgentStatuses $agentsDir

    # Render dashboard
    $html = Render-Dashboard $feature $agentStatuses

    # Write dashboard atomically
    $tempFile = "$outputFileFull.tmp"
    $html | Out-File -FilePath $tempFile -Encoding UTF8 -NoNewline
    Move-Item -Path $tempFile -Destination $outputFileFull -Force

    # Check if all agents are completed
    $totalAgents = $feature.agents.Count
    $agentFiles = @()
    if (Test-Path $agentsDir) {
        $agentFiles = Get-ChildItem -Path $agentsDir -Filter "*.json" -ErrorAction SilentlyContinue
    }

    $cCount = 0
    foreach ($s in $agentStatuses) { if ($s.status -eq "completed") { $cCount++ } }
    $bCount = 0
    foreach ($s in $agentStatuses) { if ($s.status -eq "blocked") { $bCount++ } }

    if ($agentFiles.Count -ge $totalAgents -and $totalAgents -gt 0 -and $cCount -ge $totalAgents) {
        Write-Host "All $totalAgents agents completed! Dashboard finalized."
        break
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("HH:mm:ss")
    Write-Host "[$timestamp] Dashboard rendered — Agents: $($agentFiles.Count)/$totalAgents | Completed: $cCount | Blocked: $bCount"

    Start-Sleep -Seconds $IntervalSeconds
}

Write-Host "PM Dashboard Monitor stopped."
