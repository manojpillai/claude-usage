@echo off
REM Double-click this to scan ~/.claude/projects/ and open the usage report.
REM Forwards any args, e.g.:  GenerateReport.bat -Days 7
REM                           GenerateReport.bat -NoDetail
REM                           GenerateReport.bat -NoOpen

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Get-ClaudeUsage.ps1" %*

if errorlevel 1 (
    echo.
    echo Script exited with an error. Press any key to close...
    pause >nul
)
