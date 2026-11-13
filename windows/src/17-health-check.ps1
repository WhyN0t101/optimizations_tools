#region Health check ---------------------------------------------------------------------
$script:Health = @{ PASS = 0; WARN = 0; FAIL = 0; INFO = 0 }
$script:HealthItems = [System.Collections.Generic.List[object]]::new()

function Write-Health {
    param([ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Area, [string]$Message)
    $script:Health[$Status]++
    $script:HealthItems.Add([pscustomobject]@{ Status = $Status; Area = $Area; Message = $Message })
    $colour = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    $line = '{0:HH:mm:ss} [{1}] {2,-9} {3}' -f (Get-Date), $Status, $Area, $Message
    if (-not $Json) { Write-Host $line -ForegroundColor $colour }
    Add-Content -Path $LogFile -Value $line
}

# Runtime state (running services, memory compression) lags behind the registry until a restart.
function Get-RuntimeStatus { if ($Ctx.SoftRuntime) { return 'INFO' } return 'FAIL' }

function Invoke-HealthArea {
    param([string]$Name, [scriptblock]$Check)
    try { & $Check }
    catch { Write-Health 'WARN' $Name "This check could not run: $($_.Exception.Message)" }
}

function Get-ServiceStartNow {
    param([string]$Name)
    $s = Get-RegSnapshot -Full "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$Name" -Name 'Start'
    if ($s.Existed) { return [int]$s.Value }
    return $null
}

function Test-RegMatchesOp {
    param($Snap, $Op)
    if (-not $Snap.Existed) { return $false }
    if ($Op.Type -eq 'None') { return $Snap.Kind -eq 'None' }
    if ($Snap.Kind -ne $Op.Type) { return $false }
    $expected = ConvertTo-StoredValue -Value $Op.Value -Kind $Op.Type
    return ((@($Snap.Value) -join ',') -ieq (@($expected) -join ','))
}

function Format-RegValueShort {
    param($Snap)
    if (-not $Snap.Existed) { return '<missing>' }
    if ($Snap.Kind -eq 'Binary') { return '<binary>' }
    return [string]$Snap.Value
}

function Test-ServiceStartChanged {
    # True when this script recorded a different original Start value, so it was the one that disabled the service.
    param([string]$Name)
    $path = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$Name"
    return Test-RecordedFirst $script:State.Registry { param($e) $e.Path -ieq $path -and $e.Name -eq 'Start' -and $e.Existed -and [int]$e.Value -ne 4 }
}

function Test-HealthServices {
    foreach ($g in $ServiceGroups.Keys) {
        $present = 0; $wrong = @(); $native = @(); $deleted = 0
        foreach ($name in $ServiceGroups[$g]) {
            $start = Get-ServiceStartNow $name
            if ($null -eq $start) {
                if ($Opt[$g] -and (Test-ServiceKeyDeletedByRun $name)) { $deleted++ }
                continue
            }
            $present++
            if ($Opt[$g] -eq ($start -eq 4)) { continue }
            # A service that is disabled although the option is off only counts when this script disabled it.
            # Some (RemoteRegistry, shpamsvc) are disabled by Windows itself.
            if ($Opt[$g] -or (Test-ServiceStartChanged $name)) { $wrong += $name } else { $native += $name }
        }
        if ($present -eq 0 -and $deleted -eq 0) { continue }
        if ($Opt[$g]) {
            $how = "all $present service(s) are disabled."
            if ($deleted -gt 0) { $how = "$deleted service(s) deleted, $present disabled." }
            if ($wrong.Count -eq 0) { Write-Health 'PASS' 'Services' "$g`: $how" }
            else { Write-Health 'WARN' 'Services' "$g`: still enabled: $($wrong -join ', '). Protected services may need a restart." }
        }
        elseif ($wrong.Count -eq 0) {
            if ($present -gt $native.Count) { Write-Health 'PASS' 'Services' "$g`: $($present - $native.Count) service(s) kept, as you asked." }
            if ($native.Count -gt 0) { Write-Health 'INFO' 'Services' "$g`: $($native -join ', ') disabled by Windows itself or an earlier tool, not by this script, so they are left alone." }
        }
        else { Write-Health 'FAIL' 'Services' "$g`: disabled although you asked to keep them: $($wrong -join ', ')." }
    }
    if ($Opt['VendorServices']) {
        $wrongVendor = @()
        $seenVendor = 0
        foreach ($pair in @(@($VendorServicesDisable, 4), @($VendorServicesManual, 3))) {
            foreach ($name in $pair[0]) {
                $start = Get-ServiceStartNow $name
                if ($null -eq $start) { continue }
                $seenVendor++
                if ($start -ne $pair[1]) { $wrongVendor += $name }
            }
        }
        if ($seenVendor -eq 0) { Write-Health 'INFO' 'Services' 'VendorServices: none of its Lenovo and Intel services is installed.' }
        elseif ($wrongVendor.Count -eq 0) { Write-Health 'PASS' 'Services' "VendorServices: all $seenVendor installed vendor service(s) are set as intended." }
        else { Write-Health 'WARN' 'Services' "VendorServices: not as intended: $($wrongVendor -join ', '). A vendor update may have reset them; -Reapply sets them again." }
    }
    $core = @('BITS', 'CryptSvc', 'Winmgmt', 'StorSvc', 'AppXSvc', 'ClipSVC', 'InstallService', 'LicenseManager', 'BFE', 'mpssvc', 'Dnscache', 'NlaSvc', 'wuauserv', 'UsoSvc', 'WaaSMedicSvc')
    if ($Defender -ne 'Disable') { $core += 'WinDefend' }
    $disabledCore = @($core | Where-Object { (Get-ServiceStartNow $_) -eq 4 })
    # Only a service this script disabled is a failure of the run. One that was disabled before it (the Windows 11 ARM
    # runner image ships StorSvc disabled, 13 Nov 2026) is reported, but the run did not cause it.
    $byRun = @($disabledCore | Where-Object { $n = $_; @($script:State.Registry | Where-Object { $_.Path -like "*\Services\$n" -and $_.Name -eq 'Start' }).Count -gt 0 })
    $before = @($disabledCore | Where-Object { $byRun -notcontains $_ })
    if ($disabledCore.Count -eq 0) { Write-Health 'PASS' 'Services' 'Store, Windows Update, BITS, Delivery Optimization path and firewall services are not disabled.' }
    if ($byRun.Count -gt 0) { Write-Health 'FAIL' 'Services' "Core services are disabled: $($byRun -join ', '). Store installs or updates may fail." }
    if ($before.Count -gt 0) { Write-Health 'WARN' 'Services' "Core services were already disabled before FocusedTweaks ran (it did not change them): $($before -join ', '). Store installs or updates may fail; set them back to Manual if that matters." }
}

function Test-HealthApps {
    $installed = @(Get-AppxPackage -AllUsers | ForEach-Object { $_.Name })
    $expect = [ordered]@{
        'Microsoft Store'      = 'Microsoft.WindowsStore'
        'Xbox app'             = 'Microsoft.GamingApp'
        'Xbox identity'        = 'Microsoft.XboxIdentityProvider'
        'Gaming services'      = 'Microsoft.GamingServices'
        'Photos'               = 'Microsoft.Windows.Photos'
        'Paint'                = 'Microsoft.Paint'
        'App Installer/winget' = 'Microsoft.DesktopAppInstaller'
    }
    foreach ($k in $expect.Keys) {
        if ($installed -contains $expect[$k]) { Write-Health 'PASS' 'Apps' "$k is installed." }
        else { Write-Health 'WARN' 'Apps' "$k not found. Ignore this if it was never on the image, otherwise reinstall it from the Store." }
    }
    $edge = Get-EdgeState
    $removedByRun = @($script:State.Removed) -contains 'Microsoft.Edge'
    if ($Opt['RemoveEdge']) {
        if (-not $edge.Installed) { Write-Health 'PASS' 'Apps' 'Microsoft Edge is removed.' }
        elseif ($removedByRun) { Write-Health 'WARN' 'Apps' 'Microsoft Edge is installed again (a Windows update brings it back). -Reapply removes it again.' }
        else { Write-Health 'INFO' 'Apps' 'Microsoft Edge was kept; the run log says why (region outside the EEA, or it is the default browser).' }
    }
    elseif ($edge.Installed) { Write-Health 'PASS' 'Apps' 'Microsoft Edge is installed.' }
    else { Write-Health 'WARN' 'Apps' 'Microsoft Edge was not found.' }
    if ($edge.WebView2) { Write-Health 'PASS' 'Apps' 'The WebView2 runtime is installed (apps that show web content need it).' }
    else { Write-Health 'WARN' 'Apps' 'The WebView2 runtime was not found. Apps such as Teams, widgets and many installers need it: winget install Microsoft.EdgeWebView2Runtime.' }
    if ($Opt['Debloat'] -and $script:State.Removed.Count -gt 0) {
        $back = @($script:State.Removed | Sort-Object -Unique | Where-Object { $installed -contains $_ })
        if ($back.Count -eq 0) { Write-Health 'PASS' 'Apps' "Debloat holds: $(@($script:State.Removed | Sort-Object -Unique).Count) removed app(s) are gone." }
        else { Write-Health 'WARN' 'Apps' "Removed apps came back: $($back -join ', '). A feature update can reinstall them." }
    }
}

function Test-HealthTweakTable {
    param([string]$Label, [object[]]$Tweaks)
    $bad = @(); $stuck = @()
    foreach ($t in $Tweaks) {
        $full = ConvertTo-FullRegPath $t.Path
        $snap = Get-RegSnapshot -Full $full -Name $t.Name
        if (-not (Test-RegMatchesOp -Snap $snap -Op ([pscustomobject]@{ Type = $t.Type; Value = $t.Value }))) {
            $text = '{0}\{1} is {2}, expected {3}' -f $full, $t.Name, (Format-RegValueShort $snap), $t.Value
            if ($KnownStuckValues -contains "$full|$($t.Name)") { $stuck += $text } else { $bad += $text }
        }
    }
    foreach ($s in $stuck) { Write-Health 'INFO' 'Registry' "$Label`: $s. Windows protects this value, even from TrustedInstaller." }
    if ($bad.Count -eq 0) { Write-Health 'PASS' 'Registry' "$Label`: $($Tweaks.Count - $stuck.Count) of $($Tweaks.Count) value(s) match, none unexpected." }
    else {
        Write-Health 'WARN' 'Registry' "$Label`: $($bad.Count) of $($Tweaks.Count) differ. First: $($bad[0])"
        foreach ($b in $bad) { Add-Content -Path $LogFile -Value "          differs: $b" }
    }
}

function Get-LaterOverrideKeys {
    # Upstream sets some values twice (for example telemetry level 1 in RegTweaks, then 0 in its telemetry block).
    # The later step wins, so the earlier one is not judged against its own value.
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $tables = @()
    if ($Opt['TelemetryPolicy']) { $tables += $TelemetryRegs }
    if ($Opt['Registry']) { $tables += $LastAccessRegs }
    if ($Opt['BiometricsPolicy']) { $tables += $BiometricsRegs }
    if ($Opt['DriverExclusion']) { $tables += $DriverExclusionRegs }
    if ($Opt['SecurityUpdatesOnly']) { $tables += $SecurityUpdatesRegs }
    if ($Opt['PauseUpdates']) { $tables += $PauseRegs; $tables += $NoAutoUpdateRegs }
    foreach ($t in $tables) { [void]$set.Add((ConvertTo-FullRegPath $t.Path) + '|' + $t.Name) }
    if ($Opt['MouseAccel']) {
        foreach ($p in 'HKEY_CURRENT_USER\Control Panel\Mouse', 'HKEY_USERS\.DEFAULT\Control Panel\Mouse') {
            foreach ($n in 'MouseSensitivity', 'MouseSpeed', 'MouseThreshold1', 'MouseThreshold2', 'SmoothMouseXCurve', 'SmoothMouseYCurve') { [void]$set.Add("$p|$n") }
        }
        foreach ($n in 'Win8DpiScaling', 'LogPixels', 'EnablePerProcessSystemDPI') { [void]$set.Add("HKEY_CURRENT_USER\Control Panel\Desktop|$n") }
    }
    return , $set
}

function Test-HealthRegistry {
    $ops = ConvertFrom-RegText -Text $UpstreamRegText
    $later = Get-LaterOverrideKeys
    $checked = 0; $overridden = 0; $bad = [System.Collections.Generic.List[string]]::new(); $runEntries = 0
    $gated = Get-GatedRegOptions
    foreach ($g in $gated.Keys) { Write-Health 'INFO' 'Registry' "$g is not applied on this PC: $($gated[$g])." }
    foreach ($op in $ops) {
        $optName = Get-RegOpOption $op
        if (-not $Opt[$optName]) { continue }
        if ($gated.ContainsKey($optName)) { continue }
        if (Test-NameMatch $op.Group $SkipRegGroup) { continue }
        $full = ConvertTo-FullRegPath $op.Path
        if ($op.Action -ne 'DeleteKey' -and $later.Contains("$full|$($op.Name)")) { $overridden++; continue }
        $checked++
        switch ($op.Action) {
            'Set' {
                $snap = Get-RegSnapshot -Full $full -Name $op.Name
                if (-not (Test-RegMatchesOp -Snap $snap -Op $op)) {
                    if (Test-WindowsRewritten -Path $full -Name $op.Name) {
                        Write-Health 'INFO' 'Registry' "$full\$(Show-RegName $op.Name) is $(Format-RegValueShort $snap): Windows resets this value itself."
                    }
                    else { $bad.Add(('[{0}] {1}\{2} is {3}' -f $op.Group, $full, (Show-RegName $op.Name), (Format-RegValueShort $snap))) }
                }
            }
            'DeleteValue' {
                if ((Get-RegSnapshot -Full $full -Name $op.Name).Existed) { $bad.Add("[$($op.Group)] $full\$($op.Name) is still present") }
            }
            'DeleteKey' {
                $k = Open-RegKey -Full $full
                if ($k) {
                    # For the Run keys only the entries RunKeys would remove count; kept ones are meant to be there.
                    $n = @($k.GetValueNames() | Where-Object { $_ -and -not (Test-StartupKept $_) }).Count
                    $k.Close()
                    if ($optName -eq 'RunKeys') { $runEntries += $n } else { $bad.Add("[$($op.Group)] $full still exists") }
                }
            }
        }
    }
    if ($bad.Count -eq 0) { Write-Health 'PASS' 'Registry' "Upstream registry import: all $checked item(s) match." }
    else {
        Write-Health 'WARN' 'Registry' "Upstream registry import: $($checked - $bad.Count) of $checked match, $($bad.Count) differ (protected keys, other user profiles, or Windows rewrote them). First: $($bad[0])"
        foreach ($b in $bad) { Add-Content -Path $LogFile -Value "          differs: $b" }
    }
    if ($overridden -gt 0) { Write-Health 'INFO' 'Registry' "$overridden upstream registry item(s) are set again by a later step (telemetry, update or mouse options) and are verified there." }
    if ($Opt['RunKeys']) {
        if ($runEntries -eq 0) { Write-Health 'PASS' 'Registry' 'Startup Run keys hold only the entries you keep.' }
        else { Write-Health 'INFO' 'Registry' "$runEntries startup entr(ies) were added to the Run keys since the cleanup. This is expected after installing software." }
    }
    if ($Opt['TelemetryPolicy']) { Test-HealthTweakTable -Label 'Telemetry policy' -Tweaks $TelemetryRegs }
    if ($Opt['Registry']) { Test-HealthTweakTable -Label 'Last access time off' -Tweaks $LastAccessRegs }
    if ($Opt['BiometricsPolicy']) { Test-HealthTweakTable -Label 'Biometrics policy' -Tweaks $BiometricsRegs }
    if ($Opt['DriverExclusion']) { Test-HealthTweakTable -Label 'Driver exclusion' -Tweaks $DriverExclusionRegs }
    if ($Opt['SecurityUpdatesOnly'] -and -not $Opt['PauseUpdates']) { Test-HealthTweakTable -Label 'Update deferral' -Tweaks $SecurityUpdatesRegs }
    if ($Opt['PauseUpdates']) {
        $deferDays = [Math]::Min($PauseDays, 365)
        $effective = foreach ($t in $PauseRegs) {
            $v = $t.Value
            if ($t.Name -in 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdatesPeriodInDays') { $v = $deferDays }
            New-Tweak $t.Path $t.Name $v $t.Type
        }
        Test-HealthTweakTable -Label 'Update pause policy' -Tweaks @($effective)
        $expiry = Get-PauseExpiry
        if ($expiry -and $expiry -le [DateTime]::UtcNow) {
            $na = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate'
            if ($na.Existed -and [int]$na.Value -eq 1) { Write-Health 'WARN' 'Updates' "The update pause ended on $($expiry.ToLocalTime().ToString('yyyy-MM-dd')), but automatic update checks are still off (NoAutoUpdate). -Revert -Only PauseUpdates turns them back on." }
            else { Write-Health 'INFO' 'Updates' "The update pause ended on $($expiry.ToLocalTime().ToString('yyyy-MM-dd')); automatic updates are back on." }
        }
        else {
            Test-HealthTweakTable -Label 'Automatic update checks off' -Tweaks $NoAutoUpdateRegs
            if ($script:State.PauseEndTask -and -not (Get-ScheduledTask -TaskPath $PauseEndTaskPath -TaskName $PauseEndTaskName -ErrorAction SilentlyContinue)) {
                Write-Health 'WARN' 'Updates' 'The task that turns automatic update checks back on when the pause ends is missing, so they would stay off. -Reapply schedules it again.'
            }
        }
    }
    if ($Opt['DefenderQuiet']) { Test-HealthTweakTable -Label 'Quiet Defender policy' -Tweaks $DefenderQuietRegs }
    if ($Opt['SpectreMeltdownOff']) { Test-HealthTweakTable -Label 'Spectre and Meltdown mitigations off' -Tweaks $MitigationRegs }
    if ($Opt['TimerResolution'] -and -not (Get-TimerSkipReasonHere)) { Test-HealthTweakTable -Label 'Global timer resolution requests' -Tweaks $TimerGlobalRegs }
    if ($Opt['NetAdapterPower'] -or $Opt['NetAdapterEee']) {
        $keywords = @(); if ($Opt['NetAdapterPower']) { $keywords += $NetPowerKeywords }; if ($Opt['NetAdapterEee']) { $keywords += $NetEeeKeywords }
        $net = @(Get-NetAdapterTweaks -Keywords $keywords -AllowOff:([bool]$Opt['NetAdapterPower']))
        if ($net.Count -gt 0) { Test-HealthTweakTable -Label 'Network adapter power settings' -Tweaks $net }
        else { Write-Health 'INFO' 'Registry' 'No physical network adapter keys were found, so the adapter power settings could not be checked.' }
    }
    # Device lists change when hardware is added, so only the values the run itself recorded are checked.
    $recorded = { param($list) @($list | Where-Object { $script:RecordedReg.Contains("$(ConvertTo-FullRegPath $_.Path)|$($_.Name)") }) }
    if ($Opt['DevicePowerSaving']) {
        $dev = @(& $recorded @(Get-DeviceTweaks -Power))
        if ($dev.Count -gt 0) { Test-HealthTweakTable -Label 'Device power saving' -Tweaks $dev }
        else { Write-Health 'INFO' 'Registry' 'Device power saving: no recorded values (skipped on battery, or not run yet).' }
    }
    if ($Opt['DeviceWakeOff']) {
        $wake = @(& $recorded @(Get-DeviceTweaks -Wake))
        if ($wake.Count -gt 0) { Test-HealthTweakTable -Label 'Device wake' -Tweaks $wake }
    }
    if ($Opt['WriteCacheFlushOff']) {
        $cache = @(& $recorded @(Get-WriteCacheTweaks))
        if ($cache.Count -gt 0) { Test-HealthTweakTable -Label 'Write cache buffer flushing off' -Tweaks $cache }
    }
    if ($Opt['MpoOff']) { Test-HealthTweakTable -Label 'Multiplane overlay off' -Tweaks $MpoRegs }
    if ($Opt['FastShutdown']) { Test-HealthTweakTable -Label 'Faster shutdown' -Tweaks $FastShutdownRegs }
    if ($Opt['BlockFeatureUpgrades']) { Test-HealthTweakTable -Label 'Feature upgrade block' -Tweaks @(Get-FeatureUpgradeTweaks) }
    if ($Opt['TimeServerPool']) {
        Test-HealthTweakTable -Label 'Time server' -Tweaks $TimeServerRegs
        # Without this task the time service is never started on a PC outside a domain, so the server setting is moot.
        if (Get-ScheduledTask -TaskPath $TimeSyncTask.Path -TaskName $TimeSyncTask.Name -ErrorAction SilentlyContinue) {
            Write-Health 'PASS' 'System' 'Time sync task is present, so the clock is kept in sync.'
        }
        else { Write-Health 'WARN' 'System' "Time sync task $($TimeSyncTask.Path)$($TimeSyncTask.Name) is missing, so the clock is not synced. Restore it from the task backups or with -Revert." }
    }
    if ($Opt['MenuKillNotResponding']) { Test-HealthTweakTable -Label 'Kill not responding menu' -Tweaks $MenuKillRegs }
    if ($Opt['MenuRestartExplorer']) { Test-HealthTweakTable -Label 'Restart Explorer menu' -Tweaks $MenuRestartExplorerRegs }
    if ($Opt['MenuTakeOwnership']) { Test-HealthTweakTable -Label 'Take ownership menu' -Tweaks $MenuTakeOwnershipRegs }
    if ($Opt['MenuRunAsAdmin']) { Test-HealthTweakTable -Label 'Run as administrator menu' -Tweaks $MenuRunAsAdminRegs }
    foreach ($m in $MenuBlocks.Keys) { if ($Opt[$m]) { Test-HealthTweakTable -Label "Right click menu ($m)" -Tweaks $MenuBlocks[$m] } }
    if ($Opt['LockScreenOff']) { Test-HealthTweakTable -Label 'Lock screen off' -Tweaks $LockScreenRegs }
    if ($Opt['EdgeBackground']) { Test-HealthTweakTable -Label 'Edge in the background off' -Tweaks $EdgeBackgroundRegs }
    if ($Opt['WindowsAIOff']) { Test-HealthTweakTable -Label 'Copilot and Windows AI off' -Tweaks $WindowsAIRegs }
    if ($Opt['TelemetryExtra']) { Test-HealthTweakTable -Label 'More telemetry off' -Tweaks $TelemetryExtraRegs }
    if ($Opt['BrowserPolicies']) { Test-HealthTweakTable -Label 'Browser ads, telemetry and AI off' -Tweaks $BrowserPolicyRegs }
    if ($Opt['StartupDelayOff']) { Test-HealthTweakTable -Label 'Startup delay off' -Tweaks $StartupDelayRegs }
    if ($Opt['MouseFullRateBackground']) { Test-HealthTweakTable -Label 'Mouse full rate in the background' -Tweaks $MouseFullRateRegs }
    if ($Opt['NoDeviceEncryption']) { Test-HealthTweakTable -Label 'Automatic device encryption off' -Tweaks $NoDeviceEncryptionRegs }
    if ($Opt['UpdateNoReboot']) { Test-HealthTweakTable -Label 'No update restarts or early features' -Tweaks $UpdateNoRebootRegs }
    if ($Opt['StandbyNetworkOff']) { Test-HealthTweakTable -Label 'Network in standby off' -Tweaks $StandbyNetworkRegs }
    if ($Opt['NvmeNativeDriver']) { Test-HealthTweakTable -Label 'Native NVMe driver' -Tweaks $NvmeRegs }
}

function Test-HealthHosts {
    $text = [IO.File]::ReadAllText($HostsPath)
    $expected = @()
    if ($Opt['TelemetryHosts']) { $expected += , @('telemetry', $TelemetryDomains) }
    if ($Opt['RazerAsusHosts']) { $expected += , @('razer-asus', @($RazerDomains + $AsusDomains)) }
    foreach ($e in $expected) {
        $n = [regex]::Escape($e[0])
        $m = [regex]::Match($text, "(?ms)^# FocusedTweaks BEGIN $n\r?\n(.*?)^# FocusedTweaks END $n")
        if (-not $m.Success) { Write-Health 'FAIL' 'Hosts' "Block '$($e[0])' is missing from the hosts file (security software may have reverted it)."; continue }
        $count = ([regex]::Matches($m.Groups[1].Value, '(?m)^0\.0\.0\.0 ')).Count
        if ($count -eq @($e[1]).Count) { Write-Health 'PASS' 'Hosts' "Block '$($e[0])' is present with $count entries." }
        else { Write-Health 'WARN' 'Hosts' "Block '$($e[0])' has $count entries, expected $(@($e[1]).Count)." }
    }
    $blockedAddr = '0.0.0.0', '127.0.0.1', '::', '::1'
    $resolve = {
        param($h)
        try { @([System.Net.Dns]::GetHostAddresses($h) | ForEach-Object { $_.ToString() }) } catch { @() }
    }
    if ($Opt['TelemetryHosts']) {
        $answer = @(& $resolve $TelemetryDomains[0])
        if ($answer.Count -gt 0 -and @($answer | Where-Object { $blockedAddr -notcontains $_ }).Count -eq 0) { Write-Health 'PASS' 'Hosts' "$($TelemetryDomains[0]) resolves to $($answer[0]), so the block is in effect." }
        elseif ($answer.Count -gt 0) { Write-Health 'WARN' 'Hosts' "$($TelemetryDomains[0]) still resolves to $($answer[0]). The DNS cache, a VPN or secure DNS may bypass the hosts file." }
    }
    $must = 'login.live.com', 'www.microsoft.com', 'displaycatalog.mp.microsoft.com', 'licensing.mp.microsoft.com', 'user.auth.xboxlive.com'
    $blocked = @(); $silent = 0
    foreach ($h in $must) {
        $a = @(& $resolve $h)
        if ($a.Count -eq 0) { $silent++ }
        elseif (@($a | Where-Object { $blockedAddr -contains $_ }).Count -gt 0) { $blocked += $h }
    }
    if ($blocked.Count -gt 0) { Write-Health 'FAIL' 'Hosts' "Store or Xbox sign in hosts are blocked: $($blocked -join ', ')." }
    elseif ($silent -eq $must.Count) { Write-Health 'INFO' 'Hosts' 'No DNS answers for the Store and Xbox hosts (offline?), so they could not be checked.' }
    else { Write-Health 'PASS' 'Hosts' 'Store and Xbox sign in hosts resolve normally.' }
}

function Test-HealthTasks {
    switch ($TaskMode) {
        'Delete' {
            $deleted = @($script:State.Tasks | Where-Object { $_.Action -eq 'Deleted' })
            $missing = @($deleted | Where-Object { -not $_.XmlFile -or -not (Test-Path -LiteralPath $_.XmlFile) })
            Write-Health 'INFO' 'Tasks' "$($deleted.Count) scheduled task(s) deleted, $(@(Get-ScheduledTask).Count) remain."
            if ($missing.Count -gt 0) { Write-Health 'FAIL' 'Tasks' "$($missing.Count) deleted task(s) have no backup XML, so -Revert cannot restore them." }
            elseif ($deleted.Count -gt 0) { Write-Health 'PASS' 'Tasks' 'Every deleted task has a backup XML, so -Revert can restore it.' }
        }
        'Disable' { Write-Health 'INFO' 'Tasks' "$(@($script:State.Tasks | Where-Object { $_.Action -eq 'Disabled' }).Count) telemetry task(s) disabled." }
        default { Write-Health 'INFO' 'Tasks' 'Scheduled tasks were left untouched.' }
    }
    if ($Opt['PauseUpdates'] -and $Opt['PauseStopsUpdateTasks']) {
        $active = @()
        foreach ($p in $UpdateTaskPaths) { $active += @(Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' } | ForEach-Object { $_.TaskName }) }
        $noAuto = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate'
        $list = (@($active) | Select-Object -First 4) -join ', '
        if ($active.Count -eq 0) { Write-Health 'PASS' 'Tasks' 'Update Orchestrator, WaaSMedic and Windows Update tasks are disabled or gone.' }
        elseif ($noAuto.Existed -and [int]$noAuto.Value -eq 1) { Write-Health 'INFO' 'Tasks' "$($active.Count) update task(s) are active again ($list): the Update Orchestrator turns them back on at every start. With automatic updates off (NoAutoUpdate) they no longer scan, download or install." }
        else { Write-Health 'WARN' 'Tasks' "$($active.Count) update task(s) are still active: $list." }
    }
}

function Test-HealthUpdates {
    if ($Opt['PauseUpdates']) {
        $p = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesExpiryTime'
        $expiry = [DateTime]::MinValue
        if ($p.Existed -and [DateTime]::TryParse([string]$p.Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$expiry)) {
            $left = [int][Math]::Floor(($expiry - [DateTime]::UtcNow).TotalDays)
            if ($left -lt 0) { Write-Health 'WARN' 'Updates' "The update pause ended $(-$left) day(s) ago. Updates are running again. Run the script again to pause."; }
            elseif ($left -le 14) { Write-Health 'WARN' 'Updates' "The update pause ends in $left day(s) ($($expiry.ToString('yyyy-MM-dd'))). Run the script again to extend it." }
            else { Write-Health 'PASS' 'Updates' "Updates are paused for another $left day(s) (until $($expiry.ToString('yyyy-MM-dd')))." }
        }
        else { Write-Health 'WARN' 'Updates' 'The pause expiry value is missing, so updates are not paused.' }
    }
    $hot = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1)
    if ($hot.Count -gt 0) {
        $age = [int]((Get-Date) - [DateTime]$hot[0].InstalledOn).TotalDays
        if ($Opt['PauseUpdates'] -or $Opt['SecurityUpdatesOnly']) { Write-Health 'INFO' 'Updates' "Last Windows update was installed $age day(s) ago ($($hot[0].HotFixID)). Updates are restricted by your settings." }
        elseif ($age -gt 60) { Write-Health 'WARN' 'Updates' "Last Windows update was installed $age day(s) ago, and updates are not restricted. Check Windows Update." }
        else { Write-Health 'PASS' 'Updates' "Last Windows update was installed $age day(s) ago." }
    }
}

function Test-HealthDefender {
    $st = $null
    try { $st = Get-MpComputerStatus -ErrorAction Stop } catch { }
    if (-not $st) { Write-Health 'WARN' 'Defender' 'Defender status is not available (another antivirus may be registered).'; return }
    $rt = $false
    if ($st.PSObject.Properties['RealTimeProtectionEnabled']) { $rt = [bool]$st.RealTimeProtectionEnabled }
    if ($Defender -eq 'Disable') {
        if (-not $rt) { Write-Health 'WARN' 'Defender' 'Real time protection is off, as you chose. Windows may switch it back on after updates.' }
        else { Write-Health (Get-RuntimeStatus) 'Defender' 'Real time protection is still on although you chose to disable it.' }
    }
    elseif ($rt) { Write-Health 'PASS' 'Defender' 'Real time protection is on.' }
    else { Write-Health 'WARN' 'Defender' 'Real time protection is off. If you did not choose that, run with -Defender Enable.' }

    if ($Opt['DefenderQuiet']) {
        $pref = Get-MpPreference -ErrorAction Stop
        if ([int]$pref.MAPSReporting -eq 0 -and [int]$pref.SubmitSamplesConsent -eq 2) { Write-Health 'PASS' 'Defender' 'Cloud reporting is off and sample submission is set to never send.' }
        else { Write-Health 'WARN' 'Defender' "Defender still reports to the cloud (MAPSReporting $($pref.MAPSReporting), SubmitSamplesConsent $($pref.SubmitSamplesConsent)). Tamper Protection can block the policy; turn it off and run again." }
    }

    if ($st.PSObject.Properties['AntivirusSignatureLastUpdated'] -and $st.AntivirusSignatureLastUpdated) {
        $age = [int]((Get-Date) - [DateTime]$st.AntivirusSignatureLastUpdated).TotalDays
        if ($rt -and $age -gt 7) {
            $predates = $Ctx.AppliedAt -and ($age -gt (((Get-Date) - $Ctx.AppliedAt).TotalDays + 1))
            $excluded = ($Opt['SecurityUpdatesOnly'] -or $Opt['PauseUpdates']) -and -not $Opt['KeepDefinitionUpdates']
            $why = if ($predates) { ' That is older than this run, so the base image was already out of date.' } else { '' }
            if ($excluded) { $why += ' Your update options also exclude definition updates, so Windows Update will not refresh them.' }
            Write-Health 'WARN' 'Defender' "Signatures are $age day(s) old.$why Fix: Update-MpSignature, or run again with -Enable KeepDefinitionUpdates."
        }
        else { Write-Health 'PASS' 'Defender' "Signatures were updated $age day(s) ago." }
    }
}

function Test-HealthSystem {
    if ($Opt['Uac']) {
        $s = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
        if ($s.Existed -and [int]$s.Value -eq 0) {
            if ($Ctx.SoftRuntime) { Write-Health 'INFO' 'System' 'UAC is set to off. It takes effect after a restart, and some Store apps behave differently without it.' }
            else { Write-Health 'PASS' 'System' 'UAC is off (EnableLUA 0, active since the last restart).' }
        }
        else { Write-Health 'WARN' 'System' 'UAC was meant to be off but EnableLUA is not 0.' }
    }
    if ($PowerProfile -ne 'Off' -and -not (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)) {
        $active = (powercfg /getactivescheme) | Out-String
        if ($active -match [regex]::Escape($PowerPlanBase)) { Write-Health 'PASS' 'System' "Active power plan is '$PowerPlanBase ($PowerProfile)'." }
        else { Write-Health 'WARN' 'System' "The tweaked power plan is not active. Current: $($active.Trim())" }
    }
    if ($Opt['DisableHibernate'] -or $Opt['RegHibernateOff']) {
        $h = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
        if ($h.Existed -and [int]$h.Value -eq 0) { Write-Health 'PASS' 'System' 'Hibernation is off.' } else { Write-Health (Get-RuntimeStatus) 'System' 'Hibernation is still on.' }
    }
    if ($Opt['MemoryCompression']) {
        $ram = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
        if (Test-MemoryCompressionTarget -RamGB $ram) {
            if (-not (Get-MMAgent).MemoryCompression) { Write-Health 'PASS' 'System' 'Memory compression is off.' }
            else { Write-Health 'INFO' 'System' 'Memory compression is still on. It changes after a restart.' }
        }
    }
    if ($Opt['SleepStudy']) {
        $on = @($SleepStudyLogs | Where-Object { ((& wevtutil.exe gl $_) | Out-String) -match 'enabled:\s*true' })
        if ($on.Count -eq 0) { Write-Health 'PASS' 'System' 'Sleep Study and power diagnostic logs are off.' } else { Write-Health 'WARN' 'System' "$($on.Count) power diagnostic log(s) are still enabled." }
    }
    if (($Opt['NvidiaProfile'] -or $Opt['NvidiaReBar']) -and (Test-NvidiaGpu)) {
        # Profile Inspector has no command to read settings back, so compare the driver database with the backup.
        $backup = Join-Path $StateDir 'nvidia-drs'
        $changed = @(Get-ChildItem -LiteralPath $backup -Filter 'nvdrsdb*.bin' -File -ErrorAction SilentlyContinue | Where-Object {
                $live = Join-Path $NvidiaDrsDir $_.Name
                (Test-Path -LiteralPath $live) -and (Get-FileHash -LiteralPath $live).Hash -ne (Get-FileHash -LiteralPath $_.FullName).Hash
            })
        if ($script:State.NvidiaDrs -ne $true) { Write-Health 'WARN' 'NVIDIA' 'The NVIDIA profile was not imported (no backup of the driver settings was taken). Check the run log.' }
        elseif ($changed.Count -gt 0) { Write-Health 'PASS' 'NVIDIA' 'The NVIDIA global profile was imported (driver settings differ from the backup). Open Profile Inspector to see the values.' }
        else { Write-Health 'WARN' 'NVIDIA' 'The NVIDIA driver settings are identical to the backup, so the import did not take, or was undone.' }
    }
    foreach ($g in $FeatureGroups.Keys) {
        if (-not $Opt[$g]) { continue }
        $still = @(Get-EnabledFeatureNames -Names $FeatureGroups[$g])
        if ($still.Count -eq 0) { Write-Health 'PASS' 'System' "$g`: none of the listed optional features is turned on." }
        else { Write-Health 'WARN' 'System' "$g`: still turned on: $($still -join ', '). A restart may be pending." }
    }
    $svcChecks = [ordered]@{}
    if ($Opt['TelemetryPolicy']) { $svcChecks['Telemetry services'] = $TelemetryServices }
    if ($Opt['Cdp']) { $svcChecks['Connected Devices Platform services'] = $CdpServices }
    foreach ($label in $svcChecks.Keys) {
        $present = @($svcChecks[$label] | Where-Object { $null -ne (Get-ServiceStartNow $_) })
        $on = @($present | Where-Object { (Get-ServiceStartNow $_) -ne 4 })
        if ($present.Count -eq 0) { continue }
        if ($on.Count -eq 0) { Write-Health 'PASS' 'Services' "$label are disabled: $($present -join ', ')." }
        else { Write-Health 'WARN' 'Services' "$label are not disabled: $($on -join ', ')." }
    }
    if ($Opt['NotificationSettings']) {
        # Only the apps the run switched off: apps installed since then were never touched.
        $root = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
        $touched = @($script:RecordedReg | Where-Object { $_ -like "$root\*|Enabled" } | ForEach-Object { $_.Substring(0, $_.Length - '|Enabled'.Length) })
        $back = @($touched | Where-Object { $s = Get-RegSnapshot -Full $_ -Name 'Enabled'; -not ($s.Existed -and [int]$s.Value -eq 0) })
        if ($touched.Count -eq 0) { Write-Health 'INFO' 'System' 'No app notifications were switched off by a run, so there is nothing to check.' }
        elseif ($back.Count -eq 0) { Write-Health 'PASS' 'System' "Notifications are off for the $($touched.Count) app(s) the run switched off." }
        else { Write-Health 'WARN' 'System' "Notifications are back on for $($back.Count) of $($touched.Count) app(s), first: $(Split-Path $back[0] -Leaf)." }
    }
    if ($script:State.PowerOverlaySet) {
        # powercfg sets the overlay of the power source active at the time, so either the AC or the DC value counts.
        $want = @($PowerOverlayNames.Keys | Where-Object { $PowerOverlayNames[$_] -eq $script:State.PowerOverlaySet })[0]
        $schemes = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
        $now = foreach ($n in 'ActiveOverlayAcPowerScheme', 'ActiveOverlayDcPowerScheme') {
            $s = Get-RegSnapshot -Full $schemes -Name $n
            if ($s.Existed -and $s.Value) { ([string]$s.Value).ToLowerInvariant() } else { '00000000-0000-0000-0000-000000000000' }
        }
        if (@($now) -contains $want) { Write-Health 'PASS' 'Power' "Power mode is $($script:State.PowerOverlaySet), as the run set it." }
        else { Write-Health 'WARN' 'Power' "Power mode is no longer $($script:State.PowerOverlaySet) (Settings or the laptop's own power tool may have changed it)." }
    }
    if ($Opt['PasswordExpiry'] -and [Environment]::OSVersion.Version.Build -gt 19045) {
        $age = Get-MaxPasswordAge
        if ($age -eq 'unlimited') { Write-Health 'PASS' 'System' 'Local passwords never expire.' }
        else { Write-Health 'WARN' 'System' "Local passwords still expire after $age days." }
    }
    if ($Opt['MsiMode']) {
        $display = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)
        $off = @($display | Where-Object {
                $s = Get-RegSnapshot -Full "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" -Name 'MSISupported'
                -not ($s.Existed -and [int]$s.Value -eq 1)
            })
        if ($display.Count -eq 0) { Write-Health 'INFO' 'System' 'No display adapter found, so MSI mode could not be checked.' }
        elseif ($off.Count -eq 0) { Write-Health 'PASS' 'System' "MSI interrupts are on for $($display.Count) display adapter(s)." }
        else { Write-Health 'WARN' 'System' "MSI interrupts are off for: $(($off | ForEach-Object { $_.FriendlyName }) -join ', ')." }
    }
    if ($Opt['MouseAccel']) {
        $m = Get-RegSnapshot -Full 'HKEY_CURRENT_USER\Control Panel\Mouse' -Name 'MouseSpeed'
        $d = Get-RegSnapshot -Full 'HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics' -Name 'AppliedDPI'
        $scale = if ($d.Existed) { [int]([Math]::Round(([int]$d.Value / 96) * 100)) } else { 100 }
        $want = $MouseProfiles[$scale]
        if ($want -and $m.Existed -and [string]$m.Value -eq $want.Speed) { Write-Health 'PASS' 'System' "Mouse profile for $scale% scaling is in place." }
        elseif ($want) { Write-Health 'WARN' 'System' "Mouse acceleration settings do not match the $scale% profile. Display scaling may have changed, run the script again." }
    }
    if ($Opt['ClearDesktopIcons']) {
        $shortcuts = @(foreach ($d in Get-DesktopFolders) { Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.Extension -in '.lnk', '.url' } })
        $bin = Get-RegSnapshot -Full 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Name '{645FF040-5081-101B-9F08-00AA002F954E}'
        if ($shortcuts.Count -eq 0 -and $bin.Existed -and [int]$bin.Value -eq 1) { Write-Health 'PASS' 'System' 'Desktop is clear: system icons hidden and no shortcuts on it.' }
        else { Write-Health 'INFO' 'System' "Desktop has $($shortcuts.Count) shortcut(s) again. This is normal after installing software, which adds its own." }
    }
    if ($Opt['ClearStartPins'] -and [Environment]::OSVersion.Version.Build -gt 19045) {
        $f = Join-Path $script:StartLayoutDir 'start2.bin'
        if (Test-Path -LiteralPath $f) {
            $want = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Convert]::FromBase64String(($EmptyStartLayout -join ''))))
            $have = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($f)))
            if ($want -eq $have) { Write-Health 'PASS' 'System' 'Start menu pins are cleared.' }
            else { Write-Health 'INFO' 'System' 'Start pins were cleared, but Windows rewrites the layout file once Start reloads, so this cannot be confirmed automatically. Open Start to check.' }
        }
    }
    if ($Opt['RemoveQuickAssist']) {
        $qa = @(Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*QuickAssist*' })
        if ($qa.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $env:windir 'System32\quickassist.exe'))) { Write-Health 'PASS' 'System' 'Quick Assist is removed.' }
        else { Write-Health 'WARN' 'System' 'Quick Assist is still present. A restart may finish the removal.' }
    }
    if ($Opt['RemoveOneDrive']) {
        $od = Get-OneDriveState
        if ($od.SignedIn.Count -gt 0) { Write-Health 'INFO' 'System' "OneDrive kept because an account is signed in ($($od.SignedIn -join ', '))." }
        else {
            if ($od.Installed.Count -eq 0) { Write-Health 'PASS' 'System' 'OneDrive is removed.' }
            else { Write-Health 'WARN' 'System' "OneDrive is still installed: $($od.Installed -join ', ')." }
            Test-HealthTweakTable -Label 'OneDrive policy' -Tweaks $OneDriveRegs
        }
    }
    if ($Opt['IPv4Only']) {
        $v6 =@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { Get-NetAdapterBinding -Name $_.Name -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue } | Where-Object { $_.Enabled })
        if ($v6.Count -eq 0) { Write-Health 'PASS' 'System' 'IPv6 is off on every physical network adapter.' }
        else { Write-Health 'WARN' 'System' "IPv6 is still on for: $(@($v6 | ForEach-Object { $_.Name }) -join ', ')." }
    }
    if ($Opt['SearchIndexingOff']) {
        if ((Get-ServiceStartNow 'WSearch') -eq 4) { Write-Health 'PASS' 'System' 'Windows Search indexing is disabled.' }
        else { Write-Health 'WARN' 'System' 'Windows Search indexing was meant to be disabled, but the WSearch service is not.' }
    }
    $timerSkip = $null
    if ($Opt['TimerResolution']) { $timerSkip = Get-TimerSkipReasonHere }
    if ($timerSkip) { Write-Health 'INFO' 'System' "Timer resolution service not installed on this PC: $timerSkip." }
    elseif ($Opt['TimerResolution']) {
        $svc = Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { Write-Health 'PASS' 'System' "Timer resolution service '$TimerServiceName' is running." }
        elseif ($svc) { Write-Health 'WARN' 'System' "Timer resolution service '$TimerServiceName' is installed but $($svc.Status)." }
        else { Write-Health 'WARN' 'System' "Timer resolution service '$TimerServiceName' is not installed." }
    }
    if ((Test-RebootPending) -or $Ctx.SoftRuntime) { Write-Health 'INFO' 'System' 'A restart is pending or needed, so some results above show the state before it.' }
}

function Test-HealthEvents {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Level = 2; StartTime = $boot } -ErrorAction SilentlyContinue)
    if ($events.Count -eq 0) { Write-Health 'PASS' 'Events' "No service errors since the last start ($($boot.ToString('yyyy-MM-dd HH:mm')))."; return }
    $tiPattern = 'Windows Modules Installer|TrustedInstaller'
    $own = @($events | Where-Object { $_.Message -match $tiPattern })
    $other = @($events | Where-Object { $_.Message -notmatch $tiPattern })
    if ($own.Count -gt 0) {
        if ($Ctx.TiCount -gt 0) {
            Write-Health 'INFO' 'Events' "$($own.Count) Windows Modules Installer service error(s) (7000, 7009, 7031) come from this script's TrustedInstaller helper, used $($Ctx.TiCount) time(s) in this run. This is expected and harmless."
        }
        else {
            Write-Health 'WARN' 'Events' "$($own.Count) Windows Modules Installer service error(s) since the last start. If you ran this script since the last restart they come from its TrustedInstaller helper and are harmless. Otherwise Windows servicing may have a problem."
        }
    }
    if ($other.Count -eq 0) { return }
    $top = $other | Group-Object { '{0}: {1}' -f $_.Id, (($_.Message -split "`r?`n")[0]) } | Sort-Object Count -Descending | Select-Object -First 5
    Write-Health 'WARN' 'Events' "$($other.Count) service error(s) since the last start. A disabled service that something depends on is the usual cause."
    foreach ($t in $top) { Write-Health 'INFO' 'Events' ("{0}x {1}" -f $t.Count, $t.Name.Substring(0, [Math]::Min(150, $t.Name.Length))) }
}

function Test-HealthAppLaunch {
    # Best effort: opens each app, waits for its process, then closes it again.
    $apps = @(
        @{ Name = 'Settings'; Uri = 'ms-settings:'; Process = 'SystemSettings'; Package = $null },
        @{ Name = 'Microsoft Store'; Uri = 'ms-windows-store:'; Process = 'WinStore.App'; Package = 'Microsoft.WindowsStore' },
        @{ Name = 'Photos'; Uri = 'ms-photos:'; Process = 'Photos'; Package = 'Microsoft.Windows.Photos' },
        @{ Name = 'Paint'; Uri = 'ms-paint:'; Process = 'mspaint'; Package = 'Microsoft.Paint' },
        @{ Name = 'Xbox'; Uri = 'xbox:'; Process = 'XboxPcApp'; Package = 'Microsoft.GamingApp' }
    )
    foreach ($a in $apps) {
        if ($a.Package -and -not (Get-AppxPackage -Name $a.Package -ErrorAction SilentlyContinue)) { Write-Health 'INFO' 'Launch' "$($a.Name) is not installed, skipped."; continue }
        $wasRunning = [bool](Get-Process -Name $a.Process -ErrorAction SilentlyContinue)
        Start-Process $a.Uri
        $up = $false
        for ($i = 0; $i -lt 30 -and -not $up; $i++) { Start-Sleep -Milliseconds 500; $up = [bool](Get-Process -Name $a.Process -ErrorAction SilentlyContinue) }
        if ($up) { Write-Health 'PASS' 'Launch' "$($a.Name) opened." }
        else { Write-Health 'WARN' 'Launch' "$($a.Name) did not start within 15 seconds (or its process name differs on this build)." }
        if ($up -and -not $wasRunning) { Start-Sleep -Seconds 1; Stop-Process -Name $a.Process -Force -ErrorAction SilentlyContinue }
    }
}

function Test-HealthEdition {
    # The registry checks above only prove a value is set. This says which policy values the edition does not honour.
    $edition = Get-EditionId
    $gaps = @(Get-EditionReport -Edition $edition)
    $notApplicable = @($gaps | Where-Object { $_.Verdict -eq 'not applicable' })
    foreach ($gap in $notApplicable) {
        Write-Health 'INFO' 'Edition' "$($gap.Path)\$($gap.Name) is not applicable on this edition ($edition): it is honoured on $($gap.Honoured) only, so Windows ignores it even though the registry value is set."
    }
    $unknown = $gaps.Count - $notApplicable.Count
    if ($unknown -gt 0) { Write-Health 'INFO' 'Edition' "$unknown policy value(s) have no confirmed effect on this edition ($edition). A matching registry value does not prove that Windows applies them." }
    if ($gaps.Count -eq 0) { Write-Health 'PASS' 'Edition' "Every policy value the options write is honoured on this edition ($edition)." }
}

function Restore-SavedRunSettings {
    # Standalone checks judge the state against the options used for the last run.
    $run = $script:State.Run
    if (-not $run) { Write-Log 'No saved run found, checking against the defaults and the options you passed now.' 'WARN'; return }
    foreach ($p in $run.Options.PSObject.Properties) { if ($Opt.ContainsKey($p.Name)) { $Opt[$p.Name] = [bool]$p.Value } }
    if ($run.TaskMode) { $script:TaskMode = $run.TaskMode }
    if ($run.Defender) { $script:Defender = $run.Defender }
    if ($run.PowerProfile) { $script:PowerProfile = $run.PowerProfile }
    if ($run.PauseDays) { $script:PauseDays = [int]$run.PauseDays }
    if ($run.SkipRegGroup) { $script:SkipRegGroup = @($run.SkipRegGroup) }
    Write-Log "Using the options saved from the run on $($run.When)."
}

function Save-ResultJson {
    # Results as JSON next to the log, so tools/Test-InVm.ps1 can summarise a run without parsing log text.
    param([string]$Kind, [hashtable]$Counts, [object[]]$Items)
    $file = Join-Path $StateDir ('{0}-{1:yyyyMMdd-HHmmss}.json' -f $Kind, (Get-Date))
    $data = [pscustomobject]@{ When = (Get-Date).ToString('o'); Build = [Environment]::OSVersion.Version.Build; Counts = $Counts; Items = @($Items) }
    ConvertTo-Json -InputObject $data -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
}

function Invoke-HealthCheck {
    $script:Health = @{ PASS = 0; WARN = 0; FAIL = 0; INFO = 0 }
    $script:HealthItems.Clear()
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $applied = $null
    if ($script:State.Run -and $script:State.Run.When) {
        $w = $script:State.Run.When
        try { $applied = if ($w -is [DateTime]) { $w } else { [DateTime]::Parse([string]$w, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } } catch { }
    }
    $Ctx.AppliedAt = $applied
    $Ctx.SoftRuntime = $Ctx.PostApply -or ($applied -and $boot -lt $applied)
    Write-Log "Health check starting$(if ($Ctx.SoftRuntime) { ' (no restart since the tweaks, so runtime state may lag)' })."

    Invoke-HealthArea 'Services' { Test-HealthServices }
    Invoke-HealthArea 'Apps' { Test-HealthApps }
    Invoke-HealthArea 'Registry' { Test-HealthRegistry }
    Invoke-HealthArea 'Edition' { Test-HealthEdition }
    Invoke-HealthArea 'Hosts' { Test-HealthHosts }
    Invoke-HealthArea 'Tasks' { Test-HealthTasks }
    Invoke-HealthArea 'Updates' { Test-HealthUpdates }
    Invoke-HealthArea 'Defender' { Test-HealthDefender }
    Invoke-HealthArea 'System' { Test-HealthSystem }
    Invoke-HealthArea 'Events' { Test-HealthEvents }
    if ($HealthCheckLaunch) { Invoke-HealthArea 'Launch' { Test-HealthAppLaunch } }
    if (-not $Ctx.PostApply) { Invoke-HealthArea 'Drift' { Test-HealthDrift } }

    $h = $script:Health
    Write-Log ("Health result: {0} passed, {1} warning(s), {2} failed, {3} note(s)." -f $h.PASS, $h.WARN, $h.FAIL, $h.INFO) $(if ($h.FAIL -gt 0) { 'ERROR' } elseif ($h.WARN -gt 0) { 'WARN' } else { 'OK' })
    if ($h.FAIL -gt 0) { Write-Log 'Failures mean something you asked to keep is broken. Undo one item with -Skip <Option>, or everything with -Revert.' 'ERROR' }
    if (-not $HealthCheckLaunch) { Write-Log 'Add -HealthCheckLaunch to also open Settings, Store, Photos, Paint and Xbox and confirm they start.' }
    if (-not $Ctx.DryRun) { Save-ResultJson -Kind 'health' -Counts $h -Items $script:HealthItems.ToArray() }
}

function Test-RevertResult {
    # Proves -Revert worked: every recorded registry value must be back to what it was before the first run, deleted
    # tasks must exist again, the hosts blocks must be gone and the timer service removed.
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $checked = 0; $rewritten = 0
    foreach ($e in $script:State.Registry) {
        # The first entry per value is the original; later duplicates come from older key spellings.
        if (-not $seen.Add("$($e.Path)|$($e.Name)")) { continue }
        $checked++
        $now = Get-RegSnapshot -Full $e.Path -Name $e.Name
        $was = if ($e.Existed) { '{0} ({1})' -f (@($e.Value) -join ','), $e.Kind } else { '<missing>' }
        $is = if ($now.Existed) { '{0} ({1})' -f (@($now.Value) -join ','), $now.Kind } else { '<missing>' }
        if ($was -eq $is) { continue }
        if (Test-WindowsRewritten -Path $e.Path -Name $e.Name) {
            $rewritten++
            Add-Content -Path $LogFile -Value "          revert check: [Note] $($e.Path)\$(Show-RegName $e.Name) was $was, is $is (Windows recomputes this value)"
            continue
        }
        $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Registry'; Message = "$($e.Path)\$(Show-RegName $e.Name) was $was, is $is" })
    }
    if ($rewritten -gt 0) { Write-Log "Revert check: $rewritten value(s) that Windows sets itself (accent colours, Start view, Game Bar, USB root hub idle) differ, as expected." }
    $badReg = $items.Count
    $index = Get-TaskIndex
    foreach ($t in @($script:State.Tasks)) {
        $now = $index["$($t.Path)$($t.Name)"]
        if (-not $now) {
            if ($t.Action -eq 'Deleted') { $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Tasks'; Message = "Task not restored: $($t.Path)$($t.Name)" }) }
            continue
        }
        # Disabled by the run and still disabled, although it was enabled before.
        if ($t.WasEnabled -and $now.State -eq 'Disabled') {
            if (Test-NameMatch "$($t.Path)$($t.Name)" $WindowsManagedTasks) {
                Add-Content -Path $LogFile -Value "          revert check: [Note] $($t.Path)$($t.Name) is back but disabled again (UsoSvc manages this task itself)"
                continue
            }
            $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Tasks'; Message = "Task still disabled: $($t.Path)$($t.Name)" })
        }
    }
    if ($script:State.Features.Count -gt 0) {
        foreach ($miss in @(Get-FeaturesNotBackOn -Names @($script:State.Features))) {
            $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Features'; Message = "Optional feature not back on: $miss" })
        }
    }
    $hosts = [IO.File]::ReadAllText($HostsPath)
    foreach ($name in $script:State.Hosts) {
        if ($hosts -match "# FocusedTweaks BEGIN $([regex]::Escape($name))") { $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Hosts'; Message = "Hosts block still present: $name" }) }
    }
    if ($script:State.TimerService -and (Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue)) {
        $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'System'; Message = "Service $TimerServiceName still exists" })
    }
    foreach ($i in $items) { Add-Content -Path $LogFile -Value "          revert check: [$($i.Area)] $($i.Message)" }
    $level = if ($items.Count -eq 0) { 'OK' } else { 'WARN' }
    Write-Log "Revert check: $($checked - $badReg) of $checked registry value(s) are back to their original, $($items.Count) item(s) differ in total. Details in the log." $level
    Save-ResultJson -Kind 'revert-check' -Counts @{ Checked = $checked; Differ = $items.Count } -Items $items.ToArray()
}
#endregion

