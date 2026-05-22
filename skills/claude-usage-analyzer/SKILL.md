---
name: claude-usage-analyzer
description: Use this skill when the user asks about Claude usage, spend, cost, token counts, model mix, expensive prompts, or wants to understand what's driving their Claude bill.
allowed-tools: Bash(pwsh *) Bash(powershell *) Glob Read
---

# Claude Usage Analyzer

This skill answers questions about the user's local Claude Code usage by running the bundled PowerShell scanner in JSON mode, then synthesizing the data into a concise text answer.

## When to trigger

Examples of phrasings that should invoke this skill:
- "show me my Claude usage"
- "what's driving my Claude spend"
- "what was my most expensive prompt"
- "which projects are using the most tokens"
- "analyze my Claude cost breakdown"
- "how much have I spent on Claude this week"
- "is Opus or Sonnet driving more of my bill"
- "are there patterns I should optimize"

If the user wants the **visual** HTML report instead of a chat summary, point them at `/claude-usage:usage-report` and don't run this skill.

## How to run

### Phase 1 — Try the PowerShell scanner (preferred)

Invoke the scanner in JSON mode. Try `pwsh` (PowerShell 7) first:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-ClaudeUsage.ps1" -Json
```

If the above fails with a command-not-found error, fall back to `powershell` (Windows PS 5.1):

```
powershell -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-ClaudeUsage.ps1" -Json
```

Optional flags: `-Days N` to limit to the last N days, `-ProjectsDir <path>` for a custom transcripts directory.

If the command succeeds, parse stdout as JSON. The payload shape:

```
{
  "generatedAt": "...", "daysFilter": 0, "projectsDir": "...", "includeText": true,
  "summary": { "totalCost", "totalUserPrompts", "totalAssistantTurns",
               "totalInput", "totalOutput", "totalCacheRead", "totalCacheWrite",
               "numProjects", "numSessions", "firstDate", "lastDate", "anyUnpriced" },
  "projects": [ { "name", "sessions", "prompts", "input", "output",
                  "cacheRead", "cacheWrite", "cost", "unpriced" }, ... ],
  "models":   [ { "name", "prompts", "input", "output",
                  "cacheRead", "cacheWrite", "cost", "unpriced" }, ... ],
  "daily":    [ { "date", "prompts", "cost" }, ... ],
  "prompts":  [ { "ts", "project", "session", "text", "isSidechain",
                  "turns", "models", "inTok", "outTok", "crTok", "cwTok",
                  "cost", "unpriced" }, ... ]
}
```

### Phase 2 — Native fallback (if PowerShell is blocked)

If the shell command fails due to a permission/deny-rule error, fall back to reading the JSONL files directly using built-in tools — no shell execution required.

**Step 1**: Locate transcript files using the `Glob` tool:
- Pattern: `~/.claude/projects/**/*.jsonl`
- Exclude files whose names start with `agent-` (subagent sidechains — count separately if needed)
- Sort by modification time descending; cap at the 20 most-recent files to avoid context overflow

**Step 2**: For each file, use the `Read` tool and parse each line as JSON. For each line where `type == "assistant"` and `message.usage` exists:
- Extract: `timestamp`, `message.model`, `message.id` (for dedup — skip if seen), `cwd` (project name = last path segment), `message.usage.input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`
- Pricing (USD per million tokens): opus-4-7/opus-4-6 = $5 in / $25 out / $6.25 cw / $0.50 cr; sonnet-4-6 = $3/$15/$3.75/$0.30; haiku-4-5 = $1/$5/$1.25/$0.10

**Step 3**: Aggregate across all files and produce the same summary format as Phase 1. Note in your response that this is a native fallback covering only the most recent files scanned, and suggest the user add `Bash(pwsh *)` and `Bash(powershell *)` to their Claude Code allow rules for full history.

## Default summary (when the user asks a general "show me" question)

Reply with a concise, scannable text summary — no tables of raw numbers, no walls of JSON. Structure it like this:

1. **One-line headline**: total estimated cost over the date range covered.
2. **Top 3 projects by cost** with their share of total spend.
3. **Model mix** as percentages (e.g., "Opus 76%, Sonnet 18%, Haiku 6%").
4. **Top 3 most expensive single prompts**: timestamp, project, truncated text (~100 chars), cost.
5. **One observation** that stands out (a notable concentration, anomaly, or trend).

## Analysis mode (when the user asks for optimization or "what should I improve")

After the default summary, walk through the data and surface concrete patterns. Look for:

- **Opus used for lightweight tasks**: prompts that produced few turns and short responses but used Opus → could likely move to Sonnet. Cite specific prompt text.
- **Cache-miss patterns**: high `cacheWrite` but low `cacheRead` ratio → user is rebuilding cache instead of reusing it. Suggest keeping related work in one session.
- **Runaway prompts**: single user prompts that ballooned into 20+ assistant turns. Often a sign that scope should have been split. Cite by prompt text.
- **Subagent concentration**: prompts with `isSidechain=true` accumulating significant cost. Worth confirming the subagent's value vs running the work inline.
- **Project-level outliers**: one project consuming a disproportionate share. Worth a workflow review.

For each pattern found, give a **concrete recommendation** — not generic advice. Reference the actual prompt text or project name.

## Always state these caveats

- Costs are **estimates at Anthropic API pricing** (table hardcoded in the script as of April 2026; verify if quoting hard numbers).
- If the user is on a Max or Pro subscription, the cost shown is **not their actual bill** — it's a "what would this cost on the API" reference.
- Cowork sessions (server-side) are **not captured**.
- Some models may show as `unpriced` (e.g., `<synthetic>`, custom models). Tokens are still counted; cost is excluded from totals. The `anyUnpriced` flag on summary/project/model objects signals this.

## What this skill should NOT do

- Don't dump the raw JSON to chat.
- Don't render markdown tables of all 165+ prompts — pick the 3-5 most relevant rows.
- Don't make pricing claims as authoritative — always frame as estimates.
- Don't write any files. (The `-Json` flag bypasses HTML generation entirely.)
- Don't run the scanner without `-Json` unless the user explicitly wants the visual report (in which case suggest the `/claude-usage:usage-report` slash command).
