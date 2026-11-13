#region Devices, shutdown, updates, search, time, right click menu ------------------------
function Set-TweakListBatched {
    # For long lists (one entry per device). Values that need TrustedInstaller are written together in a few calls,
    # because each call restarts a service and takes seconds. A dry run prints one summary line, not every value.
    # The journal gets one flushed write per registry key before its values change and one for their results, instead
    # of two per value: device options touch thousands of values.
    param([string]$Label, [object[]]$Tweaks)
    if ($script:Reapply) { $Tweaks = @($Tweaks | Where-Object { -not (Test-RegValueIs -Full (ConvertTo-FullRegPath $_.Path) -Name $_.Name -Value $_.Value -Type $_.Type) }) }
    if ($Tweaks.Count -eq 0) { Write-Log "$Label`: nothing to change on this machine."; return }
    $keys = @($Tweaks | ForEach-Object { $_.Path } | Select-Object -Unique).Count
    if (Test-DryRun "$Label`: set $($Tweaks.Count) value(s) under $keys registry key(s)") { return }
    $denied = [System.Collections.Generic.List[object]]::new()
    $failed = 0
    foreach ($group in @($Tweaks | Group-Object { ConvertTo-FullRegPath $_.Path })) {
        $full = $group.Name
        $events = [System.Collections.Generic.List[object]]::new()
        $pending = [System.Collections.Generic.List[object]]::new()
        foreach ($e in @(Get-MissingKeyEvents -Full $full)) { $events.Add($e) }
        foreach ($t in $group.Group) {
            $change = $null
            foreach ($e in @(New-RegChangeEvents -Full $full -Name $t.Name -After (Format-RegIntent -Value $t.Value -Kind $t.Type) -SkipKeys)) { $events.Add($e); $change = $e }
            $pending.Add([pscustomobject]@{ Full = $full; Tweak = $t; Change = $change })
        }
        Add-JournalEvents $events.ToArray()
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $pending) {
            try {
                Write-RegRaw -Full $full -Name $p.Tweak.Name -Value $p.Tweak.Value -Kind $p.Tweak.Type
                $r = Complete-RegChange -Change $p.Change -Full $full -Name $p.Tweak.Name -Value $p.Tweak.Value -Kind $p.Tweak.Type -Quiet
                if ($r.Result -ne 'OK') { $failed++ }
                $results.Add($r)
            }
            catch {
                if (Test-AccessDenied $_) { $denied.Add($p); continue }
                $script:Failures++
                Write-Log "Registry write failed: $full\$(Show-RegName $p.Tweak.Name). $($_.Exception.Message)" 'ERROR'
                $results.Add((New-ChangeResult -Change $p.Change -Result 'FAILED' -Now $_.Exception.Message))
            }
        }
        if ($results.Count -gt 0) { Add-JournalEvents $results.ToArray() }
    }
    # About 30 commands keep the encoded command well below the service command line limit.
    for ($i = 0; $i -lt $denied.Count; $i += 30) {
        $chunk = @($denied[$i..([Math]::Min($i + 29, $denied.Count - 1))])
        [void](Invoke-AsTI -PsCommand (($chunk | ForEach-Object { Format-TiRegAdd -Full $_.Full -Name $_.Tweak.Name -Value $_.Tweak.Value -Kind $_.Tweak.Type }) -join '; '))
    }
    if ($denied.Count -gt 0) {
        $results = @(foreach ($p in $denied) { Complete-RegChange -Change $p.Change -Full $p.Full -Name $p.Tweak.Name -Value $p.Tweak.Value -Kind $p.Tweak.Type -Quiet })
        $failed += @($results | Where-Object { $_.Result -ne 'OK' }).Count
        Add-JournalEvents $results
    }
    if ($failed -gt 0) { Write-Log "$Label`: $failed of $($Tweaks.Count) value(s) did not read back as set (MISMATCH in the journal), even as TrustedInstaller." 'WARN' }
    Write-Log "$Label`: $($Tweaks.Count - $failed) value(s) set under $keys registry key(s). They apply after a restart." 'OK'
}

function Get-DeviceParameterKeys {
    # The 'Device Parameters' key of every device instance under the given Enum roots (present or not).
    param([string[]]$Roots, [string]$HardwareLike = '*')
    foreach ($root in $Roots) {
        $rootPath = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$root"
        $rootKey = Open-RegKey -Full $rootPath
        if (-not $rootKey) { continue }
        try {
            foreach ($hw in @($rootKey.GetSubKeyNames() | Where-Object { $_ -like $HardwareLike })) {
                $hwKey = $rootKey.OpenSubKey($hw)
                if (-not $hwKey) { continue }
                try {
                    foreach ($inst in $hwKey.GetSubKeyNames()) {
                        try { $params = $hwKey.OpenSubKey("$inst\Device Parameters") }
                        catch { continue }   # a few instance keys are readable by SYSTEM only, nothing to change there
                        if (-not $params) { continue }
                        [pscustomobject]@{ Path = "$rootPath\$hw\$inst\Device Parameters"; HasWdf = (@($params.GetSubKeyNames()) -contains 'WDF') }
                        $params.Close()
                    }
                }
                finally { $hwKey.Close() }
            }
        }
        finally { $rootKey.Close() }
    }
}

function Get-DeviceTweaks {
    param([switch]$Power, [switch]$Wake)
    foreach ($d in @(Get-DeviceParameterKeys -Roots $DeviceEnumRoots)) {
        if ($Power) {
            foreach ($v in $DevicePowerValues) { New-Tweak $d.Path $v.Name $v.Value $v.Type }
            if ($d.HasWdf) { New-Tweak "$($d.Path)\WDF" 'IdleInWorkingState' 0 'DWord' }
        }
        if ($Wake) { New-Tweak $d.Path 'WaitWakeEnabled' 0 'DWord' }
    }
}

function Get-WriteCacheTweaks {
    # Disks only: Enum\SCSI also lists optical drives, which Ultimate changes as well.
    foreach ($d in @(Get-DeviceParameterKeys -Roots 'SCSI', 'NVME' -HardwareLike 'Disk*')) { New-Tweak "$($d.Path)\Disk" 'CacheIsPowerProtected' 1 'DWord' }
}

function Set-DevicePowerSaving {
    if ((Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) -and -not $ForcePowerPlanOnLaptop) {
        Write-Log 'Battery detected, device power saving kept. Use -ForcePowerPlanOnLaptop to override.' 'WARN'
        return
    }
    Set-TweakListBatched -Label 'Device power saving' -Tweaks @(Get-DeviceTweaks -Power)
}

function Get-FeatureUpgradeTweaks {
    # Same policy as upstream: pin the current product and version, so Windows Update offers no newer version.
    $nt = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $version = if ($nt.PSObject.Properties['DisplayVersion']) { [string]$nt.DisplayVersion } elseif ($nt.PSObject.Properties['ReleaseId']) { [string]$nt.ReleaseId } else { '' }
    if (-not $version) { throw 'Could not read the current Windows version (DisplayVersion).' }
    $product = if ([Environment]::OSVersion.Version.Build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    $wu = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    New-Tweak $wu 'ProductVersion' $product 'String'
    New-Tweak $wu 'TargetReleaseVersion' 1 'DWord'
    New-Tweak $wu 'TargetReleaseVersionInfo' $version 'String'
}

function Set-FeatureUpgradeBlock {
    $tweaks = @(Get-FeatureUpgradeTweaks)
    Set-TweakList $tweaks
    if (-not $script:DryRun) { Write-Log "Windows stays on $($tweaks[0].Value) $($tweaks[2].Value). Remove this before that version reaches end of support." 'WARN' }
}

function Update-TimeService {
    # Makes the time service read its settings again and sync. A failed sync is not fatal: it retries on its own.
    Start-Service -Name W32Time -ErrorAction SilentlyContinue
    $out = Invoke-Native w32tm.exe @('/config', '/update')
    if ($LASTEXITCODE -ne 0) { Write-Log "w32tm /config /update failed: $($out.Trim())" 'WARN'; return }
    $out = Invoke-Native w32tm.exe @('/resync', '/nowait')
    if ($LASTEXITCODE -ne 0) { Write-Log "w32tm /resync failed, Windows will retry on its own: $($out.Trim())" 'WARN' }
}

function Set-TimeServer {
    if ($script:Reapply -and @($TimeServerRegs | Where-Object { -not (Test-RegValueIs -Full (ConvertTo-FullRegPath $_.Path) -Name $_.Name -Value $_.Value -Type $_.Type) }).Count -eq 0) { return }
    Set-TweakList $TimeServerRegs
    if ($script:DryRun) { return }
    Update-TimeService
    Write-Log 'Time is now synced from pool.ntp.org.' 'OK'
}
#endregion

