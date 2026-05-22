@echo off
REM Installs the claude-usage plugin into Claude Code for the current user.
REM Run this once. Bypasses PowerShell execution policy automatically.
REM
REM After install, restart Claude Code, then:
REM   Skill   - ask "show me my Claude usage" or "what's driving my spend"
REM   Command - type /claude-usage:usage-report

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0scripts\Install-Plugin-PowerShell.ps1"

if errorlevel 1 (
    echo.
    echo Install failed. See error above.
    echo Press any key to close...
    pause >nul
) else (
    echo.
    echo Press any key to close...
    pause >nul
)
