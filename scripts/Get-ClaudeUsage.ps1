<#
.SYNOPSIS
    Scans Claude Code session transcripts and generates a static HTML usage report.

.DESCRIPTION
    Reads JSONL session files from ~/.claude/projects/, aggregates token usage
    by project, model, day, and individual prompt.

    Two output modes:
      Default (HTML): Writes report.html (metadata only — no prompt text) and
      report-detail.html (same data plus full prompt text). Use -NoDetail to
      skip writing the detail report entirely.

      Structured (-Json): Emits a JSON object to stdout that includes both
      metadata and prompt text. Used by the claude-usage-analyzer skill.
      Output encoding is forced to UTF-8.

.PARAMETER Days
    Only include turns from the last N days. 0 or unset = all history.

.PARAMETER OutFile
    Path to write the HTML report. Default: report.html next to this script.

.PARAMETER ProjectsDir
    Directory containing per-project session subfolders. Default: ~/.claude/projects (resolved via $HOME).

.PARAMETER NoOpen
    Do not auto-open the report in the default browser.

.PARAMETER NoDetail
    Skip writing the detail report (report-detail.html). Only the metadata-only
    report.html is written. Prompt text is not read from disk in this mode.

.PARAMETER Json
    Emit structured JSON to stdout instead of writing HTML files. Includes
    metadata and prompt text. Encoding is forced to UTF-8 (no BOM). This is
    the mode used by the claude-usage-analyzer skill — do not combine with
    -NoDetail (it has no effect in JSON mode).

.EXAMPLE
    .\Get-ClaudeUsage.ps1
    Scan everything, write report.html, open it.

.EXAMPLE
    .\Get-ClaudeUsage.ps1 -Days 30 -NoOpen
    Last 30 days only, do not open browser.
#>

[CmdletBinding()]
param(
    [int]$Days = 0,
    [string]$OutFile,
    [string]$ProjectsDir,
    [switch]$NoOpen,
    [switch]$NoDetail,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# Ensure JSON output is UTF-8 without BOM when -Json is set
if ($Json) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}

# Progress writer that respects -Json (silent in JSON mode so stdout stays clean)
function Write-Info {
    param([string]$Message, [string]$ForegroundColor)
    if ($Json) { return }
    if ($ForegroundColor) { Write-Host $Message -ForegroundColor $ForegroundColor }
    else { Write-Host $Message }
}

# ----- Pricing (USD per million tokens). Edit here to update. -----
# Source: claude.com/pricing#api - verify before relying on totals.
$Pricing = @{
    'opus-4-7'   = @{ Input = 5.00; Output = 25.00; CacheWrite = 6.25; CacheRead = 0.50 }
    'opus-4-6'   = @{ Input = 5.00; Output = 25.00; CacheWrite = 6.25; CacheRead = 0.50 }
    'sonnet-4-6' = @{ Input = 3.00; Output = 15.00; CacheWrite = 3.75; CacheRead = 0.30 }
    'haiku-4-5'  = @{ Input = 1.00; Output = 5.00;  CacheWrite = 1.25; CacheRead = 0.10 }
}

function Get-ModelPricing {
    param([string]$Model)
    if ([string]::IsNullOrEmpty($Model)) { return $null }
    foreach ($key in $Pricing.Keys) {
        if ($Model -like "*$key*") { return $Pricing[$key] }
    }
    return $null
}

function Get-TurnCost {
    param([string]$Model, [long]$In, [long]$Out, [long]$Cw, [long]$Cr)
    $p = Get-ModelPricing -Model $Model
    if ($null -eq $p) { return $null }
    return ($In * $p.Input + $Out * $p.Output + $Cw * $p.CacheWrite + $Cr * $p.CacheRead) / 1000000.0
}

function ConvertTo-HtmlEscaped {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

function ConvertTo-SafeJson {
    param($Object)
    # Depth 10 covers our nested aggregates. -Compress for smaller output.
    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    # Prevent </script> breakout if any value contained a literal </
    return $json.Replace('</', '<\/')
}

function Get-UserPromptText {
    # Return the human-typed prompt text, or $null if this user record is
    # auto-injected context (tool results, IDE hints, slash command output).
    param($Content)
    if ($null -eq $Content) { return $null }
    if ($Content -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Content)) { return $null }
        $trimmed = $Content.Trim()
        if ($trimmed -match '^<(\w[\w-]*)>[\s\S]*</\1>$') { return $null }
        return $Content
    }
    $autoTags = 'ide_opened_file|system-reminder|command-message|command-name|command-args|local-command-stdout|local-command-stderr|user-prompt-submit-hook'
    $texts = @()
    foreach ($block in $Content) {
        if ($null -eq $block) { continue }
        if ($block.type -ne 'text') { continue }
        $text = [string]$block.text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $trimmed = $text.Trim()
        if ($trimmed -match "^<($autoTags)>[\s\S]*</\1>$") { continue }
        $texts += $text
    }
    if ($texts.Count -eq 0) { return $null }
    return ($texts -join "`n`n")
}

# ----- Resolve paths -----
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ProjectsDir) { $ProjectsDir = [System.IO.Path]::Combine($HOME, '.claude', 'projects') }
if (-not $OutFile) {
    # When the script lives inside a scripts/ subdirectory (typical plugin layout),
    # write reports to the parent so they're discoverable at the plugin root.
    $reportDir = if ((Split-Path -Leaf $scriptDir) -ieq 'scripts') { Split-Path -Parent $scriptDir } else { $scriptDir }
    $OutFile = Join-Path $reportDir 'report.html'
}

if (-not (Test-Path -LiteralPath $ProjectsDir)) {
    Write-Error "Projects directory not found: $ProjectsDir"
    exit 1
}

Write-Info "Scanning $ProjectsDir ..."

# ----- Scan -----
$cutoff = $null
if ($Days -gt 0) { $cutoff = (Get-Date).ToUniversalTime().AddDays(-$Days) }

$seenMessageIds = New-Object 'System.Collections.Generic.HashSet[string]'
$turns = New-Object 'System.Collections.Generic.List[object]'
$userPrompts = [ordered]@{}  # uuid -> aggregate prompt object

$jsonlFiles = Get-ChildItem -LiteralPath $ProjectsDir -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue
$fileCount = $jsonlFiles.Count
$fileIdx = 0
$lineErrors = 0

foreach ($file in $jsonlFiles) {
    $fileIdx++
    if ($fileIdx % 5 -eq 0 -or $fileIdx -eq $fileCount) {
        Write-Info "  [$fileIdx/$fileCount] $($file.Name)"
    }

    # Project name = basename of cwd from record (preferred) or basename of folder name
    $folderName = $file.Directory.Name
    $folderProject = ($folderName -split '-')[-1]
    if ([string]::IsNullOrEmpty($folderProject)) { $folderProject = $folderName }

    # Track current user prompt per chain (main vs sidechain/subagent) within this file
    $currentMainPromptKey = $null
    $currentSidePromptKey = $null

    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $rec = $line | ConvertFrom-Json
        } catch {
            $lineErrors++
            continue
        }

        # User-prompt detection: any user record with real (non-auto-injected) text
        # becomes the "current prompt" that subsequent assistant turns aggregate under.
        if ($rec.type -eq 'user' -and $null -ne $rec.message) {
            $promptText = Get-UserPromptText -Content $rec.message.content
            if ($null -ne $promptText) {
                $promptKey = [string]$rec.uuid
                if (-not [string]::IsNullOrEmpty($promptKey)) {
                    $pTsStr = [string]$rec.timestamp
                    $pTs = $null
                    if (-not [string]::IsNullOrEmpty($pTsStr)) {
                        try { $pTs = [datetime]::Parse($pTsStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $pTs = $null }
                    }
                    $pCwd = [string]$rec.cwd
                    $pProject = $null
                    if (-not [string]::IsNullOrEmpty($pCwd)) { $pProject = Split-Path -Path $pCwd -Leaf }
                    if ([string]::IsNullOrEmpty($pProject)) { $pProject = $folderProject }
                    $pSession = [string]$rec.sessionId
                    if ([string]::IsNullOrEmpty($pSession)) { $pSession = $file.BaseName }

                    $userPrompts[$promptKey] = [pscustomobject]@{
                        key         = $promptKey
                        ts          = if ($null -ne $pTs) { $pTs.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { '' }
                        tsTicks     = if ($null -ne $pTs) { $pTs.Ticks } else { 0 }
                        project     = $pProject
                        session     = $pSession
                        text        = $promptText
                        isSidechain = [bool]$rec.isSidechain
                        turns       = 0
                        models      = (New-Object 'System.Collections.Generic.HashSet[string]')
                        inTok       = 0L; outTok = 0L; crTok = 0L; cwTok = 0L
                        cost        = 0.0
                        unpriced    = $false
                    }

                    if ([bool]$rec.isSidechain) { $currentSidePromptKey = $promptKey }
                    else { $currentMainPromptKey = $promptKey }
                }
            }
            continue
        }

        if ($rec.type -ne 'assistant') { continue }
        if ($null -eq $rec.message) { continue }
        if ($null -eq $rec.message.usage) { continue }

        # Dedup: same message.id appears across multiple records (split responses)
        $msgId = $rec.message.id
        if ([string]::IsNullOrEmpty($msgId)) { continue }
        if (-not $seenMessageIds.Add($msgId)) { continue }

        $tsStr = [string]$rec.timestamp
        $ts = $null
        if (-not [string]::IsNullOrEmpty($tsStr)) {
            try { $ts = [datetime]::Parse($tsStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $ts = $null }
        }
        if ($null -ne $cutoff -and $null -ne $ts -and $ts -lt $cutoff) { continue }

        $cwd = [string]$rec.cwd
        $project = $null
        if (-not [string]::IsNullOrEmpty($cwd)) {
            $project = Split-Path -Path $cwd -Leaf
        }
        if ([string]::IsNullOrEmpty($project)) { $project = $folderProject }

        $sessionId = [string]$rec.sessionId
        if ([string]::IsNullOrEmpty($sessionId)) { $sessionId = $file.BaseName }

        $u = $rec.message.usage
        $inTok = 0L; $outTok = 0L; $crTok = 0L; $cwTok = 0L
        if ($null -ne $u.input_tokens) { $inTok = [long]$u.input_tokens }
        if ($null -ne $u.output_tokens) { $outTok = [long]$u.output_tokens }
        if ($null -ne $u.cache_read_input_tokens) { $crTok = [long]$u.cache_read_input_tokens }
        if ($null -ne $u.cache_creation_input_tokens) { $cwTok = [long]$u.cache_creation_input_tokens }

        $model = [string]$rec.message.model
        $cost = Get-TurnCost -Model $model -In $inTok -Out $outTok -Cw $cwTok -Cr $crTok

        $turn = [pscustomobject]@{
            ts        = if ($null -ne $ts) { $ts.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { '' }
            tsTicks   = if ($null -ne $ts) { $ts.Ticks } else { 0 }
            date      = if ($null -ne $ts) { $ts.ToString("yyyy-MM-dd") } else { '' }
            project   = $project
            session   = $sessionId
            model     = if ($model) { $model } else { '(unknown)' }
            inTok     = $inTok
            outTok    = $outTok
            crTok     = $crTok
            cwTok     = $cwTok
            cost      = $cost
        }
        $turns.Add($turn) | Out-Null

        # Attribute this turn to its parent user prompt (main vs sidechain)
        $parentKey = if ([bool]$rec.isSidechain) { $currentSidePromptKey } else { $currentMainPromptKey }
        if ($parentKey -and $userPrompts.Contains($parentKey)) {
            $p = $userPrompts[$parentKey]
            $p.turns++
            if ($turn.model) { [void]$p.models.Add($turn.model) }
            $p.inTok  += $inTok
            $p.outTok += $outTok
            $p.crTok  += $crTok
            $p.cwTok  += $cwTok
            if ($null -ne $cost) { $p.cost += $cost } else { $p.unpriced = $true }
        }
    }
}

Write-Info ""
Write-Info "Scanned $($turns.Count) turns from $fileCount file(s). Skipped $lineErrors malformed line(s)."

# ----- Aggregate -----
$summary = [ordered]@{
    totalPrompts    = $turns.Count
    totalInput      = 0L
    totalOutput     = 0L
    totalCacheRead  = 0L
    totalCacheWrite = 0L
    totalCost       = 0.0
    anyUnpriced     = $false
    numProjects     = 0
    numSessions     = 0
    firstDate       = $null
    lastDate        = $null
}

$projAgg = @{}   # name -> agg
$modelAgg = @{}  # name -> agg
$dailyAgg = @{}  # yyyy-MM-dd -> agg
$sessions = New-Object 'System.Collections.Generic.HashSet[string]'

function New-Agg {
    return [ordered]@{
        prompts = 0L; input = 0L; output = 0L; cacheRead = 0L; cacheWrite = 0L; cost = 0.0; unpriced = $false; sessions = (New-Object 'System.Collections.Generic.HashSet[string]')
    }
}

foreach ($t in $turns) {
    $summary.totalInput      += $t.inTok
    $summary.totalOutput     += $t.outTok
    $summary.totalCacheRead  += $t.crTok
    $summary.totalCacheWrite += $t.cwTok
    if ($null -ne $t.cost) { $summary.totalCost += $t.cost } else { $summary.anyUnpriced = $true }

    if ($t.session) { [void]$sessions.Add($t.session) }
    if ($t.ts) {
        if ($null -eq $summary.firstDate -or $t.ts -lt $summary.firstDate) { $summary.firstDate = $t.ts }
        if ($null -eq $summary.lastDate  -or $t.ts -gt $summary.lastDate)  { $summary.lastDate  = $t.ts }
    }

    # Project agg
    if (-not $projAgg.ContainsKey($t.project)) { $projAgg[$t.project] = New-Agg }
    $a = $projAgg[$t.project]
    $a.prompts++; $a.input += $t.inTok; $a.output += $t.outTok; $a.cacheRead += $t.crTok; $a.cacheWrite += $t.cwTok
    if ($null -ne $t.cost) { $a.cost += $t.cost } else { $a.unpriced = $true }
    if ($t.session) { [void]$a.sessions.Add($t.session) }

    # Model agg
    if (-not $modelAgg.ContainsKey($t.model)) { $modelAgg[$t.model] = New-Agg }
    $m = $modelAgg[$t.model]
    $m.prompts++; $m.input += $t.inTok; $m.output += $t.outTok; $m.cacheRead += $t.crTok; $m.cacheWrite += $t.cwTok
    if ($null -ne $t.cost) { $m.cost += $t.cost } else { $m.unpriced = $true }

    # Daily agg
    if ($t.date) {
        if (-not $dailyAgg.ContainsKey($t.date)) { $dailyAgg[$t.date] = New-Agg }
        $d = $dailyAgg[$t.date]
        $d.prompts++; $d.cost += if ($null -ne $t.cost) { $t.cost } else { 0.0 }
    }
}

$summary.numSessions = $sessions.Count
$summary.numProjects = $projAgg.Count

# Build sortable arrays for JSON output
$projects = @()
foreach ($k in $projAgg.Keys) {
    $a = $projAgg[$k]
    $projects += [ordered]@{
        name = $k; sessions = $a.sessions.Count; prompts = $a.prompts
        input = $a.input; output = $a.output; cacheRead = $a.cacheRead; cacheWrite = $a.cacheWrite
        cost = [math]::Round($a.cost, 4); unpriced = $a.unpriced
    }
}
$projects = $projects | Sort-Object { -$_.cost }

$models = @()
foreach ($k in $modelAgg.Keys) {
    $a = $modelAgg[$k]
    $models += [ordered]@{
        name = $k; prompts = $a.prompts
        input = $a.input; output = $a.output; cacheRead = $a.cacheRead; cacheWrite = $a.cacheWrite
        cost = [math]::Round($a.cost, 4); unpriced = $a.unpriced
    }
}
$models = $models | Sort-Object { -$_.cost }

$daily = @()
foreach ($k in ($dailyAgg.Keys | Sort-Object)) {
    $a = $dailyAgg[$k]
    $daily += [ordered]@{ date = $k; prompts = $a.prompts; cost = [math]::Round($a.cost, 4) }
}

# Per-user-prompt list. Only include prompts that actually got an assistant response.
# Sort on the PSCustomObject form (Sort-Object reads properties reliably), then
# project into ordered dicts for JSON output (without the tsTicks sort key).
$promptsRaw = @()
foreach ($k in $userPrompts.Keys) {
    $p = $userPrompts[$k]
    if ($p.turns -eq 0) { continue }
    $promptsRaw += $p
}
$promptsRaw = $promptsRaw | Sort-Object -Property tsTicks -Descending

$prompts = @()
foreach ($p in $promptsRaw) {
    $prompts += [ordered]@{
        ts          = $p.ts
        project     = $p.project
        session     = $p.session
        text        = $p.text
        isSidechain = $p.isSidechain
        turns       = $p.turns
        models      = (($p.models | Sort-Object) -join ', ')
        inTok       = $p.inTok
        outTok      = $p.outTok
        crTok       = $p.crTok
        cwTok       = $p.cwTok
        cost        = [math]::Round($p.cost, 6)
        unpriced    = $p.unpriced
    }
}

$summary.totalCost = [math]::Round($summary.totalCost, 4)
$summary.totalUserPrompts = $prompts.Count
$summary.totalAssistantTurns = $summary.totalPrompts
$summary.Remove('totalPrompts') | Out-Null

$generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")

function New-Payload {
    param([bool]$IncludeText)
    $promptsCopy = @()
    foreach ($p in $prompts) {
        $entry = [ordered]@{}
        foreach ($k in $p.Keys) {
            if ($k -eq 'text' -and -not $IncludeText) { $entry[$k] = '' } else { $entry[$k] = $p[$k] }
        }
        $promptsCopy += $entry
    }
    return [ordered]@{
        generatedAt = $generatedAt
        daysFilter  = $Days
        projectsDir = $ProjectsDir
        includeText = $IncludeText
        summary     = $summary
        projects    = $projects
        models      = $models
        daily       = $daily
        prompts     = $promptsCopy
    }
}

# ----- JSON output mode (for the claude-usage-analyzer skill) -----
if ($Json) {
    $payload = New-Payload -IncludeText $true
    ConvertTo-Json -InputObject $payload -Depth 10 -Compress
    return
}

# ----- HTML template -----
$html = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src data:;">
<title>Claude Usage Report</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght,SOFT@0,9..144,400..700,30..100;1,9..144,400..700,30..100&family=Geist:wght@300..700&family=JetBrains+Mono:wght@400;500;600&display=swap">
<style>
  /* === EDITORIAL DISPATCH ===
     Warm paper-cream by day, deep ink-and-amber by night.
     Display: Georgia.  Body: Segoe UI Variable.  Numbers: Cascadia Mono.
  */
  :root {
    --bg: #faf6ec;
    --bg-card: #fffdf6;
    --bg-elev: #f1ead7;
    --bg-deep: #ebe2c8;
    --ink: #1c1814;
    --ink-strong: #0a0805;
    --ink-muted: #6b5d4a;
    --ink-faint: #b0a48c;
    --rule: #d8ccb0;
    --rule-strong: #968864;
    --accent: #b4530c;
    --accent-strong: #7a3805;
    --accent-soft: rgba(180, 83, 12, 0.08);
    --accent-glow: rgba(180, 83, 12, 0.25);
    --danger: #b91c1c;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0c0a07;
      --bg-card: #15110b;
      --bg-elev: #1d1810;
      --bg-deep: #08060a;
      --ink: #ede4cf;
      --ink-strong: #fff8e4;
      --ink-muted: #968870;
      --ink-faint: #56503e;
      --rule: #2a241a;
      --rule-strong: #4a4233;
      --accent: #f59e0b;
      --accent-strong: #fbbf24;
      --accent-soft: rgba(245, 158, 11, 0.10);
      --accent-glow: rgba(245, 158, 11, 0.4);
      --danger: #ef4444;
    }
  }

  /* Font stacks (variable web fonts with system fallbacks) */
  :root {
    --font-display: "Fraunces", Georgia, "Bookman Old Style", "Times New Roman", serif;
    --font-body: "Geist", "Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, sans-serif;
    --font-mono: "JetBrains Mono", "Cascadia Mono", "Consolas", ui-monospace, monospace;
    --font-label: "Geist", "Segoe UI Variable Small", "Segoe UI", system-ui, sans-serif;
  }

  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body {
    background: var(--bg); color: var(--ink); min-height: 100vh;
    font: 14px/1.55 var(--font-body);
    font-feature-settings: "ss01", "ss02";
    background-image:
      radial-gradient(ellipse 1200px 600px at 70% -100px, var(--accent-soft) 0%, transparent 60%),
      radial-gradient(ellipse 800px 500px at 10% 100%, var(--bg-elev) 0%, transparent 70%);
    background-attachment: fixed;
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
  }
  ::selection { background: var(--accent); color: var(--bg); }
  ::-webkit-scrollbar { width: 10px; height: 10px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--rule); border: 2px solid var(--bg); border-radius: 6px; }
  ::-webkit-scrollbar-thumb:hover { background: var(--rule-strong); }

  .wrap { max-width: 1280px; margin: 0 auto; padding: 64px 56px 96px; }

  /* === NAMEPLATE === */
  .nameplate {
    display: flex; align-items: center; justify-content: space-between;
    margin-bottom: 40px; gap: 24px; flex-wrap: wrap;
  }
  .brand {
    display: flex; align-items: center; gap: 12px;
    font: 600 10px/1 var(--font-label);
    letter-spacing: 0.22em; text-transform: uppercase; color: var(--ink-muted);
  }
  .brand-mark {
    width: 9px; height: 9px; border-radius: 50%;
    background: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft);
    animation: pulse 2.2s ease-in-out infinite;
  }
  @keyframes pulse {
    0%, 100% { box-shadow: 0 0 0 3px var(--accent-soft); transform: scale(1); }
    50% { box-shadow: 0 0 0 6px var(--accent-soft); transform: scale(1.05); }
  }
  .timestamp {
    font: 10px var(--font-mono);
    color: var(--ink-faint); letter-spacing: 0.08em; text-transform: uppercase;
  }

  h1.title {
    font: italic 400 84px/0.92 var(--font-display);
    font-variation-settings: "SOFT" 70, "opsz" 144;
    letter-spacing: -0.03em; color: var(--ink-strong);
    margin: 0 0 18px;
  }
  h1.title .amp {
    color: var(--accent); font-style: italic;
    font-variation-settings: "SOFT" 100, "opsz" 144, "wght" 500;
  }

  .subtitle {
    font: 11px var(--font-mono);
    color: var(--ink-muted); letter-spacing: 0.06em;
    text-transform: uppercase;
  }
  .subtitle .dot { color: var(--ink-faint); margin: 0 12px; }
  .subtitle code { color: var(--accent); background: transparent; padding: 0;
    font-family: inherit; text-transform: none; letter-spacing: 0.02em; }

  /* === SECTION === */
  section { margin: 56px 0; }
  h2.section-title {
    font: 600 10px/1 var(--font-label);
    letter-spacing: 0.26em; text-transform: uppercase; color: var(--ink-muted);
    margin: 0 0 24px;
    display: flex; align-items: center; gap: 14px;
  }
  h2.section-title svg.section-icon {
    width: 16px; height: 16px; color: var(--accent);
    stroke-width: 1.5; flex-shrink: 0;
  }
  h2.section-title::after {
    content: ''; flex: 1; height: 1px; background: var(--rule);
    margin-left: 8px; max-width: 80px;
  }
  h2.section-title .note {
    font-weight: 400; text-transform: none; letter-spacing: 0.01em;
    color: var(--ink-faint); font-family: var(--font-mono);
    font-size: 11px;
  }
  h2.section-title .note code { color: var(--accent); background: transparent; }

  /* === HERO === */
  .hero {
    display: grid; grid-template-columns: repeat(4, 1fr);
    gap: 40px;
    padding: 40px 0 44px;
    border-top: 1px solid var(--rule);
    border-bottom: 1px solid var(--rule);
  }
  .hero-stat .stat-label {
    font: 600 10px/1 var(--font-label);
    letter-spacing: 0.22em; text-transform: uppercase;
    color: var(--ink-muted); margin-bottom: 16px;
  }
  .hero-stat .stat-value {
    font: 400 52px/1 var(--font-display);
    font-variation-settings: "SOFT" 60, "opsz" 72;
    color: var(--ink-strong); letter-spacing: -0.025em;
    font-variant-numeric: tabular-nums;
  }
  .hero-stat-cost .stat-value {
    color: var(--accent); font-style: italic;
    font-variation-settings: "SOFT" 75, "opsz" 72, "wght" 450;
  }
  .hero-stat-cost .currency {
    font: 400 0.5em/1 var(--font-display);
    font-variation-settings: "SOFT" 50, "opsz" 36;
    vertical-align: 0.35em;
    color: var(--ink-muted); margin-right: 0.05em; letter-spacing: 0;
    font-style: normal;
  }
  .hero-stat .stat-sub {
    margin-top: 12px;
    font: 10px var(--font-mono); color: var(--ink-faint);
    letter-spacing: 0.06em; text-transform: uppercase;
  }

  /* === STAT STRIP === */
  .stat-strip {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    background: var(--bg-card);
    border: 1px solid var(--rule);
  }
  .stat-cell {
    padding: 22px 26px; border-right: 1px solid var(--rule);
    transition: background 200ms ease;
  }
  .stat-cell:last-child { border-right: 0; }
  .stat-cell:hover { background: var(--bg-elev); }
  .stat-cell .cell-label {
    font: 600 9px var(--font-label);
    letter-spacing: 0.22em; text-transform: uppercase; color: var(--ink-muted);
  }
  .stat-cell .cell-value {
    font: 500 26px var(--font-mono);
    color: var(--ink-strong); margin-top: 8px;
    font-variant-numeric: tabular-nums;
  }
  .stat-cell .cell-sub {
    font: 10px var(--font-mono); color: var(--ink-faint);
    margin-top: 4px; letter-spacing: 0.04em;
  }
  .warn {
    color: var(--danger); font-size: 11px; margin-top: 20px;
    font-family: var(--font-mono); letter-spacing: 0.04em;
    padding: 12px 16px; border-left: 2px solid var(--danger);
    background: var(--bg-card);
  }

  /* === SPARKLINE === */
  .spark-wrap {
    background: var(--bg-card); border: 1px solid var(--rule);
    padding: 28px 24px 16px; position: relative;
  }
  .spark-svg { display: block; width: 100%; height: 220px; overflow: visible; }
  .spark-tooltip {
    position: absolute; pointer-events: none; opacity: 0;
    background: var(--bg-deep); color: var(--ink-strong);
    border: 1px solid var(--rule-strong); padding: 10px 14px;
    font: 10px var(--font-mono);
    letter-spacing: 0.04em; transition: opacity 120ms ease;
    box-shadow: 0 8px 24px rgba(0,0,0,0.18);
    z-index: 10; white-space: nowrap;
  }
  .spark-tooltip .tt-date {
    color: var(--ink-muted); text-transform: uppercase; letter-spacing: 0.1em;
  }
  .spark-tooltip .tt-cost {
    color: var(--accent); font-size: 14px; font-weight: 600;
    margin-top: 6px; font-style: normal;
  }

  /* === TABLE === */
  table { width: 100%; border-collapse: collapse; }
  table.refined { background: var(--bg-card); border: 1px solid var(--rule); }
  thead tr { border-bottom: 1px solid var(--rule-strong); }
  th {
    padding: 16px 18px; text-align: left;
    cursor: pointer; user-select: none;
    font: 600 10px/1 var(--font-label);
    text-transform: uppercase; letter-spacing: 0.18em;
    color: var(--ink-muted); white-space: nowrap;
    transition: color 150ms ease;
  }
  th:hover { color: var(--ink-strong); }
  th.sort-asc, th.sort-desc { color: var(--accent); }
  th.sort-asc::after  { content: " \2191"; font-size: 11px; font-weight: 700; }
  th.sort-desc::after { content: " \2193"; font-size: 11px; font-weight: 700; }
  td {
    padding: 16px 18px; border-bottom: 1px solid var(--rule);
    vertical-align: middle; color: var(--ink); font-size: 13px;
  }
  tbody tr:last-child td { border-bottom: 0; }
  td.num, th.num {
    text-align: right;
    font-family: var(--font-mono);
    font-variant-numeric: tabular-nums;
  }
  tbody tr { transition: background 150ms ease; }
  tbody tr:hover { background: var(--bg-elev); }
  td.cost { color: var(--accent); font-weight: 600; }

  .bar-cell { position: relative; overflow: hidden; }
  .bar-fill {
    position: absolute; right: 0; top: 50%; height: 70%;
    transform: translateY(-50%);
    background: linear-gradient(90deg, transparent, var(--accent-soft) 50%, var(--accent-soft));
    pointer-events: none; z-index: 0;
  }
  .bar-cell > span { position: relative; z-index: 1; }

  .nowrap { white-space: nowrap; }
  .small-mono {
    font-family: var(--font-mono); font-size: 11px;
    color: var(--ink-muted); letter-spacing: 0.02em;
  }
  .empty {
    padding: 64px; text-align: center; color: var(--ink-muted);
    font: italic 16px var(--font-display);
  }

  /* === FILTER === */
  .filter {
    display: flex; align-items: center; gap: 20px;
    margin-bottom: 20px; flex-wrap: wrap;
  }
  .filter input {
    flex: 1; max-width: 520px; min-width: 240px;
    background: var(--bg-card); color: var(--ink);
    border: 0; border-bottom: 1px solid var(--rule-strong);
    padding: 12px 4px; font: 13px var(--font-mono);
    outline: none; transition: border-color 150ms ease;
  }
  .filter input:focus { border-bottom-color: var(--accent); }
  .filter input::placeholder { color: var(--ink-faint); }
  .filter .count {
    font: 10px var(--font-mono); color: var(--ink-muted);
    letter-spacing: 0.08em; text-transform: uppercase;
  }
  .filter-cost-wrap {
    position: relative; display: inline-flex; align-items: center; flex: 0 0 auto;
  }
  .filter-cost-prefix {
    position: absolute; left: 4px; pointer-events: none;
    font: 13px var(--font-mono); color: var(--ink-faint);
  }
  .filter input#filter-cost {
    width: 130px; min-width: 0; flex: 0 0 auto;
    padding-left: 18px; padding-right: 4px;
    appearance: textfield; -moz-appearance: textfield;
  }
  .filter input#filter-cost::-webkit-outer-spin-button,
  .filter input#filter-cost::-webkit-inner-spin-button {
    -webkit-appearance: none; margin: 0;
  }
  .filter input#filter-cost:focus + * , .filter-cost-wrap:focus-within .filter-cost-prefix { color: var(--accent); }

  /* === BUTTONS === */
  .show-more { margin-top: 24px; text-align: center; }
  .show-more button {
    background: transparent; color: var(--ink-strong);
    border: 1px solid var(--rule-strong);
    padding: 14px 32px; cursor: pointer; transition: all 180ms ease;
    font: 600 10px/1 var(--font-label);
    letter-spacing: 0.22em; text-transform: uppercase;
  }
  .show-more button:hover {
    background: var(--accent); color: var(--bg);
    border-color: var(--accent);
    box-shadow: 0 0 0 4px var(--accent-soft);
  }

  /* === PROMPT ROW + EXPANSION === */
  .prompt-row { cursor: pointer; }
  .prompt-row.expanded { background: var(--bg-elev); }
  .prompt-row.expanded td:first-child {
    box-shadow: inset 3px 0 0 var(--accent);
  }
  .prompt-preview {
    max-width: 480px; overflow: hidden; text-overflow: ellipsis;
    white-space: nowrap; color: var(--ink);
    font: italic 14.5px var(--font-display);
    font-variation-settings: "SOFT" 50, "opsz" 14;
  }
  .expanded-row td {
    padding: 0; background: var(--bg-deep);
    border-bottom: 1px solid var(--rule-strong);
  }
  .expanded-content {
    padding: 40px 64px 48px; max-width: 760px; margin: 0 auto;
    animation: fadeIn 280ms ease;
  }
  @keyframes fadeIn { from { opacity: 0; transform: translateY(-4px); } to { opacity: 1; transform: none; } }
  .expanded-meta {
    font: 600 9px var(--font-label);
    letter-spacing: 0.22em; text-transform: uppercase;
    color: var(--ink-muted); margin-bottom: 24px;
    display: flex; align-items: center; gap: 16px; flex-wrap: wrap;
  }
  .expanded-meta::after {
    content: ''; flex: 1; min-width: 40px; height: 1px; background: var(--rule);
  }
  .expanded-meta .em-cost { color: var(--accent); }
  .expanded-text {
    background: transparent; border: 0; padding: 0; margin: 0;
    font: 15px/1.65 var(--font-display);
    font-variation-settings: "SOFT" 50, "opsz" 16;
    color: var(--ink-strong); white-space: pre-wrap; word-wrap: break-word;
    max-height: 640px; overflow: auto;
  }

  /* === TAGS === */
  .tag {
    display: inline-flex; align-items: center;
    padding: 2px 8px; font: 600 9px var(--font-label);
    letter-spacing: 0.14em; text-transform: uppercase;
    background: transparent; color: var(--accent);
    border: 1px solid var(--accent); margin-left: 8px;
  }
  .partial {
    color: var(--danger); font-size: 9px; font-family: var(--font-label);
    letter-spacing: 0.14em; text-transform: uppercase; margin-left: 8px;
    font-weight: 600;
  }

  table.no-text .col-text, table.no-text .prompt-preview { display: none; }
  table.no-text .prompt-row { cursor: default; }
  table.no-text .prompt-row.expanded td:first-child { box-shadow: none; }

  /* === ENTRY ANIMATION === */
  .stagger > * {
    opacity: 0; transform: translateY(12px);
    animation: rise 700ms cubic-bezier(0.2, 0.7, 0.2, 1) forwards;
  }
  .stagger > *:nth-child(1) { animation-delay: 40ms; }
  .stagger > *:nth-child(2) { animation-delay: 120ms; }
  .stagger > *:nth-child(3) { animation-delay: 200ms; }
  .stagger > *:nth-child(4) { animation-delay: 280ms; }
  .stagger > *:nth-child(5) { animation-delay: 360ms; }
  .stagger > *:nth-child(6) { animation-delay: 440ms; }
  .stagger > *:nth-child(7) { animation-delay: 520ms; }
  .stagger > *:nth-child(8) { animation-delay: 600ms; }
  @keyframes rise { to { opacity: 1; transform: translateY(0); } }

  /* === RESPONSIVE === */
  @media (max-width: 900px) {
    .wrap { padding: 32px 24px 64px; }
    h1.title { font-size: 56px; }
    .hero { grid-template-columns: repeat(2, 1fr); gap: 32px; }
    .hero-stat .stat-value { font-size: 42px; }
    .expanded-content { padding: 28px 32px; }
  }
  @media (max-width: 560px) {
    .hero { grid-template-columns: 1fr; gap: 24px; }
    .hero-stat .stat-value { font-size: 38px; }
    th, td { padding: 12px 10px; font-size: 12px; }
    .filter input { max-width: 100%; }
  }
</style>
</head>
<body>
<div class="wrap stagger">

  <header class="nameplate">
    <div class="brand">
      <span class="brand-mark"></span>
      <span>Claude &middot; Usage Report</span>
    </div>
    <div class="timestamp" id="meta-timestamp"></div>
  </header>

  <h1 class="title">Token <span class="amp">Analytics</span></h1>
  <div class="subtitle" id="subtitle"></div>

  <section class="hero">
    <div class="hero-stat hero-stat-cost">
      <div class="stat-label">Estimated Cost</div>
      <div class="stat-value"><span class="currency">$</span><span id="hero-cost">0.00</span></div>
      <div class="stat-sub" id="hero-cost-sub"></div>
    </div>
    <div class="hero-stat">
      <div class="stat-label">User Prompts</div>
      <div class="stat-value" id="hero-prompts">0</div>
    </div>
    <div class="hero-stat">
      <div class="stat-label">Assistant Turns</div>
      <div class="stat-value" id="hero-turns">0</div>
    </div>
    <div class="hero-stat">
      <div class="stat-label">Total Tokens</div>
      <div class="stat-value" id="hero-tokens">0</div>
    </div>
  </section>

  <div id="warn" class="warn" style="display:none;"></div>

  <section>
    <h2 class="section-title">
      <svg class="section-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"/><path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65"/><path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65"/></svg>
      Token Composition
    </h2>
    <div class="stat-strip" id="stat-strip"></div>
  </section>

  <section>
    <h2 class="section-title">
      <svg class="section-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><polyline points="22 7 13.5 15.5 8.5 10.5 2 17"/><polyline points="16 7 22 7 22 13"/></svg>
      Daily Burn &mdash; Last 30 Days
    </h2>
    <div class="spark-wrap">
      <svg class="spark-svg" id="spark-svg" preserveAspectRatio="none"></svg>
      <div class="spark-tooltip" id="spark-tooltip"></div>
    </div>
  </section>

  <section>
    <h2 class="section-title">
      <svg class="section-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.93a2 2 0 0 1-1.66-.9l-.82-1.2A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/></svg>
      By Project
    </h2>
    <div id="projects-empty" class="empty" style="display:none;">No data.</div>
    <table id="projects-table" class="refined">
      <thead><tr>
        <th data-key="name">Project</th>
        <th class="num" data-key="sessions">Sessions</th>
        <th class="num" data-key="prompts">Turns</th>
        <th class="num" data-key="input">Input</th>
        <th class="num" data-key="output">Output</th>
        <th class="num" data-key="cacheRead">Cache R</th>
        <th class="num" data-key="cacheWrite">Cache W</th>
        <th class="num" data-key="cost">Cost</th>
      </tr></thead>
      <tbody></tbody>
    </table>
  </section>

  <section>
    <h2 class="section-title">
      <svg class="section-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m12 3-1.912 5.813a2 2 0 0 1-1.275 1.275L3 12l5.813 1.912a2 2 0 0 1 1.275 1.275L12 21l1.912-5.813a2 2 0 0 1 1.275-1.275L21 12l-5.813-1.912a2 2 0 0 1-1.275-1.275L12 3Z"/><path d="M5 3v4"/><path d="M19 17v4"/><path d="M3 5h4"/><path d="M17 19h4"/></svg>
      By Model
    </h2>
    <div id="models-empty" class="empty" style="display:none;">No data.</div>
    <table id="models-table" class="refined">
      <thead><tr>
        <th data-key="name">Model</th>
        <th class="num" data-key="prompts">Turns</th>
        <th class="num" data-key="input">Input</th>
        <th class="num" data-key="output">Output</th>
        <th class="num" data-key="cacheRead">Cache R</th>
        <th class="num" data-key="cacheWrite">Cache W</th>
        <th class="num" data-key="cost">Cost</th>
      </tr></thead>
      <tbody></tbody>
    </table>
  </section>

  <section>
    <h2 class="section-title">
      <svg class="section-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>
      Per-Prompt Log <span id="prompts-mode" class="note"></span>
    </h2>
    <div class="filter">
      <input id="filter-input" type="search" placeholder="Filter by project, model, or session..." autocomplete="off">
      <div class="filter-cost-wrap">
        <span class="filter-cost-prefix">$</span>
        <input id="filter-cost" type="number" min="0" step="0.01" placeholder="min cost" inputmode="decimal">
      </div>
      <span class="count" id="filter-count"></span>
    </div>
    <table id="prompts-table" class="refined">
      <thead><tr>
        <th data-key="ts">When</th>
        <th data-key="project">Project</th>
        <th data-key="text" class="col-text">Prompt</th>
        <th data-key="models">Model</th>
        <th class="num" data-key="cost">Cost</th>
        <th class="num" data-key="turns">Turns</th>
        <th class="num" data-key="inTok">In</th>
        <th class="num" data-key="outTok">Out</th>
        <th class="num" data-key="crTok">Cache R</th>
        <th class="num" data-key="cwTok">Cache W</th>
      </tr></thead>
      <tbody></tbody>
    </table>
    <div id="prompts-empty" class="empty" style="display:none;">No data.</div>
    <div class="show-more"><button id="show-more-btn" style="display:none;">Load more</button></div>
  </section>
</div>

<script id="usage-data" type="application/json">__DATA__</script>
<script>
(function () {
  var DATA = JSON.parse(document.getElementById('usage-data').textContent);
  var fmtInt = new Intl.NumberFormat('en-US');
  var fmtCompact = new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 });
  var fmtUsd = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 4 });
  var fmtUsd2 = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });

  function esc(s) {
    if (s == null) return '';
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c];
    });
  }
  function fmtCost(v) { return v == null ? '<span style="color:var(--ink-faint)">n/a</span>' : fmtUsd.format(v); }
  function fmtCost2(v) { return v == null ? '<span style="color:var(--ink-faint)">n/a</span>' : fmtUsd2.format(v); }

  // Compact timestamp: "2026-05-13T19:52:48Z" -> "05-13 19:52"
  function shortTs(t) {
    if (!t) return '';
    var m = String(t).match(/^\d{4}-(\d{2}-\d{2})T(\d{2}:\d{2})/);
    return m ? m[1] + ' ' + m[2] : t;
  }

  var s = DATA.summary;

  // === HEADER / TIMESTAMP / SUBTITLE ===
  document.getElementById('meta-timestamp').textContent = DATA.generatedAt || '';

  var sub = [];
  sub.push('SRC <code>' + esc(DATA.projectsDir) + '</code>');
  sub.push('<span class="dot">&middot;</span>' + (DATA.daysFilter > 0 ? 'LAST ' + DATA.daysFilter + ' DAYS' : 'ALL HISTORY'));
  if (s.firstDate && s.lastDate) {
    sub.push('<span class="dot">&middot;</span>' + esc(s.firstDate.substring(0,10)) + ' &rarr; ' + esc(s.lastDate.substring(0,10)));
  }
  sub.push('<span class="dot">&middot;</span>' + (DATA.includeText ? 'DETAIL EDITION' : 'METADATA EDITION'));
  document.getElementById('subtitle').innerHTML = sub.join(' ');

  // === COUNT-UP ANIMATION ===
  function countUp(el, target, opts) {
    opts = opts || {};
    var duration = opts.duration || 1100;
    var format = opts.format || function (v) { return fmtInt.format(Math.round(v)); };
    if (target === 0) { el.textContent = format(0); return; }
    var startT = performance.now();
    function frame(now) {
      var t = Math.min(1, (now - startT) / duration);
      var eased = 1 - Math.pow(1 - t, 3); // ease-out cubic
      el.textContent = format(target * eased);
      if (t < 1) requestAnimationFrame(frame);
      else el.textContent = format(target);
    }
    requestAnimationFrame(frame);
  }

  var totalTokens = s.totalInput + s.totalOutput + s.totalCacheRead + s.totalCacheWrite;
  countUp(document.getElementById('hero-cost'), s.totalCost, {
    duration: 1400,
    format: function (v) {
      return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }
  });
  countUp(document.getElementById('hero-prompts'), s.totalUserPrompts);
  countUp(document.getElementById('hero-turns'), s.totalAssistantTurns);
  countUp(document.getElementById('hero-tokens'), totalTokens, {
    format: function (v) { return fmtCompact.format(Math.round(v)); }
  });
  document.getElementById('hero-cost-sub').textContent =
    s.anyUnpriced ? 'partial &mdash; some models unpriced' : 'estimated at api pricing';

  if (s.anyUnpriced) {
    var w = document.getElementById('warn');
    w.style.display = 'block';
    w.textContent = '\u26A0  Some turns used models without pricing in the table \u2014 tokens counted, cost shown as n/a.';
  }

  // === STAT STRIP ===
  var stripCells = [
    { label: 'Input',       value: fmtInt.format(s.totalInput),       sub: 'prompt tokens' },
    { label: 'Output',      value: fmtInt.format(s.totalOutput),      sub: 'generated tokens' },
    { label: 'Cache Read',  value: fmtInt.format(s.totalCacheRead),   sub: 'from cache' },
    { label: 'Cache Write', value: fmtInt.format(s.totalCacheWrite),  sub: 'to cache' },
    { label: 'Sessions',    value: fmtInt.format(s.numSessions),      sub: fmtInt.format(s.numProjects) + ' projects' }
  ];
  document.getElementById('stat-strip').innerHTML = stripCells.map(function (c) {
    return '<div class="stat-cell">' +
      '<div class="cell-label">' + esc(c.label) + '</div>' +
      '<div class="cell-value">' + c.value + '</div>' +
      '<div class="cell-sub">' + esc(c.sub) + '</div></div>';
  }).join('');

  // === SVG SPARKLINE (daily cost) ===
  (function renderSparkline() {
    var svg = document.getElementById('spark-svg');
    var tooltip = document.getElementById('spark-tooltip');
    var data = DATA.daily.slice(-30);
    if (data.length === 0) {
      svg.innerHTML = '<text x="50%" y="50%" text-anchor="middle" style="fill: var(--ink-faint); font: italic 14px var(--font-display);">No daily data yet.</text>';
      return;
    }
    function sizeAndDraw() {
      var W = svg.clientWidth || 1100;
      var H = 220;
      svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
      var pad = { l: 44, r: 18, t: 14, b: 32 };
      var iw = W - pad.l - pad.r, ih = H - pad.t - pad.b;
      var maxCost = Math.max.apply(null, data.map(function (d) { return d.cost || 0; })) || 1;
      var step = data.length > 1 ? iw / (data.length - 1) : 0;
      var pts = data.map(function (d, i) {
        return {
          x: pad.l + i * step,
          y: pad.t + ih - ((d.cost || 0) / maxCost) * ih,
          d: d
        };
      });
      // Catmull-Rom to bezier smooth path
      function smoothPath(pts) {
        if (pts.length < 2) return '';
        var p = 'M ' + pts[0].x.toFixed(1) + ' ' + pts[0].y.toFixed(1);
        for (var i = 0; i < pts.length - 1; i++) {
          var p0 = pts[i - 1] || pts[i];
          var p1 = pts[i];
          var p2 = pts[i + 1];
          var p3 = pts[i + 2] || p2;
          var cp1x = p1.x + (p2.x - p0.x) / 6;
          var cp1y = p1.y + (p2.y - p0.y) / 6;
          var cp2x = p2.x - (p3.x - p1.x) / 6;
          var cp2y = p2.y - (p3.y - p1.y) / 6;
          p += ' C ' + cp1x.toFixed(1) + ' ' + cp1y.toFixed(1) +
               ', ' + cp2x.toFixed(1) + ' ' + cp2y.toFixed(1) +
               ', ' + p2.x.toFixed(1) + ' ' + p2.y.toFixed(1);
        }
        return p;
      }
      var linePath = smoothPath(pts);
      var areaPath = linePath + ' L ' + pts[pts.length - 1].x.toFixed(1) + ' ' + (pad.t + ih) +
        ' L ' + pts[0].x.toFixed(1) + ' ' + (pad.t + ih) + ' Z';
      // Y axis grid + labels
      var yTickCount = 4;
      var yGrid = '';
      for (var t = 0; t <= yTickCount; t++) {
        var ty = pad.t + ih - (t / yTickCount) * ih;
        var tv = maxCost * t / yTickCount;
        yGrid += '<line x1="' + pad.l + '" y1="' + ty + '" x2="' + (W - pad.r) + '" y2="' + ty +
          '" style="stroke: var(--rule); stroke-width: 0.5;" stroke-dasharray="2 4" />' +
          '<text x="' + (pad.l - 10) + '" y="' + (ty + 3) + '" text-anchor="end" style="fill: var(--ink-faint); font: 9px JetBrains Mono, Cascadia Mono, Consolas, monospace;">$' +
          (tv < 10 ? tv.toFixed(2) : tv.toFixed(0)) + '</text>';
      }
      // X labels (~8 evenly spaced)
      var xLabels = '';
      var labelEvery = Math.max(1, Math.ceil(data.length / 7));
      pts.forEach(function (p, i) {
        if (i % labelEvery === 0 || i === pts.length - 1) {
          xLabels += '<text x="' + p.x + '" y="' + (H - 10) + '" text-anchor="middle" style="fill: var(--ink-faint); font: 9px JetBrains Mono, Cascadia Mono, Consolas, monospace; letter-spacing: 0.05em;">' +
            esc(p.d.date.substring(5)) + '</text>';
        }
      });
      // Dots
      var dots = pts.map(function (p) {
        return '<circle cx="' + p.x + '" cy="' + p.y + '" r="3" style="fill: var(--accent); stroke: var(--bg-card); stroke-width: 2; opacity: 0.9;" />';
      }).join('');

      svg.innerHTML =
        '<defs>' +
          '<linearGradient id="sparkGrad" x1="0" y1="0" x2="0" y2="1">' +
            '<stop offset="0%" style="stop-color: var(--accent); stop-opacity: 0.35;" />' +
            '<stop offset="100%" style="stop-color: var(--accent); stop-opacity: 0;" />' +
          '</linearGradient>' +
        '</defs>' +
        yGrid +
        '<path d="' + areaPath + '" style="fill: url(#sparkGrad);" />' +
        '<path d="' + linePath + '" style="fill: none; stroke: var(--accent); stroke-width: 1.75; stroke-linejoin: round; stroke-linecap: round;" />' +
        dots +
        xLabels;

      // Hover behavior
      var rect;
      svg.addEventListener('mousemove', function (ev) {
        rect = svg.getBoundingClientRect();
        var mx = (ev.clientX - rect.left) * (W / rect.width);
        var nearest = 0, minDx = Infinity;
        for (var i = 0; i < pts.length; i++) {
          var dx = Math.abs(pts[i].x - mx);
          if (dx < minDx) { minDx = dx; nearest = i; }
        }
        var p = pts[nearest];
        var d = p.d;
        tooltip.innerHTML =
          '<div class="tt-date">' + esc(d.date) + ' &middot; ' + fmtInt.format(d.prompts) + ' prompts</div>' +
          '<div class="tt-cost">' + fmtUsd.format(d.cost) + '</div>';
        tooltip.style.opacity = '1';
        var tx = (p.x / W) * rect.width + 18;
        var ty = (p.y / H) * rect.height - 6;
        // keep inside the wrap
        var maxX = svg.parentElement.clientWidth - 160;
        tooltip.style.left = Math.min(tx, maxX) + 'px';
        tooltip.style.top = Math.max(0, ty - 30) + 'px';
      });
      svg.addEventListener('mouseleave', function () {
        tooltip.style.opacity = '0';
      });
    }
    sizeAndDraw();
    var resizeT;
    window.addEventListener('resize', function () {
      clearTimeout(resizeT);
      resizeT = setTimeout(sizeAndDraw, 150);
    });
  })();

  // === SORTABLE TABLES ===
  function makeTable(tableId, rows, columns, formatters, sortDefault) {
    var table = document.getElementById(tableId);
    var tbody = table.querySelector('tbody');
    var state = { key: sortDefault.key, dir: sortDefault.dir };
    var maxCostCol = rows.reduce(function (m, r) { return Math.max(m, r.cost || 0); }, 0);

    function render() {
      var sorted = rows.slice().sort(function (a, b) {
        var av = a[state.key], bv = b[state.key];
        if (av == null && bv == null) return 0;
        if (av == null) return 1;
        if (bv == null) return -1;
        if (typeof av === 'number' && typeof bv === 'number') return state.dir === 'asc' ? av - bv : bv - av;
        return state.dir === 'asc' ? String(av).localeCompare(String(bv)) : String(bv).localeCompare(String(av));
      });
      tbody.innerHTML = sorted.map(function (r) {
        return '<tr>' + columns.map(function (col) {
          var v = r[col.key];
          var inner = formatters[col.key] ? formatters[col.key](v, r) : esc(v);
          var classes = [];
          if (col.num) classes.push('num');
          if (col.bar) classes.push('bar-cell');
          if (col.cost) classes.push('cost');
          var cls = classes.length ? ' class="' + classes.join(' ') + '"' : '';
          var bar = '';
          if (col.bar && typeof v === 'number' && maxCostCol > 0) {
            var pct = Math.max(0, Math.min(100, (v / maxCostCol) * 100));
            bar = '<div class="bar-fill" style="width:' + pct + '%"></div>';
          }
          return '<td' + cls + '>' + bar + '<span>' + inner + '</span></td>';
        }).join('') + '</tr>';
      }).join('');
      var ths = table.querySelectorAll('th');
      ths.forEach(function (th) { th.classList.remove('sort-asc', 'sort-desc'); });
      var active = table.querySelector('th[data-key="' + state.key + '"]');
      if (active) active.classList.add(state.dir === 'asc' ? 'sort-asc' : 'sort-desc');
    }

    table.querySelectorAll('th').forEach(function (th) {
      th.addEventListener('click', function () {
        var key = th.getAttribute('data-key');
        if (state.key === key) state.dir = state.dir === 'asc' ? 'desc' : 'asc';
        else { state.key = key; state.dir = (rows[0] && typeof rows[0][key] === 'number') ? 'desc' : 'asc'; }
        render();
      });
    });
    render();
  }

  if (DATA.projects.length === 0) document.getElementById('projects-empty').style.display = 'block';
  else makeTable('projects-table', DATA.projects, [
    { key: 'name' }, { key: 'sessions', num: true }, { key: 'prompts', num: true },
    { key: 'input', num: true }, { key: 'output', num: true }, { key: 'cacheRead', num: true },
    { key: 'cacheWrite', num: true }, { key: 'cost', num: true, bar: true, cost: true }
  ], {
    sessions: function (v) { return fmtInt.format(v); }, prompts: function (v) { return fmtInt.format(v); },
    input: function (v) { return fmtInt.format(v); }, output: function (v) { return fmtInt.format(v); },
    cacheRead: function (v) { return fmtInt.format(v); }, cacheWrite: function (v) { return fmtInt.format(v); },
    cost: function (v, r) { return fmtCost(v) + (r.unpriced ? '<span class="partial">partial</span>' : ''); }
  }, { key: 'cost', dir: 'desc' });

  if (DATA.models.length === 0) document.getElementById('models-empty').style.display = 'block';
  else makeTable('models-table', DATA.models, [
    { key: 'name' }, { key: 'prompts', num: true }, { key: 'input', num: true },
    { key: 'output', num: true }, { key: 'cacheRead', num: true }, { key: 'cacheWrite', num: true },
    { key: 'cost', num: true, bar: true, cost: true }
  ], {
    prompts: function (v) { return fmtInt.format(v); }, input: function (v) { return fmtInt.format(v); },
    output: function (v) { return fmtInt.format(v); }, cacheRead: function (v) { return fmtInt.format(v); },
    cacheWrite: function (v) { return fmtInt.format(v); },
    cost: function (v, r) { return fmtCost(v) + (r.unpriced ? '<span class="partial">n/a</span>' : ''); }
  }, { key: 'cost', dir: 'desc' });

  // === PROMPT LOG ===
  var promptsBody = document.querySelector('#prompts-table tbody');
  var promptsTable = document.getElementById('prompts-table');
  var filterInput = document.getElementById('filter-input');
  var filterCostInput = document.getElementById('filter-cost');
  var filterCount = document.getElementById('filter-count');
  var showMoreBtn = document.getElementById('show-more-btn');
  var PAGE = 200;
  var filtered = DATA.prompts;
  var rendered = 0;

  var modeEl = document.getElementById('prompts-mode');
  if (DATA.includeText) {
    modeEl.textContent = '\u2014 click a row to read the prompt';
    filterInput.placeholder = 'Filter by prompt text, project, model, session...';
  } else {
    modeEl.innerHTML = '\u2014 metadata only &middot; rerun without <code>-NoDetail</code> for prompt text';
    promptsTable.classList.add('no-text');
  }

  function previewText(t) {
    if (!t) return '';
    var oneLine = t.replace(/\s+/g, ' ').trim();
    return oneLine.length > 130 ? oneLine.substring(0, 130) + '…' : oneLine;
  }
  function shortModel(m) {
    if (!m) return '';
    return m.split(',').map(function (s) {
      return s.trim().replace(/^claude-/, '').replace(/-\d{8}$/, '');
    }).join(', ');
  }

  function renderPromptRow(p, fIdx) {
    var sideTag = p.isSidechain ? ' <span class="tag">subagent</span>' : '';
    var cost = p.unpriced ? (fmtCost2(p.cost) + '<span class="partial">partial</span>') : fmtCost2(p.cost);
    var promptCell = DATA.includeText
      ? '<td class="prompt-preview" title="Click to read">' + esc(previewText(p.text)) + '</td>'
      : '';
    return '<tr class="prompt-row" data-idx="' + fIdx + '">' +
      '<td class="small-mono nowrap">' + esc(shortTs(p.ts)) + '</td>' +
      '<td class="nowrap">' + esc(p.project) + sideTag + '</td>' +
      promptCell +
      '<td class="small-mono nowrap">' + esc(shortModel(p.models)) + '</td>' +
      '<td class="num cost">' + cost + '</td>' +
      '<td class="num">' + fmtInt.format(p.turns) + '</td>' +
      '<td class="num">' + fmtInt.format(p.inTok) + '</td>' +
      '<td class="num">' + fmtInt.format(p.outTok) + '</td>' +
      '<td class="num">' + fmtInt.format(p.crTok) + '</td>' +
      '<td class="num">' + fmtInt.format(p.cwTok) + '</td>' +
      '</tr>';
  }
  function renderNext() {
    var slice = [];
    for (var i = rendered; i < Math.min(filtered.length, rendered + PAGE); i++) {
      slice.push(renderPromptRow(filtered[i], i));
    }
    promptsBody.insertAdjacentHTML('beforeend', slice.join(''));
    rendered += slice.length;
    var remaining = filtered.length - rendered;
    showMoreBtn.style.display = remaining > 0 ? 'inline-block' : 'none';
    showMoreBtn.textContent = 'Load ' + fmtInt.format(Math.min(PAGE, remaining)) + ' more · ' + fmtInt.format(remaining) + ' remain';
  }
  function applyFilter() {
    var q = filterInput.value.trim().toLowerCase();
    var minCost = parseFloat(filterCostInput.value);
    if (isNaN(minCost)) minCost = null;
    filtered = DATA.prompts.filter(function (p) {
      if (minCost !== null && (p.cost == null || p.cost < minCost)) return false;
      if (!q) return true;
      var match = (p.project && p.project.toLowerCase().indexOf(q) >= 0) ||
                  (p.models  && p.models.toLowerCase().indexOf(q) >= 0) ||
                  (p.session && p.session.toLowerCase().indexOf(q) >= 0);
      if (!match && DATA.includeText && p.text) {
        match = p.text.toLowerCase().indexOf(q) >= 0;
      }
      return match;
    });
    promptsBody.innerHTML = '';
    rendered = 0;
    filterCount.textContent = fmtInt.format(filtered.length) + ' / ' + fmtInt.format(DATA.prompts.length);
    document.getElementById('prompts-empty').style.display = filtered.length === 0 ? 'block' : 'none';
    if (filtered.length > 0) renderNext();
  }

  if (DATA.includeText) {
    promptsBody.addEventListener('click', function (e) {
      var tr = e.target.closest('tr.prompt-row');
      if (!tr) return;
      var next = tr.nextElementSibling;
      if (next && next.classList.contains('expanded-row')) {
        next.remove();
        tr.classList.remove('expanded');
        return;
      }
      var idx = parseInt(tr.getAttribute('data-idx'), 10);
      var p = filtered[idx];
      if (!p) return;
      var detail = document.createElement('tr');
      detail.className = 'expanded-row';
      var ts = (p.ts || '').replace('T', ' ').replace('Z', ' UTC');
      detail.innerHTML = '<td colspan="10"><div class="expanded-content">' +
        '<div class="expanded-meta">' +
          '<span>' + esc(ts) + '</span>' +
          '<span>' + esc(p.project) + '</span>' +
          (p.isSidechain ? '<span>subagent</span>' : '') +
          '<span>' + fmtInt.format(p.turns) + ' turn' + (p.turns === 1 ? '' : 's') + '</span>' +
          '<span class="em-cost">' + fmtCost2(p.cost) + '</span>' +
        '</div><div class="expanded-text">' + esc(p.text || '') + '</div></div></td>';
      tr.parentNode.insertBefore(detail, tr.nextSibling);
      tr.classList.add('expanded');
    });
  }

  filterInput.addEventListener('input', applyFilter);
  filterCostInput.addEventListener('input', applyFilter);
  showMoreBtn.addEventListener('click', renderNext);
  applyFilter();
})();
</script>
</body>
</html>
'@

# Resolve detail file path: insert "-detail" before extension of OutFile
$ext = [System.IO.Path]::GetExtension($OutFile)
$stem = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($OutFile), [System.IO.Path]::GetFileNameWithoutExtension($OutFile))
$DetailFile = "$stem-detail$ext"

# Ensure output dir exists
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

function Write-Report {
    param([string]$Path, [bool]$IncludeText)
    $payload = New-Payload -IncludeText $IncludeText
    $rendered = $html.Replace('__DATA__', (ConvertTo-SafeJson $payload))
    Set-Content -LiteralPath $Path -Value $rendered -Encoding UTF8
}

# Always write the safe (metadata-only) report
Write-Report -Path $OutFile -IncludeText $false

# Write the detail report unless explicitly opted out
if (-not $NoDetail) {
    Write-Report -Path $DetailFile -IncludeText $true
}

Write-Info ""
Write-Info "Reports written:"
Write-Info "  $OutFile  (metadata only - safe to share)"
if (-not $NoDetail) {
    Write-Info "  $DetailFile  (includes prompt text - keep local)"
}
Write-Info "  $($summary.totalUserPrompts) user prompts ($($summary.totalAssistantTurns) assistant turns) | `$$($summary.totalCost) estimated | $($summary.numProjects) projects | $($summary.numSessions) sessions"
if ($summary.anyUnpriced) { Write-Info "  Note: some turns used unpriced models - totals are partial." -ForegroundColor Yellow }

if (-not $NoOpen) {
    # Open the detail report if it exists, otherwise the safe one
    if (-not $NoDetail) { Start-Process $DetailFile | Out-Null }
    else { Start-Process $OutFile | Out-Null }
}
