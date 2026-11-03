$ErrorActionPreference = 'Continue'
$env:ProgramData='/tmp/sim/pd'; $env:SystemRoot='/tmp/sim/sr'; $env:LOCALAPPDATA='/tmp/sim/la'; $env:TEMP='/tmp/sim'; $env:ProgramFiles='/tmp/sim/pf'; ${env:ProgramFiles(x86)}='/tmp/sim/pf86'; $env:windir='/tmp/sim/sr'
$global:LASTEXITCODE = 0
$src = Get-Content /mnt/user-data/outputs/FocusedTweaks.ps1 -Raw
$src = $src -replace '#Requires -RunAsAdministrator',''
$src = $src -replace '\[Environment\]::OSVersion\.Version\.Build', '26200'
Set-Content /tmp/sim/ft_only.ps1 $src

# a Start menu folder (the script builds the path with Join-Path, so create it the same way)
$dir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
[IO.File]::WriteAllBytes((Join-Path $dir 'start2.bin'), [byte[]](1..200))
$origHash = (Get-FileHash (Join-Path $dir 'start2.bin')).Hash

$global:Cap = @([pscustomobject]@{ Name='App.Support.QuickAssist~~~~0.0.1.0'; State='Installed' })
$global:Pkg = @([pscustomobject]@{ PackageName='Microsoft-Windows-QuickAssist-Package~31bf3856ad364e35~amd64~~10.0.26100.1'; PackageState='Installed' })
$global:App = @([pscustomobject]@{ Name='MicrosoftCorporationII.QuickAssist'; PackageFullName='MicrosoftCorporationII.QuickAssist_1_x64' })
function Get-WindowsCapability { param([switch]$Online) $global:Cap }
function Remove-WindowsCapability { param([switch]$Online,$Name,$ErrorAction) $global:Cap = @(); "removed capability $Name" | Out-File -Append /tmp/sim/only_actions.txt }
function Get-WindowsPackage { param([switch]$Online) $global:Pkg }
function Remove-WindowsPackage { param([switch]$Online,$PackageName,[switch]$NoRestart,$ErrorAction) $global:Pkg = @(); "removed package $PackageName" | Out-File -Append /tmp/sim/only_actions.txt }
function Get-AppxPackage { param([switch]$AllUsers) $global:App }
function Remove-AppxPackage { param($Package,[switch]$AllUsers,$ErrorAction) $global:App = @(); "removed app $Package" | Out-File -Append /tmp/sim/only_actions.txt }
function Get-CimInstance { param($ClassName,$ErrorAction) if ($ClassName -eq 'Win32_OperatingSystem') { [pscustomobject]@{ LastBootUpTime = (Get-Date).AddMinutes(10) } } else { $null } }
function Checkpoint-Computer { }
function Get-ScheduledTask { param($TaskPath,$TaskName,$ErrorAction) @() }
function Get-MpComputerStatus { param($ErrorAction) $null }
function Get-HotFix { param($ErrorAction) @() }
function Get-WinEvent { param($FilterHashtable,$ErrorAction) @() }

$state='/tmp/sim/state_only'; Remove-Item $state -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item /tmp/sim/only_actions.txt -ErrorAction SilentlyContinue
function Run($label,$p) { Write-Host "`n########## $label ##########" -ForegroundColor Cyan; $p['StateDir']=$state; try { & /tmp/sim/ft_only.ps1 @p; Write-Host "[exit code: $LASTEXITCODE]" } catch { Write-Host "[stopped with error: $($_.Exception.Message)]" } }

Run '1. DRY RUN of -Only ClearStartPins,RemoveQuickAssist' @{ Only=@('ClearStartPins','RemoveQuickAssist'); DryRun=$true }
Run '2. REAL RUN' @{ Only=@('ClearStartPins','RemoveQuickAssist'); Force=$true; SkipRestorePoint=$true }
$newHash = (Get-FileHash (Join-Path $dir 'start2.bin')).Hash
"start2.bin replaced: $($newHash -ne $origHash) | size now $((Get-Item (Join-Path $dir 'start2.bin')).Length) bytes (expect 4540)"
"backup of original kept: $(Test-Path /tmp/sim/state_only/start2.bin.original) | backup identical to original: $((Get-FileHash /tmp/sim/state_only/start2.bin.original).Hash -eq $origHash)"
"Quick Assist actions: $((Get-Content /tmp/sim/only_actions.txt) -join ' | ')"
Run '3. HEALTH CHECK' @{ HealthCheck=$true }
Run '4. REVERT' @{ Revert=$true }
"start2.bin restored to original: $((Get-FileHash (Join-Path $dir 'start2.bin')).Hash -eq $origHash)"
Run '5. unknown option' @{ Only=@('Nonsense'); DryRun=$true }
Run '6. explicit TaskMode is respected with -Only' @{ Only=@('Cdp'); TaskMode='Disable'; DryRun=$true }
