#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test for FocusedTweaks.ps1 on a disposable GitHub Actions Windows runner.

.DESCRIPTION
    Runs FocusedTweaks for real: dry run with the defaults, dry run with the laptop profile, a real run with the
    defaults, the health check and -Revert. Collects the logs and the health and revert-check JSON of every stage
    into -OutDir, writes summary.txt and exits 1 when a stage fails or the health check reports FAIL.

    It refuses to run anywhere but a GitHub Actions runner: FocusedTweaks changes the machine it runs on.
    Windows Server has no Store apps, Quick Assist or restore points, so some results differ from Windows 11.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File windows\tools\Test-Smoke.ps1 -Script dist\FocusedTweaks.ps1 -OutDir smoke
#>
param(
    [Parameter(Mandatory)][string]$Script,
    [string]$LaptopProfile,
    [string]$OutDir = 'smoke'
)

if ($env:GITHUB_ACTIONS -ne 'true') {
    Write-Error 'Test-Smoke.ps1 runs FocusedTweaks for real and only runs on a disposable GitHub Actions runner.'
    exit 3
}
$ErrorActionPreference = 'Stop'
# Computed here, not as a parameter default: Windows PowerShell 5.1 leaves $PSScriptRoot empty there.
if (-not $LaptopProfile) { $LaptopProfile = Join-Path (Split-Path $PSCommandPath -Parent) '..\profiles\laptop.json' }

$Script = (Resolve-Path -LiteralPath $Script).Path
$LaptopProfile = (Resolve-Path -LiteralPath $LaptopProfile).Path
$StateDir = Join-Path $env:ProgramData 'FocusedTweaks'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# Packages is skipped: winget installs make the run slow and flaky without testing the script itself.
# The health check runs as its own stage, so the built-in one after the apply is skipped too.
$stages = @(
    @{ Name = 'Dry-Defaults'; Args = "-DryRun -Force -SkipRestorePoint" }
    @{ Name = 'Dry-Laptop'; Args = "-DryRun -Force -SkipRestorePoint -ProfilePath '$LaptopProfile'" }
    @{ Name = 'Apply'; Args = '-Force -SkipRestorePoint -Skip Packages,HealthCheckAfter' }
    @{ Name = 'Health'; Args = '-HealthCheck' }
    @{ Name = 'Revert'; Args = '-Revert -Force' }
)

$results = [System.Collections.Generic.List[object]]::new()
$index = 0
foreach ($stage in $stages) {
    $index++
    $label = '{0:00}-{1}' -f $index, $stage.Name
    $dest = Join-Path $OutDir $label
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $start = Get-Date
    Write-Host "==> $label`: FocusedTweaks.ps1 $($stage.Args)" -ForegroundColor Cyan
    # -Command, not -File: lists such as -Skip A,B only bind as arrays from a command line.
    $command = "& '$Script' $($stage.Args)"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command *>&1 | Tee-Object -FilePath (Join-Path $dest 'console.txt')
    $code = $LASTEXITCODE
    Get-ChildItem -LiteralPath $StateDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $start -and $_.Extension -in '.log', '.json' } |
        Copy-Item -Destination $dest
    $results.Add([pscustomobject]@{ Name = $label; Dir = $dest; Code = $code })
}

function Get-StageJson {
    param([string]$Dir, [string]$Kind)
    $file = Get-ChildItem -Path (Join-Path $Dir "$Kind-*.json") -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($file) { return Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json }
    return $null
}

$lines = [System.Collections.Generic.List[string]]::new()
$bad = $false
foreach ($r in $results) {
    $errors = @(Get-ChildItem -Path (Join-Path $r.Dir 'run-*.log') -ErrorAction SilentlyContinue | Select-String -SimpleMatch '[ERROR]')
    $lines.Add("$($r.Name): exit code $($r.Code), $($errors.Count) error line(s) in the log")
    foreach ($e in ($errors | Select-Object -First 10)) { $lines.Add("    $($e.Line.Trim())") }
    if ($r.Code -ne 0 -or $errors.Count -gt 0) { $bad = $true }
    $health = Get-StageJson -Dir $r.Dir -Kind 'health'
    if ($health) {
        $lines.Add("    health: $($health.Counts.PASS) passed, $($health.Counts.WARN) warning(s), $($health.Counts.FAIL) failed, $($health.Counts.INFO) note(s)")
        foreach ($i in @($health.Items | Where-Object { $_.Status -in 'WARN', 'FAIL' })) { $lines.Add("    [$($i.Status)] $($i.Area): $($i.Message)") }
        if ($health.Counts.FAIL -gt 0) { $bad = $true }
    }
    $revert = Get-StageJson -Dir $r.Dir -Kind 'revert-check'
    if ($revert) {
        $lines.Add("    revert check: $($revert.Counts.Checked) value(s) checked, $($revert.Counts.Differ) item(s) differ")
        foreach ($i in @($revert.Items | Select-Object -First 25)) { $lines.Add("    [$($i.Area)] $($i.Message)") }
    }
}
$lines | Set-Content -LiteralPath (Join-Path $OutDir 'summary.txt') -Encoding UTF8
if ($env:GITHUB_STEP_SUMMARY) { @('```') + $lines + @('```') | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8 }
Write-Host ''
$lines | ForEach-Object { Write-Host $_ }
exit ([int]$bad)
