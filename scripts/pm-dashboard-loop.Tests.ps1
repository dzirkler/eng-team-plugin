# Pester regression tests for pm-dashboard-loop.ps1::Parse-TasksMd.
#
# Parser-drift coverage: keeps each in-the-wild tasks.md header/bullet
# format honest so a future refactor can't silently drop phases or tasks
# again.
#
# Run:
#   pwsh -NoProfile -Command "Invoke-Pester -Path scripts/pm-dashboard-loop.Tests.ps1 -Output Detailed"
# Or with legacy Pester 3.4 ships in this box:
#   pwsh -NoProfile -Command "Invoke-Pester -Path scripts/pm-dashboard-loop.Tests.ps1"
#
# Tests cover the four documented task formats AND the three phase formats:
#   Phase formats:   ## Phase N: name   |   ### Phase N (label)   |   ## Theme N — name   |   ### Theme N — name
#   Task formats:    ### TNNN [tags] desc   |   - **TNNN** desc   |   - [ ] **TNNN** desc   |   - [x] TNNN [tags] desc

# ---- lift functions under test out of the dashboard script via AST ----
# (avoids triggering the main loop). Both the test file and the dashboard
# script live side-by-side in this plugin's scripts/ directory.
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$dashPath    = Join-Path $scriptDir "pm-dashboard-loop.ps1"
$tokens      = $null; $parseErrors = $null
$ast         = [System.Management.Automation.Language.Parser]::ParseFile($dashPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw ("Dashboard script has parse errors: " + ($parseErrors -join "; "))
}
$funcNames = @('Parse-TasksMd', 'Normalize-TaskId')
foreach ($fn in $funcNames) {
    # Build a predicate closed over the local $fn name (PS closures over a
    # foreach-loop variable don't capture the current value reliably under
    # AST FindAll — we explicitly bind via [ScriptBlock]::Create).
    $predicate = [ScriptBlock]::Create(
        "param(`$node); `$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -eq '$fn'"
    )
    $bodies = $ast.FindAll($predicate, $true)
    $body = $bodies | Where-Object { $_.Name -eq $fn } | Select-Object -First 1
    if (-not $body) { throw "Function $fn not found in $dashPath" }
    Invoke-Expression ($body.ToString())
}

# ---- shared fixture writer ----
function Write-Fixture($content) {
    $path = [System.IO.Path]::GetTempFileName() + ".md"
    Set-Content -Path $path -Value $content -Encoding UTF8 -NoNewline
    return $path
}

Describe "Parse-TasksMd task header formats" {
    It "parses H3-header task form: ### TNNN [tags] description" {
        $p = Write-Fixture @'
## Phase 1: Header

### T001 [All_ACs] [P] First task description
### T002 Second task with multi-line body that should not affect parse

## Phase 2: Second

### T003a [P] Suffix task
'@
        try {
            $r = Parse-TasksMd $p
            $r.phases.Count | Should Be 2
            $r.phases[0].tasks.Count | Should Be 2
            $r.phases[0].tasks[0].id | Should Be "T001"
            $r.phases[1].tasks[0].id | Should Be "T003a"
            # Tag cluster stripped from the description
            $r.phases[0].tasks[0].name | Should Be "First task description"
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }

    It "parses bullet+bold form: - **TNNN** description" {
        $p = Write-Fixture @'
### Theme 1 - Setup
- **T001** First task description
- **T002** Second task description
'@
        try {
            $r = Parse-TasksMd $p
            $r.phases[0].kind | Should Be "theme"
            $r.phases[0].tasks.Count | Should Be 2
            $r.phases[0].tasks[0].id | Should Be "T001"
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }

    It "parses checkbox+bold form: - [ ] **TNNN** description" {
        $p = Write-Fixture @'
### Theme 1 - Setup
- [ ] **T001** First task description
- [x] **T002** Checked but still a task per parser
'@
        try {
            $r = Parse-TasksMd $p
            $r.phases[0].tasks.Count | Should Be 2
            $r.phases[0].tasks[1].id | Should Be "T002"
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }

    It "parses checkbox+unbold form: - [x] TNNN [tags] description" {
        $p = Write-Fixture @'
## Phase 1: Header
- [x] T001 First task without bolding
- [ ] T002 [P] [US1] Tagged task with no bolding
'@
        try {
            $r = Parse-TasksMd $p
            $r.phases[0].tasks.Count | Should Be 2
            $r.phases[0].tasks[0].name | Should Be "First task without bolding"
            $r.phases[0].tasks[1].name | Should Be "Tagged task with no bolding"
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Parse-TasksMd phase header formats" {
    It "parses H2 colon phase header: ## Phase N: name" {
        $p = Write-Fixture @'
## Phase 1: Foundational work

### T001 do something
'@
        try {
            $r = Parse-TasksMd $p
            $r.phases.Count | Should Be 1
            $r.phases[0].kind | Should Be "phase"
            $r.phases[0].index | Should Be 1
            $r.phases[0].name | Should Be "Foundational work"
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }

    It "parses H3 parens phase header: ### Phase N (label)" {
        $p = Write-Fixture @'
### Phase 1 (Foundation)

- **T001** task one
'@
        try {
            $r = Parse-TasksMd $p
            $r.phases[0].kind | Should Be "phase"
            $r.phases[0].name | Should Be "Foundation"
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }

    It "parses H2/H3 theme em-dash variants: ## Theme N — name and ### Theme N — name" {
        $p = Write-Fixture @'
## Theme 1 — First theme

- **T001** task

### Theme 2 — Second theme

- **T002** another
'@
        try {
            $r = Parse-TasksMd $p
            $r.phases.Count | Should Be 2
            $r.phases[0].kind | Should Be "theme"
            $r.phases[1].name | Should Be "Second theme"
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }

    It "H2 non-phase/non-theme headers CLOSE task collection" {
        # Reproduces the checkbox-style Dependencies-section concern: bullets
        # after a ## Dependencies H2 should NOT be counted as tasks.
        $p = Write-Fixture @'
## Phase 1: Setup

### T001 task one

## Dependencies

- **T001** depends on something else
- **T002** depends on something else
'@
        try {
            $r = Parse-TasksMd $p
            $total = 0
            foreach ($ph in $r.phases) { $total += $ph.tasks.Count }
            $total | Should Be 1
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Parse-TasksMd synthetic fallback + Normalize-TaskId" {
    It "creates a synthetic 'Tasks' phase when tasks appear before any phase header" {
        $p = Write-Fixture @'
- **T001** task one
- **T002** task two
'@
        try {
            $r = Parse-TasksMd $p
            $r.phases.Count | Should Be 1
            $r.phases[0].kind | Should Be "synthetic"
            $r.phases[0].tasks.Count | Should Be 2
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }

    It "Normalize-TaskId flattens parenthesised suffixes (T012(a) -> T012a)" {
        Normalize-TaskId "T012(a)" | Should Be "T012a"
        Normalize-TaskId "T012"     | Should Be "T012"
        Normalize-TaskId "T012b"    | Should Be "T012b"
    }
}

Describe "Parse-TasksMd real-repo smoke tests (skippable)" {
    # These two tests parse a REAL tasks.md from a consuming repo to catch
    # subtle parser regressions against genuine in-the-wild fixtures. The
    # plugin ships no fixtures of its own, so each test gracefully SKIPS
    # when its target file is absent. Set the `SDD_TEST_REPO_ROOT` env var
    # (or edit the default below) to point at a consuming repo whose
    # specs/ tree contains tasks.md fixtures you want to exercise.
    $testRepoRoot = $env:SDD_TEST_REPO_ROOT
    if ([string]::IsNullOrWhiteSpace($testRepoRoot)) {
        $testRepoRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $scriptDir)) "social-campaign-manager"
    }

    # Pester v5 ships Set-ItResult -Skipped; older versions (v3/v4) do not.
    # Wrap so the plugin's tests pass on any Pester version.
    function Skip-Test($reason) {
        if (Get-Command Set-ItResult -ErrorAction SilentlyContinue) {
            Set-ItResult -Skipped -Because $reason
        } else {
            Write-Warning "SKIP: $reason"
            return
        }
    }

    It "real tasks.md (colon-form phases, H3-header tasks): 5 phases, 13 tasks" {
        $p = Join-Path $testRepoRoot "specs/017-assistant-rename-folder/tasks.md"
        if (-not (Test-Path $p)) { Skip-Test "fixture not found at $p (set SDD_TEST_REPO_ROOT to enable)"; return }
        $r = Parse-TasksMd $p
        $r.phases.Count | Should Be 5
        $total = 0
        foreach ($ph in $r.phases) { $total += $ph.tasks.Count }
        $total | Should Be 13
    }

    It "real tasks.md (checkbox bullet form): 8 phases, 41 tasks" {
        $p = Join-Path $testRepoRoot "specs/016-post-level-analytics/tasks.md"
        if (-not (Test-Path $p)) { Skip-Test "fixture not found at $p (set SDD_TEST_REPO_ROOT to enable)"; return }
        $r = Parse-TasksMd $p
        $r.phases.Count | Should Be 8
        $total = 0
        foreach ($ph in $r.phases) { $total += $ph.tasks.Count }
        $total | Should Be 41
    }
}
