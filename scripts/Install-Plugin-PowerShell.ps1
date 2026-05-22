<#
.SYNOPSIS
    Installs the claude-usage plugin into Claude Code for the current user.

.DESCRIPTION
    Claude Code's plugin install command only works with marketplace-registered plugins,
    not raw local folders. This script creates a lightweight marketplace wrapper in
    ~/claude-plugins/, links it to this plugin directory, then registers and installs.

    Run once per machine. To update after pulling new changes, run:
        claude plugin update claude-usage

    To uninstall:
        claude plugin uninstall claude-usage

.PARAMETER MarketplaceRoot
    Where to create the marketplace wrapper (default: ~/claude-plugins).
    Choose any folder you own; it just needs to persist on disk.
#>

param (
    [string]$MarketplaceRoot = [System.IO.Path]::Combine($HOME, 'claude-plugins')
)

$ErrorActionPreference = 'Stop'
$pluginRoot   = Split-Path -Parent $PSScriptRoot        # the ClaudeUsage repo root
$manifestDir  = [System.IO.Path]::Combine($MarketplaceRoot, '.claude-plugin')
$pluginLink   = [System.IO.Path]::Combine($MarketplaceRoot, 'claude-usage')

Write-Host "Setting up claude-usage plugin..."
Write-Host "  Plugin root     : $pluginRoot"
Write-Host "  Marketplace root: $MarketplaceRoot"

# 1. Create marketplace wrapper directory and manifest
$null = New-Item -ItemType Directory -Force $manifestDir
$manifestJson = ConvertTo-Json -Depth 5 @{
    name    = 'local'
    owner   = @{ name = 'Assurant' }
    plugins = @(@{ name = 'claude-usage'; source = './claude-usage' })
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText(
    [System.IO.Path]::Combine($manifestDir, 'marketplace.json'),
    $manifestJson,
    $utf8NoBom
)

# 2. Link marketplace/claude-usage -> plugin root (junction on Windows, symlink on Mac/Linux)
if (Test-Path $pluginLink) {
    $existingPluginLink = Get-Item -LiteralPath $pluginLink -Force
    if (($existingPluginLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-Item -LiteralPath $pluginLink -Force -Recurse -ErrorAction SilentlyContinue
    } else {
        throw "Refusing to remove existing non-link path '$pluginLink'. Please delete or move it manually, or choose a different -MarketplaceRoot."
    }
}
if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    New-Item -ItemType Junction -Path $pluginLink -Target $pluginRoot | Out-Null
} else {
    & ln -sf $pluginRoot $pluginLink
}

# 3. Register the marketplace (idempotent: update if already known, add if new)
$marketplaceList = & claude plugin marketplace list 2>&1
if ($marketplaceList -match '\blocal\b') {
    Write-Host "  Marketplace 'local' already registered -- updating..."
    & claude plugin marketplace update local | Out-Null
} else {
    Write-Host "  Registering marketplace..."
    & claude plugin marketplace add $MarketplaceRoot --scope user | Out-Null
}

# 4. Install or update the plugin
$pluginList = & claude plugin list 2>&1
if ($pluginList -match 'claude-usage') {
    Write-Host "  Plugin already installed -- updating to latest..."
    & claude plugin marketplace update local | Out-Null
    $installOut = & claude plugin update 'claude-usage@local' 2>&1
} else {
    Write-Host "  Installing plugin..."
    $installOut = & claude plugin install 'claude-usage@local' --scope user 2>&1
}
Write-Host "  $installOut"

Write-Host ""
Write-Host "Done. Restart Claude Code to activate the plugin." -ForegroundColor Green
Write-Host ""
Write-Host "  Skill  : ask ""show me my Claude usage"" or ""what's driving my spend"""
Write-Host "  Command: /claude-usage:usage-report (opens HTML report)"
