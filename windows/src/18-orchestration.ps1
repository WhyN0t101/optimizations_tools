#region Orchestration ---------------------------------------------------------------------
# docs/AUDIT.md C-2 and A-08: checks run before a run, each with a name that -SkipCheck accepts.
$PreflightChecks = @('PendingReboot', 'WindowsUpdate', 'PowerSource', 'Managed', 'Edition', 'TamperProtection', 'SystemProtection')

function Test-RebootPending {
    return (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    ($null -ne (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue))
}

# Enrolment entries Windows creates itself on every PC, managed or not (seen with EnrollmentState 1 on an unmanaged
# Windows 11 VM, build 26200, 11 Nov 2026). Only other providers, such as Intune's 'MS DM Server', mean real MDM.
$BuiltInMdmProviders = @('Local Authority', 'Cloud Authority', 'Deploy Authority')

function Test-MdmProvider {
    param([string]$ProviderId)
    return [bool]($ProviderId -and $BuiltInMdmProviders -notcontains $ProviderId)
}

function Get-ManagedFacts {
    # Signs that someone else manages this PC: a domain, Microsoft Entra ID, an MDM enrolment, or Group Policy objects
    # from a domain (their DSPath is an LDAP path; the local policy's is 'LocalGPO').
    $facts = [ordered]@{ PartOfDomain = $false; Domain = ''; EntraJoined = $false; MdmProviders = @(); DomainGpos = 0 }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) { $facts.PartOfDomain = [bool]$cs.PartOfDomain; $facts.Domain = [string]$cs.Domain }
    $join = Open-RegKey -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
    if ($join) { try { $facts.EntraJoined = $join.SubKeyCount -gt 0 } finally { $join.Close() } }
    $enrolments = Open-RegKey -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Enrollments'
    if ($enrolments) {
        try {
            foreach ($n in $enrolments.GetSubKeyNames()) {
                $k = $enrolments.OpenSubKey($n)
                if (-not $k) { continue }
                try {
                    $provider = [string]$k.GetValue('ProviderID', '')
                    $state = $k.GetValue('EnrollmentState', $null)
                    if ((Test-MdmProvider $provider) -and $null -ne $state -and [int]$state -eq 1) { $facts.MdmProviders += $provider }
                }
                finally { $k.Close() }
            }
        }
        finally { $enrolments.Close() }
    }
    $history = Open-RegKey -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History'
    if ($history) {
        try {
            foreach ($extension in $history.GetSubKeyNames()) {
                $e = $history.OpenSubKey($extension)
                if (-not $e) { continue }
                try {
                    foreach ($gpo in $e.GetSubKeyNames()) {
                        $g = $e.OpenSubKey($gpo)
                        if (-not $g) { continue }
                        try { if ([string]$g.GetValue('DSPath', '') -match '^(LDAP://)?cn=') { $facts.DomainGpos++ } }
                        finally { $g.Close() }
                    }
                }
                finally { $e.Close() }
            }
        }
        finally { $history.Close() }
    }
    return [pscustomobject]$facts
}

function Get-ManagedReasons {
    param($Facts)
    if ($Facts.PartOfDomain) { "joined to the Active Directory domain $($Facts.Domain)" }
    if ($Facts.EntraJoined) { 'joined to Microsoft Entra ID' }
    foreach ($p in @($Facts.MdmProviders)) { "enrolled in device management (MDM provider $p)" }
    if ($Facts.DomainGpos -gt 0) { "$($Facts.DomainGpos) Group Policy object setting(s) from a domain are applied" }
}

function Get-PreflightFacts {
    $tamperChecked = [bool]($Opt['DefenderQuiet'] -or $Defender -eq 'Disable')
    $tamper = $null
    if ($tamperChecked) {
        try { $tamper = [bool](Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected } catch { $tamper = $null }
    }
    $gaps = @(Get-EditionReport)
    $ignored = @($gaps | Where-Object { $_.Verdict -eq 'not applicable' }).Count
    $latest = @(Get-RestorePoints | ForEach-Object { ConvertFrom-DmtfDate $_.CreationTime } | Where-Object { $_ } | Sort-Object -Descending) | Select-Object -First 1
    $srPolicy = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR'
    return [pscustomobject]@{
        RebootPending      = [bool](Test-RebootPending)
        Servicing          = [bool](Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue)
        HasBattery         = [bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
        OnBattery          = ((Get-PowerSource) -eq 'Dc')
        Managed            = Get-ManagedFacts
        Edition            = Get-EditionId
        EditionIgnored     = $ignored
        EditionUnknown     = $gaps.Count - $ignored
        TamperChecked      = $tamperChecked
        TamperProtected    = $tamper
        LatestRestorePoint = $latest
        SystemRestoreOff   = [bool]($srPolicy.Existed -and [int]$srPolicy.Value -eq 1)
        SkipRestorePoint   = [bool]$SkipRestorePoint
    }
}

function Get-PreflightResults {
    # One result per check: PASS, INFO, WARN or BLOCK, with the reason it fired. Only Managed blocks; -AllowManaged
    # turns that into a warning, and -SkipCheck turns any check into SKIPPED.
    param([Parameter(Mandatory)]$Facts, [string[]]$Skip = @(), [switch]$AllowManaged, [DateTime]$Now = (Get-Date))
    foreach ($name in $Skip) {
        if (-not ($PreflightChecks | Where-Object { $_ -ieq $name })) { throw "Unknown check '$name' for -SkipCheck. Valid: $($PreflightChecks -join ', ')." }
    }
    $new = { param($check, $status, $message) [pscustomobject]@{ Check = $check; Status = $status; Message = $message } }
    $results = @(
        if ($Facts.RebootPending) { & $new 'PendingReboot' 'WARN' 'A restart is pending (servicing, Windows Update or a file rename). Restart first: Windows can overwrite values changed now, and the health check would read the state before the restart.' }
        else { & $new 'PendingReboot' 'PASS' 'No restart is pending.' }
        if ($Facts.Servicing) { & $new 'WindowsUpdate' 'WARN' 'Windows servicing is installing something right now (TiWorker is running). Wait until Windows Update is done: it can reset or lock values this run changes.' }
        else { & $new 'WindowsUpdate' 'PASS' 'Windows servicing is idle.' }
        if ($Facts.OnBattery) { & $new 'PowerSource' 'WARN' 'Running on battery. The power plan and device power saving steps are skipped on battery machines, and a benchmark taken now is not comparable with one on AC power.' }
        elseif ($Facts.HasBattery) { & $new 'PowerSource' 'INFO' 'Battery present, running on AC power.' }
        else { & $new 'PowerSource' 'PASS' 'No battery (desktop).' }
        $reasons = @(Get-ManagedReasons -Facts $Facts.Managed)
        if ($reasons.Count -eq 0) { & $new 'Managed' 'PASS' 'Not joined to a domain or Entra ID, not enrolled in MDM, no domain Group Policy.' }
        elseif ($AllowManaged) { & $new 'Managed' 'WARN' "This PC is managed: $($reasons -join '; '). Allowed by -AllowManaged: its policies can undo or fight these changes, and SvcOther disables Netlogon, which domain sign in needs." }
        else { & $new 'Managed' 'BLOCK' "This PC is managed: $($reasons -join '; '). Its policies can undo or fight these changes, and SvcOther disables Netlogon, which domain sign in needs. Run it on a PC you manage yourself, or pass -AllowManaged to run anyway." }
        $editionText = "Edition $($Facts.Edition): $($Facts.EditionIgnored) policy value(s) of this run are not applicable on this edition, so Windows ignores them; for $($Facts.EditionUnknown) more the effect on this edition is not confirmed. The plan and the health check name them."
        if ($Facts.EditionIgnored -gt 0) { & $new 'Edition' 'WARN' $editionText }
        elseif ($Facts.EditionUnknown -gt 0) { & $new 'Edition' 'INFO' $editionText }
        else { & $new 'Edition' 'PASS' "Edition $($Facts.Edition) honours every policy value of this run." }
        if (-not $Facts.TamperChecked) { & $new 'TamperProtection' 'INFO' 'No Defender option of this run depends on Tamper Protection.' }
        elseif ($null -eq $Facts.TamperProtected) { & $new 'TamperProtection' 'INFO' 'Defender status is not available, so Tamper Protection was not checked.' }
        elseif ($Facts.TamperProtected) { & $new 'TamperProtection' 'WARN' 'Tamper Protection is on, so Defender may ignore or undo the Defender settings of this run. The run asks you to turn it off first.' }
        else { & $new 'TamperProtection' 'PASS' 'Tamper Protection is off.' }
        if ($Facts.SkipRestorePoint) { & $new 'SystemProtection' 'INFO' 'No restore point will be made (-SkipRestorePoint).' }
        elseif ($Facts.SystemRestoreOff) { & $new 'SystemProtection' 'WARN' 'System Restore is turned off by policy (DisableSR 1), so no restore point can be made.' }
        elseif ($Facts.LatestRestorePoint -and $Facts.LatestRestorePoint -gt $Now.AddHours(-24)) { & $new 'SystemProtection' 'WARN' "The newest restore point is from $($Facts.LatestRestorePoint.ToString('yyyy-MM-dd HH:mm')), less than 24 hours ago, so Windows will probably refuse a new one. -Enable EnableSystemRestore allows it." }
        elseif ($Facts.LatestRestorePoint) { & $new 'SystemProtection' 'PASS' "The newest restore point is from $($Facts.LatestRestorePoint.ToString('yyyy-MM-dd HH:mm'))." }
        else { & $new 'SystemProtection' 'INFO' 'No restore point exists yet. If System Protection is off for the system drive, -Enable EnableSystemRestore turns it on.' }
    )
    foreach ($r in $results) {
        if ($Skip | Where-Object { $_ -ieq $r.Check }) { $r.Message = "Skipped by -SkipCheck $($r.Check). It said: [$($r.Status)] $($r.Message)"; $r.Status = 'SKIPPED' }
    }
    return $results
}

function Invoke-Preflight {
    # Logs every check with the reason it fired. Returns $false when a check blocks a real run; a dry run goes on.
    # -Strict (used by -Reapply) blocks on a pending restart or servicing at work: an update in the middle of being
    # installed would undo the repair again.
    param([switch]$Strict)
    $script:PreflightResults = @(Get-PreflightResults -Facts (Get-PreflightFacts) -Skip $SkipCheck -AllowManaged:$AllowManaged)
    if ($Strict) {
        foreach ($p in $script:PreflightResults) {
            if ($p.Check -in 'PendingReboot', 'WindowsUpdate' -and $p.Status -eq 'WARN') { $p.Status = 'BLOCK'; $p.Message += ' -Reapply waits for this.' }
        }
    }
    foreach ($p in $script:PreflightResults) {
        $level = switch ($p.Status) { 'WARN' { 'WARN' } 'BLOCK' { 'ERROR' } default { 'INFO' } }
        Write-Log "Pre flight $($p.Check) [$($p.Status)]: $($p.Message)" $level
    }
    $blocks = @($script:PreflightResults | Where-Object { $_.Status -eq 'BLOCK' })
    if ($blocks.Count -eq 0) { return $true }
    if ($Ctx.DryRun) { Write-Log 'A real run would stop here because of the pre flight check(s) above. The dry run goes on.' 'WARN'; return $true }
    Write-Log "Run refused by the pre flight check(s) $(@($blocks | ForEach-Object { $_.Check }) -join ', '). Nothing was changed. Skip a check by name with -SkipCheck." 'ERROR'
    return $false
}

function Get-UserMismatch {
    # Per user settings go to the account running the script. When a standard user elevates with another account, that
    # is the admin account, not the person at the desktop. Returns a warning in that case, otherwise $null.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $owners = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
            $r = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue
            if ($r -and $r.Sid) { $r.Sid }
        } | Select-Object -Unique)
    if ($owners.Count -eq 0 -or $owners -contains $me.User.Value) { return $null }
    $names = foreach ($sid in $owners) {
        try { ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value }
        catch { $sid }   # an account that no longer resolves is shown by its SID
    }
    return "Per user settings (mouse, desktop, Start pins, notifications, End task, user Temp) will go to $($me.Name), but the desktop belongs to $($names -join ', '). Sign in as that account and run it elevated there, unless this is what you want."
}

function Get-Windows10Notice {
    # Windows 10 gets security updates only through Extended Security Updates, which Microsoft's end of support page
    # (microsoft.com/windows/end-of-support, checked 9 Nov 2026) says run until 12 October 2027. Returns $null on Windows 11.
    param([int]$Build = [Environment]::OSVersion.Version.Build)
    if ($Build -ge 22000) { return $null }
    return 'Windows 10 detected. It receives security updates only through Extended Security Updates (ESU), until 12 October 2027. The PauseUpdates and SecurityUpdatesOnly options delay those updates too.'
}

function Get-EditionId {
    $p = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction SilentlyContinue
    if ($p -and $p.PSObject.Properties['EditionID']) { return [string]$p.EditionID }
    return ''
}

function Get-EditionVerdict {
    # 'applies', 'not applicable' or 'unknown' for one registry value on one edition, plus the editions that honour it.
    param([string]$Edition, [string]$Full, [string]$Name, $Value)
    $result = { param($verdict, $label) [pscustomobject]@{ Verdict = $verdict; Honoured = $label } }
    if ($Full -notlike '*\Policies\*') { return & $result 'applies' '' }
    foreach ($rule in $EditionRules) {
        if ($rule.Names -notcontains $Name) { continue }
        if ($rule.ContainsKey('Value') -and [string]$Value -ne [string]$rule.Value) { continue }
        if (Test-NameMatch $Edition $rule.Honoured) { return & $result 'applies' $rule.Label }
        if (Test-NameMatch $Edition $rule.Ignored) { return & $result 'not applicable' $rule.Label }
        return & $result 'unknown' $rule.Label
    }
    if (Test-NameMatch $Edition $EditionFullPolicy) { return & $result 'applies' '' }
    return & $result 'unknown' ''
}

function Get-PolicyTweaks {
    # Every value under a Policies key that the chosen options write, as full path, name and value.
    $seen = @{}
    $add = {
        param($path, $name, $value)
        $full = ConvertTo-FullRegPath $path
        if ($full -like '*\Policies\*') { $seen["$full|$name"] = [pscustomobject]@{ Path = $full; Name = $name; Value = $value } }
    }
    $ops = ConvertFrom-RegText -Text $UpstreamRegText
    foreach ($op in $ops) {
        if ($op.Action -ne 'Set' -or -not $Opt[(Get-RegOpOption $op)] -or (Test-NameMatch $op.Group $SkipRegGroup)) { continue }
        & $add $op.Path $op.Name $op.Value
    }
    $tables = [ordered]@{
        TelemetryPolicy = $TelemetryRegs; BiometricsPolicy = $BiometricsRegs; DriverExclusion = $DriverExclusionRegs
        SecurityUpdatesOnly = $SecurityUpdatesRegs; PauseUpdates = @($PauseRegs) + @($NoAutoUpdateRegs); DefenderQuiet = $DefenderQuietRegs; LockScreenOff = $LockScreenRegs
        EdgeBackground = $EdgeBackgroundRegs; RemoveOneDrive = $OneDriveRegs; WindowsAIOff = $WindowsAIRegs
        TelemetryExtra = $TelemetryExtraRegs; BrowserPolicies = $BrowserPolicyRegs; NoDeviceEncryption = $NoDeviceEncryptionRegs
        UpdateNoReboot = $UpdateNoRebootRegs; StandbyNetworkOff = $StandbyNetworkRegs
    }
    foreach ($option in $tables.Keys) { if ($Opt[$option]) { foreach ($t in $tables[$option]) { & $add $t.Path $t.Name $t.Value } } }
    if ($Opt['BlockFeatureUpgrades']) { foreach ($t in @(Get-FeatureUpgradeTweaks)) { & $add $t.Path $t.Name $t.Value } }
    return @($seen.Values | Sort-Object Path, Name)
}

function Get-EditionReport {
    # The policy values of this run that the edition ignores ('not applicable') or may ignore ('unknown').
    param([string]$Edition = (Get-EditionId))
    foreach ($t in @(Get-PolicyTweaks)) {
        $v = Get-EditionVerdict -Edition $Edition -Full $t.Path -Name $t.Name -Value $t.Value
        if ($v.Verdict -ne 'applies') { [pscustomobject]@{ Path = $t.Path; Name = $t.Name; Verdict = $v.Verdict; Honoured = $v.Honoured } }
    }
}

function Get-SecurityTradeoffs {
    # docs/AUDIT.md B-02: these stay on by default for speed; the plan says plainly what each one weakens.
    $weakens = [ordered]@{
        SpectreMeltdownOff = 'SpectreMeltdownOff weakens the CPU side channel protection: programs and scripts in web pages can read kernel and other processes'' memory through Spectre variant 2 and Meltdown on CPUs without the hardware fix.'
        CoreIsolation      = 'CoreIsolation weakens kernel protection: without memory integrity (HVCI) and Credential Guard, a malicious or vulnerable driver can change kernel code, and stolen administrator rights reach stored credentials more easily.'
        Uac                = 'Uac weakens the boundary between you and administrator: every program you start runs with full administrator rights, with no prompt, so malware does too.'
    }
    foreach ($k in $weakens.Keys) { if ($Opt[$k]) { $weakens[$k] } }
}

function Show-Plan {
    Write-Log "Mode: $(if ($Ctx.DryRun) { 'DRY RUN (no changes)' } else { 'APPLY' }). State and logs: $StateDir"
    $edition = Get-EditionId
    $editionGaps = @(Get-EditionReport -Edition $edition)
    $notApplicable = @($editionGaps | Where-Object { $_.Verdict -eq 'not applicable' })
    Write-Log "  Edition: $edition. $($notApplicable.Count) policy value(s) not applicable on this edition, $($editionGaps.Count - $notApplicable.Count) with an unconfirmed effect on it."
    foreach ($gap in $notApplicable) { Write-Log "    Not applicable on this edition: $($gap.Path)\$($gap.Name) (honoured on $($gap.Honoured) only). The value is still written." }
    $on = @($OptionInfo.Keys | Where-Object { $Opt[$_] })
    $off = @($OptionInfo.Keys | Where-Object { -not $Opt[$_] })
    Write-Log "  Options on : $($on -join ', ')"
    Write-Log "  Options off: $($off -join ', ')"
    foreach ($line in @(Get-SecurityTradeoffs)) { Write-Log "  Security trade-off: $line" 'WARN' }
    Write-Log "  Tasks: $TaskMode | Services: $ServiceMode | Defender: $Defender | Power profile: $PowerProfile | Power mode: $PowerMode | Pause days: $PauseDays"
    if ($WantNvidia) { Write-Log "  NVIDIA: $(if ($NvidiaInstaller) { $NvidiaInstaller } else { 'download ' + $(if ($NvidiaVersion) { $NvidiaVersion } else { 'latest' }) })" }
    if ($ProfilePath) { Write-Log "  Profile: $ProfilePath (command line parameters win over it)" }
    $script:UserMismatch = Get-UserMismatch
    if ($script:UserMismatch) { Write-Log $script:UserMismatch 'WARN' }
}

function Confirm-Run {
    if ($Force -or $Ctx.DryRun) { return $true }
    Write-Host ''
    $notes = @()
    if ($Opt['Debloat']) { $notes += 'App debloat cannot be undone by -Revert.' }
    if ($Opt['RemoveOneDrive']) { $notes += 'OneDrive will be uninstalled unless an account is signed in (reinstall with winget).' }
    if ($Opt['RemoveEdge']) { $notes += 'The Edge browser will be uninstalled where Windows allows it; WebView2 stays (reinstall Edge with winget).' }
    if ($ServiceMode -eq 'Delete') { $notes += 'Services in the enabled service groups will be deleted (exported first, -Revert brings them back).' }
    if ($TaskMode -eq 'Delete') { $notes += 'Scheduled tasks will be deleted (backups are kept), except time sync, SSD retrim, TPM, BitLocker, Defender, System Restore, certificate and browser update tasks.' }
    if ($Opt['TempCleanup'] -or $Opt['UpdateCacheCleanup']) { $notes += 'Temp and update cache files are deleted for good.' }
    if ($Opt['SpectreMeltdownOff']) { $notes += 'CPU security mitigations will be turned off.' }
    if ($Opt['WriteCacheFlushOff']) { $notes += 'Disk write cache flushing will be turned off (a power cut can lose data).' }
    if ($Opt['FastShutdown']) { $notes += 'Hung apps will be closed at shutdown without asking.' }
    if ($script:UserMismatch) { $notes += 'Per user settings go to another account than the one at the desktop (see the warning above).' }
    $answer = Read-Host "$($notes -join ' ') A snapshot or restore point is recommended. Type YES to continue"
    return ($answer -ceq 'YES')
}

function Invoke-Apply {
    Write-Log "Windows build $([Environment]::OSVersion.Version.Build)."
    # Saved settings accumulate across runs: a later partial run (-Only) must not make the health check forget
    # what an earlier run applied, because those changes are still in place.
    $prev = $script:State.Run
    $merged = [ordered]@{}
    foreach ($k in $Opt.Keys) {
        $before = $prev -and $prev.Options.PSObject.Properties[$k] -and [bool]$prev.Options.$k
        $merged[$k] = [bool]$Opt[$k] -or [bool]$before
    }
    $mTask = if ($TaskMode -ne 'None') { $TaskMode } elseif ($prev -and $prev.TaskMode) { $prev.TaskMode } else { 'None' }
    $mDef = if ($Defender -ne 'Keep') { $Defender } elseif ($prev -and $prev.Defender) { $prev.Defender } else { 'Keep' }
    $mPower = if ($PowerProfile -ne 'Off') { $PowerProfile } elseif ($prev -and $prev.PowerProfile) { $prev.PowerProfile } else { 'Off' }
    $mDays = if ($Opt['PauseUpdates'] -or -not ($prev -and $prev.PauseDays)) { $PauseDays } else { [int]$prev.PauseDays }
    $mSkip = @($SkipRegGroup) + $(if ($prev -and $prev.SkipRegGroup) { @($prev.SkipRegGroup) } else { @() })
    Set-StateValue -Name 'Run' -Value ([pscustomobject]@{
        When = (Get-Date).ToString('o'); Options = [pscustomobject]$merged; TaskMode = $mTask; Defender = $mDef
        ServiceMode = $(if ($ServiceMode -eq 'Delete' -or ($prev -and $prev.PSObject.Properties['ServiceMode'] -and $prev.ServiceMode -eq 'Delete')) { 'Delete' } else { 'Disable' })
        PowerProfile = $mPower; PauseDays = $mDays; SkipRegGroup = @($mSkip | Select-Object -Unique)
    })
    if ([Environment]::OSVersion.Version.Build -lt 19041) { Write-Log 'This script targets Windows 10 2004 (19041) or later. Behaviour on older builds is untested.' 'WARN' }
    $windows10 = Get-Windows10Notice
    if ($windows10) { Write-Log $windows10 'WARN' }
    if (-not $SkipRestorePoint -and -not $Ctx.DryRun) {
        $script:RestorePoint = $null
        Invoke-Step 'Restore point' { $script:RestorePoint = New-SafetyRestorePoint }
        $why = 'the restore point step failed'
        if ($script:RestorePoint) { $why = $script:RestorePoint.Reason }
        if (-not ($script:RestorePoint -and $script:RestorePoint.Created) -and -not (Confirm-NoRestorePoint -Reason $why)) {
            Write-Log 'Cancelled before any tweak: no restore point, and continuing without one was not confirmed.' 'WARN'
            Save-State
            Exit-Run 2 'No restore point, and continuing without one was not confirmed.'
        }
    }
    if ($Opt['DefenderQuiet'] -or $Defender -eq 'Disable') { Wait-TamperProtectionOff }
    Invoke-ApplySteps
}

function Invoke-ApplySteps {
    # Every change of a run, in order. -Reapply runs the same steps; see Invoke-Reapply.
    if ($Opt['Packages']) { Invoke-Step 'Packages' -Option 'Packages' { Install-RuntimePackages } }
    if ($WantNvidia) { Invoke-Step 'NVIDIA driver' { Install-NvidiaDriver } }
    if ($Opt['NvidiaProfile']) { Invoke-Step 'NVIDIA global profile' -Option 'NvidiaProfile' { Import-NvidiaSettings -Label 'base profile' -Settings $NvidiaBaseSettings } }
    if ($Opt['NvidiaReBar']) { Invoke-Step 'NVIDIA Resizable BAR' -Option 'NvidiaReBar' { Import-NvidiaSettings -Label 'Resizable BAR' -Settings $NvidiaReBarSettings } }
    if ($Opt['Debloat']) { Invoke-Step 'App debloat' -Option 'Debloat' { Remove-BloatApps } }
    if ($Opt['Debloat']) { Invoke-Step 'Block removed apps coming back' -Option 'Debloat' { Set-TweakList $DebloatRegs } }
    if ($Opt['PrivacyDenials']) { Invoke-Step 'Consent database reset' -Option 'PrivacyDenials' { Reset-ConsentDatabase } }
    if ($Opt['RemoveQuickAssist']) { Invoke-Step 'Remove Quick Assist' -Option 'RemoveQuickAssist' { Remove-QuickAssist } }
    if ($Opt['RemoveOneDrive']) { Invoke-Step 'Remove OneDrive' -Option 'RemoveOneDrive' { Remove-OneDrive } }
    if ($Opt['RemoveEdge']) { Invoke-Step 'Remove Edge' -Option 'RemoveEdge' { Remove-Edge } }
    if ($Opt['EdgeBackground']) { Invoke-Step 'Edge in the background' -Option 'EdgeBackground' { Set-TweakList $EdgeBackgroundRegs } }
    if ($Opt['WindowsAIOff']) { Invoke-Step 'Copilot and Windows AI' -Option 'WindowsAIOff' { Set-TweakList $WindowsAIRegs } }
    if ($Opt['TelemetryExtra']) { Invoke-Step 'More telemetry off' -Option 'TelemetryExtra' { Set-TweakList $TelemetryExtraRegs } }
    if ($Opt['BrowserPolicies']) { Invoke-Step 'Browser ads, telemetry and AI' -Option 'BrowserPolicies' { Set-TweakList $BrowserPolicyRegs } }
    if ($Opt['StartupDelayOff']) { Invoke-Step 'Startup delay' -Option 'StartupDelayOff' { Set-TweakList $StartupDelayRegs } }
    if ($Opt['MouseFullRateBackground']) { Invoke-Step 'Mouse rate in the background' -Option 'MouseFullRateBackground' { Set-TweakList $MouseFullRateRegs } }
    if ($Opt['NoDeviceEncryption']) { Invoke-Step 'Automatic device encryption' -Option 'NoDeviceEncryption' { Set-TweakList $NoDeviceEncryptionRegs } }
    if ($Opt['UpdateNoReboot']) { Invoke-Step 'Update restarts and early features' -Option 'UpdateNoReboot' { Set-TweakList $UpdateNoRebootRegs } }
    if ($Opt['StandbyNetworkOff']) { Invoke-Step 'Network in standby' -Option 'StandbyNetworkOff' { Set-TweakList $StandbyNetworkRegs } }
    foreach ($g in $FeatureGroups.Keys) { if ($Opt[$g]) { Invoke-Step "Optional features ($g)" -Option $g { Disable-FeatureGroup -Group $g } } }
    # Runs when any option that owns an upstream registry group is on, taken from the same mapping the import and the
    # health check use, so an option such as -Only NoAutoMaintenance cannot be left out of a hand-kept list.
    $regOps = ConvertFrom-RegText -Text $UpstreamRegText   # returned as one list object, so unroll it from a variable
    $regOwners = @($regOps | ForEach-Object { Get-RegOpOption $_ } | Select-Object -Unique)
    if (@($regOwners | Where-Object { $Opt[$_] }).Count -gt 0) { Invoke-Step 'Registry tweaks' { Import-UpstreamRegistry } }
    if ($Opt['Registry']) { Invoke-Step 'Last access time off (current Windows format)' -Option 'Registry' { Set-TweakList $LastAccessRegs } }
    if ($Opt['Uac']) { Invoke-Step 'LUA file virtualization' -Option 'Uac' { Set-ServiceStart -Name 'luafv' -Mode Disabled } }
    if ($Opt['TelemetryPolicy'] -or $Opt['BiometricsPolicy'] -or $Opt['Cdp'] -or $Opt['TelemetryHosts']) { Invoke-Step 'Telemetry' { Invoke-TelemetryTweaks } }
    if (@($ServiceGroups.Keys | Where-Object { $Opt[$_] }).Count -gt 0) { Invoke-Step 'Service groups' { Disable-ServiceGroups } }
    if ($Opt['VendorServices']) { Invoke-Step 'Vendor services' -Option 'VendorServices' { Set-VendorServices } }
    if ($TaskMode -ne 'None') { Invoke-Step "Scheduled tasks ($TaskMode)" -Option 'TaskMode' { Invoke-TaskMode } }
    if ($Opt['RazerAsusHosts']) { Invoke-Step 'Razer and ASUS hosts block' -Option 'RazerAsusHosts' { Set-RazerAsusBlock } }
    if ($Opt['DriverExclusion'] -or $Opt['SecurityUpdatesOnly'] -or $Opt['PauseUpdates']) { Invoke-Step 'Windows Update policy' { Set-UpdatePolicies } }
    if ($PowerProfile -ne 'Off') { Invoke-Step "Power plan ($PowerProfile)" -Option 'PowerProfile' { Set-PerformancePowerPlan } }
    if ($PowerMode -ne 'Keep') { Invoke-Step "Power mode ($PowerMode)" -Option 'PowerMode' { Set-PowerModeOverlay } }
    if ($Opt['DisableHibernate']) { Invoke-Step 'Disable hibernation' -Option 'DisableHibernate' { Disable-Hibernation } }
    if ($Opt['MouseAccel']) { Invoke-Step 'Mouse acceleration' -Option 'MouseAccel' { Disable-MouseAcceleration } }
    if ($Opt['MsiMode']) { Invoke-Step 'MSI mode' -Option 'MsiMode' { Set-MsiMode } }
    if ($Opt['MemoryCompression']) { Invoke-Step 'Memory compression' -Option 'MemoryCompression' { Disable-MemoryCompression } }
    if ($Opt['SleepStudy']) { Invoke-Step 'Sleep Study logs' -Option 'SleepStudy' { Disable-SleepStudy } }
    if ($Opt['PasswordExpiry']) { Invoke-Step 'Password expiry' -Option 'PasswordExpiry' { Set-PasswordExpiry } }
    if ($Opt['FaultTolerantHeap']) { Invoke-Step 'Fault tolerant heap' -Option 'FaultTolerantHeap' { Reset-FaultTolerantHeap } }
    if ($Opt['NotificationSettings']) { Invoke-Step 'App notification settings' -Option 'NotificationSettings' { Disable-NotificationSettings } }
    if ($Defender -eq 'Keep') { Write-Log 'Microsoft Defender left untouched.' } else { Invoke-Step "Defender ($Defender)" -Option 'Defender' { Set-DefenderState -Mode $Defender } }
    if ($Opt['DefenderQuiet']) { Invoke-Step 'Quiet Defender' -Option 'DefenderQuiet' { Set-DefenderQuiet } }
    if ($Opt['NetAdapterPower']) { Invoke-Step 'Network adapter power saving' -Option 'NetAdapterPower' { Set-NetAdapterOff -Label 'Network adapter power saving' -Keywords $NetPowerKeywords -AllowOff } }
    if ($Opt['NetAdapterEee']) { Invoke-Step 'Energy Efficient Ethernet' -Option 'NetAdapterEee' { Set-NetAdapterOff -Label 'Energy Efficient Ethernet' -Keywords $NetEeeKeywords } }
    if ($Opt['SpectreMeltdownOff']) { Invoke-Step 'Spectre and Meltdown mitigations' -Option 'SpectreMeltdownOff' { Disable-SpectreMeltdownMitigations } }
    if ($Opt['TimerResolution']) { Invoke-Step 'Timer resolution service' -Option 'TimerResolution' { Install-TimerResolutionService } }
    if ($Opt['DevicePowerSaving']) { Invoke-Step 'Device power saving' -Option 'DevicePowerSaving' { Set-DevicePowerSaving } }
    if ($Opt['DeviceWakeOff']) { Invoke-Step 'Device wake' -Option 'DeviceWakeOff' { Set-TweakListBatched -Label 'Device wake off' -Tweaks @(Get-DeviceTweaks -Wake) } }
    if ($Opt['WriteCacheFlushOff']) { Invoke-Step 'Write cache buffer flushing' -Option 'WriteCacheFlushOff' { Set-TweakListBatched -Label 'Write cache buffer flushing off' -Tweaks @(Get-WriteCacheTweaks) } }
    if ($Opt['MpoOff']) { Invoke-Step 'Multiplane overlay' -Option 'MpoOff' { Set-TweakList $MpoRegs } }
    if ($Opt['FastShutdown']) { Invoke-Step 'Faster shutdown' -Option 'FastShutdown' { Set-TweakList $FastShutdownRegs } }
    if ($Opt['BlockFeatureUpgrades']) { Invoke-Step 'Feature upgrade block' -Option 'BlockFeatureUpgrades' { Set-FeatureUpgradeBlock } }
    if ($Opt['SearchIndexingOff']) { Invoke-Step 'Search indexing' -Option 'SearchIndexingOff' { Set-ServiceStart -Name 'WSearch' -Mode Disabled } }
    if ($Opt['TimeServerPool']) { Invoke-Step 'Time server' -Option 'TimeServerPool' { Set-TimeServer } }
    if ($Opt['MenuKillNotResponding']) { Invoke-Step 'Kill not responding menu' -Option 'MenuKillNotResponding' { Set-TweakList $MenuKillRegs } }
    if ($Opt['MenuRestartExplorer']) { Invoke-Step 'Restart Explorer menu' -Option 'MenuRestartExplorer' { Set-TweakList $MenuRestartExplorerRegs } }
    if ($Opt['MenuTakeOwnership']) { Invoke-Step 'Take ownership menu' -Option 'MenuTakeOwnership' { Set-TweakList $MenuTakeOwnershipRegs } }
    if ($Opt['MenuRunAsAdmin']) { Invoke-Step 'Run as administrator menu' -Option 'MenuRunAsAdmin' { Set-TweakList $MenuRunAsAdminRegs } }
    $menus = @($MenuBlocks.Keys | Where-Object { $Opt[$_] })
    if ($menus.Count -gt 0) { Invoke-Step "Right click menu cleanup ($($menus -join ', '))" { foreach ($m in $menus) { Set-TweakList $MenuBlocks[$m] } } }
    if ($Opt['LockScreenOff']) { Invoke-Step 'Lock screen' -Option 'LockScreenOff' { Set-TweakList $LockScreenRegs } }
    if ($Opt['NvmeNativeDriver']) { Invoke-Step 'Native NVMe driver' -Option 'NvmeNativeDriver' { Set-NvmeNativeDriver } }
    if ($Opt['IPv4Only']) { Invoke-Step 'IPv4 only' -Option 'IPv4Only' { Set-IPv4Only } }
    if ($Opt['ClearDesktopIcons']) { Invoke-Step 'Clear desktop icons' -Option 'ClearDesktopIcons' { Clear-DesktopIcons } }
    if ($Opt['ClearStartPins']) { Invoke-Step 'Clear Start menu pins' -Option 'ClearStartPins' { Clear-StartPins } }
    if ($Opt['TempCleanup']) { Invoke-Step 'Temp cleanup' -Option 'TempCleanup' { Clear-TempFiles } }
    if ($Opt['UpdateCacheCleanup']) {
        Invoke-Step 'Update cache cleanup' -Option 'UpdateCacheCleanup' { Clear-UpdateDownloadCache }
        # Starting UsoSvc again registers its Schedule Scan tasks anew, so the pause would show active tasks.
        if ($Opt['PauseUpdates'] -and $Opt['PauseStopsUpdateTasks']) { Invoke-Step 'Disable update tasks re-registered by UsoSvc' -Option 'PauseStopsUpdateTasks' { Disable-UpdateTasks } }
    }
    if ($Opt['RestartExplorer'] -or $Ctx.ShellDirty) { Invoke-Step 'Refresh settings and restart Explorer' { Update-UserVisuals } }
    if ($Opt['HealthCheckAfter'] -and -not $Ctx.DryRun) {
        $Ctx.PostApply = $true
        Invoke-Step 'Health check' { Invoke-HealthCheck }
        # A run whose own health check fails must not end with "Finished without errors" and exit code 0.
        if ($script:Health.FAIL -gt 0) { $Ctx.Failures++; Write-Log "The health check after the run reported $($script:Health.FAIL) failure(s)." 'ERROR' }
    }
}

# Options -Reapply leaves alone: running them again would undo choices made since the run (startup entries, pins,
# desktop shortcuts, app permissions, installed software), or they are one shot actions (cleanup, heap reset, NVIDIA
# profile import). PauseStopsUpdateTasks: Windows turns those tasks back on at every start; NoAutoUpdate covers them.
$ReapplyLeavesAlone = @('Packages', 'RunKeys', 'ClearStartPins', 'ClearDesktopIcons', 'HideAllDesktopIcons', 'PrivacyDenials',
    'TempCleanup', 'UpdateCacheCleanup', 'EnableSystemRestore', 'FaultTolerantHeap', 'NvidiaProfile', 'NvidiaReBar',
    'NvidiaTelemetryStrip', 'PauseStopsUpdateTasks')

function Set-ReapplyOptions {
    # The options of the earlier run, minus those -Reapply leaves alone and those named with -Skip. Options this
    # version has that the run did not know stay off: they are new choices, not drift. Returns what was left out.
    param($Run, [string[]]$SkipNames = @())
    $saved = @($Run.Options.PSObject.Properties | ForEach-Object { $_.Name })
    $newOptions = @($OptionInfo.Keys | Where-Object { $saved -notcontains $_ })
    foreach ($k in @($OptionInfo.Keys)) { $Opt[$k] = $false }
    foreach ($p in $Run.Options.PSObject.Properties) { if ($Opt.ContainsKey($p.Name)) { $Opt[$p.Name] = [bool]$p.Value } }
    $left = @($ReapplyLeavesAlone | Where-Object { $Opt[$_] })
    foreach ($n in $left) { $Opt[$n] = $false }
    foreach ($name in @($SkipNames | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $match = $OptionInfo.Keys | Where-Object { $_ -ieq $name } | Select-Object -First 1
        if (-not $match) { throw "Unknown option '$name'. Run with -ListOptions to see the valid names." }
        $Opt[$match] = $false
    }
    return [pscustomobject]@{ LeftAlone = $left; New = $newOptions }
}

function Invoke-Reapply {
    # Big Windows updates set some values back, register removed tasks and services again and reinstall apps. This
    # runs the apply steps again in two passes: the first only lists what drifted (every primitive skips what is
    # still as the run left it), the second puts back just that, through the journal, so -Revert still restores the
    # originals of the first run. No restore point, no power plan, no Defender switch: those are not drift.
    $run = $script:State.Run
    if (-not $run) { Write-Log "No earlier run is recorded in $StateFile, so there is nothing to put back. Run the script normally first." 'WARN'; return }
    $sel = Set-ReapplyOptions -Run $run -SkipNames $Skip
    $script:TaskMode = if ($run.TaskMode) { [string]$run.TaskMode } else { 'None' }
    if ($script:TaskMode -eq 'Delete' -and @($script:State.Tasks).Count -eq 0) { $script:TaskMode = 'None' }
    $script:PowerProfile = 'Off'; $script:PowerMode = 'Keep'; $script:Defender = 'Keep'; $script:WantNvidia = $false
    # Runs from before ServiceMode was recorded: an exported service key means the services were deleted.
    $script:ServiceMode = 'Disable'
    if ($run.PSObject.Properties['ServiceMode'] -and $run.ServiceMode -eq 'Delete') { $script:ServiceMode = 'Delete' }
    elseif (@($script:State.KeyBackups | Where-Object { $_.Path -like "$ServicesRoot\*" }).Count -gt 0) { $script:ServiceMode = 'Delete' }
    if ($run.PauseDays) { $script:PauseDays = [int]$run.PauseDays }
    if ($run.SkipRegGroup) { $script:SkipRegGroup = @($run.SkipRegGroup) }
    Write-Log "Reapply: putting back what changed since the run on $($run.When)."
    if ($sel.LeftAlone.Count -gt 0) { Write-Log "  Left alone (running them again would undo choices made since, or they run once): $($sel.LeftAlone -join ', ')" }
    if ($sel.New.Count -gt 0) { Write-Log "  Options the earlier run did not have, not applied (run normally to add them): $($sel.New -join ', ')" }
    if (-not (Invoke-Preflight -Strict)) { Exit-Run 3 "Refused by the pre flight check(s) $(@($script:PreflightResults | Where-Object { $_.Status -eq 'BLOCK' } | ForEach-Object { $_.Check }) -join ', ')." }

    $realRun = -not $Ctx.DryRun
    $Ctx.Reapply = $true
    $Ctx.DryRun = $true
    $Ctx.DryRunCount = 0
    $healthAfter = $Opt['HealthCheckAfter']
    $Opt['HealthCheckAfter'] = $false
    Write-Log 'Pass 1: looking for settings that drifted. Nothing is changed in this pass; each DRY RUN line below is one drifted item.'
    Invoke-ApplySteps
    $drift = $Ctx.DryRunCount
    $Ctx.DryRun = -not $realRun
    $Opt['HealthCheckAfter'] = $healthAfter
    if ($drift -eq 0) { Write-Log 'Nothing drifted: everything the run set is still in place.' 'OK'; return }
    Write-Log "$drift item(s) drifted, listed above." 'WARN'
    if (-not $realRun) { return }
    if (-not $Force) {
        $answer = Read-Host "Put these $drift item(s) back? Type YES to continue"
        if ($answer -cne 'YES') { Write-Log 'Cancelled, nothing was changed.' 'WARN'; Exit-Run 2 'The reapply was not confirmed.' }
    }
    Write-Log 'Pass 2: putting the drifted items back.'
    Invoke-ApplySteps
    Save-State
}

# Updates that are not Windows itself: Defender definitions (daily) and platform, the malicious software removal tool.
$UpdateKbsNotWindows = @('KB2267602', 'KB4052623', 'KB890830')

function Test-WindowsUpdateMessage {
    # True for the installation event of a Windows update (it names a KB); Store apps and the KBs above do not count.
    param([string]$Message)
    $kbs = @([regex]::Matches($Message, 'KB\d{6,8}') | ForEach-Object { $_.Value.ToUpperInvariant() })
    if ($kbs.Count -eq 0) { return $false }
    return @($kbs | Where-Object { $UpdateKbsNotWindows -notcontains $_ }).Count -gt 0
}

function Get-LastUpdateInstall {
    # When Windows Update last installed a Windows update, from its own event (19, installation successful), or $null.
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19 } -MaxEvents 300 -ErrorAction SilentlyContinue)
    foreach ($e in $events) { if (Test-WindowsUpdateMessage $e.Message) { return $e.TimeCreated } }
    return $null
}

function Test-HealthDrift {
    # After a run, updates are what undoes tweaks. Point at -Reapply when one installed since and something drifted.
    if (-not $Ctx.AppliedAt) { return }
    $last = Get-LastUpdateInstall
    if (-not $last -or $last -le $Ctx.AppliedAt) { Write-Health 'PASS' 'Drift' 'No Windows update installed since the run.'; return }
    $msg = "Windows Update installed a Windows update on $($last.ToString('yyyy-MM-dd HH:mm')), after the run on $($Ctx.AppliedAt.ToString('yyyy-MM-dd HH:mm'))."
    if ($script:Health.WARN -gt 0 -or $script:Health.FAIL -gt 0) { Write-Health 'WARN' 'Drift' "$msg Updates can set tweaks back; run -Reapply -DryRun to list what changed, then -Reapply to put it back." }
    else { Write-Health 'INFO' 'Drift' "$msg Nothing above looks changed by it." }
}

# -Revert -Only: what the journal can undo per option. Registry values and keys, service start values and tasks carry
# the option that changed them; these other options keep their own records and are undone here as well.
$RevertOnlyExtra = @{ TelemetryHosts = 'Hosts'; RazerAsusHosts = 'Hosts'; TimerResolution = 'TimerService'; LegacyFeatures = 'Features'; HypervisorFeatures = 'Features'; PauseUpdates = 'PauseEndTask' }

function Get-OptionChanges {
    # From journal lines: the registry values, key exports and tasks that the named options changed. A value another
    # option changed as well is left out and listed as shared: undoing it would undo that option too.
    param([string[]]$Options, [object[]]$Lines)
    $owners = @{}
    $byTarget = [ordered]@{}
    foreach ($e in @($Lines | Where-Object { $_.Op -eq 'Change' -and $_.PSObject.Properties['Option'] -and $_.Option })) {
        $id = "$($e.Kind)|$($e.Target)"
        if (-not $owners.ContainsKey($id)) { $owners[$id] = @() }
        if ($owners[$id] -notcontains $e.Option) { $owners[$id] += $e.Option }
        if (($Options -contains $e.Option) -and -not $byTarget.Contains($id)) { $byTarget[$id] = $e }
    }
    $result = [pscustomobject]@{ Registry = @(); Keys = @(); Tasks = @(); Shared = @() }
    foreach ($id in $byTarget.Keys) {
        $e = $byTarget[$id]
        $others = @($owners[$id] | Where-Object { $Options -notcontains $_ })
        if ($others.Count -gt 0) { $result.Shared += "$($e.Target) (also set by $($others -join ', '))"; continue }
        switch ($e.Kind) {
            'Registry' { $result.Registry += [pscustomobject]@{ Path = $e.Before.Path; Name = $e.Before.Name } }
            'RegistryKey' { $result.Keys += [string]$e.Before }
            'Task' { $result.Tasks += $e.Before }
        }
    }
    return $result
}

function Invoke-RevertOptions {
    # Undoes only the named options, from the journal of the current cycle, and keeps everything else as it is.
    param([string[]]$Names)
    if (-not (Test-Path -LiteralPath $JournalFile)) { Write-Log "No change journal at $JournalFile, so single options cannot be undone. Use -Revert without -Only." 'WARN'; return }
    $options = @(foreach ($n in @($Names | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $m = @($OptionInfo.Keys | Where-Object { $_ -ieq $n })
            if ($m.Count -eq 0) { throw "Unknown option '$n'. Run with -ListOptions to see the valid names." }
            $m[0]
        })
    $lines = @(foreach ($text in [IO.File]::ReadAllLines($JournalFile)) { if ($text.Trim()) { try { $text | ConvertFrom-Json } catch { } } })
    $sel = Get-OptionChanges -Options $options -Lines $lines
    Write-Log "Undoing only: $($options -join ', ') ($($sel.Registry.Count) registry value(s), $($sel.Keys.Count) deleted key(s), $($sel.Tasks.Count) task(s))."
    Invoke-Step "Revert options ($($options -join ', '))" {
        foreach ($r in $sel.Registry) {
            $orig = @($script:State.Registry | Where-Object { $_.Path -ieq $r.Path -and $_.Name -eq $r.Name } | Select-Object -First 1)
            if ($orig.Count -gt 0) { Restore-RegValue -Entry $orig[0] }
        }
        foreach ($f in $sel.Keys) {
            if (-not (Test-Path -LiteralPath $f)) { Write-Log "Registry key backup $f is missing." 'WARN'; continue }
            $null = & cmd.exe /d /c "reg.exe import `"$f`" >nul 2>&1"
            if ($LASTEXITCODE -ne 0) { Write-Log "Could not import $f (reg.exe exit $LASTEXITCODE)" 'WARN' }
        }
        if ($sel.Tasks.Count -gt 0) { Restore-Tasks -Tasks $sel.Tasks }
        foreach ($o in $options) {
            switch ($RevertOnlyExtra[$o]) {
                'Hosts' {
                    $name = if ($o -eq 'TelemetryHosts') { 'telemetry' } else { 'razer-asus' }
                    Write-HostsFile -Text (Remove-HostsText -Text ([IO.File]::ReadAllText($HostsPath)) -Name $name)
                    Write-Log "Hosts block removed: $name" 'OK'
                }
                'TimerService' { if ($script:State.TimerService) { Remove-TimerResolutionService } }
                'PauseEndTask' { Remove-PauseEndTask }
                'Features' {
                    $f = @($script:State.Features | Where-Object { $FeatureGroups[$o] -contains $_ })
                    if ($f.Count -gt 0) { Set-FeatureState -Names $f -Enable $true }
                }
            }
        }
    }
    foreach ($s in $sel.Shared) { Write-Log "Kept, because another option you did not name set it too: $s" 'WARN' }
    $untracked = @($options | Where-Object { -not $RevertOnlyExtra.ContainsKey($_) -and $NotRevertedAlone -contains $_ })
    if ($untracked.Count -gt 0) { Write-Log "Not undone on their own (only the full -Revert, or nothing, undoes them): $($untracked -join ', ')." 'WARN' }
    # The health check must stop expecting what was undone; a later full -Revert still has every original.
    if ($script:State.Run) {
        $run = $script:State.Run
        foreach ($o in $options) { if ($run.Options.PSObject.Properties[$o]) { $run.Options.$o = $false } }
        Set-StateValue -Name 'Run' -Value $run
    }
    Save-State
    Write-Log 'Restart Windows so the restored services and policies take effect.'
}

# Options whose changes are not in the journal per option: power plan, Defender switches, app removal, cleanup and the
# like. -Revert -Only says so instead of pretending.
$NotRevertedAlone = @('Packages', 'Debloat', 'RemoveQuickAssist', 'RemoveOneDrive', 'RemoveEdge', 'NvidiaProfile', 'NvidiaReBar', 'NvidiaTelemetryStrip',
    'PrivacyDenials', 'DisableHibernate', 'MemoryCompression', 'SleepStudy', 'PasswordExpiry', 'FaultTolerantHeap', 'ClearDesktopIcons',
    'ClearStartPins', 'TempCleanup', 'UpdateCacheCleanup', 'EnableSystemRestore', 'IPv4Only', 'MouseAccel', 'RestartExplorer', 'HealthCheckAfter')

function Invoke-Revert {
    if (-not (Test-Path -LiteralPath $StateFile)) { Write-Log "No state file at $StateFile. Nothing to revert." 'WARN'; return }
    Write-Log 'Reverting recorded changes.'
    Invoke-Step 'Restore registry values' {
        # Newest first, so if one value was recorded twice (an older state file used other key spellings) the
        # earliest, original snapshot is written last and wins.
        $entries = @($script:State.Registry)
        [array]::Reverse($entries)
        foreach ($e in $entries) {
            try { Restore-RegValue -Entry $e }
            catch { $Ctx.Failures++; Write-Log "Could not restore $($e.Path)\$(Show-RegName $e.Name). $($_.Exception.Message)" 'ERROR' }
        }
    }
    if ($script:State.CreatedKeys.Count -gt 0) { Invoke-Step 'Remove registry keys created by the run' { Remove-CreatedKeys } }
    # A running Explorer keeps its own copy of these settings and saves it over the restored values (HideIcons came back
    # as 1 a minute after the restore, VM run of 14 Nov 2026). Stop it, write them again, and Windows starts it fresh.
    $explorerValues = @($script:State.Registry | Where-Object { $_.Path -like 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer*' })
    if ($explorerValues.Count -gt 0) { Invoke-Step 'Restart Explorer with the restored settings' { Restore-ExplorerValues -Entries $explorerValues } }
    if (@($script:State.Registry | Where-Object { $_.Path -like '*\Services\W32Time\Parameters' }).Count -gt 0) { Invoke-Step 'Apply the restored time server' { Update-TimeService } }
    Invoke-Step 'Restore deleted registry keys' { Restore-KeyBackups }
    Invoke-Step 'Restore hosts file' {
        foreach ($name in $script:State.Hosts) {
            Write-HostsFile -Text (Remove-HostsText -Text ([IO.File]::ReadAllText($HostsPath)) -Name $name)
            Write-Log "Hosts block removed: $name" 'OK'
        }
    }
    if ($script:State.Tasks.Count -gt 0) { Invoke-Step 'Restore scheduled tasks' { Restore-Tasks } }
    if ($script:State.Features.Count -gt 0) { Invoke-Step 'Restore optional features' { Restore-Features } }
    if ($script:State.NvidiaDrs -eq $true) { Invoke-Step 'Restore NVIDIA driver settings' { Restore-NvidiaDrs } }
    Invoke-Step 'Restore power plan' { Restore-PowerPlan }
    if ($script:State.PowerOverlay) { Invoke-Step 'Restore power mode' { Restore-PowerMode } }
    if ($script:State.Hibernate -eq $true) { Invoke-Step 'Restore hibernation' { powercfg /hibernate on | Out-Null; Write-Log 'Hibernation re-enabled.' 'OK' } }
    if ($script:State.MemCompress -eq $true) { Invoke-Step 'Restore memory compression' { Enable-MMAgent -MemoryCompression; Write-Log 'Memory compression re-enabled.' 'OK' } }
    if ($script:State.SleepStudy -ne $false) {
        Invoke-Step 'Restore Sleep Study logs' {
            # State from older runs only says $true (all were turned off); newer runs list the logs that were on.
            $logs = @($SleepStudyLogs)
            if ($script:State.SleepStudy -ne $true) { $logs = @($script:State.SleepStudy | Where-Object { $SleepStudyLogs -contains $_ }) }
            foreach ($log in $logs) {
                & wevtutil.exe sl $log /e:true | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Log "wevtutil could not turn $log back on ($LASTEXITCODE)." 'WARN' }
            }
            Write-Log "Sleep Study logs restored: $($logs.Count) turned back on." 'OK'
        }
    }
    if ($script:State.PwAge -ne $false) {
        Invoke-Step 'Restore password expiry' {
            # Older runs stored $true and no value: 42 days is the Windows default.
            $age = '42'
            if ($script:State.PwAge -ne $true) { $age = [string]$script:State.PwAge }
            if ($age -notmatch '^(\d{1,3}|unlimited)$') { throw "Saved password age '$age' is not valid, not restoring it." }
            & net.exe accounts "/maxpwage:$age" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "net accounts /maxpwage:$age failed ($LASTEXITCODE)." }
            Write-Log "Maximum password age set back to $age$(if ($age -ne 'unlimited') { ' days' })." 'OK'
        }
    }
    if ($script:State.ConsentDb) {
        Invoke-Step 'Restore consent database' {
            Stop-Service -Name camsvc -Force -ErrorAction SilentlyContinue
            Copy-Item -Path (Join-Path $script:State.ConsentDb '*') -Destination (Join-Path $env:ProgramData 'Microsoft\Windows\CapabilityAccessManager') -Force
        }
    }
    if ($script:State.Defender -eq $true) {
        Invoke-Step 'Restore Defender preferences' { Restore-DefenderPrefs }
    }
    if ($script:State.Dep) { Invoke-Step 'Restore Data Execution Prevention' { Restore-Dep } }
    if ($script:State.TimerService) { Invoke-Step 'Remove timer resolution service' { Remove-TimerResolutionService } }
    if ($script:State.PauseEndTask) { Invoke-Step 'Remove the task that ends the update pause' { Remove-PauseEndTask } }
    if ($script:State.NetBindings.Count -gt 0) { Invoke-Step 'Turn IPv6 back on' { Restore-NetBindings } }
    if ($script:State.StartLayout) { Invoke-Step 'Restore Start menu layout' { Restore-StartPins } }
    if ($script:State.DesktopMoved.Count -gt 0) { Invoke-Step 'Restore desktop shortcuts' { Restore-DesktopIcons } }
    if (@($script:State.Registry | Where-Object { $_.Path -like '*Control Panel\Mouse' }).Count -gt 0) { Invoke-Step 'Refresh mouse settings' { Sync-MouseSettings } }
    if ($script:State.Removed.Count -gt 0) {
        Write-Log ('Apps removed earlier (reinstall from the Store or winget if wanted): ' + (($script:State.Removed | Sort-Object -Unique) -join ', ')) 'WARN'
    }
    if ($Ctx.ShellDirty) { Update-UserVisuals }
    Invoke-Step 'Revert check' { Test-RevertResult }
    $archive = Join-Path $StateDir ('state.reverted-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    Move-Item -LiteralPath $StateFile -Destination $archive -Force
    # The journal belongs to the cycle just reverted; the next run starts a new one.
    if (Test-Path -LiteralPath $JournalFile) { Move-Item -LiteralPath $JournalFile -Destination ($archive -replace 'state\.reverted-', 'journal.reverted-' -replace '\.json$', '.jsonl') -Force }
    # The .bak belongs to the cycle just reverted; a later run must never fall back to it.
    Remove-Item -LiteralPath "$StateFile.bak" -Force -ErrorAction SilentlyContinue
    Write-Log "State archived to $archive"
}
#endregion

