#region Services and scheduled tasks ------------------------------------------------------
function Set-ServiceStart {
    param([Parameter(Mandatory)][string]$Name, [ValidateSet('Disabled', 'Manual')][string]$Mode = 'Disabled')
    $reg = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$Name"
    $probe = Open-RegKey -Full $reg
    if (-not $probe) { Write-Log "Service not present: $Name"; return }
    $probe.Close()
    if ($Ctx.Reapply -and (Get-ServiceStartNow $Name) -eq $(if ($Mode -eq 'Disabled') { 4 } else { 3 })) { return }
    Set-RegValue -Path $reg -Name 'Start' -Value $(if ($Mode -eq 'Disabled') { 4 } else { 3 }) -Type DWord
    if ($Mode -eq 'Disabled' -and -not $Ctx.DryRun) {
        foreach ($svc in @(Get-Service -Name $Name, "${Name}_*" -ErrorAction SilentlyContinue)) {
            # Disabled is what counts; a service that will not stop now stays stopped after the next restart.
            if (-not (Stop-ServiceBounded -Name $svc.Name)) { Write-Log "Service $($svc.Name) is disabled but did not stop within 30 s. It stops at the next restart." }
        }
    }
}

$ServicesRoot = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services'

function Remove-ServiceKey {
    # -ServiceMode Delete: the service is gone after the next restart. Its key, and the keys of its per user copies
    # (Name_xxxxx), are exported first by Remove-RegKey, so -Revert brings them back (also after a restart).
    param([Parameter(Mandatory)][string]$Name)
    $root = Open-RegKey -Full $ServicesRoot
    if (-not $root) { return }
    try { $keys = @($root.GetSubKeyNames() | Where-Object { $_ -ieq $Name -or $_ -like "${Name}_*" }) } finally { $root.Close() }
    if (@($keys | Where-Object { $_ -ieq $Name }).Count -eq 0) { Write-Log "Service not present: $Name"; return }
    if (-not $Ctx.DryRun) {
        foreach ($svc in @(Get-Service -Name $Name, "${Name}_*" -ErrorAction SilentlyContinue)) {
            if (-not (Stop-ServiceBounded -Name $svc.Name)) { Write-Log "Service $($svc.Name) did not stop within 30 s; it is gone after the next restart anyway." }
        }
    }
    foreach ($k in $keys) { Remove-RegKey -Path "$ServicesRoot\$k" }
}

function Test-ServiceKeyDeletedByRun {
    # A missing service key counts as done only when this script deleted it (it holds the export).
    param([string]$Name)
    $path = "$ServicesRoot\$Name"
    return @($script:State.KeyBackups | Where-Object { $_.Path -ieq $path }).Count -gt 0
}

function Set-VendorServices {
    $present = 0
    foreach ($pair in @(@($VendorServicesDisable, 'Disabled'), @($VendorServicesManual, 'Manual'))) {
        foreach ($name in $pair[0]) {
            if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { continue }
            $present++
            Set-ServiceStart -Name $name -Mode $pair[1]
        }
    }
    if ($present -eq 0) { Write-Log 'Vendor services: none of the Lenovo and Intel services this option handles is installed.' }
}

function Disable-ServiceGroups {
    foreach ($g in $ServiceGroups.Keys) {
        if (-not $Opt[$g]) { Write-Log "Services kept (option $g is off): $($ServiceGroups[$g] -join ', ')" }
    }
    if ($ServiceMode -eq 'Delete') { Write-Log 'Service mode Delete: the services below are deleted (their keys are exported first) and are gone after the next restart. A Windows update may register one again.' 'WARN' }
    $done = @()
    foreach ($g in $ServiceGroups.Keys) {
        if (-not $Opt[$g]) { continue }
        $Ctx.JournalOption = $g
        foreach ($name in $ServiceGroups[$g]) {
            if ($done -contains $name) { continue }
            if ($ServiceMode -eq 'Delete') { Remove-ServiceKey -Name $name } else { Set-ServiceStart -Name $name -Mode Disabled }
            $done += $name
        }
    }
}

function Get-TaskRecord {
    param([string]$Path, [string]$Name)
    return @($script:State.Tasks | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name }) | Select-Object -First 1
}

function Save-TaskState {
    # Returns what it did: 'new', 'upgraded' (a Disabled record became Deleted) or 'kept'. The first record keeps the
    # original WasEnabled; a task disabled by one run and deleted by a later one must still be restorable from XML.
    param($Task, [string]$Action, [string]$XmlFile = $null)
    $e = Get-TaskRecord -Path $Task.TaskPath -Name $Task.TaskName
    $mode = 'kept'
    if (-not $e) { $mode = 'new' }
    elseif ($Action -eq 'Deleted' -and $e.Action -eq 'Disabled') { $mode = 'upgraded' }
    if ($mode -eq 'kept') { return 'kept' }
    $wasEnabled = ($Task.State -ne 'Disabled')
    if ($e) { $wasEnabled = [bool]$e.WasEnabled }
    $record = [pscustomobject]@{ Path = $Task.TaskPath; Name = $Task.TaskName; Action = $Action; WasEnabled = $wasEnabled; XmlFile = $XmlFile }
    Add-JournalEvents @([ordered]@{ Op = 'Task'; Mode = $mode; Record = $record })
    return $mode
}

function Undo-TaskRecord {
    # A delete that failed must not leave a record claiming the task was removed.
    param($Task, [string]$Outcome)
    if ($Outcome -notin 'new', 'upgraded') { return }
    Add-JournalEvents @([ordered]@{ Op = 'TaskUndo'; Path = $Task.TaskPath; Name = $Task.TaskName; Outcome = $Outcome })
}

function New-TaskChange {
    # The journal line announcing one task change. Before is what a rollback of the step registers or enables again:
    # the task as it is right now, from the export that holds it.
    param($Task, [string]$Action, [string]$XmlFile = $null)
    $before = [pscustomobject]@{ Path = $Task.TaskPath; Name = $Task.TaskName; Action = $Action; WasEnabled = ($Task.State -ne 'Disabled'); XmlFile = $XmlFile }
    return [ordered]@{ Op = 'Change'; Kind = 'Task'; Target = "$($Task.TaskPath)$($Task.TaskName)"; Before = $before; After = $Action }
}

function Disable-TaskRecorded {
    param($Task)
    $full = "$($Task.TaskPath)$($Task.TaskName)"
    if ($Task.State -eq 'Disabled') { return }
    if (Test-DryRun "disable task $full") { return }
    [void](Save-TaskState -Task $Task -Action 'Disabled')
    $change = New-TaskChange -Task $Task -Action 'Disabled'
    Add-JournalEvents @($change)
    try { Disable-ScheduledTask -InputObject $Task -ErrorAction Stop | Out-Null }
    catch {
        # Through cmd.exe: schtasks reports failure on stderr, which stops the step under 'Stop' in PowerShell 5.1.
        $null = & cmd.exe /d /c "schtasks.exe /Change /TN `"$full`" /Disable >nul 2>&1"
        if ($LASTEXITCODE -ne 0) {
            # Tasks that belong to SYSTEM, such as the Update Orchestrator tasks UsoSvc registers again, need SYSTEM.
            [void](Invoke-AsTI -PsCommand "Disable-ScheduledTask -TaskPath $(ConvertTo-PsLiteral $Task.TaskPath) -TaskName $(ConvertTo-PsLiteral $Task.TaskName) | Out-Null")
        }
    }
    $now = Get-ScheduledTask -TaskPath $Task.TaskPath -TaskName $Task.TaskName -ErrorAction SilentlyContinue
    if ($now -and $now.State -ne 'Disabled') {
        Write-Log "Could not disable task $full, not even as TrustedInstaller." 'WARN'
        Add-JournalEvents @(New-ChangeResult -Change $change -Result 'MISMATCH' -Now ([string]$now.State))
    }
    else { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'OK' -Now 'Disabled') }
}

function Disable-TelemetryTasks {
    foreach ($t in $TelemetryTasks) {
        $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($task) { Disable-TaskRecorded -Task $task }
    }
}

function Remove-AllScheduledTasks {
    # Upstream behaviour: unregister every task except three. Each task is exported first so -Revert can restore it.
    # The built-in keep list survives on top: deleting those gains no speed but stops time sync, TPM upkeep,
    # BitLocker and SSD retrim.
    $dir = Join-Path $StateDir 'tasks'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $tasks = @(Get-ScheduledTask | Where-Object {
            $_.TaskName -notin @('SvcRestartTask', 'MsCtfMonitor') -and "$($_.TaskPath)$($_.TaskName)" -ne '\Microsoft\Windows\Shell\CreateObjectTask'
        })
    $deleted = 0; $failed = 0; $seen = 0
    foreach ($t in $tasks) {
        $full = "$($t.TaskPath)$($t.TaskName)"
        if (Test-NameMatch $full $TaskKeepBuiltIn) { continue }
        if (Test-NameMatch $full $TaskKeep) { continue }
        # -Reapply deletes only tasks the earlier run deleted and Windows registered again, never ones added since.
        if ($Ctx.Reapply -and -not (Get-TaskRecord -Path $t.TaskPath -Name $t.TaskName)) { continue }
        if ($Ctx.Reapply -and (Test-NameMatch $full $WindowsManagedTasks)) { continue }
        if (Test-DryRun "delete task $full (exported first)") { continue }
        # Each task takes about a second (export, then delete), so say that the step is still working.
        $seen++
        if ($seen % 40 -eq 0) { Write-Log "Scheduled tasks: $seen of $($tasks.Count) processed, still working." }
        $file = Join-Path $dir (($full -replace '[\\/:*?"<>| ]', '_') + '.xml')
        $outcome = $null
        $change = $null
        try {
            # The first export is the original. A later run may meet a copy that Windows registered again (UsoSvc
            # after the cache cleanup) and the script then disabled; exporting that would overwrite the original.
            $prior = Get-TaskRecord -Path $t.TaskPath -Name $t.TaskName
            $haveOriginal = $prior -and $prior.Action -eq 'Deleted' -and $prior.XmlFile -and (Test-Path -LiteralPath $prior.XmlFile)
            if (-not $haveOriginal) {
                Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Set-Content -LiteralPath $file -Encoding Unicode
                $outcome = Save-TaskState -Task $t -Action 'Deleted' -XmlFile $file
            }
            else { $file = [string]$prior.XmlFile }
            $change = New-TaskChange -Task $t -Action 'Deleted' -XmlFile $file
            Add-JournalEvents @($change)
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Add-JournalEvents @(New-ChangeResult -Change $change -Result 'OK' -Now 'Deleted')
            $deleted++
        }
        catch {
            $failed++
            if ($outcome) { Undo-TaskRecord -Task $t -Outcome $outcome }
            if ($change) { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'FAILED' -Now $_.Exception.Message) }
            Write-Log "Task $full not deleted: $($_.Exception.Message)"
        }
    }
    if (-not $Ctx.DryRun) {
        $level = 'OK'; if ($failed -gt 0) { $level = 'WARN' }
        Write-Log "Scheduled tasks deleted: $deleted (backups in $dir). $failed could not be removed (protected by the system, listed above)." $level
    }
}

function Invoke-TaskMode {
    switch ($TaskMode) {
        'Delete' { Remove-AllScheduledTasks }
        'Disable' { Disable-TelemetryTasks }
        'None' { Write-Log 'Scheduled tasks left untouched (-TaskMode None).' }
    }
}

function Set-TaskEnabledState {
    # Brings a task back to enabled or disabled as it was before the run.
    param([string]$Path, [string]$Name, [bool]$Enabled)
    $now = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop
    if ($Enabled -and $now.State -eq 'Disabled') { Enable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null }
    elseif (-not $Enabled -and $now.State -ne 'Disabled') { Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null }
}

function Restore-Tasks {
    param([object[]]$Tasks = @($script:State.Tasks))
    $denied = [System.Collections.Generic.List[object]]::new()
    $problems = 0
    foreach ($t in $Tasks) {
        try {
            if ($t.Action -eq 'Deleted') {
                if (-not $t.XmlFile -or -not (Test-Path -LiteralPath $t.XmlFile)) {
                    Write-Log "Could not restore task $($t.Path)$($t.Name): its backup file is missing ($($t.XmlFile))." 'WARN'
                    $problems++
                    continue
                }
                Register-ScheduledTask -Xml (Get-Content -LiteralPath $t.XmlFile -Raw) -TaskName $t.Name -TaskPath $t.Path -Force -ErrorAction Stop | Out-Null
            }
            # The export may hold a disabled copy (a task disabled by one run, deleted by a later one).
            Set-TaskEnabledState -Path $t.Path -Name $t.Name -Enabled ([bool]$t.WasEnabled)
        }
        catch {
            # Tasks whose principal is SYSTEM or a service (BitLocker, DeviceDirectoryClient, the Update Orchestrator
            # and more) can be deleted or disabled by an administrator but only registered or enabled again by
            # SYSTEM. Retry those as TrustedInstaller.
            if (Test-AccessDenied $_) { $denied.Add($t) }
            else { Write-Log "Could not restore task $($t.Path)$($t.Name). $($_.Exception.Message)" 'WARN'; $problems++ }
        }
    }
    if ($denied.Count -gt 0) { $problems += Restore-ProtectedTasks -Tasks $denied }
    if ($problems -eq 0) { Write-Log "Scheduled tasks restored: $(@($Tasks).Count)." 'OK' }
    else { Write-Log "Scheduled tasks restored with $problems problem(s), listed above." 'WARN' }
}

function Restore-SelectedTasks {
    # -RestoreTask: bring back only the deleted or disabled tasks whose full path matches, leaving the rest of the run
    # in place. Entries stay in the state file, so a later full -Revert still covers them (registering again is harmless).
    $picked = @($script:State.Tasks | Where-Object { Test-NameMatch "$($_.Path)$($_.Name)" $RestoreTask })
    if ($picked.Count -eq 0) { Write-Log "No recorded task matches $($RestoreTask -join ', '). The task backups are in $(Join-Path $StateDir 'tasks')." 'WARN'; return }
    foreach ($t in $picked) { Write-Log "Restoring task $($t.Path)$($t.Name) ($($t.Action.ToLowerInvariant()) by the run)." }
    Restore-Tasks -Tasks $picked
}

function Restore-ProtectedTasks {
    param([object[]]$Tasks)
    # One TrustedInstaller call for all of them (each call stops and restarts the service). The commands go into a
    # file in the state folder, because the service command line goes through cmd.exe and its 8191 character limit.
    # Each line registers the task again (Deleted) and sets it enabled or disabled as it was; the result is checked
    # below, so a failure inside the batch still shows up as a warning.
    $calls = foreach ($t in $Tasks) {
        $register = ''
        if ($t.Action -eq 'Deleted') {
            $register = 'Register-ScheduledTask -Xml (Get-Content -LiteralPath {0} -Raw) -TaskName {1} -TaskPath {2} -Force -ErrorAction Stop | Out-Null; ' -f
                (ConvertTo-PsLiteral $t.XmlFile), (ConvertTo-PsLiteral $t.Name), (ConvertTo-PsLiteral $t.Path)
        }
        $state = 'Disable-ScheduledTask'; if ($t.WasEnabled) { $state = 'Enable-ScheduledTask' }
        'try {{ {0}{1} -TaskPath {2} -TaskName {3} -ErrorAction Stop | Out-Null }} catch {{ }}' -f $register, $state, (ConvertTo-PsLiteral $t.Path), (ConvertTo-PsLiteral $t.Name)
    }
    $file = Join-Path $StateDir 'restore-protected-tasks.ps1'
    Set-Content -LiteralPath $file -Value $calls -Encoding UTF8
    # Read and run as a script block, not as a .ps1 file, so the execution policy does not block it.
    try { [void](Invoke-AsTI -PsCommand ". ([scriptblock]::Create((Get-Content -LiteralPath $(ConvertTo-PsLiteral $file) -Raw)))") }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    $restored = 0
    foreach ($t in $Tasks) {
        $now = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($now -and (($now.State -ne 'Disabled') -eq [bool]$t.WasEnabled)) { $restored++ }
        elseif ($now) { Write-Log "Task $($t.Path)$($t.Name) is back but still $($now.State), not even TrustedInstaller could change it." 'WARN' }
        else { Write-Log "Could not restore task $($t.Path)$($t.Name), not even as TrustedInstaller." 'WARN' }
    }
    $level = 'OK'; if ($restored -lt @($Tasks).Count) { $level = 'WARN' }
    Write-Log "Protected tasks restored as TrustedInstaller: $restored of $(@($Tasks).Count)." $level
    return @($Tasks).Count - $restored
}
#endregion

