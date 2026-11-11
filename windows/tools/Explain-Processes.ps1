#Requires -Version 5.1
<#
.SYNOPSIS
    Explains what is running and why: which services each svchost holds, which vendor each process belongs to,
    which app started each WebView, and which vendor services are safe to set to Manual or remove. Changes nothing.

.DESCRIPTION
    Run it without parameters for the report. Save a snapshot on one machine and compare it with another:

        .\Explain-Processes.ps1 -SaveSnapshot desktop.json
        .\Explain-Processes.ps1 -Compare desktop.json, laptop.json

    Advice comes from a short built-in list of common Windows, Lenovo, Intel, Dolby, Realtek and Synaptics services.
    Services it does not know are listed without advice. Run it as administrator to see every process path; without
    it some system processes show no publisher.

.PARAMETER SaveSnapshot
    Also write the process and service lists to this JSON file.

.PARAMETER Compare
    Two snapshot files: show what runs on one machine and not the other. Nothing on this machine is read.
#>
param(
    [string]$SaveSnapshot,
    [string[]]$Compare
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Service name -> advice, reason. Keep = needed; Manual = safe to set to Manual; Remove = uninstall the app or
# disable it (FocusedTweaks does the Windows ones). Names are matched without the per-user suffix (_1a2b3c).
$Advice = @{
    # Lenovo
    'LITSSVC' = @('Keep', 'Lenovo thermal and fan control, Fn+T power modes')
    'IBMPMSVC' = @('Keep', 'ThinkPad power management, battery charge limits')
    'LPlatSvc' = @('Keep', 'Lenovo platform service used by power management')
    'TPHKLOAD' = @('Keep', 'Fn keys, mic mute light, on-screen display')
    'LenovoAICCLoader' = @('Keep', 'Loads the display colour profile')
    'LenovoBrightCtrl' = @('Keep', 'Display brightness on some Lenovo panels')
    'LenovoVantageService' = @('Remove', 'Lenovo Vantage: uninstall the app and its service if you do not use it')
    'ImControllerService' = @('Remove', 'Reinstalls Lenovo Vantage and its add-ins')
    'LenovoSmartStandby' = @('Manual', 'Tunes sleep from usage habits; not needed')
    'SmartSense' = @('Manual', 'Presence sensing (walk-away lock, wake on approach)')
    'EPDService' = @('Manual', 'ELAN presence sensor service')
    'LvfInstallService' = @('Manual', 'Installs Lenovo View camera effects')
    # Intel
    'ipfsvc' = @('Keep', 'Intel thermal and power framework used by the OEM thermal service')
    'IntelAudioService' = @('Keep', 'Microphones and speakers on Intel Smart Sound laptops')
    'cplspcon' = @('Keep', 'HDCP for protected video and some external displays')
    'jhi_service' = @('Keep', 'Intel security features used by some drivers')
    'WMIRegistrationService' = @('Manual', 'Intel ME reporting; not needed day to day')
    'dptftcs' = @('Manual', 'Intel Dynamic Tuning telemetry only')
    'IntelCstService' = @('Manual', 'Intel presence sensing')
    'IntelGraphicsSoftwareService' = @('Manual', 'Intel graphics control panel; the driver works without it')
    # Audio and input
    'DolbyDAXAPI' = @('Manual', 'Dolby app interface; test the speakers after setting it to Manual')
    'DolbyFusionAPI' = @('Manual', 'Dolby app interface; test the speakers after setting it to Manual')
    'RtkAudioUniversalService' = @('Keep', 'Realtek audio, jack detection')
    'SynHsaService' = @('Keep', 'Synaptics touchpad and fingerprint support')
    # Windows extras that nothing usable depends on (FocusedTweaks SvcExtra and telemetry)
    'PimIndexMaintenanceSvc' = @('Remove', 'Contact sync for the Mail and People apps')
    'UnistoreSvc' = @('Remove', 'User data storage for the Mail and People apps')
    'UserDataSvc' = @('Remove', 'User data access for the Mail and People apps')
    'SSDPSRV' = @('Remove', 'Old network device discovery (SSDP)')
    'smphost' = @('Remove', 'Storage Spaces; only needed if you pool drives')
    'RasMan' = @('Remove', 'Built-in VPN client; keep it if you use Settings > VPN')
    'SstpSvc' = @('Remove', 'Built-in VPN client (SSTP); keep it if you use Settings > VPN')
    'DiagTrack' = @('Remove', 'Telemetry')
    'dmwappushservice' = @('Remove', 'Telemetry push routing')
    'MapsBroker' = @('Remove', 'Offline maps')
    'RemoteRegistry' = @('Remove', 'Remote registry access')
    # Updaters and app helpers
    'edgeupdate' = @('Manual', 'Edge updater service; Edge also updates through its scheduled tasks, which FocusedTweaks keeps')
    'edgeupdatem' = @('Manual', 'Edge updater service; Edge also updates through its scheduled tasks, which FocusedTweaks keeps')
    'MozillaMaintenance' = @('Manual', 'Firefox silent updater')
    'Steam Client Service' = @('Manual', 'Steam starts it when needed')
    'CoworkVMService' = @('Manual', 'Claude desktop Cowork; Manual if you do not use Cowork')
    # Security: a choice, not bloat
    'WinDefend' = @('Keep', 'Microsoft Defender antivirus (turning it off is a security trade-off)')
    'MDCoreSvc' = @('Keep', 'Microsoft Defender core')
    'WdNisSvc' = @('Keep', 'Microsoft Defender network inspection')
}

# Optional Windows features worth knowing about: what turning them off gains.
$FeatureAdvice = [ordered]@{
    'Microsoft-Hyper-V-All' = 'Hyper-V. Keeps the Windows hypervisor running (a few % CPU, more latency); needed for Hyper-V VMs'
    'VirtualMachinePlatform' = 'Virtual Machine Platform. Starts the hypervisor; needed for WSL 2 and Android apps'
    'HypervisorPlatform' = 'Windows Hypervisor Platform. Lets VMware and VirtualBox run on top of Hyper-V'
    'Microsoft-Windows-Subsystem-Linux' = 'WSL. Needed to run Linux distributions'
    'Containers-DisposableClientVM' = 'Windows Sandbox. Starts the hypervisor when used'
    'SMB1Protocol' = 'SMB 1.0. Old file sharing protocol, a security risk; no speed effect'
    'MicrosoftWindowsPowerShellV2Root' = 'PowerShell 2.0. Old engine attackers use to dodge logging; no speed effect'
    'Recall' = 'Recall. Takes and indexes screenshots in the background'
    'WorkFolders-Client' = 'Work Folders. Company file sync, rarely used at home'
    'WindowsMediaPlayer' = 'Windows Media Player Legacy. Old player, no speed effect'
}

function Show-Features {
    Write-Host "`nOptional Windows features" -ForegroundColor Cyan
    try { $on = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' } | ForEach-Object { $_.FeatureName }) }
    catch { Write-Host '  Run as administrator to list them.'; return }
    $hits = @($FeatureAdvice.Keys | Where-Object { $on -contains $_ })
    if ($hits.Count -eq 0) { Write-Host '  None of the features in the built-in list is turned on.'; return }
    foreach ($f in $hits) { Write-Host ("  {0,-34} {1}" -f $f, $FeatureAdvice[$f]) }
    $hyper = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    if ($hyper) { Write-Host '  The Windows hypervisor is running. Memory integrity (core isolation) also needs it, so removing the features above may not stop it.' }
}

function Get-BaseName([string]$Name) { return ($Name -replace '_[0-9a-f]{4,8}$', '') }

function Get-Company([string]$Path) {
    if (-not $Path) { return '' }
    try { return [string][Diagnostics.FileVersionInfo]::GetVersionInfo($Path).CompanyName } catch { return '' }
}

function Get-Category($Proc, [string]$Company) {
    $path = [string]$Proc.ExecutablePath
    if ($Proc.Name -eq 'svchost.exe') { return 'Windows service hosts' }
    if ($Proc.Name -match '^(MsMpEng|NisSrv|MpDefenderCoreService|SecurityHealthService)\.exe$') { return 'Defender' }
    if ($Proc.Name -match '^msedgewebview2\.exe$') { return 'WebView (browser engine inside apps)' }
    if ($path -match '\\DriverStore\\' -or $Proc.Name -match '^WUDFHost\.exe$') { return 'Drivers and vendor services' }
    if ($Company -and $Company -notmatch 'Microsoft') {
        if ($path -match '\\Program Files|\\AppData\\|\\scoop\\') { return 'Your apps' }
        return 'Drivers and vendor services'
    }
    if (-not $path -or $path -match '\\Windows\\') { return 'Windows' }
    return 'Your apps'
}

function Get-Snapshot {
    $procs = @(Get-CimInstance Win32_Process)
    $svcs = @(Get-CimInstance Win32_Service)
    $byPid = @{}
    foreach ($p in $procs) { $byPid[[int]$p.ProcessId] = $p }
    $rows = foreach ($p in $procs) {
        $company = Get-Company $p.ExecutablePath
        $parent = $null
        if ($byPid.ContainsKey([int]$p.ParentProcessId)) { $parent = $byPid[[int]$p.ParentProcessId].Name }
        [pscustomobject]@{
            Name = $p.Name; Id = [int]$p.ProcessId; Parent = $parent; Company = $company
            MB = [Math]::Round([double]$p.WorkingSetSize / 1MB, 1); Category = Get-Category $p $company
        }
    }
    $running = @($svcs | Where-Object { $_.State -eq 'Running' })
    $services = foreach ($s in $running) {
        $exe = ([string]$s.PathName -replace '^"([^"]+)".*$', '$1') -replace '^(\S+\.exe).*$', '$1'
        [pscustomobject]@{ Name = Get-BaseName $s.Name; Display = $s.DisplayName; StartMode = $s.StartMode; ProcessId = [int]$s.ProcessId; Company = Get-Company $exe; Shared = ($s.PathName -match 'svchost') }
    }
    $ram = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    return [pscustomobject]@{ Machine = $env:COMPUTERNAME; When = (Get-Date).ToString('s'); RamGB = $ram; Processes = @($rows); Services = @($services) }
}

function Show-Report($Snap) {
    $procs = @($Snap.Processes); $services = @($Snap.Services)
    Write-Host ''
    Write-Host ("{0}: {1} processes, {2} running services, {3} GB RAM" -f $Snap.Machine, $procs.Count, $services.Count, $Snap.RamGB) -ForegroundColor Cyan
    $hosts = @($procs | Where-Object { $_.Name -eq 'svchost.exe' }).Count
    if ($Snap.RamGB -gt 3.5) { Write-Host "  $hosts are svchost: with more than 3.5 GB of RAM Windows runs most services in their own svchost, so a high count is normal." }

    Write-Host "`nBy origin" -ForegroundColor Cyan
    $procs | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
        $mb = [Math]::Round((($_.Group | Measure-Object MB -Sum).Sum), 0)
        $top = ($_.Group | Group-Object Name | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { if ($_.Count -gt 1) { "$($_.Name -replace '\.exe$','') x$($_.Count)" } else { $_.Name -replace '\.exe$', '' } }) -join ', '
        Write-Host ("  {0,4}  {1,-38} {2,6} MB  {3}" -f $_.Count, $_.Name, $mb, $top)
    }

    $views = @($procs | Where-Object { $_.Name -eq 'msedgewebview2.exe' -and $_.Parent -ne 'msedgewebview2.exe' })
    if ($views.Count -gt 0) {
        Write-Host "`nWebView started by" -ForegroundColor Cyan
        $views | Group-Object Parent | ForEach-Object { Write-Host ("  {0} (each root WebView brings several helper processes)" -f $_.Name) }
    }

    Write-Host "`nServices with advice" -ForegroundColor Cyan
    $known = @($services | Where-Object { $Advice.ContainsKey($_.Name) } | Sort-Object { $Advice[$_.Name][0] }, Name)
    foreach ($s in $known) {
        $a = $Advice[$s.Name]
        $colour = switch ($a[0]) { 'Keep' { 'Gray' } 'Manual' { 'Yellow' } default { 'Green' } }
        Write-Host ("  {0,-7} {1,-30} {2}" -f $a[0], $s.Name, $a[1]) -ForegroundColor $colour
    }
    if ($known.Count -eq 0) { Write-Host '  None of the services in the built-in list are running.' }

    $other = @($services | Where-Object { -not $Advice.ContainsKey($_.Name) -and $_.Company -and $_.Company -notmatch 'Microsoft' })
    if ($other.Count -gt 0) {
        Write-Host "`nOther non-Microsoft services (no advice, look them up before changing)" -ForegroundColor Cyan
        foreach ($s in ($other | Sort-Object Company, Name)) { Write-Host ("  {0,-30} {1,-8} {2}" -f $s.Name, $s.StartMode, $s.Company) }
    }
    Show-Features
    Write-Host "`nKeep: needed. Manual: safe to set to Manual (Services, or Set-Service -StartupType Manual as admin)."
    Write-Host 'Remove: uninstall the app it belongs to, or let FocusedTweaks disable the Windows ones. Nothing was changed.'
}

function Show-Comparison([string]$A, [string]$B) {
    $sa = Get-Content -LiteralPath $A -Raw | ConvertFrom-Json
    $sb = Get-Content -LiteralPath $B -Raw | ConvertFrom-Json
    # Two snapshots of one machine (before and after a run) are told apart by their time.
    if ($sa.Machine -eq $sb.Machine) { $sa.Machine = "$($sa.Machine) at $($sa.When)"; $sb.Machine = "$($sb.Machine) at $($sb.When)" }
    Write-Host ("`n{0} ({1} processes, {2} services)  vs  {3} ({4} processes, {5} services)" -f $sa.Machine, @($sa.Processes).Count, @($sa.Services).Count, $sb.Machine, @($sb.Processes).Count, @($sb.Services).Count) -ForegroundColor Cyan
    $svcA = @($sa.Services | ForEach-Object { $_.Name }); $svcB = @($sb.Services | ForEach-Object { $_.Name })
    foreach ($pair in @(@($sa, $svcA, $svcB), @($sb, $svcB, $svcA))) {
        $only = @($pair[0].Services | Where-Object { $pair[2] -notcontains $_.Name } | Sort-Object Name)
        Write-Host "`nRunning only on $($pair[0].Machine) ($($only.Count))" -ForegroundColor Cyan
        foreach ($s in $only) {
            $note = ''
            if ($Advice.ContainsKey($s.Name)) { $note = "{0}: {1}" -f $Advice[$s.Name][0], $Advice[$s.Name][1] }
            Write-Host ("  {0,-32} {1}" -f $s.Name, $note)
        }
    }
    $countA = @{}; foreach ($g in ($sa.Processes | Group-Object Name)) { $countA[$g.Name] = $g.Count }
    $countB = @{}; foreach ($g in ($sb.Processes | Group-Object Name)) { $countB[$g.Name] = $g.Count }
    Write-Host "`nProcess counts that differ" -ForegroundColor Cyan
    $names = @($countA.Keys) + @($countB.Keys) | Sort-Object -Unique
    $diffs = foreach ($n in $names) {
        $x = 0; $y = 0
        if ($countA.ContainsKey($n)) { $x = $countA[$n] }
        if ($countB.ContainsKey($n)) { $y = $countB[$n] }
        if ($x -ne $y) { [pscustomobject]@{ Name = $n; A = $x; B = $y; Delta = [Math]::Abs($x - $y) } }
    }
    foreach ($d in (@($diffs) | Sort-Object Delta -Descending | Select-Object -First 25)) { Write-Host ("  {0,-34} {1,4} vs {2,4}" -f $d.Name, $d.A, $d.B) }
}

if ($Compare) {
    # powershell -File passes "a.json,b.json" as one string, so split it here.
    $Compare = @($Compare | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (@($Compare).Count -ne 2) { throw '-Compare takes two snapshot files, for example -Compare desktop.json, laptop.json' }
    Show-Comparison $Compare[0] $Compare[1]
    return
}
$snap = Get-Snapshot
Show-Report $snap
if ($SaveSnapshot) {
    ConvertTo-Json -InputObject $snap -Depth 4 | Set-Content -LiteralPath $SaveSnapshot -Encoding UTF8
    Write-Host "`nSnapshot saved to $SaveSnapshot" -ForegroundColor Cyan
}
