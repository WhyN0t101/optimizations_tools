#region Defender --------------------------------------------------------------------------
function Set-DefenderState {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Enable')][string]$Mode)
    $root = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender'
    $rtp = "$root\Real-Time Protection"
    $rtpValues = 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableIOAVProtection', 'DisableOnAccessProtection', 'DisableScanOnRealtimeEnable'
    if ($Mode -eq 'Disable') {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if ($status.PSObject.Properties['IsTamperProtected'] -and $status.IsTamperProtected) {
            throw 'Tamper Protection is on. Turn it off yourself in Windows Security (Virus and threat protection settings), then run again. This script does not try to bypass it.'
        }
        if (Test-DryRun 'disable Defender real time protection through policy and Set-MpPreference') { return }
        Save-DefenderPrefs
        Set-RegValue -Path $root -Name 'DisableAntiSpyware' -Value 1
        foreach ($v in $rtpValues) { Set-RegValue -Path $rtp -Name $v -Value 1 }
        Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true -DisableIOAVProtection $true -ErrorAction Stop
        Write-Log 'Defender real time protection is now disabled. Windows may switch it back on after updates.' 'WARN'
    }
    else {
        if (Test-DryRun 'remove Defender policy blocks and enable real time protection') { return }
        Save-DefenderPrefs
        Remove-RegValue -Path $root -Name 'DisableAntiSpyware'
        foreach ($v in $rtpValues) { Remove-RegValue -Path $rtp -Name $v }
        Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableIOAVProtection $false -ErrorAction Stop
        Write-Log 'Defender policy blocks removed and real time protection enabled.' 'OK'
    }
}

function Save-DefenderPrefs {
    # docs/AUDIT.md A-17: the three preferences -Defender changes are recorded the first time, so -Revert puts back
    # what was there instead of switching everything on.
    if ($script:State.Defender -eq $true) { return }
    $p = Get-MpPreference -ErrorAction Stop
    Set-StateValue -Name 'DefenderPrefs' -Value ([pscustomobject]@{
            DisableRealtimeMonitoring = [bool]$p.DisableRealtimeMonitoring
            DisableBehaviorMonitoring = [bool]$p.DisableBehaviorMonitoring
            DisableIOAVProtection     = [bool]$p.DisableIOAVProtection
        })
    Set-StateValue -Name 'Defender' -Value $true
}

function Restore-DefenderPrefs {
    $prefs = $script:State.DefenderPrefs
    if (-not $prefs) {
        # State from v7.4 and older holds no preferences, only that -Defender was used.
        Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableIOAVProtection $false -ErrorAction Stop
        Write-Log 'Defender real time protection enabled (no recorded preferences: the state comes from an older version).' 'OK'
        return
    }
    Set-MpPreference -DisableRealtimeMonitoring ([bool]$prefs.DisableRealtimeMonitoring) -DisableBehaviorMonitoring ([bool]$prefs.DisableBehaviorMonitoring) -DisableIOAVProtection ([bool]$prefs.DisableIOAVProtection) -ErrorAction Stop
    Write-Log "Defender preferences restored as recorded: DisableRealtimeMonitoring $([bool]$prefs.DisableRealtimeMonitoring), DisableBehaviorMonitoring $([bool]$prefs.DisableBehaviorMonitoring), DisableIOAVProtection $([bool]$prefs.DisableIOAVProtection)." 'OK'
}
#endregion

