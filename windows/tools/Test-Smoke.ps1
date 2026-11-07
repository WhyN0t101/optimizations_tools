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
    [string]$OutDir = 'smoke',
    [int]$StageMinutes = 12
)

if ($env:GITHUB_ACTIONS -ne 'true') {
    Write-Error 'Test-Smoke.ps1 runs FocusedTweaks for real and only runs on a disposable GitHub Actions runner.'
    exit 3
}
$ErrorActionPreference = 'Stop'
# Anything that stops this script must still reach the public annotations, or the failure is invisible.
trap {
    $msg = "Test-Smoke.ps1 stopped: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)" -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Host "::error title=Test-Smoke::$msg"
    exit 1
}
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
    @{ Name = 'RestoreTask'; Args = "-RestoreTask '\Microsoft\Windows\Application Experience\*'" }
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
    # A separate process with a time limit: a stage that hangs (DISM, a service that will not stop) must not use up
    # the whole job, or the job is killed before this script can publish anything.
    $out = Join-Path $dest 'console.txt'
    $err = Join-Path $dest 'console-err.txt'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $proc = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded `
        -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    if ($proc.WaitForExit($StageMinutes * 60 * 1000)) { $code = $proc.ExitCode }
    else {
        $null = & cmd.exe /d /c "taskkill /T /F /PID $($proc.Id) >nul 2>&1"
        $code = 124
        Write-Host "$label timed out after $StageMinutes minutes and was stopped." -ForegroundColor Red
    }
    Get-Content -LiteralPath $out, $err -ErrorAction SilentlyContinue | Write-Host
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

# Annotations are public on a public repo and readable through the API without signing in, unlike step logs.
function Write-Annotation {
    param([ValidateSet('error', 'warning', 'notice')][string]$Level, [string]$Title, [string[]]$Body)
    $text = ($Body -join "`n") -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Host "::$Level title=$Title::$text"
}

$lines = [System.Collections.Generic.List[string]]::new()
$bad = $false
foreach ($r in $results) {
    $stageLines = [System.Collections.Generic.List[string]]::new()
    $stageBad = $false
    $errors = @(Get-ChildItem -Path (Join-Path $r.Dir 'run-*.log') -ErrorAction SilentlyContinue | Select-String -SimpleMatch '[ERROR]')
    $stageLines.Add("$($r.Name): exit code $($r.Code), $($errors.Count) error line(s) in the log")
    foreach ($e in ($errors | Select-Object -First 15)) { $stageLines.Add("    $($e.Line.Trim())") }
    # "Could not ..." warnings carry the reason behind items the revert check reports; logs are not public.
    $couldNot = @(Get-ChildItem -Path (Join-Path $r.Dir 'run-*.log') -ErrorAction SilentlyContinue | Select-String -Pattern '\[WARN\] Could not')
    foreach ($w in ($couldNot | Select-Object -First 10)) { $stageLines.Add("    $($w.Line.Trim())") }
    if ($r.Code -ne 0 -or $errors.Count -gt 0) { $stageBad = $true }
    if ($r.Code -eq 124) {
        # Timed out: the last log lines show the step it hung in.
        $stageLines.Add("    TIMED OUT after $StageMinutes minutes. Last log lines:")
        $log = Get-ChildItem -Path (Join-Path $r.Dir 'run-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($log) { foreach ($l in @(Get-Content -LiteralPath $log.FullName -Tail 12)) { $stageLines.Add("    log: $l") } }
    }
    elseif ($r.Code -ne 0 -and $errors.Count -eq 0) {
        # A failure before the log starts (parameter binding, a throw at the top) only shows in the console.
        foreach ($c in @(Get-Content -LiteralPath (Join-Path $r.Dir 'console.txt') -ErrorAction SilentlyContinue | Select-Object -Last 15)) { $stageLines.Add("    console: $c") }
    }
    $health = Get-StageJson -Dir $r.Dir -Kind 'health'
    if ($health) {
        $stageLines.Add("    health: $($health.Counts.PASS) passed, $($health.Counts.WARN) warning(s), $($health.Counts.FAIL) failed, $($health.Counts.INFO) note(s)")
        foreach ($i in @($health.Items | Where-Object { $_.Status -in 'WARN', 'FAIL' })) { $stageLines.Add("    [$($i.Status)] $($i.Area): $($i.Message)") }
        if ($health.Counts.FAIL -gt 0) { $stageBad = $true }
    }
    $revert = Get-StageJson -Dir $r.Dir -Kind 'revert-check'
    if ($revert) {
        $stageLines.Add("    revert check: $($revert.Counts.Checked) value(s) checked, $($revert.Counts.Differ) item(s) differ")
        foreach ($i in @($revert.Items | Select-Object -First 25)) { $stageLines.Add("    [$($i.Area)] $($i.Message)") }
    }
    $level = 'notice'
    if ($stageBad) { $level = 'error'; $bad = $true }
    Write-Annotation -Level $level -Title $r.Name -Body $stageLines
    $lines.AddRange($stageLines)
}
$lines | Set-Content -LiteralPath (Join-Path $OutDir 'summary.txt') -Encoding UTF8
if ($env:GITHUB_STEP_SUMMARY) { @('```') + $lines + @('```') | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8 }
Write-Host ''
$lines | ForEach-Object { Write-Host $_ }
exit ([int]$bad)
