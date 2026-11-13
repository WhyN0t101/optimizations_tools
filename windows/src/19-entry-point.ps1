#region Entry point -----------------------------------------------------------------------
if ($Revert -and $DryRun) { throw '-DryRun is not supported together with -Revert.' }
if ($Benchmark -or $FrameBenchmark) { throw 'The benchmarks moved to their own tool, with the same parameters: .\tools\Measure-Performance.ps1 (system), or .\tools\Measure-Performance.ps1 -FrameProcess game.exe (game frame times).' }
if ($Reapply -and ($Revert -or $HealthCheck -or $StartupReview -or $RestoreTask.Count -gt 0)) { throw '-Reapply cannot be combined with -Revert, -HealthCheck, -StartupReview or -RestoreTask.' }
if ($Reapply -and $Only.Count -gt 0) { throw '-Reapply uses the options of the earlier run. Leave some out with -Skip; -Only does not apply here.' }
Initialize-StateDir
# An unreadable state file ends every mode here with one clear line, before anything is changed.
try { Import-State }
catch { Write-Log $_.Exception.Message 'ERROR'; Exit-Run 4 $_.Exception.Message }
try { Repair-TrustedInstallerPath }
catch { $script:Failures++; Write-Log $_.Exception.Message 'ERROR' }
if ($StartupReview) { Show-StartupReview; Exit-Run 0 }
if ($HealthCheck) {
    Restore-SavedRunSettings
    Invoke-HealthCheck
    Exit-Run ([int]($script:Health.FAIL -gt 0))
}
if ($RestoreTask.Count -gt 0) {
    if ($Revert -or $DryRun) { throw '-RestoreTask cannot be combined with -Revert or -DryRun.' }
    Invoke-Step 'Restore selected tasks' { Restore-SelectedTasks }
    Exit-Run ([int]($script:Failures -gt 0))
}
if ($Revert -and $Only.Count -gt 0) {
    # -Only with -Revert names what to undo, not what to apply.
    Invoke-RevertOptions -Names $Only
}
elseif ($Revert) { Invoke-Revert }
elseif ($Reapply) {
    if ($Json -and -not $Force -and -not $script:DryRun) { Exit-Run 2 'A -Json run cannot answer questions. Add -Force for an unattended run.' }
    Invoke-Reapply
}
else {
    if ($Json -and -not $Force -and -not $script:DryRun) { Exit-Run 2 'A -Json run cannot answer questions. Add -Force for an unattended run.' }
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

if ($script:DryRun) { Write-Log 'Dry run complete. Nothing was changed.' 'OK'; Exit-Run 0 'Dry run, nothing was changed.' }
if ($script:Failures -gt 0) { Write-Log "Finished with $($script:Failures) failure(s) and $($script:Warnings) warning(s). Review the log: $LogFile" 'WARN' }
else { Write-Log "Finished without errors ($($script:Warnings) warning(s)). Log: $LogFile" 'OK' }
if (-not $Revert -and (Test-Path -LiteralPath $JournalFile)) { Write-Log "Every change with its option, value before, value after and result (OK, MISMATCH, FAILED): $JournalFile" }
Write-Log 'Restart Windows so service, policy and power changes take full effect.'
Exit-Run ([int]($script:Failures -gt 0))
#endregion
