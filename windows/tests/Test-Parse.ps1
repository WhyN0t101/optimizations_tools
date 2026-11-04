<#
Static checks for FocusedTweaks.ps1. No admin rights needed and nothing is changed on the machine.
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
$wantedFns = 'Import-RunProfile', 'Test-ServiceStartChanged', 'Test-RecordedFirst', 'ConvertTo-PsLiteral','Test-ProtectedPath','Test-ReparsePoint', 'Get-CleanupTree', 'Remove-CleanupEntry', 'Clear-FolderContents', 'Test-DryRun','New-Tweak','ConvertFrom-RegHex', 'ConvertFrom-RegText', 'Get-RegGroupOption', 'Test-NameMatch', 'ConvertTo-FullRegPath', 'ConvertTo-StoredValue', 'ConvertFrom-StoredValue', 'Format-TiRegAdd', 'Get-GuidFromText', 'Remove-HostsText'
foreach ($n in $wantedFns) { $f = $fns | Where-Object { $_.Name -eq $n } | Select-Object -First 1; . ([scriptblock]::Create($f.Extent.Text)) }
$wantedVars = '$UpstreamRegText', '$TelemetryRegs', '$ServiceGroups', '$TelemetryDomains', '$RazerDomains', '$AsusDomains', '$MouseProfiles', '$DriverExclusionRegs', '$SecurityUpdatesRegs', '$PauseRegs', '$UpdateClassifications', '$OptionInfo', '$AppsToRemove', '$KeepApps', '$EmptyStartLayout', '$PowerProfiles', '$UsbSuspendGuid', '$DefenderQuietRegs', '$MitigationRegs', '$TimerGlobalRegs', '$TimerServiceSource', '$NetPowerKeywords', '$NetEeeKeywords', '$DeviceEnumRoots', '$DevicePowerValues', '$MpoRegs', '$FastShutdownRegs', '$TimeServerRegs', '$MenuKillRegs', '$MenuRestartExplorerRegs', '$TakeOwnFile', '$TakeOwnDir', '$MenuTakeOwnershipRegs', '$PowerOverlayNames', '$KnownStuckValues'
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
Check 'Bluetooth, printing, Delivery Optimization and radio services are kept by default' (-not $OptionInfo['SvcBluetooth'][0] -and -not $OptionInfo['SvcPrinting'][0] -and -not $OptionInfo['SvcDeliveryOpt'][0] -and -not $OptionInfo['SvcRadio'][0])
Check 'Core isolation is off by default' (-not $OptionInfo['CoreIsolation'][0])
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
foreach ($o in 'SpectreMeltdownOff', 'DepOff', 'TimerResolution') { Check "$o is off by default" (-not $OptionInfo[$o][0]) }
foreach ($o in 'DefenderQuiet', 'NetAdapterPower', 'NetAdapterEee', 'TempCleanup', 'UpdateCacheCleanup') { Check "$o exists and is on by default" ($OptionInfo.Contains($o) -and $OptionInfo[$o][0]) }
Check 'Quiet Defender sets 6 policy values and never turns protection off' (@($DefenderQuietRegs).Count -eq 6 -and @($DefenderQuietRegs | Where-Object { $_.Name -like 'Disable*Protection*' -or $_.Name -like 'DisableRealtime*' -or $_.Name -eq 'DisableAntiSpyware' }).Count -eq 0)
Check 'Mitigation values are 3 and 3' (@($MitigationRegs | Where-Object { $_.Value -ne 3 }).Count -eq 0 -and @($MitigationRegs).Count -eq 2)
Check 'Timer service source is ASCII and names the service' (($TimerServiceSource -cmatch '^[\x00-\x7F]*$') -and $TimerServiceSource.Contains('"FocusedTimerResolution"'))
Check 'EEE and power keyword lists do not overlap' (@($NetEeeKeywords | Where-Object { $NetPowerKeywords -contains $_ }).Count -eq 0)
foreach ($o in 'DevicePowerSaving', 'TimeServerPool', 'MenuKillNotResponding', 'MenuRestartExplorer') { Check "$o exists and is on by default" ($OptionInfo.Contains($o) -and $OptionInfo[$o][0]) }
foreach ($o in 'DeviceWakeOff', 'MpoOff', 'WriteCacheFlushOff', 'FastShutdown', 'BlockFeatureUpgrades', 'SearchIndexingOff', 'MenuTakeOwnership') { Check "$o exists and is off by default" ($OptionInfo.Contains($o) -and -not $OptionInfo[$o][0]) }

# Every option the code reads exists, and every option exists for a reason.
$used = @([regex]::Matches($text, "\`$Opt\['([A-Za-z]+)'\]") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$unknown = @($used | Where-Object { -not $OptionInfo.Contains($_) })
Check 'Every option the code reads is defined' ($unknown.Count -eq 0) ($unknown -join ', ')
$unused = @($OptionInfo.Keys | Where-Object { $used -notcontains $_ -and -not $ServiceGroups.Contains($_) -and (Get-RegGroupOption $_) -ne $_ -and $_ -notin 'Registry', 'CoreIsolation', 'HideLockOption', 'HideSleepOption' })
Check 'Every defined option is used' ($unused.Count -eq 0) ($unused -join ', ')

Check 'Registry paths in ControlSet001 are written to CurrentControlSet' ((ConvertTo-FullRegPath 'HKLM\SYSTEM\ControlSet001\Services\X') -eq 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\X')
$diag = @($TelemetryRegs | Where-Object { $_.Path -like '*Diagtrack-Listener' -and $_.Name -eq 'Start' })
Check 'The protected Diagtrack value is recognised after path normalisation' ($diag.Count -eq 1 -and $KnownStuckValues -contains ((ConvertTo-FullRegPath $diag[0].Path) + '|Start'))
Check 'Device power values are DWord 0 or a single zero byte' (@($DevicePowerValues | Where-Object { -not (($_.Type -eq 'DWord' -and $_.Value -eq 0) -or ($_.Type -eq 'Binary' -and (@($_.Value) -join ',') -eq '0')) }).Count -eq 0)
Check 'Right click menu entries have a command' ((@($MenuKillRegs | Where-Object { $_.Path -like '*\command' -and $_.Name -eq '' }).Count -eq 1) -and (@($MenuRestartExplorerRegs | Where-Object { $_.Path -like '*\command' -and $_.Name -eq '' }).Count -eq 1))
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

$vmTool = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Test-InVm.ps1'
$vmErrs = $null; $vmTokens = $null
$vmAst = [System.Management.Automation.Language.Parser]::ParseFile($vmTool, [ref]$vmTokens, [ref]$vmErrs)
Check 'tools\Test-InVm.ps1 parses without errors' ($vmErrs.Count -eq 0) ($vmErrs | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } | Out-String)
$vmText = [IO.File]::ReadAllText($vmTool)
Check 'tools\Test-InVm.ps1 is ASCII and never starts FocusedTweaks on this PC' (($vmText -cmatch '^[\x00-\x7F]*$') -and ($vmText -notmatch '(?m)^\s*&\s*\$scriptFile'))

if ($script:fail -gt 0) { Write-Host "`n$script:fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll checks passed." -ForegroundColor Green
