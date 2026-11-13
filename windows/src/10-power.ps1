#region Power -----------------------------------------------------------------------------
function Get-GuidFromText {
    param([string]$Text)
    $m = [regex]::Match($Text, '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value }
    return $null
}

function Get-TweakedPlanGuids {
    $found = @()
    foreach ($line in @(powercfg /list)) {
        if ($line -match [regex]::Escape($PowerPlanBase)) { $g = Get-GuidFromText $line; if ($g) { $found += $g } }
    }
    return $found
}

function Set-PlanValue {
    param([string]$Guid, [string]$Sub, [string]$Setting, [string]$Value)
    foreach ($mode in '/setacvalueindex', '/setdcvalueindex') {
        powercfg $mode $Guid $Sub $Setting $Value | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "powercfg $mode failed for $Setting" 'WARN' }
    }
}

function Set-PerformancePowerPlan {
    if ((Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) -and -not $ForcePowerPlanOnLaptop) {
        Write-Log 'Battery detected, skipping the custom power plan. Use -ForcePowerPlanOnLaptop to override.' 'WARN'
        return
    }
    $spec = $PowerProfiles[$PowerProfile]
    $planName = '{0} ({1})' -f $PowerPlanBase, $PowerProfile
    if (Test-DryRun "create and activate the power plan '$planName'") { return }
    $active = Get-GuidFromText ((powercfg /getactivescheme) | Out-String)
    $existing = powercfg /list | Select-String -SimpleMatch $planName | Select-Object -First 1
    if ($existing) { $guid = Get-GuidFromText $existing.Line }
    else {
        $guid = $null
        foreach ($base in $spec.Base) {
            $guid = Get-GuidFromText (Invoke-Native powercfg.exe @('/duplicatescheme', $base))
            if ($guid) { break }
        }
        if (-not $guid) {
            Write-Log 'Base scheme unavailable (common on Modern Standby systems), cloning the active scheme instead.' 'WARN'
            $guid = Get-GuidFromText (Invoke-Native powercfg.exe @('/duplicatescheme', $active))
        }
        if (-not $guid) { throw 'Unable to create the custom power plan.' }
        powercfg /changename $guid $planName "Created by FocusedTweaks ($PowerProfile)" | Out-Null
    }
    if (-not $script:State.Power) {
        $previous = if ($active -and $active -ne $guid -and -not (@(Get-TweakedPlanGuids) -contains $active)) { $active } else { $BalancedGuid }
        Set-StateValue -Name 'Power' -Value ([pscustomobject]@{ Previous = $previous; Custom = $guid })
    }
    else { Set-StateValue -Name 'Power' -Value ([pscustomobject]@{ Previous = $script:State.Power.Previous; Custom = $guid }) }
    foreach ($s in $spec.Settings) { Set-PlanValue -Guid $guid -Sub $s[0] -Setting $s[1] -Value $s[2] }
    powercfg /setactive $guid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'powercfg /setactive failed.' }
    Write-Log "Active power plan set to '$planName' ($guid)." 'OK'
    foreach ($old in @(Get-TweakedPlanGuids)) { if ($old -ne $guid) { powercfg /delete $old | Out-Null } }
}

function Get-PowerSource {
    # 'Ac' or 'Dc' (battery). powercfg /OverlaySetActive changes the overlay of whichever source is active.
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Offline') { return 'Dc' }
    }
    catch { }   # no way to tell: treat as AC, which is also what a desktop is
    return 'Ac'
}

function Set-PowerModeOverlay {
    $overlay = if ($PowerMode -eq 'Best') { 'OVERLAY_SCHEME_MAX' } else { 'OVERLAY_SCHEME_NONE' }
    if (Test-DryRun "set the Windows power mode overlay to $overlay") { return }
    if (-not $script:State.PowerOverlay) {
        # Recorded first so -Revert can put the previous power mode back, for the same power source the change hits.
        # A missing value means Windows' default.
        $source = Get-PowerSource
        $prev = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name "ActiveOverlay$($source)PowerScheme"
        Set-StateValue -Name 'PowerOverlay' -Value $(if ($prev.Existed -and $prev.Value) { [string]$prev.Value } else { '00000000-0000-0000-0000-000000000000' })
        Set-StateValue -Name 'PowerOverlaySource' -Value $source
    }
    powercfg /OverlaySetActive $overlay | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log 'Power mode overlays are not available on this Windows build.' 'WARN'; return }
    Set-StateValue -Name 'PowerOverlaySet' -Value $overlay   # what the health check compares against
    Write-Log "Power mode set ($PowerMode)." 'OK'
}

function Restore-PowerMode {
    $guid = ([string]$script:State.PowerOverlay).ToLowerInvariant()
    $name = $PowerOverlayNames[$guid]
    if (-not $name) {
        if ($guid -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') { throw "Unexpected saved power mode '$guid', not restoring it." }
        $name = $guid
    }
    # The overlay can only be set for the active power source. State from older runs has no source: AC.
    $source = 'Ac'
    if ($script:State.PowerOverlaySource -eq 'Dc') { $source = 'Dc' }
    if ((Get-PowerSource) -ne $source) {
        # powercfg only reaches the active source, so write the other source's stored overlay directly; Windows
        # uses it the next time that source becomes active.
        Write-RegRaw -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name "ActiveOverlay$($source)PowerScheme" -Value $guid -Kind 'String'
        Write-Log "Power mode for $(if ($source -eq 'Dc') { 'battery' } else { 'AC power' }) restored ($name). It applies when the PC next runs on that power source." 'OK'
        return
    }
    $null = Invoke-Native powercfg.exe @('/OverlaySetActive', $name)
    if ($LASTEXITCODE -ne 0) { throw "powercfg could not set the power mode back to $name." }
    Write-Log "Power mode restored ($name)." 'OK'
}

function Restore-PowerPlan {
    if (-not $script:State.Power) { return }
    $list = (powercfg /list) | Out-String
    $target = $script:State.Power.Previous
    if (-not $target -or $list -notmatch [regex]::Escape($target)) { $target = $BalancedGuid }
    powercfg /setactive $target | Out-Null
    foreach ($g in @(Get-TweakedPlanGuids)) { powercfg /delete $g | Out-Null }
    Write-Log "Power plan restored to $target and tweaked plans deleted." 'OK'
}

function Disable-Hibernation {
    if ($script:Reapply) {
        $h = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue
        if ($h -and $h.PSObject.Properties['HibernateEnabled'] -and $h.HibernateEnabled -eq 0) { return }
    }
    if (Test-DryRun 'turn hibernation off (this also removes Fast Startup)') { return }
    if ($null -eq $script:State.Hibernate) {
        $p = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue
        Set-StateValue -Name 'Hibernate' -Value ([bool]($p -and $p.PSObject.Properties['HibernateEnabled'] -and $p.HibernateEnabled -eq 1))
    }
    powercfg /hibernate off | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'powercfg /hibernate off failed.' }
    Write-Log 'Hibernation disabled (Fast Startup is unavailable while it is off).' 'OK'
}
#endregion

