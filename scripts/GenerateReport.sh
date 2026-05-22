#!/usr/bin/env bash
# Mac/Linux mirror of GenerateReport.bat.
# Forwards any args to the PowerShell scanner, e.g.:
#   ./GenerateReport.sh -Days 7
#   ./GenerateReport.sh -NoDetail
#   ./GenerateReport.sh -NoOpen
# Requires PowerShell 7 (pwsh). On macOS:  brew install --cask powershell

set -e
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "Error: PowerShell 7 (pwsh) is required but not installed." >&2
    echo "  macOS:  brew install --cask powershell" >&2
    echo "  Linux:  https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux" >&2
    exit 1
fi

set +e
pwsh -NoProfile -File "$SCRIPT_DIR/Get-ClaudeUsage.ps1" "$@"
exit_code=$?
set -e

if [ $exit_code -ne 0 ]; then
    if [ -t 0 ]; then
        echo
        echo "Script exited with code $exit_code. Press Enter to close..."
        read
    fi
fi

exit $exit_code
