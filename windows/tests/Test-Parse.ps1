<#
Static checks for FocusedTweaks.ps1. No admin rights needed and nothing is left changed on the machine: the tests
work in temp folders and in a scratch key under HKCU\Software\FocusedTweaksTest-<id>, and remove both again.
Run:  powershell -ExecutionPolicy Bypass -File tests\Test-Parse.ps1
Exit code 1 if any check fails.
#>
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "[FAIL] $Name $Detail" -ForegroundColor Red }
}

$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'FocusedTweaks.ps1'
$errs = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
Check 'Script parses without errors' ($errs.Count -eq 0) ($errs | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } | Out-String)
if ($errs.Count -gt 0) { exit 1 }

$fns = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
Check 'Functions found' ($fns.Count -gt 50) "found $($fns.Count)"

$badVars = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $args[0].Left.VariablePath.UserPath -in @('profile', 'args', 'input', 'matches', 'error', 'host', 'home', 'pid', 'pwd') }, $true))
Check 'No assignments to automatic variables' ($badVars.Count -eq 0)

$bytes = [IO.File]::ReadAllBytes($path)
Check 'UTF-8 BOM present' ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$nonAscii = 0; for ($i = 3; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $nonAscii++ } }
Check 'ASCII only after the BOM' ($nonAscii -eq 0) "$nonAscii non ASCII bytes"
$text = [Text.Encoding]::UTF8.GetString($bytes)
Check 'CRLF line endings only' (($text -replace "`r`n", '') -notmatch "`n")
Check 'No state entry named Keys (shadows the hashtable property)' ($text -notmatch '\$script:State\.Keys\b')

# Load the data blocks and the pure helper functions, then test them
$wantedFns = 'Split-RegPath', 'Open-RegKey', 'Get-RegSnapshot', 'Write-RegRaw', 'Remove-RegKey', 'ConvertTo-StoredRecord', 'ConvertFrom-StoredRecord', 'Add-StateItem', 'Invoke-JournalEvent', 'Add-JournalEvents', 'Set-StateValue', 'Add-StateRecord', 'New-ChangeResult', 'Import-Journal', 'Undo-CreatedKey', 'Test-RollbackSafe', 'Undo-FailedStep', 'Invoke-Step', 'Get-MissingKeyEvents', 'New-RegChangeEvents', 'Format-RegIntent', 'Complete-RegChange', 'Remove-CreatedKeys', 'Set-RegValue', 'Remove-RegValueRaw', 'Remove-RegValue', 'Restore-RegValue', 'Restore-KeyBackups', 'Test-RegValueNow', 'Format-RegValueShort', 'Show-RegName', 'Get-TaskRecord', 'Save-DefenderPrefs', 'Restore-DefenderPrefs', 'Test-AccessDenied', 'Save-State', 'Read-StateFile', 'Import-State', 'Import-RunProfile', 'Resolve-Options', 'Get-Windows10Notice', 'Get-EditionVerdict', 'Get-PolicyTweaks', 'Get-EditionReport', 'Test-ServiceStartChanged', 'Test-RecordedFirst', 'ConvertTo-PsLiteral','Test-ProtectedPath','Test-ReparsePoint', 'Get-CleanupTree', 'Remove-CleanupEntry', 'Clear-FolderContents', 'Test-DryRun','New-Tweak','ConvertFrom-RegHex', 'ConvertFrom-RegText', 'Get-RegGroupOption', 'Get-RegOpOption', 'Test-NameMatch', 'ConvertTo-FullRegPath', 'ConvertTo-StoredValue', 'ConvertFrom-StoredValue', 'Format-TiRegAdd', 'Get-GuidFromText', 'Remove-HostsText'
foreach ($n in $wantedFns) { $f = $fns | Where-Object { $_.Name -eq $n } | Select-Object -First 1; . ([scriptblock]::Create($f.Extent.Text)) }
$wantedVars = '$StateVersion', '$script:Hives', '$UpstreamRegText', '$EditionRules', '$EditionFullPolicy', '$BiometricsRegs', '$TelemetryRegs', '$ServiceGroups', '$TelemetryDomains', '$RazerDomains', '$AsusDomains', '$MouseProfiles', '$DriverExclusionRegs', '$SecurityUpdatesRegs', '$PauseRegs', '$UpdateClassifications', '$OptionInfo', '$AppsToRemove', '$KeepApps', '$EmptyStartLayout', '$PowerProfiles', '$UsbSuspendGuid', '$DefenderQuietRegs', '$MitigationRegs', '$TimerGlobalRegs', '$TimerServiceSource', '$NetPowerKeywords', '$NetEeeKeywords', '$DeviceEnumRoots', '$DevicePowerValues', '$MpoRegs', '$FastShutdownRegs', '$TimeServerRegs', '$MenuKillRegs', '$MenuRestartExplorerRegs', '$TakeOwnFile', '$TakeOwnDir', '$MenuTakeOwnershipRegs', '$PowerOverlayNames', '$KnownStuckValues', '$LockScreenRegs', '$BlockedExt', '$MenuBlocks', '$MenuRunAsAdminRegs', '$NvmeRegs', '$TaskKeepBuiltIn', '$FeatureGroups'
$assigns = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -in $wantedVars }, $true)
foreach ($a in $assigns) { Invoke-Expression $a.Extent.Text }

$ops = ConvertFrom-RegText -Text $UpstreamRegText
$src = ($UpstreamRegText -replace "`r", '') -split "`n"
$valueLines = @($src | Where-Object { $_ -match '^(?:"(?:[^"\\]|\\.)*"|@)=' }).Count
Check 'Registry parser: every value line becomes an operation' (@($ops | Where-Object { $_.Action -ne 'DeleteKey' }).Count -eq $valueLines)
Check 'Registry parser: every key deletion is kept' (@($ops | Where-Object { $_.Action -eq 'DeleteKey' }).Count -eq @($src | Where-Object { $_ -match '^\[-' }).Count)
Check 'Registry parser: no Set operation without a type' (@($ops | Where-Object { $_.Action -eq 'Set' -and -not $_.Type }).Count -eq 0)
Check 'Excluded by default: core isolation, lock, sleep, hibernate groups map to their own options' ((Get-RegGroupOption 'Disable core isolation (VBS)') -eq 'CoreIsolation' -and (Get-RegGroupOption 'Disable lock') -eq 'HideLockOption' -and (Get-RegGroupOption 'Disable sleep') -eq 'HideSleepOption' -and (Get-RegGroupOption 'Disable hibernate') -eq 'RegHibernateOff')

$conflicts = @(); foreach ($g in $ServiceGroups.Keys) { if (-not $OptionInfo.Contains($g)) { $conflicts += $g } }
Check 'Every service group has an option' ($conflicts.Count -eq 0) ($conflicts -join ', ')
Check 'Bluetooth, printing and radio services are kept by default' (-not $OptionInfo['SvcBluetooth'][0] -and -not $OptionInfo['SvcPrinting'][0] -and -not $OptionInfo['SvcRadio'][0])
Check 'Delivery Optimization and core isolation are disabled by default (maximum performance)' ($OptionInfo['SvcDeliveryOpt'][0] -and $OptionInfo['CoreIsolation'][0])
Check 'Hard floor: SSD retrim, automatic maintenance and display scaling are left alone by default' (-not $OptionInfo['SvcDefrag'][0] -and -not $OptionInfo['NoAutoMaintenance'][0] -and -not $OptionInfo['ForceDpi100'][0])
Check 'Hard floor: DPI and maintenance groups map to their own options' ((Get-RegGroupOption '100% DPI scaling') -eq 'ForceDpi100' -and (Get-RegGroupOption 'Disable fix scaling for apps') -eq 'ForceDpi100' -and (Get-RegGroupOption 'Disable automatic maintenance') -eq 'NoAutoMaintenance')
$owned = @{ 'Turn off enhance pointer precision' = 'MouseAccel'; 'Disable notifications' = 'NotificationSettings'; 'Disable sleep study' = 'SleepStudy'; 'Disable background apps global' = 'PrivacyDenials'; 'Disable fault tolerant heap' = 'FaultTolerantHeap'; 'Disable delivery optimization' = 'SvcDeliveryOpt' }
$wrong = @($owned.Keys | Where-Object { (Get-RegGroupOption $_) -ne $owned[$_] })
$missingGroups = @($owned.Keys | Where-Object { $UpstreamRegText -notmatch ('(?m)^; ' + [regex]::Escape($_) + '\s*$') })
Check 'Upstream groups that duplicate an option belong to that option' ($wrong.Count -eq 0 -and $missingGroups.Count -eq 0) (@($wrong) + @($missingGroups) -join ', ')
$featureConflicts = @($FeatureGroups.Keys | Where-Object { -not $OptionInfo.Contains($_) })
Check 'Feature groups have options; hypervisor features are kept by default, legacy ones removed' ($featureConflicts.Count -eq 0 -and $OptionInfo['LegacyFeatures'][0] -and -not $OptionInfo['HypervisorFeatures'][0]) ($featureConflicts -join ', ')
Check 'Hard floor: time sync, Defrag, TPM and BitLocker tasks are never deleted' ((Test-NameMatch '\Microsoft\Windows\Time Synchronization\SynchronizeTime' $TaskKeepBuiltIn) -and (Test-NameMatch '\Microsoft\Windows\Defrag\ScheduledDefrag' $TaskKeepBuiltIn) -and (Test-NameMatch '\Microsoft\Windows\TPM\Tpm-Maintenance' $TaskKeepBuiltIn) -and (Test-NameMatch '\Microsoft\Windows\BitLocker\BitLocker MDM policy Refresh' $TaskKeepBuiltIn))
# A-14: the -RestoreTask examples must name tasks a run can delete or disable, never a path on the keep list.
$readmeText = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'README.md'))
$restoreExamples = @([regex]::Matches($text + $readmeText, "-RestoreTask '+(\\[^'\r\n]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$keptExamples = @($restoreExamples | Where-Object { Test-NameMatch ($_ -replace '\*', 'AnyTask') $TaskKeepBuiltIn })
Check 'The -RestoreTask examples (help, -ListOptions hint, README) are not on the built-in keep list' ($restoreExamples.Count -ge 1 -and $keptExamples.Count -eq 0) ("found $($restoreExamples.Count); kept: $($keptExamples -join ', ')")
$mustKeep = 'Microsoft.WindowsStore', 'Microsoft.XboxGamingOverlay', 'Microsoft.GamingApp', 'Microsoft.MicrosoftEdge.Stable', 'Microsoft.Paint', 'Microsoft.Windows.Photos', 'Microsoft.WindowsCalculator', 'Microsoft.DesktopAppInstaller'
$unprotected = @($mustKeep | Where-Object { -not (Test-NameMatch $_ $KeepApps) })
Check 'Apps you wanted kept are on the keep list' ($unprotected.Count -eq 0) ($unprotected -join ', ')
$wouldRemove = @($mustKeep | Where-Object { (Test-NameMatch $_ $AppsToRemove) -and -not (Test-NameMatch $_ $KeepApps) })
Check 'None of those apps can be removed' ($wouldRemove.Count -eq 0)
Check 'USB selective suspend uses the corrected GUID' ($UsbSuspendGuid -eq '48e6b7a6-50f5-4782-a5d4-53bb8f07e226')
Check 'Mouse profiles cover 100 to 225 percent scaling' (@($MouseProfiles.Keys).Count -eq 6)
Check 'Start layout blob decodes' (([Convert]::FromBase64String(($EmptyStartLayout -join ''))).Length -gt 1000)
Check 'Binary registry values survive a round trip' ((ConvertFrom-StoredValue -Value (ConvertTo-StoredValue -Value ([byte[]](1, 171, 255)) -Kind Binary) -Kind Binary) -join ',' -eq '1,171,255')
$endTask = @($ops | Where-Object { $_.Name -eq 'TaskbarEndTask' })
Check 'End task registry value maps to its own option, on by default' ($endTask.Count -eq 1 -and (Get-RegGroupOption $endTask[0].Group) -eq 'TaskbarEndTask' -and $OptionInfo['TaskbarEndTask'][0])
foreach ($o in 'SpectreMeltdownOff', 'TimerResolution', 'FastShutdown', 'SearchIndexingOff') { Check "$o is on by default (maximum performance)" ($OptionInfo.Contains($o) -and $OptionInfo[$o][0]) }
Check 'DepOff is off by default (needs Secure Boot off)' (-not $OptionInfo['DepOff'][0])
foreach ($o in 'DefenderQuiet', 'NetAdapterPower', 'NetAdapterEee', 'TempCleanup', 'UpdateCacheCleanup') { Check "$o exists and is on by default" ($OptionInfo.Contains($o) -and $OptionInfo[$o][0]) }
Check 'Quiet Defender sets 6 policy values and never turns protection off' (@($DefenderQuietRegs).Count -eq 6 -and @($DefenderQuietRegs | Where-Object { $_.Name -like 'Disable*Protection*' -or $_.Name -like 'DisableRealtime*' -or $_.Name -eq 'DisableAntiSpyware' }).Count -eq 0)
Check 'Mitigation values are 3 and 3' (@($MitigationRegs | Where-Object { $_.Value -ne 3 }).Count -eq 0 -and @($MitigationRegs).Count -eq 2)
Check 'Timer service source is ASCII and names the service' (($TimerServiceSource -cmatch '^[\x00-\x7F]*$') -and $TimerServiceSource.Contains('"FocusedTimerResolution"'))
Check 'EEE and power keyword lists do not overlap' (@($NetEeeKeywords | Where-Object { $NetPowerKeywords -contains $_ }).Count -eq 0)
foreach ($o in 'DevicePowerSaving', 'TimeServerPool', 'MenuKillNotResponding', 'MenuRestartExplorer') { Check "$o exists and is on by default" ($OptionInfo.Contains($o) -and $OptionInfo[$o][0]) }
foreach ($o in 'DeviceWakeOff', 'MpoOff', 'WriteCacheFlushOff', 'BlockFeatureUpgrades', 'MenuTakeOwnership') { Check "$o exists and is off by default" ($OptionInfo.Contains($o) -and -not $OptionInfo[$o][0]) }

# Every option the code reads exists, and every option exists for a reason.
$used = @([regex]::Matches($text, "\`$Opt\['([A-Za-z0-9]+)'\]") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$unknown = @($used | Where-Object { -not $OptionInfo.Contains($_) })
Check 'Every option the code reads is defined' ($unknown.Count -eq 0) ($unknown -join ', ')
# Options that own an upstream registry group are used through the mapping, not through a literal $Opt['Name'].
$regOps = ConvertFrom-RegText -Text $UpstreamRegText
$regOwners = @($regOps | ForEach-Object { Get-RegOpOption $_ } | Select-Object -Unique)
$unused = @($OptionInfo.Keys | Where-Object { $used -notcontains $_ -and -not $ServiceGroups.Contains($_) -and -not $FeatureGroups.Contains($_) -and -not $MenuBlocks.Contains($_) -and $regOwners -notcontains $_ })
Check 'The registry import is started from the option mapping' ($text -match '\$regOwners = @\(\$regOps \| ForEach-Object \{ Get-RegOpOption') ''
Check 'The mapping finds the owners it should (NoAutoMaintenance, ForceDpi100, CoreIsolation, TaskbarEndTask)' (@('NoAutoMaintenance', 'ForceDpi100', 'CoreIsolation', 'TaskbarEndTask' | Where-Object { $regOwners -notcontains $_ }).Count -eq 0) ($regOwners -join ', ')
Check 'Every defined option is used' ($unused.Count -eq 0) ($unused -join ', ')

Check 'Registry paths in ControlSet001 are written to CurrentControlSet' ((ConvertTo-FullRegPath 'HKLM\SYSTEM\ControlSet001\Services\X') -eq 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\X')
$diag = @($TelemetryRegs | Where-Object { $_.Path -like '*Diagtrack-Listener' -and $_.Name -eq 'Start' })
Check 'The protected Diagtrack value is recognised after path normalisation' ($diag.Count -eq 1 -and $KnownStuckValues -contains ((ConvertTo-FullRegPath $diag[0].Path) + '|Start'))
Check 'Device power values are DWord 0 or a single zero byte' (@($DevicePowerValues | Where-Object { -not (($_.Type -eq 'DWord' -and $_.Value -eq 0) -or ($_.Type -eq 'Binary' -and (@($_.Value) -join ',') -eq '0')) }).Count -eq 0)
Check 'Right click menu entries have a command' ((@($MenuKillRegs | Where-Object { $_.Path -like '*\command' -and $_.Name -eq '' }).Count -eq 1) -and (@($MenuRestartExplorerRegs | Where-Object { $_.Path -like '*\command' -and $_.Name -eq '' }).Count -eq 1))
$menuBad = @($MenuBlocks.Keys | Where-Object { -not $OptionInfo.Contains($_) -or $OptionInfo[$_][0] })
Check 'Every right click menu cleanup is an option, off by default' ($menuBad.Count -eq 0) ($menuBad -join ', ')
$blocked = @($MenuBlocks.Values | ForEach-Object { $_ } | Where-Object { $_.Path -like '*Shell Extensions\Blocked' })
Check 'Blocked shell extensions are named by a CLSID' (@($blocked | Where-Object { $_.Name -notmatch '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$' }).Count -eq 0)
foreach ($o in 'MenuRunAsAdmin', 'LockScreenOff', 'IPv4Only', 'NvmeNativeDriver') { Check "$o exists and is off by default" ($OptionInfo.Contains($o) -and -not $OptionInfo[$o][0]) }
Check 'Run as administrator commands keep the file argument' (@($MenuRunAsAdminRegs | Where-Object { $_.Path -like '*\command' -and $_.Value -notmatch '%1' }).Count -eq 0)
Check 'Native NVMe driver sets 4 overrides and both Safe Mode entries' (@($NvmeRegs | Where-Object { $_.Path -like '*Overrides' }).Count -eq 4 -and @($NvmeRegs | Where-Object { $_.Path -like '*SafeBoot*' }).Count -eq 2)
Check 'Power mode names cover the default overlay' ($PowerOverlayNames['00000000-0000-0000-0000-000000000000'] -eq 'OVERLAY_SCHEME_NONE')

# Profiles: values are applied, the command line wins, unknown or invalid settings are refused.
$profileFile = Join-Path ([IO.Path]::GetTempPath()) ('ft-profile-' + [guid]::NewGuid().ToString('N') + '.json')
Set-Content -LiteralPath $profileFile -Value '{ "Enable": ["MpoOff","TimerResolution"], "TaskMode": "Disable", "PauseDays": 30 }'
$ProfilePath = $profileFile; $BoundNames = @('PauseDays'); $Enable = @(); $TaskMode = 'Delete'; $PauseDays = 365
Import-RunProfile
Check 'Profile sets lists and choices' ((@($Enable) -join ',') -eq 'MpoOff,TimerResolution' -and $TaskMode -eq 'Disable')
Check 'Command line wins over the profile' ($PauseDays -eq 365)
Set-Content -LiteralPath $profileFile -Value '{ "Bogus": 1 }'
$threw = $false; try { Import-RunProfile } catch { $threw = $true }
Check 'Profile refuses unknown settings' $threw
Set-Content -LiteralPath $profileFile -Value '{ "TaskMode": "Nuke" }'
$BoundNames = @(); $threw = $false; try { Import-RunProfile } catch { $threw = $true }
Check 'Profile refuses invalid choices' $threw
Remove-Item -LiteralPath $profileFile -Force
foreach ($file in @(Get-ChildItem -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'profiles\*.json'))) {
    $ProfilePath = $file.FullName; $BoundNames = @(); $Enable = @(); $Skip = @(); $Only = @(); $threw = ''
    try { Import-RunProfile } catch { $threw = $_.Exception.Message }
    $badNames = @(@($Enable) + @($Skip) + @($Only) | Where-Object { $_ -and -not $OptionInfo.Contains($_) })
    Check "Profile $($file.Name) loads and names real options" (-not $threw -and $badNames.Count -eq 0) "$threw $($badNames -join ', ')"
}

# A-15: option lists work as an array (typed at the prompt) and as one comma separated string (powershell -File).
function Get-ResolvedOptions([string[]]$EnableList, [string[]]$SkipList, [string[]]$OnlyList = @()) {
    $script:Opt = @{}; foreach ($k in $OptionInfo.Keys) { $script:Opt[$k] = [bool]$OptionInfo[$k][0] }
    $script:Enable = $EnableList; $script:Skip = $SkipList; $script:Only = $OnlyList
    $script:CommandLineNames = @('Enable', 'Skip', 'Only'); $script:ProfileNames = @()
    Resolve-Options
    return (@($OptionInfo.Keys | Where-Object { $script:Opt[$_] } | Sort-Object) -join ',')
}
$asArray = Get-ResolvedOptions @('MpoOff', 'DepOff') @('Packages', 'Debloat')
$asString = Get-ResolvedOptions @('MpoOff, DepOff') @('Packages,Debloat')
Check 'Option lists: an array and a comma separated string give the same options' ($asArray -eq $asString -and $asArray -match '\bMpoOff\b' -and $asArray -match '\bDepOff\b' -and $asArray -notmatch '\bPackages\b' -and $asArray -notmatch '\bDebloat\b')
Check 'Option lists: -Only accepts a comma separated string' ((Get-ResolvedOptions @() @() @('MpoOff,DepOff')) -eq 'DepOff,MpoOff')
$threw = $false; try { [void](Get-ResolvedOptions @('MpoOff,NoSuchOption') @()) } catch { $threw = $true }
Check 'Option lists: an unknown name inside a comma list is refused' $threw

# A-16: Windows 10 gets the ESU notice, Windows 11 does not, and the run logs it.
$w10 = Get-Windows10Notice -Build 19045
Check 'Windows 10 notice names ESU, 12 October 2027 and the two update options' ($w10 -match 'ESU' -and $w10 -match '12 October 2027' -and $w10 -match 'PauseUpdates' -and $w10 -match 'SecurityUpdatesOnly')
Check 'Windows 11 gets no Windows 10 notice' ($null -eq (Get-Windows10Notice -Build 22000) -and $null -eq (Get-Windows10Notice -Build 26200))
Check 'The run logs the Windows 10 notice' ($text -match '\$windows10 = Get-Windows10Notice\r\n\s+if \(\$windows10\) \{ Write-Log \$windows10 ''WARN'' \}')

# A-09: edition awareness. Home is every Core* edition; values without a documented rule are 'unknown', never guessed.
$dc = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
$wu = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$verdict = { param($e, $p, $n, $v) (Get-EditionVerdict -Edition $e -Full $p -Name $n -Value $v).Verdict }
Check 'Edition: telemetry level 0 is not applicable on Home and Pro, applies on Enterprise' ((& $verdict 'Core' $dc 'AllowTelemetry' 0) -eq 'not applicable' -and (& $verdict 'Professional' $dc 'AllowTelemetry' 0) -eq 'not applicable' -and (& $verdict 'Enterprise' $dc 'AllowTelemetry' 0) -eq 'applies')
Check 'Edition: every Home edition ID is matched (Core*)' (@('Core', 'CoreN', 'CoreSingleLanguage', 'CoreCountrySpecific' | Where-Object { (& $verdict $_ $wu 'DeferQualityUpdates' 1) -ne 'not applicable' }).Count -eq 0)
Check 'Edition: update deferral applies on Pro' ((& $verdict 'Professional' $wu 'DeferQualityUpdates' 1) -eq 'applies')
Check 'Edition: a policy value without a rule is unknown on Home and Pro, never guessed' ((& $verdict 'Core' $wu 'SetAllowOptionalContent' 0) -eq 'unknown' -and (& $verdict 'Professional' $wu 'SetAllowOptionalContent' 0) -eq 'unknown' -and (& $verdict 'ProfessionalEducation' $dc 'AllowTelemetry' 0) -eq 'unknown')
Check 'Edition: values outside a Policies key are not judged' ((& $verdict 'Core' 'HKEY_CURRENT_USER\Control Panel\Mouse' 'MouseSpeed' '0') -eq 'applies')
$script:Opt = @{}; foreach ($k in $OptionInfo.Keys) { $script:Opt[$k] = $true }
$SkipRegGroup = @(); $script:Opt['BlockFeatureUpgrades'] = $false   # that option reads the live Windows version
$homeGaps = @(Get-EditionReport -Edition 'CoreSingleLanguage')
$homeIgnored = @($homeGaps | Where-Object { $_.Verdict -eq 'not applicable' } | ForEach-Object { $_.Name } | Sort-Object -Unique)
Check 'Edition report on Home lists the telemetry level and the update deferrals as not applicable' ($homeIgnored -contains 'AllowTelemetry' -and $homeIgnored -contains 'DeferFeatureUpdatesPeriodInDays' -and $homeIgnored -contains 'DeferQualityUpdates' -and @($homeGaps | Where-Object { -not $_.Honoured -and $_.Verdict -eq 'not applicable' }).Count -eq 0) ($homeIgnored -join ', ')
Check 'Edition report on Enterprise is empty' (@(Get-EditionReport -Edition 'Enterprise').Count -eq 0)
foreach ($k in $OptionInfo.Keys) { $script:Opt[$k] = $false }
Check 'Edition report is empty when no option writes a policy value' (@(Get-EditionReport -Edition 'Core').Count -eq 0)
Check 'Edition gaps are reported in the plan, the run log and the health check' ($text -match 'Not applicable on this edition: ' -and $text -match 'are not applicable on this edition, so Windows ignores them' -and $text -match "Invoke-HealthArea 'Edition' \{ Test-HealthEdition \}" -and $text -notmatch "EditionID -eq 'Core'")

# A-05: the state file is replaced atomically, the version before it is kept, and an unreadable file is handled.
$stateInit = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$script:State' }, $true))[0].Extent.Text
function Reset-TestState {
    Invoke-Expression $stateInit
    $script:RecordedReg = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $script:LogLines = [System.Collections.Generic.List[string]]::new()
    $script:JournalSeq = 0; $script:StepId = 0; $script:StepName = ''; $script:JournalOption = ''; $script:StopRun = $false
    $script:StepEvents = [System.Collections.Generic.List[object]]::new()
    $script:Failures = 0
}
function Get-JournalLines { @(Get-Content -LiteralPath $JournalFile -ErrorAction SilentlyContinue | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
function Write-Log { param([string]$Message, [string]$Level = 'INFO') $script:LogLines.Add("[$Level] $Message") }
$script:DryRun = $false
$StateDir = Join-Path ([IO.Path]::GetTempPath()) ('ft-state-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$StateFile = Join-Path $StateDir 'state.json'
$JournalFile = Join-Path $StateDir 'journal.jsonl'
$record = { param($n) [pscustomobject]@{ Path = 'HKEY_CURRENT_USER\Software\X'; Name = $n; Existed = $true; Kind = 'DWord'; Value = 1 } }
Reset-TestState
$script:State.Registry.Add((& $record 'One')); Save-State
Check 'State: the first save writes state.json and leaves no temporary or backup file' ((Test-Path -LiteralPath $StateFile) -and -not (Test-Path -LiteralPath "$StateFile.tmp") -and -not (Test-Path -LiteralPath "$StateFile.bak"))
$script:State.Registry.Add((& $record 'Two')); Save-State
$bakCount = @((Get-Content -LiteralPath "$StateFile.bak" -Raw | ConvertFrom-Json).Registry).Count
Check 'State: a later save keeps the version before it as state.json.bak' ($bakCount -eq 1 -and @((Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).Registry).Count -eq 2 -and -not (Test-Path -LiteralPath "$StateFile.tmp"))
$full = [IO.File]::ReadAllText($StateFile)
[IO.File]::WriteAllText($StateFile, $full.Substring(0, [int]($full.Length / 2)))   # what a crash during an in-place write left behind
Reset-TestState; Import-State
Check 'State: a truncated state.json falls back to state.json.bak and says so' ($script:State.Registry.Count -eq 1 -and $script:State.Registry[0].Name -eq 'One' -and @($script:LogLines | Where-Object { $_ -like '`[WARN`]*previous version*' }).Count -eq 1)
[IO.File]::WriteAllText("$StateFile.bak", '{ "Registry": [')
Reset-TestState; $message = ''
try { Import-State } catch { $message = $_.Exception.Message }
Check 'State: when neither file can be read the error is one clear sentence' ($message -like 'The saved state in * cannot be read*' -and $message -match 'state\.json:' -and $message -match 'state\.json\.bak:' -and $script:State.Registry.Count -eq 0)
Check 'State: an unreadable state stops every mode with exit code 4 before anything changes' ($text -match "try \{ Import-State \}\r\ncatch \{ Write-Log \`$_\.Exception\.Message 'ERROR'; exit 4 \}")
Check 'State: -Revert removes the backup of the cycle it reverted' ($text -match 'Remove-Item -LiteralPath "\$StateFile\.bak" -Force')
Remove-Item -LiteralPath $StateDir -Recurse -Force

# A-19 and the journal (A-01, A-02, A-04, A-06, A-11, A-17), against a scratch key under HKCU that is removed at the end.
$scratch = 'HKEY_CURRENT_USER\Software\FocusedTweaksTest-' + [guid]::NewGuid().ToString('N')
$StateDir = Join-Path ([IO.Path]::GetTempPath()) ('ft-state-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$StateFile = Join-Path $StateDir 'state.json'
$JournalFile = Join-Path $StateDir 'journal.jsonl'
$realWriteRegRaw = ($fns | Where-Object { $_.Name -eq 'Write-RegRaw' } | Select-Object -First 1).Extent.Text
Reset-TestState
try {
    # First original kept: the value was 1 before the run, two writes later the record still says 1.
    Write-RegRaw -Full $scratch -Name 'V' -Value 1 -Kind 'DWord'
    Set-RegValue -Path $scratch -Name 'V' -Value 2
    Set-RegValue -Path $scratch -Name 'V' -Value 3
    Check 'Journal: a second write of a value keeps the first original' (@($script:State.Registry | Where-Object { $_.Name -eq 'V' }).Count -eq 1 -and [int]@($script:State.Registry | Where-Object { $_.Name -eq 'V' })[0].Value -eq 1 -and $script:Failures -eq 0)
    $lines = Get-JournalLines
    $changes = @($lines | Where-Object { $_.Op -eq 'Change' -and $_.Target -eq "$scratch\V" })
    $results = @($lines | Where-Object { $_.Op -eq 'Result' -and $_.Target -eq "$scratch\V" })
    Check 'Journal: each write has a change line (before, after) and a result line, in that order' ($changes.Count -eq 2 -and $results.Count -eq 2 -and [int]$changes[0].Before.Value -eq 1 -and $changes[0].After -eq '2 (DWord)' -and [int]$changes[1].Before.Value -eq 2 -and $results[0].Ref -eq $changes[0].Seq -and $results[0].Seq -gt $changes[0].Seq -and $results[0].Result -eq 'OK')
    Check 'Journal: lines carry time, step and option' (@($lines | Where-Object { -not $_.T -or $null -eq $_.Step -or $null -eq $_.PSObject.Properties['Option'] }).Count -eq 0)

    # A-06 and "before the change": a write that fails still leaves its original and its announcement in the journal.
    . ([scriptblock]::Create('function Write-RegRaw { param($Full, $Name, $Value, $Kind) throw "disk on fire" }'))
    Set-RegValue -Path $scratch -Name 'W' -Value 5
    $wLines = @(Get-JournalLines | Where-Object { $_.Target -eq "$scratch\W" })
    Check 'Journal: the change line is written before the write, and a failed write is recorded as FAILED' ($script:Failures -eq 1 -and $wLines.Count -eq 2 -and $wLines[0].Op -eq 'Change' -and $wLines[1].Result -eq 'FAILED' -and $script:RecordedReg.Contains("$scratch|W"))
    . ([scriptblock]::Create('function Write-RegRaw { param($Full, $Name, $Value, $Kind) }'))
    Set-RegValue -Path $scratch -Name 'X' -Value 9
    $xResult = @(Get-JournalLines | Where-Object { $_.Op -eq 'Result' -and $_.Target -eq "$scratch\X" })
    Check 'Read back: a write that does not take is a MISMATCH in the journal and a warning in the log' ($xResult.Count -eq 1 -and $xResult[0].Result -eq 'MISMATCH' -and $xResult[0].Now -eq '<missing>' -and @($script:LogLines | Where-Object { $_ -like "``[WARN``] MISMATCH: $scratch\X*" }).Count -eq 1)
    . ([scriptblock]::Create($realWriteRegRaw))
    $script:Failures = 0

    # A-01: a run that stops before the state file is saved loses nothing: the journal is replayed at the next start.
    Reset-TestState
    Remove-Item -LiteralPath $StateFile, "$StateFile.bak", $JournalFile -Force -ErrorAction SilentlyContinue
    Set-RegValue -Path "$scratch\Crash" -Name 'A' -Value 1
    Set-RegValue -Path "$scratch\Crash" -Name 'B' -Value 'x' -Type String
    $seqBefore = $script:JournalSeq
    Reset-TestState; Import-State
    Check 'Journal: originals and created keys are recovered when the run stopped before saving the state' ($script:RecordedReg.Contains("$scratch\Crash|A") -and $script:RecordedReg.Contains("$scratch\Crash|B") -and @($script:State.CreatedKeys) -contains "$scratch\Crash" -and $script:JournalSeq -eq $seqBefore -and @($script:LogLines | Where-Object { $_ -like '`[WARN`] Recovered *' }).Count -eq 1)
    Save-State
    Set-RegValue -Path "$scratch\Crash" -Name 'C' -Value 3
    Reset-TestState; Import-State
    Check 'Journal: only lines newer than the state file are replayed, with no duplicates' ($script:State.Registry.Count -eq 3 -and $script:RecordedReg.Contains("$scratch\Crash|C") -and @($script:LogLines | Where-Object { $_ -like '`[WARN`] Recovered 1 record*' }).Count -eq 1)
    [IO.File]::AppendAllText($JournalFile, '{"Seq":99,"Op":"Add","Sec')
    Reset-TestState; Import-State
    Check 'Journal: a line cut off by a crash is skipped with a warning' ($script:State.Registry.Count -eq 3 -and @($script:LogLines | Where-Object { $_ -like '`[WARN`] 1 journal line(s) could not be read*' }).Count -eq 1)
    Remove-Item -LiteralPath $StateFile, "$StateFile.bak", $JournalFile -Force -ErrorAction SilentlyContinue

    # State save and load: values that JSON could change on the way survive (date-like string, expandable string, binary).
    Reset-TestState
    Write-RegRaw -Full $scratch -Name 'When' -Value '2026-11-08T10:00:00Z' -Kind 'String'
    Write-RegRaw -Full $scratch -Name 'Dir' -Value '%SystemRoot%\x' -Kind 'ExpandString'
    Write-RegRaw -Full $scratch -Name 'Bin' -Value ([byte[]](0, 171, 255)) -Kind 'Binary'
    Set-RegValue -Path $scratch -Name 'V' -Value 4
    Set-RegValue -Path $scratch -Name 'When' -Value 'later' -Type String
    Set-RegValue -Path $scratch -Name 'Dir' -Value 'y' -Type String
    Set-RegValue -Path $scratch -Name 'Bin' -Value ([byte[]](1)) -Type Binary
    Remove-RegValue -Path $scratch -Name 'Missing'
    Set-StateValue -Name 'Hibernate' -Value $true; Set-StateValue -Name 'PwAge' -Value '42'; Add-StateRecord -Section 'Hosts' -Item 'telemetry'
    Save-State
    foreach ($round in 'state file', 'journal') {
        if ($round -eq 'journal') { Remove-Item -LiteralPath $StateFile, "$StateFile.bak" -Force -ErrorAction SilentlyContinue }   # the journal alone holds it all
        Reset-TestState; Import-State
        $byName = @{}; foreach ($e in $script:State.Registry) { $byName[$e.Name] = $e }
        Check "State save and load ($round): registry records come back unchanged" ($script:State.Registry.Count -eq 5 -and [int]$byName['V'].Value -eq 3 -and -not $byName['Missing'].Existed -and $byName['When'].Value -is [string] -and $byName['When'].Value -ceq '2026-11-08T10:00:00Z' -and $byName['Dir'].Value -ceq '%SystemRoot%\x' -and $byName['Dir'].Kind -eq 'ExpandString' -and ((ConvertFrom-StoredValue -Value $byName['Bin'].Value -Kind Binary) -join ',') -eq '0,171,255')
        Check "State save and load ($round): lists and single values come back" ($script:State.Hibernate -eq $true -and [string]$script:State.PwAge -eq '42' -and @($script:State.Hosts) -contains 'telemetry')
    }
    Remove-Item -LiteralPath $JournalFile -Force

    # A-04: a failed step is rolled back from its journal lines; a step it cannot roll back stops the run.
    Reset-TestState
    Write-RegRaw -Full $scratch -Name 'V' -Value 10 -Kind 'DWord'
    Invoke-Step 'Rollback test' -Option 'MpoOff' { Set-RegValue -Path "$scratch\New\Deep" -Name 'A' -Value 1; Set-RegValue -Path $scratch -Name 'V' -Value 11; throw 'boom' }
    $now = Get-RegSnapshot -Full $scratch -Name 'V'
    $stepLines = @(Get-JournalLines | Where-Object { $_.StepName -eq 'Rollback test' })
    Check 'Rollback: a failed step puts back its values and removes the keys it created' ([int]$now.Value -eq 10 -and $null -eq (Open-RegKey -Full "$scratch\New") -and -not $script:StopRun -and $script:Failures -eq 1 -and @($script:LogLines | Where-Object { $_ -like "``[WARN``] Rolled back 'Rollback test': 2 change(s)*" }).Count -eq 1)
    Check 'Journal: lines name the step and its option, and the rollback is recorded' ($stepLines.Count -gt 0 -and @($stepLines | Where-Object { $_.Option -ne 'MpoOff' -or $_.Step -ne 1 }).Count -eq 0 -and @($stepLines | Where-Object { $_.Op -eq 'Rollback' -and $_.Result -eq 'OK' }).Count -eq 1)
    Invoke-Step 'Clean step' { Set-RegValue -Path $scratch -Name 'V' -Value 12 }
    Check 'Rollback: a step without failures is left as it is' ([int](Get-RegSnapshot -Full $scratch -Name 'V').Value -eq 12 -and $script:Failures -eq 1)
    Invoke-Step 'Unsafe step' { Set-RegValue -Path $scratch -Name 'V' -Value 13; Set-StateValue -Name 'Hibernate' -Value $true; throw 'boom' }
    $script:ranAfter = $false
    Invoke-Step 'After the stop' { $script:ranAfter = $true }
    Check 'Rollback: a step that changed something the journal cannot put back stops the run' ($script:StopRun -and -not $script:ranAfter -and [int](Get-RegSnapshot -Full $scratch -Name 'V').Value -eq 13 -and @($script:LogLines | Where-Object { $_ -like "``[ERROR``] Rollback of 'Unsafe step' is not safe: the step also changed Hibernate*" }).Count -eq 1 -and @($script:LogLines | Where-Object { $_ -like "``[WARN``] Skipped: After the stop*" }).Count -eq 1)
    Reset-TestState

    # A-02: every run exports the key again; revert imports all exports, newest first, so the original wins.
    $runKey = "$scratch\Run"
    Write-RegRaw -Full $runKey -Name 'First' -Value 'first.exe' -Kind 'String'
    Write-RegRaw -Full $runKey -Name 'Shared' -Value 'original' -Kind 'String'
    Remove-RegKey -Path $runKey
    Check 'Remove-RegKey: the key is exported, recorded and deleted' ($null -eq (Open-RegKey -Full $runKey) -and $script:State.KeyBackups.Count -eq 1 -and [IO.File]::ReadAllText($script:State.KeyBackups[0].File) -match '"First"="first\.exe"')
    Start-Sleep -Milliseconds 20
    Write-RegRaw -Full $runKey -Name 'Second' -Value 'second.exe' -Kind 'String'
    Write-RegRaw -Full $runKey -Name 'Shared' -Value 'changed' -Kind 'String'
    Remove-RegKey -Path $runKey
    $files = @($script:State.KeyBackups | ForEach-Object { $_.File })
    Check 'Remove-RegKey on repeat: a second export with its own name holds the entries added since' ($null -eq (Open-RegKey -Full $runKey) -and $files.Count -eq 2 -and $files[0] -ne $files[1] -and [IO.File]::ReadAllText($files[1]) -match '"Second"="second\.exe"' -and $script:Failures -eq 0)
    Remove-RegKey -Path $runKey
    Check 'Remove-RegKey: a key that is already gone is not an error and adds no export' ($script:Failures -eq 0 -and $script:State.KeyBackups.Count -eq 2)
    Restore-KeyBackups
    $back = { param($n) (Get-RegSnapshot -Full $runKey -Name $n).Value }
    Check 'Revert: every export is imported and the oldest wins where they overlap' ((& $back 'First') -eq 'first.exe' -and (& $back 'Second') -eq 'second.exe' -and (& $back 'Shared') -eq 'original')
    $deleteLines = @(Get-JournalLines | Where-Object { $_.Op -eq 'Change' -and $_.Kind -eq 'RegistryKey' })
    Check 'Journal: each key deletion names its export as the value before' ($deleteLines.Count -eq 2 -and $deleteLines[0].Before -eq $files[0] -and $deleteLines[1].Before -eq $files[1])

    # Migration: a version 1 state file (v7.4 and older, no journal) loads without loss and is saved as version 2.
    Reset-TestState
    Remove-Item -LiteralPath $StateFile, "$StateFile.bak", $JournalFile -Force -ErrorAction SilentlyContinue
    $v1 = '{"Registry":[{"Path":"HKEY_CURRENT_USER\\Software\\X","Name":"S","Existed":true,"Kind":"String","Value":"s:2026-01-02T03:04:05Z"},{"Path":"HKEY_CURRENT_USER\\Software\\X","Name":"D","Existed":false,"Kind":null,"Value":null}],' +
    '"KeyBackups":[{"Path":"HKEY_CURRENT_USER\\Software\\X\\Run","File":"C:\\ProgramData\\FocusedTweaks\\keys\\HKEY_CURRENT_USER_Software_X_Run.reg"}],' +
    '"Tasks":[{"Path":"\\Microsoft\\Windows\\A\\","Name":"T","Action":"Deleted","WasEnabled":true,"XmlFile":"C:\\t.xml"}],"Removed":["Microsoft.BingNews"],"Hosts":["telemetry"],' +
    '"DesktopMoved":[],"CreatedKeys":["HKEY_CURRENT_USER\\Software\\X\\New"],"NetBindings":[],"Features":["SMB1Protocol"],"Power":{"Previous":"381b4222-f694-41f0-9685-ff5bb260df2e","Custom":"11111111-2222-3333-4444-555555555555"},' +
    '"Defender":true,"Hibernate":true,"MemCompress":null,"SleepStudy":["Microsoft-Windows-SleepStudy/Diagnostic"],"PwAge":"42","ConsentDb":null,"Run":null,"StartLayout":null,"Dep":null,"TimerService":null,"PowerOverlay":null,"PowerOverlaySet":null,"PowerOverlaySource":null,"NvidiaDrs":false}'
    [IO.File]::WriteAllText($StateFile, $v1)
    Import-State
    $checkV1 = {
        $s = @($script:State.Registry | Where-Object { $_.Name -eq 'S' })
        $s.Count -eq 1 -and $s[0].Value -is [string] -and $s[0].Value -ceq '2026-01-02T03:04:05Z' -and $script:State.Registry.Count -eq 2 -and $script:State.KeyBackups.Count -eq 1 -and
        $script:State.Tasks.Count -eq 1 -and $script:State.Tasks[0].XmlFile -eq 'C:\t.xml' -and @($script:State.Removed) -contains 'Microsoft.BingNews' -and @($script:State.Features) -contains 'SMB1Protocol' -and
        @($script:State.CreatedKeys) -contains 'HKEY_CURRENT_USER\Software\X\New' -and $script:State.Power.Custom -eq '11111111-2222-3333-4444-555555555555' -and $script:State.Defender -eq $true -and
        $null -eq $script:State.DefenderPrefs -and [string]$script:State.PwAge -eq '42' -and @($script:State.SleepStudy).Count -eq 1
    }
    Check 'Migration: a version 1 state file loads with every record' ((& $checkV1) -and $script:JournalSeq -eq 0 -and $script:LogLines.Count -eq 0)
    Save-State
    $saved = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    Reset-TestState; Import-State
    Check 'Migration: saving writes version 2 with the journal position, and nothing is lost on the way' ($saved.StateVersion -eq 2 -and $null -ne $saved.PSObject.Properties['JournalSeq'] -and (& $checkV1))
    Remove-Item -LiteralPath $StateFile, "$StateFile.bak" -Force -ErrorAction SilentlyContinue

    # A-17: the Defender preferences are recorded once, before -Defender changes them, and -Revert puts them back.
    Reset-TestState
    $script:mp = [pscustomobject]@{ DisableRealtimeMonitoring = $false; DisableBehaviorMonitoring = $true; DisableIOAVProtection = $false }
    function Get-MpPreference { [CmdletBinding()] param() $script:mp }
    function Set-MpPreference { [CmdletBinding()] param([bool]$DisableRealtimeMonitoring, [bool]$DisableBehaviorMonitoring, [bool]$DisableIOAVProtection) $script:mpSet = '{0},{1},{2}' -f $DisableRealtimeMonitoring, $DisableBehaviorMonitoring, $DisableIOAVProtection }
    Save-DefenderPrefs
    $script:mp = [pscustomobject]@{ DisableRealtimeMonitoring = $true; DisableBehaviorMonitoring = $true; DisableIOAVProtection = $true }
    Save-DefenderPrefs
    Check 'Defender: the preferences are recorded the first time only' ($script:State.Defender -eq $true -and $script:State.DefenderPrefs.DisableRealtimeMonitoring -eq $false -and $script:State.DefenderPrefs.DisableBehaviorMonitoring -eq $true)
    Restore-DefenderPrefs
    Check 'Defender: -Revert restores the recorded preferences, not fixed values' ($script:mpSet -eq 'False,True,False')
    $script:State.DefenderPrefs = $null
    Restore-DefenderPrefs
    Check 'Defender: state from an older version without preferences still turns protection back on' ($script:mpSet -eq 'False,False,False')
    Remove-Item function:\Get-MpPreference, function:\Set-MpPreference
}
finally {
    . ([scriptblock]::Create($realWriteRegRaw))
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(($scratch -replace '^HKEY_CURRENT_USER\\', ''), $false)
    Remove-Item -LiteralPath $StateDir -Recurse -Force
}
Check 'The scratch registry key is gone after the tests' ($null -eq (Open-RegKey -Full $scratch))
Check 'Revert archives the journal with the state, so the next run starts a new one' ($text -match 'Move-Item -LiteralPath \$JournalFile -Destination')
Check 'Every state change in the script goes through the journal' (@([regex]::Matches($text, '\$script:State\.\w+(\.\w+)? = |\$script:State\.\w+\.(Add|Remove)\(')).Count -eq 3)

$keep = 'C:\Users\x\AppData\Local\Temp\sub\FocusedTweaks.ps1', 'C:\ProgramData\FocusedTweaks'
Check 'Cleanup protects the folder holding the script and the state folder' ((Test-ProtectedPath 'C:\Users\x\AppData\Local\Temp\sub' -Keep $keep) -and (Test-ProtectedPath 'C:\ProgramData\FocusedTweaks' -Keep $keep) -and -not (Test-ProtectedPath 'C:\Users\x\AppData\Local\Temp\other' -Keep $keep))

# A service Windows disables itself (RemoteRegistry) must not be blamed on the script; one the script changed must be.
$svcKey = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\'
$script:State = @{ Registry = [System.Collections.Generic.List[object]]::new() }
$script:State.Registry.Add([pscustomobject]@{ Path = $svcKey + 'DiagTrack'; Name = 'Start'; Existed = $true; Kind = 'DWord'; Value = 2 })
$script:State.Registry.Add([pscustomobject]@{ Path = $svcKey + 'AlreadyOff'; Name = 'Start'; Existed = $true; Kind = 'DWord'; Value = 4 })
Check 'Health check blames a disabled service only when the script changed it' ((Test-ServiceStartChanged 'DiagTrack') -and -not (Test-ServiceStartChanged 'RemoteRegistry') -and -not (Test-ServiceStartChanged 'AlreadyOff'))

# Values from the state file are quoted before they reach a TrustedInstaller command, including typographic quotes.
$hostile = "x'; Remove-Item C:\; '" + [char]0x2019 + "; calc; " + [char]0x2018
Check 'Quoting keeps hostile text inside one string literal' ((Invoke-Expression (ConvertTo-PsLiteral $hostile)) -ceq $hostile)

# Cleanup must remove a junction as a link and leave its target alone (Windows PowerShell 5.1 -Recurse would follow it).
function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
$script:DryRun = $false
$root = Join-Path ([IO.Path]::GetTempPath()) ('ft-test-' + [guid]::NewGuid().ToString('N'))
$victim = Join-Path $root 'victim'; $target = Join-Path $root 'target'
New-Item -ItemType Directory -Path $victim, (Join-Path $target 'sub'), (Join-Path $victim 'real\inner') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $victim 'real\inner\a.txt') -Value 'a'
Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'keep'
Set-Content -LiteralPath (Join-Path $target 'sub\keep2.txt') -Value 'keep2'
Set-Content -LiteralPath (Join-Path $victim 'ro.txt') -Value 'ro'; Set-ItemProperty -LiteralPath (Join-Path $victim 'ro.txt') -Name IsReadOnly -Value $true
Set-Content -LiteralPath (Join-Path $victim 'skipme.txt') -Value 'skip'
New-Item -ItemType Junction -Path (Join-Path $victim 'link') -Target $target | Out-Null
Clear-FolderContents -Label 'test' -Path $victim -Skip 'skipme*'
Check 'Cleanup keeps the junction target and its files' ((Test-Path -LiteralPath (Join-Path $target 'keep.txt')) -and (Test-Path -LiteralPath (Join-Path $target 'sub\keep2.txt')))
Check 'Cleanup removes the junction, real folders and read-only files' (-not (Test-Path -LiteralPath (Join-Path $victim 'link')) -and -not (Test-Path -LiteralPath (Join-Path $victim 'real')) -and -not (Test-Path -LiteralPath (Join-Path $victim 'ro.txt')))
Check 'Cleanup honours the skip pattern' (Test-Path -LiteralPath (Join-Path $victim 'skipme.txt'))
Remove-Item -LiteralPath $root -Recurse -Force

$hosts = "127.0.0.1 localhost`r`n# FocusedTweaks BEGIN t`r`n0.0.0.0 a.com`r`n# FocusedTweaks END t`r`n"
Check 'Hosts block removal leaves other lines alone' ((Remove-HostsText -Text $hosts -Name 't') -eq "127.0.0.1 localhost`r`n")

# docs\OPTIONS.md is generated by the build; it must list every option with its current default and description.
$optionsDoc = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\OPTIONS.md'))
$stale = @($OptionInfo.Keys | Where-Object {
        $row = '| `{0}` | {1} |' -f $_, $(if ($OptionInfo[$_][0]) { 'on' } else { 'off' })
        -not $optionsDoc.Contains($row) -or -not $optionsDoc.Contains(($OptionInfo[$_][1] -replace '\|', '/'))
    })
Check 'docs\OPTIONS.md lists every option with its default and description (rebuild if not)' ($stale.Count -eq 0) ($stale -join ', ')

$vmTool = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Test-InVm.ps1'
$vmErrs = $null; $vmTokens = $null
$vmAst = [System.Management.Automation.Language.Parser]::ParseFile($vmTool, [ref]$vmTokens, [ref]$vmErrs)
Check 'tools\Test-InVm.ps1 parses without errors' ($vmErrs.Count -eq 0) ($vmErrs | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } | Out-String)
$vmText = [IO.File]::ReadAllText($vmTool)
Check 'tools\Test-InVm.ps1 is ASCII and never starts FocusedTweaks on this PC' (($vmText -cmatch '^[\x00-\x7F]*$') -and ($vmText -notmatch '(?m)^\s*&\s*\$scriptFile'))

# Every other script in the repo parses in this PowerShell and is ASCII.
$windowsDir = Split-Path $PSScriptRoot -Parent
foreach ($tool in @(Get-ChildItem -Path (Join-Path $windowsDir 'tools\*.ps1') | Where-Object { $_.Name -notin 'Test-InVm.ps1', 'FocusedTweaks.template.ps1' })) {
    $tErrs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($tool.FullName, [ref]$null, [ref]$tErrs)
    $tText = [IO.File]::ReadAllText($tool.FullName)
    Check "tools\$($tool.Name) parses and is ASCII" ($tErrs.Count -eq 0 -and $tText -cmatch '^[\x00-\x7F]*$') ($tErrs | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } | Out-String)
}
$smokeText = [IO.File]::ReadAllText((Join-Path $windowsDir 'tools\Test-Smoke.ps1'))
Check 'tools\Test-Smoke.ps1 refuses to run outside GitHub Actions' ($smokeText -match "GITHUB_ACTIONS -ne 'true'")

# Windows PowerShell 5.1 turns redirected stderr of a native command into errors that stop the script under 'Stop'
# (2>&1 into a pipe, *> $null). Native output goes through Invoke-Native, or through cmd.exe with its own >nul 2>&1.
$risky = @([regex]::Matches($text, '(?m)^[^\r\n#]*(\*>\s*\$null|2>&1\s*\)\s*\|)[^\r\n]*$') | Where-Object { $_.Value -notmatch 'cmd\.exe' } | ForEach-Object { $_.Value.Trim() })
Check 'No native command redirects stderr in a way that stops the script under Windows PowerShell 5.1' ($risky.Count -eq 0) ($risky -join ' | ')

if ($script:fail -gt 0) { Write-Host "`n$script:fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll checks passed." -ForegroundColor Green
