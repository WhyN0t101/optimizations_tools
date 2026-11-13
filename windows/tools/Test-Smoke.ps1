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
    [int]$StageMinutes = 12,
    # steps.json of an earlier run on the same runner: each step's time is compared with it, and a step that got much
    # slower is flagged. The workflow keeps the last one in the Actions cache.
    [string]$PreviousTimes
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
    # -AllowManaged: whether the hosted runner image is domain or Entra joined is not under our control, and it is thrown
    # away afterwards, so the pre flight block for managed PCs must not fail the smoke test.
    @{ Name = 'Apply'; Args = '-Force -SkipRestorePoint -AllowManaged -Skip Packages,HealthCheckAfter' }
    @{ Name = 'Health'; Args = '-HealthCheck' }
    # Both passes of -Reapply: the scan and the repair. The runner is never restarted, so the restart the optional
    # features asked for stays pending; -Reapply would wait for it, hence the two skipped checks.
    @{ Name = 'Reapply'; Args = '-Reapply -Force -AllowManaged -SkipCheck PendingReboot,WindowsUpdate' }
    # Read only, so it can run between the others; this only proves it runs cleanly as administrator.
    @{ Name = 'Explain'; Script = (Join-Path (Split-Path $PSCommandPath -Parent) 'Explain-Processes.ps1'); Args = '' }
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
    $stageScript = $Script
    if ($stage.ContainsKey('Script')) { $stageScript = $stage.Script }
    Write-Host "==> $label`: $(Split-Path $stageScript -Leaf) $($stage.Args)" -ForegroundColor Cyan
    # -Command, not -File: lists such as -Skip A,B only bind as arrays from a command line.
    $command = "& '$stageScript' $($stage.Args)"
    # A separate process with a time limit: a stage that hangs (DISM, a service that will not stop) must not use up
    # the whole job, or the job is killed before this script can publish anything.
    $out = Join-Path $dest 'console.txt'
    $err = Join-Path $dest 'console-err.txt'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $proc = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded `
        -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    # Reading Handle right away keeps the process handle open; without it ExitCode comes back empty.
    $null = $proc.Handle
    if ($proc.WaitForExit($StageMinutes * 60 * 1000)) { $proc.WaitForExit(); $code = $proc.ExitCode }
    else {
        $null = & cmd.exe /d /c "taskkill /T /F /PID $($proc.Id) >nul 2>&1"
        $code = 124
        Write-Host "$label timed out after $StageMinutes minutes and was stopped." -ForegroundColor Red
    }
    Get-Content -LiteralPath $out, $err -ErrorAction SilentlyContinue | Write-Host
    Get-ChildItem -LiteralPath $StateDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $start -and $_.Extension -in '.log', '.json' } |
        Copy-Item -Destination $dest
    $end = Get-Date
    $results.Add([pscustomobject]@{ Name = $label; Dir = $dest; Code = $code; Seconds = [int]($end - $start).TotalSeconds; Start = $start; End = $end })
}

function Get-StepTimes {
    # Seconds per step, from the "Starting: X" and "Completed: X" (or "Failed: X. ...") lines of the stage's run log.
    param([string]$Dir, [string]$Stage)
    $log = Get-ChildItem -Path (Join-Path $Dir 'run-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $log) { return @() }
    $open = @{}
    $out = [System.Collections.Generic.List[object]]::new()
    $last = $null; $dayOffset = 0
    foreach ($line in [IO.File]::ReadLines($log.FullName)) {
        if ($line -notmatch '^(\d\d):(\d\d):(\d\d) \[\w+\]\s+(Starting|Completed|Failed): (.+)$') { continue }
        $t = ([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) + [int]$Matches[3]
        if ($null -ne $last -and $t + $dayOffset -lt $last) { $dayOffset += 86400 }   # past midnight
        $t += $dayOffset; $last = $t
        $kind = $Matches[4]; $text = $Matches[5].Trim()
        if ($kind -eq 'Starting') { $open[$text] = $t; continue }
        # "Failed: Packages. 1 change(s) in it failed" names the step at the start of its text.
        $name = @($open.Keys | Where-Object { $text -eq $_ -or $text.StartsWith("$_.") }) | Select-Object -First 1
        if (-not $name) { continue }
        # -Reapply runs its steps twice (scan, then repair): the second one is "Step (2)", so both compare correctly.
        $label = $name; $n = 2
        while (@($out | Where-Object { $_.Step -eq $label }).Count -gt 0) { $label = "$name ($n)"; $n++ }
        $out.Add([pscustomobject]@{ Stage = $Stage; Step = $label; Seconds = [int]($t - $open[$name]) })
        $open.Remove($name)
    }
    return $out
}

function Get-LogEdges {
    # Seconds from the stage's launch to its first log line, and from its last log line to the end of the process:
    # PowerShell starting and loading the script, the set up before logging begins, and whatever runs after the last
    # line. $null when the stage wrote no run log (the Explain tool).
    param([string]$Dir, [datetime]$Start, [datetime]$End)
    $log = Get-ChildItem -Path (Join-Path $Dir 'run-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $log) { return $null }
    $times = @(Select-String -LiteralPath $log.FullName -Pattern '^(\d\d):(\d\d):(\d\d) ' | ForEach-Object { ([int]$_.Matches[0].Groups[1].Value * 3600) + ([int]$_.Matches[0].Groups[2].Value * 60) + [int]$_.Matches[0].Groups[3].Value })
    if ($times.Count -eq 0) { return $null }
    # Log lines have whole seconds, so a gap can come out as -1; the day wrap covers a stage across midnight.
    $gap = { param($from, $to) $d = (($to - $from) % 86400 + 86400) % 86400; if ($d -gt 43200) { $d -= 86400 }; [Math]::Max(0, $d) }
    # Time inside the log while no step or timed part is open, and the line the longest such gap followed.
    $depth = 0; $untimed = 0; $prev = $null; $prevLine = ''; $worst = 0; $worstAfter = ''
    foreach ($line in [IO.File]::ReadLines($log.FullName)) {
        if ($line -notmatch '^(\d\d):(\d\d):(\d\d) ') { continue }
        $t = ([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) + [int]$Matches[3]
        if ($null -ne $prev -and $depth -eq 0) {
            $d = & $gap $prev $t
            $untimed += $d
            if ($d -gt $worst) { $worst = $d; $worstAfter = $prevLine }
        }
        if ($line -match '\]\s+Starting: ') { $depth++ } elseif ($line -match '\]\s+(Completed|Failed): ' -and $depth -gt 0) { $depth-- }
        $prev = $t; $prevLine = $line
    }
    return [pscustomobject]@{
        BeforeLog    = & $gap ([int]$Start.TimeOfDay.TotalSeconds) $times[0]
        AfterLog     = & $gap $times[-1] ([int]$End.TimeOfDay.TotalSeconds)
        Untimed      = $untimed
        UntimedAfter = $(if ($worst -ge 5) { "$worst s after: $($worstAfter.Substring(0, [Math]::Min(100, $worstAfter.Length)))" } else { '' })
    }
}

function Get-TimeFindings {
    # The step time lines for the summary, and the steps that got much slower than in the previous run: at least 50 %
    # and 30 seconds more, so normal noise on a shared runner does not count.
    param([object[]]$Stages, [object[]]$Steps, $Previous)
    $before = @{}
    if ($Previous) {
        foreach ($p in @($Previous.Stages)) {
            $before["stage|$($p.Stage)"] = [int]$p.Seconds
            if ($p.PSObject.Properties['BeforeLog'] -and $null -ne $p.BeforeLog) { $before["before|$($p.Stage)"] = [int]$p.BeforeLog; $before["after|$($p.Stage)"] = [int]$p.AfterLog }
            if ($p.PSObject.Properties['Untimed'] -and $null -ne $p.Untimed) { $before["untimed|$($p.Stage)"] = [int]$p.Untimed }
        }
        foreach ($p in @($Previous.Steps)) { $before["$($p.Stage)|$($p.Step)"] = [int]$p.Seconds }
    }
    $show = { param($key, $now) if ($before.ContainsKey($key)) { "$now s (was $($before[$key]) s)" } else { "$now s" } }
    $slower = { param($key, $now) $before.ContainsKey($key) -and $now -ge $before[$key] * 1.5 -and $now - $before[$key] -ge 30 }
    $lines = [System.Collections.Generic.List[string]]::new()
    $flags = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Time per stage, with its slowest steps' + $(if ($Previous) { ' (previous run in brackets):' } else { ' (no previous run to compare with):' }))
    foreach ($s in $Stages) {
        $lines.Add("  $($s.Stage): $(& $show "stage|$($s.Stage)" $s.Seconds)")
        if ($s.PSObject.Properties['BeforeLog'] -and $null -ne $s.BeforeLog) {
            $lines.Add("      before the first log line: $(& $show "before|$($s.Stage)" $s.BeforeLog), after the last: $(& $show "after|$($s.Stage)" $s.AfterLog), in the log outside any step: $(& $show "untimed|$($s.Stage)" $s.Untimed)")
            if ($s.UntimedAfter) { $lines.Add("      longest of those: $($s.UntimedAfter)") }
        }
        if (& $slower "stage|$($s.Stage)" $s.Seconds) { $flags.Add("$($s.Stage) took $($s.Seconds) s, was $($before["stage|$($s.Stage)"]) s") }
        foreach ($st in @($Steps | Where-Object { $_.Stage -eq $s.Stage -and $_.Seconds -ge 5 } | Sort-Object Seconds -Descending | Select-Object -First 5)) {
            $key = "$($st.Stage)|$($st.Step)"
            $lines.Add("      $($st.Step): $(& $show $key $st.Seconds)")
        }
        foreach ($st in @($Steps | Where-Object { $_.Stage -eq $s.Stage })) {
            $key = "$($st.Stage)|$($st.Step)"
            if (& $slower $key $st.Seconds) { $flags.Add("$($st.Stage) / $($st.Step) took $($st.Seconds) s, was $($before[$key]) s") }
        }
    }
    return [pscustomobject]@{ Lines = $lines; Slower = $flags }
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
# Step times: kept as steps.json for the next run to compare with, and shown in the summary. A much slower step is a
# warning, not a failure: shared runners vary, but a step that doubles is worth a look on the push that caused it.
$stageTimes = @($results | ForEach-Object {
        $edges = Get-LogEdges -Dir $_.Dir -Start $_.Start -End $_.End
        [pscustomobject]@{ Stage = $_.Name; Seconds = $_.Seconds; BeforeLog = $(if ($edges) { $edges.BeforeLog }); AfterLog = $(if ($edges) { $edges.AfterLog })
            Untimed = $(if ($edges) { $edges.Untimed }); UntimedAfter = $(if ($edges) { $edges.UntimedAfter }) }
    })
$stepTimes = @(foreach ($r in $results) { Get-StepTimes -Dir $r.Dir -Stage $r.Name })
[pscustomobject]@{ Stages = $stageTimes; Steps = $stepTimes } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir 'steps.json') -Encoding UTF8
$previous = $null
if ($PreviousTimes -and (Test-Path -LiteralPath $PreviousTimes)) {
    try { $previous = Get-Content -LiteralPath $PreviousTimes -Raw | ConvertFrom-Json } catch { Write-Host "Previous step times unreadable: $($_.Exception.Message)" }
}
$timing = Get-TimeFindings -Stages $stageTimes -Steps $stepTimes -Previous $previous
Write-Annotation -Level 'notice' -Title 'Step times' -Body $timing.Lines
if ($timing.Slower.Count -gt 0) { Write-Annotation -Level 'warning' -Title 'Slower than the previous run' -Body $timing.Slower }
$lines.Add('')
$lines.AddRange($timing.Lines)
foreach ($f in $timing.Slower) { $lines.Add("  SLOWER: $f") }
$lines | Set-Content -LiteralPath (Join-Path $OutDir 'summary.txt') -Encoding UTF8
if ($env:GITHUB_STEP_SUMMARY) { @('```') + $lines + @('```') | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8 }
Write-Host ''
$lines | ForEach-Object { Write-Host $_ }
exit ([int]$bad)
