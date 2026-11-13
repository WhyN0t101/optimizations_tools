#region Entry point -----------------------------------------------------------------------
function Get-ModeConflict {
    # The one place that refuses parameter combinations, so a mode is never dropped without a word. Returns the message,
    # or $null when the combination is fine. Pure: it only looks at the flags it is given.
    param([Parameter(Mandatory)][hashtable]$Flags)
    if ($Flags.Benchmark -or $Flags.FrameBenchmark) { return 'The benchmarks moved to their own tool, with the same parameters: .\tools\Measure-Performance.ps1 (system), or .\tools\Measure-Performance.ps1 -FrameProcess game.exe (game frame times).' }
    if ($Flags.Revert -and $Flags.DryRun) { return '-DryRun is not supported together with -Revert.' }
    if ($Flags.RestoreTask -and $Flags.DryRun) { return '-RestoreTask cannot be combined with -DryRun.' }
    if ($Flags.Reapply -and $Flags.Only) { return '-Reapply uses the options of the earlier run. Leave some out with -Skip; -Only does not apply here.' }
    $modes = @('Revert', 'Reapply', 'HealthCheck', 'StartupReview', 'RestoreTask' | Where-Object { $Flags[$_] })
    if ($modes.Count -gt 1) { return "-$($modes -join ', -') are separate modes; run them one at a time." }
    return $null
}

function Assert-CanAsk {
    # A run that may ask a question cannot be unattended without -Force: with -Json nobody sees the question.
    if ($Json -and -not $Force -and -not $Ctx.DryRun) { Exit-Run 2 'A -Json run cannot answer questions. Add -Force for an unattended run.' }
}

function Invoke-ApplyMode {
    Assert-CanAsk
    # Only a hint: the defaults trade battery and security for speed, and laptops usually want the laptop profile.
    if (-not $ProfilePath -and (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)) {
        Write-Log "Battery detected and no profile given. The defaults favour speed over battery life and security; on a laptop consider -ProfilePath $(Join-Path $PSScriptRoot 'profiles\laptop.json')." 'WARN'
    }
    Show-Plan
    if (-not (Invoke-Preflight)) { Exit-Run 3 "Refused by the pre flight check(s) $(@($script:PreflightResults | Where-Object { $_.Status -eq 'BLOCK' } | ForEach-Object { $_.Check }) -join ', ')." }
    if (-not (Confirm-Run)) { Write-Log 'Cancelled, nothing was changed.' 'WARN'; Exit-Run 2 'The run was not confirmed.' }
    Invoke-Apply
    Save-State
}

# What each mode does, keyed by Get-RunMode. Modes that end on their own call Exit-Run; the others fall through to the
# common summary below.
$ModeActions = [ordered]@{
    startupreview = { Show-StartupReview; Exit-Run 0 }
    healthcheck   = { Restore-SavedRunSettings; Invoke-HealthCheck; Exit-Run ([int]($script:Health.FAIL -gt 0)) }
    restoretask   = { Invoke-Step 'Restore selected tasks' { Restore-SelectedTasks }; Exit-Run ([int]($Ctx.Failures -gt 0)) }
    revertonly    = { Invoke-RevertOptions -Names $Only }   # -Only with -Revert names what to undo
    revert        = { Invoke-Revert }
    reapply       = { Assert-CanAsk; Invoke-Reapply }
    dryrun        = { Invoke-ApplyMode }
    apply         = { Invoke-ApplyMode }
}

$conflict = Get-ModeConflict -Flags @{
    Revert = [bool]$Revert; DryRun = [bool]$DryRun; Reapply = [bool]$Reapply; HealthCheck = [bool]$HealthCheck
    StartupReview = [bool]$StartupReview; RestoreTask = ($RestoreTask.Count -gt 0); Only = ($Only.Count -gt 0)
    Benchmark = [bool]$Benchmark; FrameBenchmark = [bool]$FrameBenchmark
}
if ($conflict) { throw $conflict }
Initialize-StateDir
# An unreadable state file ends every mode here with one clear line, before anything is changed.
try { Import-State }
catch { Write-Log $_.Exception.Message 'ERROR'; Exit-Run 4 $_.Exception.Message }
try { Repair-TrustedInstallerPath }
catch { $Ctx.Failures++; Write-Log $_.Exception.Message 'ERROR' }
& $ModeActions[(Get-RunMode)]

if ($Ctx.DryRun) { Write-Log 'Dry run complete. Nothing was changed.' 'OK'; Exit-Run 0 'Dry run, nothing was changed.' }
if ($Ctx.Failures -gt 0) { Write-Log "Finished with $($Ctx.Failures) failure(s) and $($Ctx.Warnings) warning(s). Review the log: $LogFile" 'WARN' }
else { Write-Log "Finished without errors ($($Ctx.Warnings) warning(s)). Log: $LogFile" 'OK' }
if (-not $Revert -and (Test-Path -LiteralPath $JournalFile)) { Write-Log "Every change with its option, value before, value after and result (OK, MISMATCH, FAILED): $JournalFile" }
Write-Log 'Restart Windows so service, policy and power changes take full effect.'
Exit-Run ([int]($Ctx.Failures -gt 0))
#endregion
