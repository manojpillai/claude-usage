# Claude Usage Report — Plugin

Local-only Claude Code plugin that scans your `~/.claude/projects/` session transcripts and produces:
- A static HTML report (per-project + per-model + daily + per-prompt breakdown), or
- A natural-language analysis in chat ("what's driving my Claude spend") via the bundled skill.

## Prerequisites

| Platform | What you need |
|---|---|
| **Windows** | PowerShell 5.1 (built in) — nothing to install |
| **macOS** | PowerShell 7 — `brew install --cask powershell` |
| **Linux** | PowerShell 7 — [install docs](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux) |

You also need Claude Code installed and at least one session in `~/.claude/projects/`.

## Install

```bash
git clone https://github.com/manojpillai/claude-usage.git
cd claude-usage
```

**Windows:**
```cmd
Install-Plugin.bat
```

**macOS / Linux:**
```bash
pwsh scripts/Install-Plugin-PowerShell.ps1
```

Restart Claude Code after the script finishes.

The script creates a local marketplace wrapper at `~/claude-plugins/`, links it to the cloned repo, and registers the plugin with Claude Code.

### Troubleshooting: PowerShell permission error

If you see **"Invokes PowerShell, which is in the user's deny rules list"**, add this to `~/.claude/settings.json`:

```json
"permissions": {
  "allow": ["Bash(pwsh *)", "Bash(powershell *)"]
}
```

### Update / Uninstall

```bash
git pull                            # get latest
claude plugin update claude-usage   # reload

claude plugin uninstall claude-usage  # remove
```

---

Once installed, three invocation paths all hit the same underlying script:

| How | What happens |
|---|---|
| **Ask Claude** — "show me my Claude usage", "what was my most expensive prompt", "analyze my Claude spend" | The `claude-usage-analyzer` skill triggers. Claude runs the scanner with `-Json`, reads the structured data, and replies with a summary (top projects, model mix, expensive prompts) plus optimization suggestions if asked. |
| **`/claude-usage:usage-report`** slash command | Generates the HTML report and opens it. Pass-through args supported: `/claude-usage:usage-report -Days 7`, `/claude-usage:usage-report -NoDetail`. Plugin commands are namespaced `plugin-name:command-name` to avoid collisions — this is expected. |
| **Standalone** — double-click `scripts\GenerateReport.bat` or call `scripts\Get-ClaudeUsage.ps1` directly | Same script, no Claude Code required. Useful for cron tasks, taskbar shortcuts, etc. |

## Why this exists

Claude Code writes a JSONL transcript of every session to `~/.claude/projects/`. Those files contain everything Claude saw and produced — your code, your prompts, possibly secrets. There are good third-party tools that read these transcripts (e.g. `phuryn/claude-usage`), but pointing unaudited third-party code at that directory is a judgment call. This tool is the minimum needed to answer "how much am I using and what does it cost", with no third-party packages, no network calls, and no prompt text stored.

## Security stance

- **Zero third-party packages in the script itself.** Pure PowerShell — read it end-to-end.
- **No HTTP server.** Output is a static `report.html` file you open in your browser.
- **Network access from the report**: the HTML loads typography from Google Fonts (`fonts.googleapis.com` + `fonts.gstatic.com`) only — Fraunces, Geist, and JetBrains Mono. A strict `Content-Security-Policy` meta tag blocks every other origin, every script source besides inline, and every image source besides inline data URIs. To go fully air-gapped, comment out the `<link>` and `<link rel="preconnect">` lines in `Get-ClaudeUsage.ps1` — the report still renders, just with system-font fallbacks (Georgia, Segoe UI, Cascadia Mono).
- **Two reports per run: a safe one and a detailed one.**
  - `report.html` — **metadata only, no prompt text.** Safe to share, attach to a ticket, or hand to your manager.
  - `report-detail.html` — same data plus the full text of every prompt you typed. **Keep this one local.**
  Use `-NoDetail` to skip the detail report entirely (so it never gets written to disk).
- **No persistent data store.** No SQLite, no cache. Re-running the script does a full rescan into memory and emits the HTML.
- **XSS-hardened report.** All user-controlled strings (prompt text, project names, model names) are HTML-escaped; embedded JSON is escaped to prevent `</script>` breakout; a strict `Content-Security-Policy` meta tag blocks any external resource the report could try to load.

`.gitignore` excludes both `*.html` outputs from version control. If you don't want the detail report on disk at all, run with `-NoDetail` and only `report.html` is written.

## Usage

### Easiest — launcher script

**Windows** — `scripts\GenerateReport.bat`. Double-click in Explorer, pin to taskbar, or call from cmd/PowerShell:
```cmd
scripts\GenerateReport.bat
scripts\GenerateReport.bat -Days 7
scripts\GenerateReport.bat -NoDetail
```

**macOS / Linux** — `scripts/GenerateReport.sh`. One-time `chmod +x`, then:
```bash
chmod +x scripts/GenerateReport.sh   # first time only
./scripts/GenerateReport.sh
./scripts/GenerateReport.sh -Days 7
./scripts/GenerateReport.sh -NoDetail
```

Both launchers resolve paths relative to themselves, so they work no matter what your current directory is.

### Calling the PowerShell script directly

On **Windows** (PowerShell 5.1 or 7):
```powershell
# Scan everything, write report.html + report-detail.html, open the detail one
.\scripts\Get-ClaudeUsage.ps1

# Only write the safe metadata report (no prompt text on disk at all)
.\scripts\Get-ClaudeUsage.ps1 -NoDetail

# Limit to last 30 days
.\scripts\Get-ClaudeUsage.ps1 -Days 30

# Don't auto-open the browser
.\scripts\Get-ClaudeUsage.ps1 -NoOpen

# Dump structured data to stdout (used by the analyzer skill)
.\scripts\Get-ClaudeUsage.ps1 -Json | ConvertFrom-Json

# Custom output location (detail report will be alongside as <name>-detail.html)
.\scripts\Get-ClaudeUsage.ps1 -OutFile C:\Reports\claude-2026-05.html
```

On **macOS / Linux** (PowerShell 7 via `pwsh`):
```bash
pwsh scripts/Get-ClaudeUsage.ps1
pwsh scripts/Get-ClaudeUsage.ps1 -Days 7 -NoDetail
pwsh scripts/Get-ClaudeUsage.ps1 -Json | jq .summary
```

If Windows PowerShell blocks the script with an execution-policy error, either use `GenerateReport.bat` (which already bypasses) or run it for the current process only:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Get-ClaudeUsage.ps1
```

### Calling it from anywhere

**Windows** — add this one-liner to your PowerShell `$PROFILE` so `claude-usage` works from any directory:
```powershell
function claude-usage { & 'C:\path\to\claude-usage\scripts\Get-ClaudeUsage.ps1' @args }
```

**macOS / Linux** — add an alias to your `~/.zshrc` or `~/.bashrc`:
```bash
alias claude-usage='~/path/to/ClaudeUsage/scripts/GenerateReport.sh'
```

## What the report shows

| Section | What's in it |
|---|---|
| Summary cards | User prompts, assistant turns, total cost, token totals (input / output / cache read / cache write), # projects, # sessions, date range |
| Daily timeline | Cost per day for the last 30 days, as an SVG sparkline (hover for prompt count) |
| By project | Sortable table: sessions, turns, tokens, cost per project |
| By model | Sortable table: same metrics grouped by model name |
| Per-prompt log | One row per user prompt: timestamp, project, prompt preview, model(s), # turns, tokens, cost. **Click a row to expand and see the full prompt text.** Searchable across prompt text, project, model, and session. |

Click any column header to sort. The per-prompt log loads 200 rows at a time — click "Show more" for the rest.

## Cost calculation

Costs are estimated using **Anthropic public API pricing** (USD per million tokens):

| Model | Input | Output | Cache write | Cache read |
|---|---|---|---|---|
| claude-opus-4-7 | $5.00 | $25.00 | $6.25 | $0.50 |
| claude-opus-4-6 | $5.00 | $25.00 | $6.25 | $0.50 |
| claude-sonnet-4-6 | $3.00 | $15.00 | $3.75 | $0.30 |
| claude-haiku-4-5 | $1.00 | $5.00 | $1.25 | $0.10 |

Models whose names don't match any row above are counted in token totals but their cost shows as `n/a` and is excluded from the total. To update prices, edit the `$Pricing` hashtable at the top of `Get-ClaudeUsage.ps1`.

**Important:** These are API prices. If you use Claude Code via a Max or Pro subscription, your actual bill is the flat subscription fee — the cost column here is a "what would this cost on the API" estimate, useful for comparing usage between projects but not for predicting your invoice. Always verify pricing at https://claude.com/pricing#api before relying on totals.

## How it works

For each `.jsonl` file under the transcripts directory:

1. Stream lines via `[System.IO.File]::ReadLines` (low-memory, PS 5.1-safe).
2. Parse each line with `ConvertFrom-Json`; skip malformed lines.
3. Keep only records where `type == "assistant"` and `message.usage` is present.
4. **Dedupe on `message.id`** — Claude Code writes the same assistant message ID across multiple records when a response includes both thinking and tool-use blocks; counting all of them would inflate tokens 2-3x. The first occurrence wins.
5. Project name comes from the basename of the record's `cwd` field (falls back to the folder name if `cwd` is missing).
6. **User-prompt detection**: any `type: "user"` record with real text content (not `tool_result`, not auto-injected wrappers like `<ide_opened_file>` or `<system-reminder>`) starts a new "user prompt". All subsequent assistant turns in the file are aggregated under that prompt until the next user prompt appears. Sidechain (subagent) prompts are tracked separately so they don't get attributed to the main chain.
7. Aggregate by project, model, day, and emit one summary row per user prompt (with the full text and totals across all its assistant turns).

## What's not covered

- **Cowork sessions** — these run server-side and don't write local JSONL.
- **API direct usage** — only Claude Code (CLI + VS Code + JetBrains extension) writes to `~/.claude/projects/`.
- **Subscription billing** — see note under "Cost calculation" above.

## Files

| File | Purpose |
|---|---|
| `.claude-plugin/plugin.json` | Plugin manifest (name, version, description, author). |
| `commands/usage-report.md` | `/usage-report` slash command — runs the scanner, opens HTML. |
| `skills/claude-usage-analyzer/SKILL.md` | Skill instructions Claude reads when you ask about your usage. Tells Claude to invoke the script with `-Json` and synthesize an answer. |
| `scripts/Get-ClaudeUsage.ps1` | The scanner. Cross-platform PowerShell. Supports `-Json` for structured stdout output, plus the existing HTML-generation flags. |
| `scripts/GenerateReport.bat` | **Windows** launcher — runs the script with `-ExecutionPolicy Bypass`, forwards args. |
| `scripts/GenerateReport.sh` | **macOS / Linux** launcher — invokes `pwsh`, forwards args. `chmod +x` once after clone. |
| `Install-Plugin.bat` | **Windows** one-click installer at the repo root — bypasses execution policy and calls the PowerShell script automatically. |
| `scripts/Install-Plugin-PowerShell.ps1` | PowerShell install helper — creates the marketplace wrapper and registers the plugin with Claude Code. Called by the bat; run directly on macOS/Linux. |
| `report.html` | Generated output: metadata only, safe to share (gitignored). |
| `report-detail.html` | Generated output: includes prompt text, keep local (gitignored). |
| `README.md` | This file. |
| `.gitignore` | Excludes generated `*.html` reports. |
