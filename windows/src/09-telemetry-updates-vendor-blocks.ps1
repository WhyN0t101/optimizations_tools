#region Telemetry, updates, vendor blocks -------------------------------------------------
function Invoke-TelemetryTweaks {
    if ($Opt['TelemetryPolicy']) {
        $Ctx.JournalOption = 'TelemetryPolicy'
        Set-TweakList $TelemetryRegs
        foreach ($s in $TelemetryServices) { Set-ServiceStart -Name $s -Mode Disabled }
        # Stop every logger under the DiagTrack autologger.
        $logger = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener'
        $k = Open-RegKey -Full $logger
        if ($k) {
            try { foreach ($sub in $k.GetSubKeyNames()) { Set-RegValue -Path "$logger\$sub" -Name 'Enabled' -Value 0 } }
            finally { $k.Close() }
        }
    }
    if ($Opt['BiometricsPolicy']) { $Ctx.JournalOption = 'BiometricsPolicy'; Set-TweakList $BiometricsRegs }
    if ($Opt['Cdp']) {
        $Ctx.JournalOption = 'Cdp'
        foreach ($s in $CdpServices) { Set-ServiceStart -Name $s -Mode Disabled }
        $cdpCache = Join-Path $env:LOCALAPPDATA 'ConnectedDevicesPlatform'
        if (-not $Ctx.Reapply -and (Test-Path -LiteralPath $cdpCache) -and -not (Test-DryRun "delete the Connected Devices Platform cache $cdpCache (not reversible, Windows rebuilds it)")) {
            Remove-Item -LiteralPath $cdpCache -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($Opt['TelemetryHosts']) { $Ctx.JournalOption = 'TelemetryHosts'; Set-HostsBlock -Name 'telemetry' -Domains $TelemetryDomains }
}

function Set-UpdatePolicies {
    $classifications = @($UpdateClassifications)
    if ($Opt['KeepDefinitionUpdates']) { $classifications = @($classifications | Where-Object { $_ -notlike '*e0789628-ce08-4437-be74-2495b842f43b*' }) }
    $classString = $classifications -join ';'
    $wu = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $ux = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

    if ($Opt['DriverExclusion']) { $Ctx.JournalOption = 'DriverExclusion'; Set-TweakList $DriverExclusionRegs }
    if ($Opt['SecurityUpdatesOnly']) {
        $Ctx.JournalOption = 'SecurityUpdatesOnly'
        Set-TweakList $SecurityUpdatesRegs
        Set-RegValue -Path $wu -Name 'ExcludeUpdateClassifications' -Value $classString -Type String
        Write-Log 'Update policy: long deferrals set and update classifications excluded (upstream behaviour).' 'WARN'
    }
    if ($Opt['PauseUpdates']) {
        $Ctx.JournalOption = 'PauseUpdates'
        $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $now = [DateTime]::UtcNow
        $start = $now.ToString($fmt, $inv)
        $end = $now.AddDays($PauseDays).ToString($fmt, $inv)
        # -Reapply keeps the pause dates of the run: writing them again would extend the pause every time.
        if (-not $Ctx.Reapply) {
            foreach ($n in 'PauseUpdatesStartTime', 'PauseFeatureUpdatesStartTime', 'PauseQualityUpdatesStartTime') { Set-RegValue -Path $ux -Name $n -Value $start -Type String }
            foreach ($n in 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesEndTime') { Set-RegValue -Path $ux -Name $n -Value $end -Type String }
        }
        foreach ($s in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc') { Set-ServiceStart -Name $s -Mode Manual }
        $deferDays = [Math]::Min($PauseDays, 365)
        foreach ($t in $PauseRegs) {
            $v = $t.Value
            if ($t.Name -in 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdatesPeriodInDays') { $v = $deferDays }
            Set-RegValue -Path $t.Path -Name $t.Name -Value $v -Type $t.Type
        }
        if ($Ctx.Reapply) {
            # -Reapply keeps the pause of the run: after it ended, updates stay on; before, the policy and its end come back.
            $expiry = Get-PauseExpiry
            if ($expiry -and $expiry -gt [DateTime]::UtcNow) {
                Set-TweakList $NoAutoUpdateRegs
                if (-not (Get-ScheduledTask -TaskPath $PauseEndTaskPath -TaskName $PauseEndTaskName -ErrorAction SilentlyContinue)) { Register-PauseEndTask -EndUtc $expiry }
            }
        }
        else {
            Set-TweakList $NoAutoUpdateRegs
            Register-PauseEndTask -EndUtc $now.AddDays($PauseDays)
        }
        # ExcludeUpdateClassifications belongs to SecurityUpdatesOnly only: it never expires, unlike the pause.
        if ($Opt['PauseStopsUpdateTasks']) { $Ctx.JournalOption = 'PauseStopsUpdateTasks'; Disable-UpdateTasks }
        if (-not $Ctx.DryRun -and -not $Ctx.Reapply) { Write-Log "Updates paused until $end (-PauseDays $PauseDays), with automatic update checks off for the same time (NoAutoUpdate). Security patches are delayed; Settings, Check for updates still works." 'WARN' }
    }
}

function Get-PauseExpiry {
    # The end of the update pause the run wrote, in UTC, or $null.
    param([string]$Text = [string](Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesExpiryTime').Value)
    if (-not $Text) { return $null }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $when = [DateTime]::MinValue
    if ([DateTime]::TryParse($Text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$when)) { return $when }
    return $null
}

function Register-PauseEndTask {
    # NoAutoUpdate has no end date of its own. This one-off task removes it as SYSTEM when the pause ends, also when the
    # PC was off at that moment. Its only action is reg.exe deleting that one value: no script or user file runs.
    param([Parameter(Mandatory)][DateTime]$EndUtc)
    if (Test-DryRun "schedule $PauseEndTaskPath$PauseEndTaskName for $($EndUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm')) to turn automatic update checks back on") { return }
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\reg.exe') -Argument 'delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f'
    $trigger = New-ScheduledTaskTrigger -Once -At $EndUtc.ToLocalTime()
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Set-StateValue -Name 'PauseEndTask' -Value $true   # recorded first, so -Revert removes the task even after a crash here
    Register-ScheduledTask -TaskPath $PauseEndTaskPath -TaskName $PauseEndTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Log "Automatic update checks come back on $($EndUtc.ToLocalTime().ToString('yyyy-MM-dd')), when the pause ends." 'OK'
}

function Remove-PauseEndTask {
    if (Get-ScheduledTask -TaskPath $PauseEndTaskPath -TaskName $PauseEndTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskPath $PauseEndTaskPath -TaskName $PauseEndTaskName -Confirm:$false
        Write-Log 'The task that ends the update pause is removed.' 'OK'
    }
}

function Disable-UpdateTasks {
    foreach ($pattern in $UpdateTaskPaths) {
        foreach ($task in @(Get-ScheduledTask -TaskPath $pattern -ErrorAction SilentlyContinue)) {
            if ($task.State -ne 'Disabled') { Disable-TaskRecorded -Task $task }
        }
    }
}

function Set-RazerAsusBlock {
    Set-HostsBlock -Name 'razer-asus' -Domains ($RazerDomains + $AsusDomains)
}
#endregion

