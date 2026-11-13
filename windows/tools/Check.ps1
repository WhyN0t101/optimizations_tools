#Requires -Version 5.1
<#
.SYNOPSIS
    The local version of CI: builds FocusedTweaks.ps1 from src/, then runs tests\Test-Parse.ps1 under Windows
    PowerShell 5.1 and PowerShell 7. Stops at the first failure. Never runs FocusedTweaks.ps1.

.DESCRIPTION
    Run it after every change:

        .\tools\Check.ps1

    -Staged is what the pre-commit hook (.githooks/pre-commit) uses: it also fails when the generated files
    (FocusedTweaks.ps1, docs\OPTIONS.md, docs\REGISTRY.md) in the commit differ from the build, which is the check
    CI makes on every push. Turn the hook on once per clone with: git config core.hooksPath .githooks
#>
[CmdletBinding()]
param([switch]$Staged)

# Not 'Stop': under Windows PowerShell 5.1 a native command writing to stderr with 2>&1 would then end the check.
$windowsDir = Split-Path $PSScriptRoot -Parent
$generated = @('FocusedTweaks.ps1', 'docs/OPTIONS.md', 'docs/REGISTRY.md')

function Stop-Check([string]$Message) {
    Write-Host "Check failed: $Message" -ForegroundColor Red
    exit 1
}

Push-Location $windowsDir
try {
    Write-Host 'Build' -ForegroundColor Cyan
    $buildOut = & python tools/build.py --out FocusedTweaks.ps1 2>&1
    if ($LASTEXITCODE -ne 0) { $buildOut | Out-Host; Stop-Check 'build.py failed.' }

    if ($Staged) {
        # The working tree holds the fresh build; the index holds what would be committed.
        & git diff --quiet --ignore-cr-at-eol -- $generated
        if ($LASTEXITCODE -ne 0) {
            Stop-Check ('the generated files in the commit are out of date. Stage them (git add ' + ($generated -join ' ') +
                ') and commit again. If src\ has edits you are not committing, stash them first.')
        }
    }

    $shells = @(@{ Name = 'Windows PowerShell 5.1'; Exe = 'powershell' }, @{ Name = 'PowerShell 7'; Exe = 'pwsh' })
    foreach ($shell in $shells) {
        if (-not (Get-Command $shell.Exe -ErrorAction SilentlyContinue)) { Stop-Check "$($shell.Exe) was not found; CI runs Test-Parse under both." }
        Write-Host "Test-Parse ($($shell.Name))" -ForegroundColor Cyan
        $testOut = & $shell.Exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Parse.ps1 2>&1
        if ($LASTEXITCODE -ne 0) {
            $testOut | Where-Object { "$_" -notlike '`[PASS`]*' } | Out-Host
            Stop-Check "Test-Parse failed under $($shell.Name)."
        }
    }
    Write-Host 'All checks passed.' -ForegroundColor Green
}
finally {
    Pop-Location
}
