$ErrorActionPreference = 'Continue'
$env:ProgramData='/tmp/sim/pd'; $env:SystemRoot='/tmp/sim/sr'; $env:LOCALAPPDATA='/tmp/sim/la'; $env:TEMP='/tmp/sim'; $env:ProgramFiles='/tmp/sim/pf'; ${env:ProgramFiles(x86)}='/tmp/sim/pf86'
$global:LASTEXITCODE = 0

# ---------- patch a copy of the script ----------
$src = Get-Content /mnt/user-data/outputs/FocusedTweaks.ps1 -Raw
$src = $src -replace '#Requires -RunAsAdministrator',''
$src = $src -replace "'System32\\drivers\\etc\\hosts'", "'hosts'"
$src = $src -replace '(?s)function Open-RegKey \{.*?\r?\n\}\r?\n', "function Open-RegKey { param([string]`$Full, [switch]`$Write, [switch]`$Create) Fake-OpenKey `$Full ([bool]`$Create) }`n"
$src = $src -replace '(?s)function Remove-RegKey \{.*?\r?\n\}\r?\n', "function Remove-RegKey { param([string]`$Path) `$full = ConvertTo-FullRegPath `$Path; if (Test-DryRun `"delete key `$full`") { return }; if (-not (Open-RegKey -Full `$full)) { return }; `$dir = Join-Path `$StateDir 'keys'; New-Item -ItemType Directory -Path `$dir -Force | Out-Null; `$file = Join-Path `$dir ((`$full -replace '[\\\\/:*?`"<>| {}]', '_') + '.reg'); & reg.exe export `$full `$file /y | Out-Null; `$script:State.KeyBackups.Add([pscustomobject]@{ Path = `$full; File = `$file }); Fake-RemoveKey `$full }`n"
$src = $src -replace 'function Sync-MouseSettings \{', "function Sync-MouseSettings { return"
$src = $src -replace '\[System\.Net\.Dns\]::GetHostAddresses\(\$h\)', 'Fake-Resolve $h'
Set-Content /tmp/sim/ft_copy.ps1 $src

# ---------- fake registry ----------
$global:Reg = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
function Fake-Ensure($p) { if (-not $global:Reg.ContainsKey($p)) { $global:Reg[$p] = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase) }; $global:Reg[$p] }
function Fake-Seed($p,$n,$kind,$v) { (Fake-Ensure $p)[$n] = @{ Kind=$kind; Value=$v } }
function Fake-OpenKey($full,$create) {
    $exists = $global:Reg.ContainsKey($full) -or @($global:Reg.Keys | ? { $_.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if (-not $exists -and -not $create) { return $null }
    $o = [pscustomobject]@{ Path = $full; Vals = (Fake-Ensure $full) }
    $o | Add-Member ScriptMethod GetValueNames { ,[string[]]@($this.Vals.Keys) }
    $o | Add-Member ScriptMethod GetValueKind { param($n) $this.Vals[$n].Kind }
    $o | Add-Member ScriptMethod GetValue { param($n,$d,$opt) $this.Vals[$n].Value }
    $o | Add-Member ScriptMethod SetValue { param($n,$v,$k) $this.Vals[$n] = @{ Kind = $k.ToString(); Value = $v } }
    $o | Add-Member ScriptMethod DeleteValue { param($n,$t) [void]$this.Vals.Remove($n) }
    $o | Add-Member ScriptMethod Close { }
    $o | Add-Member ScriptMethod GetSubKeyNames { $pfx = $this.Path + '\'; ,[string[]]@($global:Reg.Keys | ? { $_.StartsWith($pfx, [StringComparison]::OrdinalIgnoreCase) } | % { $_.Substring($pfx.Length).Split('\')[0] } | Select-Object -Unique) }
    $o | Add-Member ScriptMethod OpenSubKey { param($n) Fake-OpenKey ($this.Path + '\' + $n) $false }
    $o
}
function Fake-RemoveKey($path) {
    $full = $path -replace '^HKLM:?\\','HKEY_LOCAL_MACHINE\' -replace '^HKCU:?\\','HKEY_CURRENT_USER\'
    foreach ($k in @($global:Reg.Keys)) { if ($k -ieq $full -or $k.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) { [void]$global:Reg.Remove($k) } }
}
function Fake-Resolve($h) { $t = Get-Content /tmp/sim/sr/hosts -Raw; if ($t -match "(?m)^0\.0\.0\.0 $([regex]::Escape($h))\s*$") { '0.0.0.0' } else { '93.184.216.34' } }

# seed: an installation with some original values
$HK='HKEY_LOCAL_MACHINE'; $HC='HKEY_CURRENT_USER'
Fake-Seed "$HK\SOFTWARE\Policies\Microsoft\Windows\DataCollection" 'AllowTelemetry' 'DWord' 1
Fake-Seed "$HK\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" 'EnableLUA' 'DWord' 1
Fake-Seed "$HK\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" 'ConsentPromptBehaviorAdmin' 'DWord' 5
Fake-Seed "$HC\Control Panel\Mouse" 'MouseSpeed' 'String' '1'
Fake-Seed "$HC\Control Panel\Mouse" 'MouseThreshold1' 'String' '6'
Fake-Seed "$HC\Control Panel\Mouse" 'SmoothMouseXCurve' 'Binary' ([byte[]](1,2,3,4,5))
Fake-Seed "$HC\Software\Microsoft\Windows\CurrentVersion\Run" 'OneDrive' 'String' 'C:\OneDrive.exe'
Fake-Seed "$HC\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\App.One" 'Enabled' 'DWord' 1
Fake-Seed "$HC\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\App.Two" 'Enabled' 'DWord' 1
Fake-Seed "$HK\SYSTEM\CurrentControlSet\Control\Power" 'HibernateEnabled' 'DWord' 1
Fake-Seed "$HK\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" 'PauseUpdatesExpiryTime' 'String' '2000-01-01T00:00:00Z'
$svcStart = @{ DiagTrack=2; dmwappushservice=3; CDPSvc=2; CDPUserSvc=2; luafv=2; wuauserv=3; UsoSvc=3; WaaSMedicSvc=3; BITS=2; CryptSvc=2; Winmgmt=2; StorSvc=2; AppXSvc=3; ClipSVC=3; InstallService=3; LicenseManager=3; BFE=2; mpssvc=2; Dnscache=2; NlaSvc=2; WinDefend=2 }
foreach ($g in 'Fax','shpamsvc','RemoteRegistry','PhoneSvc','defragsvc','wisvc','TabletInputService','AssignedAccessManagerSvc','MapsBroker','lfsvc','Netlogon','WpcMonSvc','WalletService','whesvc','wuqisvc','WSAIFabricSvc','WbioSrvc','SCardSvr','ScDeviceEnum','SCPolicySvc','diagsvc','DPS','WdiServiceHost','WdiSystemHost','BTAGService','BthAvctpSvc','bthserv','BluetoothUserService','Spooler','PrintWorkflowUserSvc','PrintNotify','DoSvc','RmSvc') { if (-not $svcStart.ContainsKey($g)) { $svcStart[$g] = 3 } }
$svcStart['Spooler']=2; $svcStart['DoSvc']=2
foreach ($k in $svcStart.Keys) { Fake-Seed "$HK\SYSTEM\CurrentControlSet\Services\$k" 'Start' 'DWord' $svcStart[$k] }
Fake-Seed "$HK\SYSTEM\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener" 'Start' 'DWord' 1
$global:OrigReg = @{}; foreach ($p in $global:Reg.Keys) { foreach ($n in $global:Reg[$p].Keys) { $global:OrigReg["$p|$n"] = "$($global:Reg[$p][$n].Kind):$(@($global:Reg[$p][$n].Value) -join ',')" } }

# ---------- stubs for Windows only commands ----------
$global:Plans = @{ '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'; '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance' }; $global:Active = '381b4222-f694-41f0-9685-ff5bb260df2e'
function powercfg { $global:LASTEXITCODE = 0
  switch -Regex ($args[0]) {
    '/getactivescheme' { "Power Scheme GUID: $global:Active  ($($global:Plans[$global:Active]))" }
    '/list' { "Existing Power Schemes (* Active)"; foreach ($k in $global:Plans.Keys) { "Power Scheme GUID: $k  ($($global:Plans[$k]))" } }
    '/duplicatescheme' { $g = [guid]::NewGuid().ToString(); $global:Plans[$g] = 'dup'; "Power Scheme GUID: $g  (dup)" }
    '/changename' { $global:Plans[$args[1]] = $args[2] }
    '/setactive' { $global:Active = $args[1] }
    '/delete' { [void]$global:Plans.Remove($args[1]) }
    '/hibernate' { if ($args[1] -eq 'off') { Fake-Seed 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 'DWord' 0 } else { Fake-Seed 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 'DWord' 1 } }
  } }
function wevtutil.exe { $global:LASTEXITCODE = 0; if ($args[0] -eq 'gl') { "enabled: $($global:LogsOn)" } else { $global:LogsOn = ($args[2] -eq '/e:true').ToString().ToLower() } }
$global:LogsOn = 'true'
function net.exe { $global:LASTEXITCODE = 0 }; function takeown.exe { $global:LASTEXITCODE = 0 }; function icacls.exe { $global:LASTEXITCODE = 0 }
function schtasks.exe { $global:LASTEXITCODE = 0 }; function rundll32.exe { $global:LASTEXITCODE = 0 }; function sc.exe { $global:LASTEXITCODE = 0 }; function taskkill.exe { $global:LASTEXITCODE = 0 }
function reg.exe { $global:LASTEXITCODE = 0
  if ($args[0] -eq 'export') { $k = $args[1]; $rows = @(); foreach ($p in $global:Reg.Keys) { if ($p -ieq $k -or $p.StartsWith($k + '\', [StringComparison]::OrdinalIgnoreCase)) { foreach ($n in $global:Reg[$p].Keys) { $rows += [pscustomobject]@{ P = $p; N = $n; K = $global:Reg[$p][$n].Kind; V = $global:Reg[$p][$n].Value } } } }; $rows | ConvertTo-Json -Depth 4 | Set-Content $args[2]; return }
  if ($args[0] -eq 'import') { foreach ($r in @(Get-Content $args[1] -Raw | ConvertFrom-Json)) { Fake-Seed $r.P $r.N $r.K $r.V }; return }
  if ($args[0] -eq 'add' -and $args -contains 'REG_NONE') { $n = if ($args -contains '/ve') { '' } else { $args[([array]::IndexOf($args,'/v')+1)] }; Fake-Seed $args[1] $n 'None' '' } }
function Get-CimInstance { param($ClassName, $ErrorAction)
  switch ($ClassName) {
    'Win32_PhysicalMemory' { [pscustomobject]@{ Capacity = 16GB } }
    'Win32_OperatingSystem' { [pscustomobject]@{ LastBootUpTime = $global:FakeBoot } }
    default { $null } } }
$global:FakeBoot = (Get-Date).AddHours(-3)
function Get-AppxPackage { param([switch]$AllUsers, $Name)
  $all = 'Microsoft.BingNews','Microsoft.WindowsStore','Microsoft.Paint','SpotifyAB.SpotifyMusic','Microsoft.XboxGamingOverlay','Microsoft.GamingApp','Microsoft.XboxIdentityProvider','Microsoft.Windows.Photos','Clipchamp.Clipchamp','Microsoft.DesktopAppInstaller'
  $all | ? { $global:Gone -notcontains $_ } | ? { -not $Name -or $_ -like $Name } | % { [pscustomobject]@{ Name=$_; IsFramework=$false; NonRemovable=$false; PackageFullName="$_`_1_x64" } } }
$global:Removed = @()
function Remove-AppxPackage { param($Package,[switch]$AllUsers,$ErrorAction) $global:Removed += $Package; $global:Gone += ($Package -replace '_1_x64$','') }
$global:Gone = @()
function Get-AppxProvisionedPackage { param([switch]$Online) @() }
function Remove-AppxProvisionedPackage { }
$global:Tasks = New-Object System.Collections.ArrayList
foreach ($t in @(@('Consolidator','\Microsoft\Windows\Customer Experience Improvement Program\'),@('Schedule Scan','\Microsoft\Windows\UpdateOrchestrator\'),@('Reboot','\Microsoft\Windows\UpdateOrchestrator\'),@('StartupAppTask','\Microsoft\Windows\Application Experience\'),@('SvcRestartTask','\Microsoft\Windows\X\'),@('MyBackup','\'))) { [void]$global:Tasks.Add([pscustomobject]@{ TaskName=$t[0]; TaskPath=$t[1]; State='Ready' }) }
function Get-ScheduledTask { param($TaskPath,$TaskName,$ErrorAction)
  $global:Tasks | ? { (-not $TaskPath -or $_.TaskPath -like $TaskPath) -and (-not $TaskName -or $_.TaskName -like $TaskName) } }
function Export-ScheduledTask { param($TaskName,$TaskPath) "<?xml version=`"1.0`" encoding=`"UTF-16`"?><Task><Name>$TaskPath$TaskName</Name></Task>" }
function Unregister-ScheduledTask { param($TaskName,$TaskPath,$Confirm,$ErrorAction) $t = $global:Tasks | ? { $_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath }; if ($t) { $global:Tasks.Remove($t) } }
function Register-ScheduledTask { param($Xml,$TaskName,$TaskPath,[switch]$Force,$ErrorAction) [void]$global:Tasks.Add([pscustomobject]@{ TaskName=$TaskName; TaskPath=$TaskPath; State='Ready' }) }
function Disable-ScheduledTask { param($InputObject,$ErrorAction) $InputObject.State = 'Disabled' }
function Enable-ScheduledTask { param($TaskPath,$TaskName,$ErrorAction) ($global:Tasks | ? { $_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath }).State = 'Ready' }
function Get-PnpDevice { param($Class,$ErrorAction) [pscustomobject]@{ InstanceId='PCI\VEN_10DE&DEV_2684\4&1' } }
$global:MMA = $true
function Get-MMAgent { [pscustomobject]@{ MemoryCompression = $global:MMA } }; function Disable-MMAgent { param([switch]$MemoryCompression) $global:MMA = $false }; function Enable-MMAgent { param([switch]$MemoryCompression) $global:MMA = $true }
function Get-Service { param($Name,$ErrorAction) $null }; function Stop-Service { }; function Start-Service { }
function Get-MpComputerStatus { param($ErrorAction) [pscustomobject]@{ IsTamperProtected=$false; RealTimeProtectionEnabled=$true; AntivirusSignatureLastUpdated=(Get-Date).AddDays($global:SigAge) } }
$global:SigAge = -2
function Set-MpPreference { }
function Get-HotFix { param($ErrorAction) [pscustomobject]@{ HotFixID='KB5000001'; InstalledOn=(Get-Date).AddDays(-30) } }
$global:Events = @( ) <# Message='A timeout was reached (30000 milliseconds) while waiting for the Windows Modules Installer service to connect.' }, [pscustomobject]@{ Id=7000; Message='The Windows Modules Installer service failed to start due to the following error:' }, #>
function Get-WinEvent { param($FilterHashtable,$ErrorAction) $global:Events }
function Checkpoint-Computer { }
function Start-Process { param($FilePath) }
function Get-Process { param($Name,$ErrorAction) $null }
function Add-Type { }

$state = '/tmp/sim/state'
function Run($label, $p) { Write-Host "`n########## $label ##########" -ForegroundColor Cyan; $p['StateDir'] = $state; & /tmp/sim/ft_copy.ps1 @p; Write-Host "[exit code: $LASTEXITCODE]" }

Run 'APPLY (real, simulated system)' @{ Force=$true; SkipRestorePoint=$true }
Write-Host "`n--- after apply: spot checks ---"
function V($p,$n) { $e = $global:Reg[$p]; if ($e -and $e.ContainsKey($n)) { "$($e[$n].Value)" } else { '<missing>' } }
"DiagTrack Start (orig 2, expect 4):      $(V "$HK\SYSTEM\CurrentControlSet\Services\DiagTrack" 'Start')"
"Spooler Start (orig 2, expect 2 kept):   $(V "$HK\SYSTEM\CurrentControlSet\Services\Spooler" 'Start')"
"bthserv Start (orig 3, expect 3 kept):   $(V "$HK\SYSTEM\CurrentControlSet\Services\bthserv" 'Start')"
"DoSvc Start (orig 2, expect 2 kept):     $(V "$HK\SYSTEM\CurrentControlSet\Services\DoSvc" 'Start')"
"wuauserv Start (expect 3 manual):        $(V "$HK\SYSTEM\CurrentControlSet\Services\wuauserv" 'Start')"
"EnableLUA (orig 1, expect 0):            $(V "$HK\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" 'EnableLUA')"
"AllowTelemetry (orig 1, expect 0):       $(V "$HK\SOFTWARE\Policies\Microsoft\Windows\DataCollection" 'AllowTelemetry')"
"MouseSpeed (orig 1, expect 0):           $(V "$HC\Control Panel\Mouse" 'MouseSpeed')"
"Run key present after apply (expect no): $($global:Reg.ContainsKey("$HC\Software\Microsoft\Windows\CurrentVersion\Run"))"
"Notification App.One Enabled (expect 0): $(V "$HC\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\App.One" 'Enabled')"
"Hibernate (orig 1, option off, expect 1): $(V "$HK\SYSTEM\CurrentControlSet\Control\Power" 'HibernateEnabled')"
"Apps removed: $($global:Removed -join ', ')"
"Tasks left: $((@($global:Tasks | % { $_.TaskPath + $_.TaskName }) -join ' | '))"
"Active plan: $($global:Plans[$global:Active])   MemCompression: $global:MMA   Logs on: $global:LogsOn"
"Hosts:"; Get-Content /tmp/sim/sr/hosts | Select-Object -First 4 | % { "   $_" }; "   ... total lines: $((Get-Content /tmp/sim/sr/hosts).Count)"
"State file keys: " + ((Get-Content "$state/state.json" -Raw | ConvertFrom-Json).PSObject.Properties.Name -join ', ')



Write-Host "`n########## PARTIAL RUN: -Only Cdp ##########" -ForegroundColor Cyan
$global:FakeBoot = (Get-Date).AddMinutes(10)
Run 'ONLY Cdp' @{ Only=@('Cdp'); Force=$true; SkipRestorePoint=$true }
Run 'HEALTH after the partial run' @{ HealthCheck=$true }
$st = Get-Content "$state/state.json" -Raw | ConvertFrom-Json
"Saved options on after both runs: $(@($st.Run.Options.PSObject.Properties | ? { $_.Value } | % Name).Count) of $(@($st.Run.Options.PSObject.Properties).Count) | TaskMode saved: $($st.Run.TaskMode) | PowerProfile saved: $($st.Run.PowerProfile) | PauseDays saved: $($st.Run.PauseDays)"
