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
$wantedFns = 'Test-ProtectedPath', 'Test-ReparsePoint', 'Get-CleanupTree', 'Remove-CleanupEntry', 'Clear-FolderContents', 'Test-DryRun','New-Tweak','ConvertFrom-RegHex', 'ConvertFrom-RegText', 'Get-RegGroupOption', 'Test-NameMatch', 'ConvertTo-FullRegPath', 'ConvertTo-StoredValue', 'ConvertFrom-StoredValue', 'Format-TiRegAdd', 'Get-GuidFromText', 'Remove-HostsText'
foreach ($n in $wantedFns) { $f = $fns | Where-Object { $_.Name -eq $n } | Select-Object -First 1; . ([scriptblock]::Create($f.Extent.Text)) }
$wantedVars = '$UpstreamRegText', '$TelemetryRegs', '$ServiceGroups', '$TelemetryDomains', '$RazerDomains', '$AsusDomains', '$MouseProfiles', '$DriverExclusionRegs', '$SecurityUpdatesRegs', '$PauseRegs', '$UpdateClassifications', '$OptionInfo', '$AppsToRemove', '$KeepApps', '$EmptyStartLayout', '$PowerProfiles', '$UsbSuspendGuid', '$DefenderQuietRegs', '$MitigationRegs', '$TimerGlobalRegs', '$TimerServiceSource', '$NetPowerKeywords', '$NetEeeKeywords'
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
foreach ($o in 'SpectreMeltdownOff', 'DepOff', 'TimerResolution') { Check "$o is off by default" (-not $OptionInfo[$o][0]) }
foreach ($o in 'DefenderQuiet', 'NetAdapterPower', 'NetAdapterEee', 'TempCleanup', 'UpdateCacheCleanup') { Check "$o exists and is on by default" ($OptionInfo.Contains($o) -and $OptionInfo[$o][0]) }
Check 'Quiet Defender sets 6 policy values and never turns protection off' (@($DefenderQuietRegs).Count -eq 6 -and @($DefenderQuietRegs | Where-Object { $_.Name -like 'Disable*Protection*' -or $_.Name -like 'DisableRealtime*' -or $_.Name -eq 'DisableAntiSpyware' }).Count -eq 0)
Check 'Mitigation values are 3 and 3' (@($MitigationRegs | Where-Object { $_.Value -ne 3 }).Count -eq 0 -and @($MitigationRegs).Count -eq 2)
Check 'Timer service source is ASCII and names the service' (($TimerServiceSource -cmatch '^[\x00-\x7F]*$') -and $TimerServiceSource.Contains('"FocusedTimerResolution"'))
Check 'EEE and power keyword lists do not overlap' (@($NetEeeKeywords | Where-Object { $NetPowerKeywords -contains $_ }).Count -eq 0)
$keep = 'C:\Users\x\AppData\Local\Temp\sub\FocusedTweaks.ps1', 'C:\ProgramData\FocusedTweaks'
Check 'Cleanup protects the folder holding the script and the state folder' ((Test-ProtectedPath 'C:\Users\x\AppData\Local\Temp\sub' -Keep $keep) -and (Test-ProtectedPath 'C:\ProgramData\FocusedTweaks' -Keep $keep) -and -not (Test-ProtectedPath 'C:\Users\x\AppData\Local\Temp\other' -Keep $keep))

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

if ($script:fail -gt 0) { Write-Host "`n$script:fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll checks passed." -ForegroundColor Green
