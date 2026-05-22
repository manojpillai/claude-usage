---
description: Generate and open the local Claude Code usage report (HTML, per-project + per-prompt breakdown).
allowed-tools: Bash(pwsh *) Bash(powershell *)
argument-hint: "[-Days N] [-NoDetail] [-NoOpen]"
---

# Generate Usage Report

Generate the local Claude Code usage HTML report and open it in the browser.

Run the PowerShell scanner, then let the user know the report has been opened. If the command fails due to a permission or deny-rule error, explain that PowerShell is blocked and offer to produce a chat-based summary instead (the same analysis the claude-usage-analyzer skill provides).

First try `pwsh` (PowerShell 7):

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-ClaudeUsage.ps1" $ARGUMENTS
```

If the above fails with a command-not-found error, fall back to `powershell` (Windows PS 5.1):

```
powershell -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-ClaudeUsage.ps1" $ARGUMENTS
```
