#region Options ---------------------------------------------------------------------------
# Name = default state, description, evidence tier, source. Defaults mirror upstream unless noted. The tier says what
# backs the option's effect (docs/AUDIT.md C-3); it is information only and never decides a default:
# Measured (a measurement on real hardware), Documented (a vendor page describes the mechanism; the size of the
# effect is not measured here), Folklore (repeated without a measurement), n/a (not about speed).
$OptionInfo = [ordered]@{
    Packages              = @($true, 'winget: runtimes, Firefox, 7-Zip, Autoruns, and NVIDIA Profile Inspector when an NVIDIA GPU is present', 'n/a', '')
    Debloat               = @($true, 'Remove consumer apps (keep list protects Store, Xbox, Edge, Paint, Photos and more)', 'Folklore', '')
    Registry              = @($true, 'Upstream RegTweaks.txt (about 270 keys, 470 values), all groups except those with their own option below', 'Folklore', '')
    Uac                   = @($true, 'Disable User Account Control (EnableLUA 0) and LUA file virtualization', 'Folklore', '')
    RunKeys               = @($true, 'Delete the startup entries in the HKCU and HKLM Run keys, except those named with -StartupKeep and Windows Security (-StartupReview lists the names)', 'Documented', 'https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys')
    PrivacyDenials        = @($true, 'Deny app access to camera, location, radios, files and more, and reset the consent database', 'n/a', '')
    CoreIsolation         = @($true, 'Disable core isolation (VBS, HVCI, Credential Guard). Faster, but kernel memory loses its hypervisor protection', 'Documented', 'https://support.microsoft.com/en-us/windows/security/windows-security/device-security-in-the-windows-security-app')
    HideLockOption        = @($false, 'Hide Lock in the Start power menu. Off, you excluded it', 'n/a', '')
    HideSleepOption       = @($false, 'Hide Sleep in the Start power menu. Off, you excluded it', 'n/a', '')
    RegHibernateOff       = @($false, 'HibernateEnabled 0 in the registry. Off, you excluded it', 'n/a', '')
    TaskbarEndTask        = @($true, 'Add End task to the right click menu of taskbar apps (Windows 11, upstream registry group)', 'n/a', '')
    DisableHibernate      = @($false, 'powercfg /hibernate off (also removes Fast Startup). Upstream does this with its power plan', 'n/a', '')
    MsiMode               = @($true, 'Enable MSI interrupts for display adapters', 'Folklore', '')
    MemoryCompression     = @($true, 'Disable memory compression when RAM is 32 GB or more', 'Folklore', '')
    SleepStudy            = @($true, 'Turn off Sleep Study and power diagnostic event logs', 'Folklore', '')
    PasswordExpiry        = @($true, 'Local passwords never expire (Windows 11 only)', 'n/a', '')
    FaultTolerantHeap     = @($true, 'Reset the fault tolerant heap (not reversible)', 'Folklore', '')
    NotificationSettings  = @($true, 'Turn off notifications for every app listed under Notifications settings', 'n/a', '')
    RestartExplorer       = @($true, 'Refresh user settings and restart Explorer at the end', 'n/a', '')
    TelemetryPolicy       = @($true, 'Telemetry, CEIP, app compatibility and advertising policy plus DiagTrack services', 'Folklore', '')
    TelemetryHosts        = @($true, 'Block 30 Microsoft telemetry domains in the hosts file', 'Folklore', '')
    BiometricsPolicy      = @($true, 'Policy that disables biometrics (Windows Hello fingerprint and face)', 'n/a', '')
    Cdp                   = @($true, 'Disable the Connected Devices Platform services and clear its cache', 'Folklore', '')
    SvcOther              = @($true, 'Disable misc services: location, maps, Netlogon, tablet input, wallet and more', 'Folklore', '')
    SvcExtra              = @($true, 'Disable contact and user data sync, SSDP discovery, Storage Spaces and the built-in VPN client (RasMan, SstpSvc) (from FR33THY Ultimate)', 'Folklore', '')
    SvcBackground         = @($true, 'Disable background helpers: Mail and Calendar sync, Program Compatibility Assistant, link tracking, app inventory, IP Helper (IPv6 tunnels; WSL localhost forwarding uses it), file sharing from this PC (Server) and clipboard history (Win+V)', 'Folklore', '')
    SvcAggressive         = @($false, 'Also disable push notifications (no toasts; Store and Teams alerts stop), data usage (its Settings page and metered settings stop working) and Shell Hardware Detection (no AutoPlay; scanners and camera import through WIA stop). Off: each costs a visible feature', 'Folklore', '')
    VendorServices        = @($false, 'Laptops: disable Lenovo Vantage and its installer, and presence sensing (Lenovo, ELAN, Intel); set Lenovo standby, camera effects installer and Intel reporting, tuning telemetry and graphics panel services to Manual. Keeps thermal, power, Fn key, audio and display services. On in laptop.json', 'Folklore', '')
    SvcDefrag             = @($false, 'Disable the Optimize Drives service. Off: without it SSDs get no retrim and slow down over time', 'Folklore', '')
    SvcBiometrics         = @($true, 'Disable the Windows Biometric Service', 'Folklore', '')
    SvcSmartCard          = @($true, 'Disable smart card services', 'Folklore', '')
    SvcDiagnostics        = @($true, 'Disable diagnostic policy and Wdi services (troubleshooters)', 'Folklore', '')
    SvcBluetooth          = @($false, 'Disable Bluetooth services. Off, you asked to keep Bluetooth', 'Folklore', '')
    SvcPrinting           = @($false, 'Disable print spooler services. Off, you asked to keep printing', 'Folklore', '')
    SvcDeliveryOpt        = @($true, 'Disable Delivery Optimization (peer to peer update sharing in the background)', 'Documented', 'https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization')
    SvcRadio              = @($false, 'Disable Radio Management (airplane mode and radio toggles). Off, it supports Bluetooth', 'Folklore', '')
    DriverExclusion       = @($true, 'Exclude drivers from Windows Update and stop device metadata downloads', 'n/a', '')
    SecurityUpdatesOnly   = @($true, 'Upstream update block: long deferrals plus excluded update classifications', 'n/a', '')
    PauseUpdates          = @($true, 'Pause updates for -PauseDays and turn off automatic update checks for the same time (NoAutoUpdate policy, removed again by a one-off task when the pause ends; Check for updates still works); update services to Manual', 'Documented', 'https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings')
    PauseStopsUpdateTasks = @($true, 'While pausing, also disable the Update Orchestrator, WaaSMedic and Windows Update tasks', 'n/a', '')
    KeepDefinitionUpdates = @($true, 'Leave Defender definition updates out of the excluded classifications, so Defender keeps current signatures', 'n/a', '')
    RazerAsusHosts        = @($true, 'Block Razer and ASUS software download servers in the hosts file', 'n/a', '')
    MouseAccel            = @($true, 'Turn off mouse acceleration using the profile for your display scaling', 'n/a', '')
    ClearDesktopIcons     = @($true, 'Hide Recycle Bin, This PC and other system icons and move shortcuts off the desktop (restorable)', 'n/a', '')
    HideAllDesktopIcons   = @($false, 'Also hide every other desktop icon (files stay on disk). Same as View, Show desktop icons', 'n/a', '')
    EnableSystemRestore   = @($false, 'If the restore point fails, turn System Protection on for the system drive and retry', 'n/a', '')
    ClearStartPins        = @($true, 'Clear all pinned apps from the Start menu (Windows 11, current user, layout is backed up)', 'n/a', '')
    ForceDpi100           = @($false, 'Force 100% display scaling and drop per-monitor scaling (upstream groups). Off: no speed gain, and it skews the mouse profile', 'Folklore', '')
    NoAutoMaintenance     = @($false, 'Turn off Windows automatic maintenance (upstream group). Off: it runs SSD retrim, and only when idle', 'Folklore', '')
    NoRecentDocsHistory   = @($false, 'Set the NoRecentDocsHistory policy (no recent files anywhere). Also stops pinning to and unpinning from Quick Access', 'n/a', '')
    RemoveQuickAssist     = @($true, 'Remove Quick Assist (Windows capability, package and app). Not reversible by -Revert', 'n/a', '')
    RemoveOneDrive        = @($true, 'Uninstall OneDrive and block it by policy. Skipped while an account is signed in; files in the OneDrive folder stay on disk. Not reversible by -Revert', 'n/a', '')
    RemoveEdge            = @($false, 'Uninstall the Edge browser, keeping WebView2 and its updater (apps need them). Only where Windows allows it (device region in the EEA); refused while Edge is the default browser. Not reversible by -Revert', 'n/a', '')
    EdgeBackground        = @($true, 'Stop Edge running in the background: no startup boost, no background apps once it is closed (policy; Edge then says it is managed)', 'Documented', 'https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#startupboostenabled')
    LegacyFeatures        = @($true, 'Turn off the optional features SMB 1.0, PowerShell 2.0, Recall, Work Folders and Windows Media Player Legacy. Needs a restart', 'n/a', '')
    HypervisorFeatures    = @($false, 'Turn off Hyper-V, Virtual Machine Platform, Windows Hypervisor Platform, WSL and Windows Sandbox. Off: VMs and WSL need them. Needs a restart', 'Folklore', '')
    WindowsAIOff          = @($true, 'Copilot and Windows AI off for your account too (the upstream group sets machine values; Microsoft documents some as per user), and the Edge sidebar with Copilot hidden (policy)', 'n/a', 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-windowsai')
    DefenderQuiet         = @($true, 'Keep Defender on but turn off cloud reporting, sample submission, infection reports and notifications (policy)', 'n/a', '')
    NetAdapterPower       = @($true, 'Turn off power saving on physical network adapters (allow-off and wake flags, green Ethernet, ultra low power)', 'Documented', 'https://learn.microsoft.com/en-us/windows-hardware/drivers/network/standardized-inf-keywords-for-power-management')
    NetAdapterEee         = @($true, 'Turn off Energy Efficient Ethernet on physical network adapters that expose it', 'Documented', 'https://learn.microsoft.com/en-us/windows-hardware/drivers/network/standardized-inf-keywords-for-power-management')
    TempCleanup           = @($true, 'Delete the contents of the user and Windows Temp folders (files in use are skipped). Not reversible', 'Folklore', '')
    UpdateCacheCleanup    = @($true, 'Delete the Windows Update download cache (SoftwareDistribution\Download). Not reversible', 'Folklore', '')
    SpectreMeltdownOff    = @($true, 'Turn off Spectre and Meltdown mitigations (FeatureSettingsOverride). Faster CPU, but programs and websites can read memory they should not. Needs a restart', 'Documented', 'https://support.microsoft.com/en-us/topic/kb4073119-windows-client-guidance-for-it-pros-to-protect-against-silicon-based-microarchitectural-and-speculative-execution-side-channel-vulnerabilities-35820a8a-ae13-1299-88cc-357f104f5b11')
    TimerResolution       = @($true, 'Compile and install a small service that holds the timer at its finest resolution (about 0.5 ms). Windows 11 only; skipped on machines with a battery', 'Documented', 'https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod')
    DevicePowerSaving     = @($true, 'Turn off power saving and selective suspend for ACPI, HID, PCI and USB devices (skipped on battery)', 'Documented', 'https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/usb-selective-suspend')
    DeviceWakeOff         = @($false, 'Stop devices waking the PC (keyboard and mouse can no longer wake it from sleep)', 'n/a', '')
    MpoOff                = @($false, 'Turn off multiplane overlay (OverlayTestMode 5). Can fix flicker and stutter, can break some HDR setups', 'Folklore', '')
    WriteCacheFlushOff    = @($false, 'Turn off write cache buffer flushing on SATA and NVMe disks. Faster, but a power cut can lose data', 'Folklore', '')
    FastShutdown          = @($true, 'Shorter shutdown timeouts and end hung apps automatically. Unsaved work in hung apps is lost', 'n/a', '')
    BlockFeatureUpgrades  = @($false, 'Stay on the current Windows version (TargetReleaseVersion). Security updates continue until it ends', 'n/a', '')
    SearchIndexingOff     = @($true, 'Disable the Windows Search indexer service (search in Start and Explorer gets slower)', 'Documented', 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-search')
    TimeServerPool        = @($true, 'Sync the clock from pool.ntp.org instead of time.windows.com', 'n/a', '')
    MenuKillNotResponding = @($true, 'Add "Kill not responding tasks" to the desktop right click menu', 'n/a', '')
    MenuRestartExplorer   = @($true, 'Add "Restart Explorer" to the desktop right click menu', 'n/a', '')
    MenuTakeOwnership     = @($false, 'Add "Take ownership" to the right click menu of files and folders (easy to misuse on system files)', 'n/a', '')
    MenuRunAsAdmin        = @($false, 'Add "Run as administrator" to .ps1, .msi and .vbs files (.bat and .cmd already have it)', 'n/a', '')
    MenuNoShare           = @($false, 'Remove "Share" from the right click menu', 'n/a', '')
    MenuNoGiveAccess      = @($false, 'Remove "Give access to" from the right click menu', 'n/a', '')
    MenuNoCast            = @($false, 'Remove "Cast to device" from the right click menu', 'n/a', '')
    MenuNoLibrary         = @($false, 'Remove "Include in library" from the right click menu', 'n/a', '')
    MenuNoQuickAccess     = @($false, 'Remove "Pin to Quick access" and "Add to favorites" from the right click menu', 'n/a', '')
    MenuNoPinToStart      = @($false, 'Remove "Pin to Start" from the right click menu', 'n/a', '')
    MenuNoPrevVersions    = @($false, 'Remove "Restore previous versions" from the right click menu and Properties', 'n/a', '')
    MenuNoTroubleshoot    = @($false, 'Remove "Troubleshoot compatibility" from the right click menu', 'n/a', '')
    MenuNoDefenderScan    = @($false, 'Remove "Scan with Microsoft Defender" from the right click menu', 'n/a', '')
    MenuNoOneDrive        = @($false, 'Remove "Move to OneDrive" from the right click menu', 'n/a', '')
    MenuNoTerminal        = @($false, 'Remove "Open in Terminal" from the right click menu', 'n/a', '')
    LockScreenOff         = @($false, 'Skip the lock screen picture and go straight to sign in (policy)', 'n/a', '')
    IPv4Only              = @($false, 'Turn off IPv6 on physical network adapters. Breaks IPv6-only networks and some VPNs', 'Folklore', '')
    HardwareGpuScheduling = @($true, 'Turn on hardware accelerated GPU scheduling (HwSchMode 2, upstream group). Skipped when no display driver is WDDM 2.7 or later. Needs a restart', 'Documented', 'https://devblogs.microsoft.com/directx/hardware-accelerated-gpu-scheduling/')
    NvmeNativeDriver      = @($false, 'Use the newer native NVMe driver (Windows 11 24H2+). Experimental, disk tools and BitLocker may misbehave', 'Documented', 'https://techcommunity.microsoft.com/blog/windowsservernewsandbestpractices/announcing-native-nvme-in-windows-server-2025-ushering-in-a-new-era-of-storage-p/4477353')
    HealthCheckAfter      = @($true, 'Run the health check at the end of a run (standalone: -HealthCheck)', 'n/a', '')
    NvidiaProfile         = @($true, 'NVIDIA GPUs only: import a low latency, maximum performance global profile with Profile Inspector (the driver settings are backed up first)', 'Folklore', '')
    NvidiaReBar           = @($false, 'NVIDIA GPUs only: force Resizable BAR on for every game. Off: helps some games and slows others, and needs ReBar on in the BIOS', 'Folklore', '')
    NvidiaTelemetryStrip  = @($true, 'After an NVIDIA install, remove telemetry DLLs and container plugins', 'Folklore', '')
}
$EvidenceTiers = @('Measured', 'Documented', 'Folklore', 'n/a')
$Opt = @{}
foreach ($k in $OptionInfo.Keys) { $Opt[$k] = [bool]$OptionInfo[$k][0] }

$BoundNames = @($PSBoundParameters.Keys)
# What was typed on the command line, as opposed to read from a profile (see Resolve-Options and -Only).
$CommandLineNames = @($PSBoundParameters.Keys)
$ProfileNames = @()

function Import-RunProfile {
    # A profile holds the same choices as the command line. Anything also given on the command line wins.
    if (-not $ProfilePath) { return }
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) { throw "Profile not found: $ProfilePath" }
    $data = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
    $lists = 'Enable', 'Skip', 'Only', 'SkipRegGroup', 'TaskKeep', 'StartupKeep'
    $choices = @{ TaskMode = @('Delete', 'Disable', 'None'); ServiceMode = @('Disable', 'Delete'); Defender = @('Keep', 'Disable', 'Enable'); PowerProfile = @('Off', 'Medium', 'High'); PowerMode = @('Keep', 'Balanced', 'Best') }
    foreach ($prop in $data.PSObject.Properties) {
        $name = $prop.Name
        if ($BoundNames -contains $name) { continue }
        $script:ProfileNames += $name
        if ($lists -contains $name) { Set-Variable -Scope Script -Name $name -Value @([string[]]@($prop.Value)) }
        elseif ($choices.ContainsKey($name)) {
            if ($choices[$name] -notcontains [string]$prop.Value) { throw "Profile: $name must be one of $($choices[$name] -join ', ')." }
            Set-Variable -Scope Script -Name $name -Value ([string]$prop.Value)
            $script:BoundNames += $name
        }
        elseif ($name -eq 'PauseDays') {
            $days = [int]$prop.Value
            if ($days -lt 1 -or $days -gt 730) { throw 'Profile: PauseDays must be between 1 and 730.' }
            $script:PauseDays = $days
        }
        else { throw "Profile: unknown setting '$name'. Valid: $(($lists + @($choices.Keys) + 'PauseDays') -join ', ')." }
    }
}
Import-RunProfile

function Resolve-Options {
    $enableList = $Enable; $skipList = $Skip
    if ($Only.Count -gt 0) {
        # -Only runs just the options you name: everything else is switched off. When -Only was typed on the command
        # line, a profile's choices and Enable/Skip lists do not apply either, only what was typed. A profile that
        # holds Only itself keeps its other settings, since its author chose them together.
        $typed = $CommandLineNames -contains 'Only'
        $keep = { param($n) ($CommandLineNames -contains $n) -or (-not $typed -and $ProfileNames -contains $n) }
        foreach ($k in @($OptionInfo.Keys)) { $Opt[$k] = $false }
        if (-not (& $keep 'TaskMode')) { $script:TaskMode = 'None' }
        if (-not (& $keep 'ServiceMode')) { $script:ServiceMode = 'Disable' }
        if (-not (& $keep 'PowerProfile')) { $script:PowerProfile = 'Off' }
        if (-not (& $keep 'PowerMode')) { $script:PowerMode = 'Keep' }
        if (-not (& $keep 'Defender')) { $script:Defender = 'Keep' }
        if (-not (& $keep 'Enable')) { $enableList = @() }
        if (-not (& $keep 'Skip')) { $skipList = @() }
    }
    foreach ($pair in @(@($Only, $true), @($enableList, $true), @($skipList, $false))) {
        # powershell -File passes "A,B" as one string, so each entry is split on commas here. Only option names are
        # split: registry group titles (-SkipRegGroup) can contain a comma.
        foreach ($name in @($pair[0] | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $match = $OptionInfo.Keys | Where-Object { $_ -ieq $name } | Select-Object -First 1
            if (-not $match) { throw "Unknown option '$name'. Run with -ListOptions to see the valid names." }
            $Opt[$match] = $pair[1]
        }
    }
}

if ($ListOptions) {
    Write-Host ('{0,-24} {1,-5} {2,-11} {3}' -f 'Option', 'Def.', 'Evidence', 'What it does')
    foreach ($k in $OptionInfo.Keys) {
        Write-Host ('{0,-24} {1,-5} {2,-11} {3}' -f $k, $(if ($OptionInfo[$k][0]) { 'on' } else { 'off' }), $OptionInfo[$k][2], $OptionInfo[$k][1])
    }
    Write-Host 'Evidence: Documented (a vendor page describes the mechanism, sources in docs\OPTIONS.md), Folklore (no measurement), n/a (not about speed).'
    Write-Host ''
    Write-Host 'Run only some options: -Only Name1,Name2 (everything else is switched off).'
    Write-Host 'Other choices: -TaskMode Delete|Disable|None (default Delete), -ServiceMode Disable|Delete (default Disable),'
    Write-Host '-Defender Keep|Disable|Enable, -PowerProfile Off|Medium|High,'
    Write-Host '-PowerMode Keep|Balanced|Best, -PauseDays 1..730, -SkipRegGroup <title wildcards>, -TaskKeep <task path wildcards>,'
    Write-Host '-StartupKeep <startup entry name wildcards> (RunKeys keeps those; -StartupReview lists the names).'
    Write-Host 'Keep a set of choices in a file: -ProfilePath file.json (see profiles\example.json).'
    Write-Host 'Measure before and after a run: tools\Measure-Performance.ps1 (add -FrameProcess game.exe for game frame times).'
    Write-Host 'List startup entries without changing them: -StartupReview.'
    Write-Host 'After a Windows update put back what it undid: -Reapply -DryRun to list it, then -Reapply.'
    Write-Host 'Pre flight checks run before every run; skip one by name with -SkipCheck <name>. A managed PC (domain, Entra ID, MDM) is refused unless -AllowManaged.'
    Write-Host 'Undo only some deleted or disabled tasks: -RestoreTask <task path wildcards>, for example -RestoreTask ''\Microsoft\Windows\Application Experience\*''.'
    exit 0
}
Resolve-Options
$WantNvidia = [bool]($NvidiaInstaller -or $NvidiaDownload -or $NvidiaVersion)
#endregion

