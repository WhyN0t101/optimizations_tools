#Requires -Version 5.1
<#
.SYNOPSIS
    Focused Windows 10/11 tweak script derived from ZOICWARE (MIT licence, copyright (c) 2024 zoicware). v7.4.

.DESCRIPTION
    A stripped down port of the ZOICWARE features in the supplied ZCONFIG, with every risky item exposed as a
    named option. Defaults aim for maximum performance with Windows still usable: things are removed or left
    alone, never half done. Left alone by default because removing them gains nothing or costs speed: SSD
    retrim (Optimize Drives service, Defrag tasks, automatic maintenance), time sync, TPM and BitLocker tasks,
    display scaling, hide Lock, hide Sleep, hibernation, and the Bluetooth, printing and radio services.
    Machine profiles (-ProfilePath) relax the defaults, for example a laptop keeping Spectre mitigations.

    Everything that changes the registry, hosts file, services, scheduled tasks, power plan and mode,
    hibernation, memory compression, sleep study logs, account password age, optional features, the NVIDIA
    driver settings and Defender is recorded first, and the state is saved after every step, so -Revert can
    restore it even after an interrupted run.

    Not reversible by -Revert: app debloat, Quick Assist removal, software installed by winget or NVIDIA, NVIDIA
    driver files removed by the telemetry strip, the fault tolerant heap reset, the Connected Devices Platform
    cache, the temp and update cache cleanup, and System Protection once switched on.

    SpectreMeltdownOff, CoreIsolation and the TimerResolution service are on by default: they trade security
    or battery for speed. Switch them off with -Skip. DepOff stays off because it needs Secure Boot off.

    Not ported from upstream (they edit per app settings.dat hives or are cosmetic): Store and App Actions
    settings, calendar expansion, priority notification blob, terminal and console colours, Task Manager
    always on top, DDU and Safe Mode driver cleaning.

    Use -Only A,B to run just those options (for example -Only ClearStartPins,RemoveQuickAssist).
    Use -ListOptions to see every option and its default, -ListRegGroups to see the registry groups.
    Use -HealthCheck at any time (ideally after a restart) to verify the result against the options you chose;
    add -HealthCheckLaunch to also open Settings, Store, Photos, Paint and Xbox and confirm they start.
    Use -Skip Name1,Name2 to switch options off and -Enable Name1,Name2 to switch them on.

    Started without administrator rights (right click, Run with PowerShell), the script asks for elevation and runs
    again in a new elevated window with the same parameters.

    Use -ProfilePath file.json to keep a set of choices in a file (see profiles\example.json). Parameters given on
    the command line win over the profile. Starter profiles: desktop-max.json, laptop.json, privacy.json.

    Use -Revert to undo a run, or -RestoreTask <task path wildcards> to bring back only some deleted or disabled tasks.

    Unattended: -Json prints one result object and nothing else on the console (the log file still gets everything);
    a real run with -Json needs -Force, since it cannot answer questions. Exit codes: 0 ok, 1 failures (or a failed
    health check), 2 cancelled, 3 pre flight refused (also: not elevated with -Json), 4 state unreadable.
    tools\Explain-Processes.ps1 explains what is running and why, without changing anything.

.EXAMPLE
    .\FocusedTweaks.ps1 -ListOptions

.EXAMPLE
    .\FocusedTweaks.ps1 -ProfilePath .\profiles\laptop.json -DryRun

.EXAMPLE
    .\FocusedTweaks.ps1 -RestoreTask '\Microsoft\Windows\Application Experience\*'

.EXAMPLE
    .\FocusedTweaks.ps1 -DryRun

.EXAMPLE
    .\FocusedTweaks.ps1 -Skip Uac,RunKeys -Enable MpoOff -PauseDays 30

.EXAMPLE
    .\FocusedTweaks.ps1 -NvidiaDownload -NvidiaApp

.EXAMPLE
    .\FocusedTweaks.ps1 -HealthCheck -HealthCheckLaunch

.EXAMPLE
    .\FocusedTweaks.ps1 -Revert
#>
[CmdletBinding()]
param(
    [switch]$Revert,
    [string[]]$RestoreTask = @(),
    [switch]$DryRun,
    [switch]$Force,
    [switch]$ListOptions,
    [switch]$ListRegGroups,
    [switch]$HealthCheck,
    [switch]$HealthCheckLaunch,
    [string[]]$Skip = @(),
    [string[]]$Enable = @(),
    [string[]]$Only = @(),
    [string[]]$SkipRegGroup = @(),
    [ValidateSet('Delete', 'Disable', 'None')][string]$TaskMode = 'Delete',
    [string[]]$TaskKeep = @(),
    [ValidateSet('Keep', 'Disable', 'Enable')][string]$Defender = 'Keep',
    [ValidateSet('Off', 'Medium', 'High')][string]$PowerProfile = 'High',
    [ValidateSet('Keep', 'Balanced', 'Best')][string]$PowerMode = 'Keep',
    [string]$NvidiaInstaller,
    [switch]$NvidiaDownload,
    [string]$NvidiaVersion,
    [switch]$NvidiaNotebook,
    [switch]$NvidiaApp,
    [switch]$NvidiaHdAudio,
    [switch]$NvidiaNoClean,
    [switch]$SkipRestorePoint,
    [switch]$ForcePowerPlanOnLaptop,
    [ValidateRange(1, 730)][int]$PauseDays = 365,
    [string]$ProfilePath,
    [switch]$Benchmark,
    [ValidateRange(1, 50)][int]$BenchmarkRuns = 5,
    [ValidateRange(10, 600)][int]$BenchmarkIdleSeconds = 60,
    [ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$BenchmarkBaseline,
    [switch]$StartupReview,
    [switch]$AllowManaged,
    [string[]]$SkipCheck = @(),
    [switch]$Json,
    [string]$StateDir = (Join-Path $env:ProgramData 'FocusedTweaks')
)

# Needs administrator rights, but a '#Requires -RunAsAdministrator' line would stop the script before any code runs, so
# right click, Run with PowerShell could never work. Instead start again elevated, with the same parameters.
# -ListOptions and -ListRegGroups only print, so they run without elevation.
if (-not ($ListOptions -or $ListRegGroups)) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if (-not $PSCommandPath) { throw 'This script needs administrator rights. Start PowerShell as administrator and run it from a file.' }
        # An unattended caller cannot accept an elevation prompt and would never see the result of the new window.
        if ($Json) {
            ConvertTo-Json -InputObject ([ordered]@{ ExitCode = 3; Result = 'pre flight refused'; Reason = 'Administrator rights are needed. Start the -Json run from an elevated PowerShell.' })
            exit 3
        }
        $quote = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
        $forwarded = foreach ($entry in $PSBoundParameters.GetEnumerator()) {
            if ($entry.Value -is [switch]) { if ($entry.Value.IsPresent) { "-$($entry.Key)" } }
            elseif (@($entry.Value).Count -gt 0) { "-$($entry.Key) " + ((@($entry.Value) | ForEach-Object { & $quote $_ }) -join ',') }
        }
        $command = "Set-Location -LiteralPath $(& $quote $PWD.ProviderPath); & $(& $quote $PSCommandPath) $(@($forwarded) -join ' ')"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        Write-Host 'Administrator rights are needed. Accept the prompt to continue in an elevated window.'
        try {
            Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ErrorAction Stop `
                -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-EncodedCommand', $encoded
        }
        catch { throw "Could not start the script as administrator: $($_.Exception.Message)" }
        exit 0
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    RunKeys               = @($true, 'Delete the HKCU and HKLM Run keys once, clearing every startup entry', 'Documented', 'https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys')
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
    PauseUpdates          = @($true, 'Pause updates for -PauseDays and set update services to Manual', 'n/a', '')
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
    LegacyFeatures        = @($true, 'Turn off the optional features SMB 1.0, PowerShell 2.0, Recall, Work Folders and Windows Media Player Legacy. Needs a restart', 'n/a', '')
    HypervisorFeatures    = @($false, 'Turn off Hyper-V, Virtual Machine Platform, Windows Hypervisor Platform, WSL and Windows Sandbox. Off: VMs and WSL need them. Needs a restart', 'Folklore', '')
    DefenderQuiet         = @($true, 'Keep Defender on but turn off cloud reporting, sample submission, infection reports and notifications (policy)', 'n/a', '')
    NetAdapterPower       = @($true, 'Turn off power saving on physical network adapters (allow-off and wake flags, green Ethernet, ultra low power)', 'Documented', 'https://learn.microsoft.com/en-us/windows-hardware/drivers/network/standardized-inf-keywords-for-power-management')
    NetAdapterEee         = @($true, 'Turn off Energy Efficient Ethernet on physical network adapters that expose it', 'Documented', 'https://learn.microsoft.com/en-us/windows-hardware/drivers/network/standardized-inf-keywords-for-power-management')
    TempCleanup           = @($true, 'Delete the contents of the user and Windows Temp folders (files in use are skipped). Not reversible', 'Folklore', '')
    UpdateCacheCleanup    = @($true, 'Delete the Windows Update download cache (SoftwareDistribution\Download). Not reversible', 'Folklore', '')
    SpectreMeltdownOff    = @($true, 'Turn off Spectre and Meltdown mitigations (FeatureSettingsOverride). Faster CPU, but programs and websites can read memory they should not. Needs a restart', 'Documented', 'https://support.microsoft.com/en-us/topic/kb4073119-windows-client-guidance-for-it-pros-to-protect-against-silicon-based-microarchitectural-and-speculative-execution-side-channel-vulnerabilities-35820a8a-ae13-1299-88cc-357f104f5b11')
    DepOff                = @($false, 'Turn off Data Execution Prevention (bcdedit nx AlwaysOff). Secure Boot must be off. Needs a restart', 'Folklore', '')
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
    $lists = 'Enable', 'Skip', 'Only', 'SkipRegGroup', 'TaskKeep'
    $choices = @{ TaskMode = @('Delete', 'Disable', 'None'); Defender = @('Keep', 'Disable', 'Enable'); PowerProfile = @('Off', 'Medium', 'High'); PowerMode = @('Keep', 'Balanced', 'Best') }
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
    Write-Host 'Other choices: -TaskMode Delete|Disable|None (default Delete), -Defender Keep|Disable|Enable, -PowerProfile Off|Medium|High,'
    Write-Host '-PowerMode Keep|Balanced|Best, -PauseDays 1..730, -SkipRegGroup <title wildcards>, -TaskKeep <task path wildcards>.'
    Write-Host 'Keep a set of choices in a file: -ProfilePath file.json (see profiles\example.json).'
    Write-Host 'Measure before and after a run: -Benchmark. List startup entries without changing them: -StartupReview.'
    Write-Host 'Pre flight checks run before every run; skip one by name with -SkipCheck <name>. A managed PC (domain, Entra ID, MDM) is refused unless -AllowManaged.'
    Write-Host 'Undo only some deleted or disabled tasks: -RestoreTask <task path wildcards>, for example -RestoreTask ''\Microsoft\Windows\Application Experience\*''.'
    exit 0
}
Resolve-Options
$script:DryRun = [bool]$DryRun
$WantNvidia = [bool]($NvidiaInstaller -or $NvidiaDownload -or $NvidiaVersion)
#endregion

#region Data (generated from the upstream ZOICWARE source) ---------------------------------
function New-Tweak {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    [pscustomobject]@{ Path = $Path; Name = $Name; Value = $Value; Type = $Type }
}

# Upstream src/RegTweaks.txt, unchanged. Groups are the comment lines above each section.
$UpstreamRegText = @'
Windows Registry Editor Version 5.00

; Restore the classic context menu
[HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]
@=""

; Disable core isolation (VBS)
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity]
"Enabled"=dword:00000000
"WasEnabledBy"=-
"ChangedInBootCycle"=-

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceGuard]
"EnableVirtualizationBasedSecurity"=dword:00000000
"RequirePlatformSecurityFeatures"=dword:00000000
"Mandatory"=dword:00000000
"HypervisorEnforcedCodeIntegrity"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard]
"EnableVirtualizationBasedSecurity"=dword:00000000
"LsaCfgFlags"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\KernelShadowStacks]
"Enabled"=dword:00000000
"AuditModeEnabled"=dword:00000000
"WasEnabledBy"=-

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard]
"Enabled"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Security Health\Miscellaneous]
"HvciKeyDismissed"=dword:00000001

; Disable suggested actions
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard]
"Disabled"=dword:00000001

; Disable storage sense
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\StorageSense]
"AllowStorageSenseGlobal"=dword:00000000

; Leftmost taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarAl"=dword:00000000

; Enable action center
[HKEY_CURRENT_USER\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"DisableNotificationCenter"=-

; Disable snap assist and layout
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"EnableSnapAssistFlyout"=dword:00000000
"EnableSnapBar"=dword:00000000
"EnableTaskGroups"=dword:00000000
"SnapAssist"=dword:00000000

; Remove gallery shortcut from file explorer
[-HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}]

; Remove home shortcut from file explorer
[HKEY_CURRENT_USER\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}]
@="CLSID_MSGraphHomeFolder"
"System.IsPinnedToNameSpaceTree"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}]
@="CLSID_MSGraphHomeFolder"
"HiddenByDefault"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu]
"{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel]
"{f874310e-b6b7-47dc-bc84-b9e6b38f5903}"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu]
"{679f85cb-0220-4080-b29b-5540cc05aab6}"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel]
"{679f85cb-0220-4080-b29b-5540cc05aab6}"=dword:00000001

; Open file explorer to this PC
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer]
"HubMode"=dword:00000001

; Disable system requirements
[HKEY_CURRENT_USER\Control Panel\UnsupportedHardwareNotificationCache]
"SV2"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassCPUCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassStorageCheck"=dword:00000001
"BypassTPMCheck"=dword:00000001

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\MoSetup]
"AllowUpgradesWithUnsupportedTPMOrCPU"=dword:00000001

; Show more pins in start menu
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_Layout"=dword:00000001

; Disable show recently added apps and recommendations
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start]
"ShowRecentList"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"HideRecentlyAddedApps"=dword:00000001
"NoInstrumentation"=dword:00000001
"NoStartMenuMFUprogramsList"=dword:00000001
"NoRecentDocsHistory"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"ShowOrHideMostUsedApps"=dword:00000002
"HideRecentlyAddedApps"=dword:00000001
"HideRecommendedPersonalizedSites"=dword:00000001

; Disable AI insights
[HKEY_CURRENT_USER\Software\Microsoft\input\Settings]
"InsightsEnabled"=dword:00000000

; Remove pinned items in network and sound flyout
[HKEY_CURRENT_USER\Control Panel\Quick Actions\Control Center\Unpinned]
"Microsoft.QuickAction.BlueLightReduction"=hex(0):
"Microsoft.QuickAction.Accessibility"=hex(0):
"Microsoft.QuickAction.NearShare"=hex(0):
"Microsoft.QuickAction.Cast"=hex(0):
"Microsoft.QuickAction.ProjectL2"=hex(0):

; Disable Windows AI
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowCopilotButton"=dword:00000000

[HKEY_LOCAL_MACHINE\Software\Policies\Microsoft\Windows\WindowsCopilot]
"TurnOffWindowsCopilot"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsAI]
"DisableAIDataAnalysis"=dword:00000001
"AllowRecallEnablement"=dword:00000000
"DisableClickToDo"=dword:00000001

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\Shell\Copilot\BingChat]
"IsUserEligible"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint]
"DisableGenerativeFill"=dword:00000001
"DisableCocreator"=dword:00000001
"DisableImageCreator"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\WindowsNotepad]
"DisableAIFeatures"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarCompanion"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Policies\Microsoft\Windows\CopilotKey]
"SetCopilotHardwareKey"=""

; Enable end task in taskbar context menu
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings]
"TaskbarEndTask"=dword:00000001

; Disable share app experiences
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CDP]
"RomeSdkChannelUserAuthzPolicy"=dword:00000000
"NearShareChannelUserAuthzPolicy"=dword:00000000
"CdpSessionUserAuthzPolicy"=dword:00000000

; Set background type to solid color
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers]
"BackgroundType"=dword:00000001        

; Disable prompt for location privacy
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location]
"ShowGlobalPrompts"=dword:00000000

; Disable user choice driver
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\UCPD]
"Start"=dword:00000004

; Disable phone companion in start menu
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start]
"RightCompanionToggledOpen"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe]
"IsEnabled"=dword:00000000
"IsAvailable"=dword:00000000

; Disable cross device resume
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration]
"IsResumeAllowed"=dword:00000000
"IsOneDriveResumeAllowed"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration\DynamicAppListing\onedrive]
"IsEnabled"=dword:00000000
"IsSupported"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume]
"value"=dword:00000001

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1387020943]
"EnabledState"=dword:00000001
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\3974600846]
"EnabledState"=dword:00000001
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\2196866703]
"EnabledState"=dword:00000001
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1694661260]
"EnabledState"=dword:00000001
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\3369582732]
"EnabledState"=dword:00000001

; Disable dynamic lighting
[HKEY_CURRENT_USER\Software\Microsoft\Lighting]
"AmbientLightingEnabled"=dword:00000000
"ControlledByForegroundApp"=dword:00000000

; Disable memory compression

; Disable user account control
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System]
"PromptOnSecureDesktop"=dword:00000000
"EnableLUA"=dword:00000000
"ConsentPromptBehaviorAdmin"=dword:00000000

; Disable update apps automatically
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\WindowsStore]
"AutoDownload"=dword:00000002

; Remove chat from taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarMn"=dword:00000000

; Remove task view from taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowTaskViewButton"=dword:00000000

; Remove search from taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Search]
"SearchboxTaskbarMode"=dword:00000000

; Remove meet now
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"HideSCAMeetNow"=dword:00000001

; Remove news and interests
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds]
"EnableFeeds"=dword:00000000

; Always hide most used list in start menu
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"ShowOrHideMostUsedApps"=dword:00000002

; Disable show recently added apps
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"HideRecentlyAddedApps"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"HideRecentlyAddedApps"=dword:00000001

; Disable show recently opened items in start, jump lists and file explorer
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_TrackDocs"=dword:00000000
"Start_TrackProgs"=dword:00000000

; Hide frequent folders in quick access
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer]
"ShowFrequent"=dword:00000000

; Show file name extensions
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"HideFileExt"=dword:00000000

; Disable menu show delay
[HKEY_CURRENT_USER\Control Panel\Desktop]
"MenuShowDelay"="0"

; Dark theme
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize]
"AppsUseLightTheme"=dword:00000000
"SystemUsesLightTheme"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize]
"AppsUseLightTheme"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize]
"ColorPrevalence"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent]
"AccentPalette"=hex:95,95,95,ff,8b,8b,8b,ff,19,19,19,ff,19,19,19,ff,19,19,19,\
  ff,19,19,19,ff,19,19,19,ff,19,19,19,00
"StartColorMenu"=dword:ff191919
"AccentColorMenu"=dword:ff191919

[HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM]
"EnableWindowColorization"=dword:00000001
"AccentColor"=dword:ff191919
"ColorizationColor"=dword:c4191919
"ColorizationAfterglow"=dword:c4191919

; Disable Windows widgets
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Dsh]
"AllowNewsAndInterests"=dword:00000000
"DisableWidgetsOnLockScreen"=dword:00000000
"DisableWidgetsBoard"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lock Screen]
"AutoSelectWidgetsOnLockScreen"=dword:00000000
"LockScreenWidgetsEnabled"=dword:00000000

; 100% DPI scaling
[HKEY_CURRENT_USER\Control Panel\Desktop]
"LogPixels"=dword:00000060
"Win8DpiScaling"=dword:00000000

; Disable fix scaling for apps
[HKEY_CURRENT_USER\Control Panel\Desktop]
"EnablePerProcessSystemDPI"=dword:00000000

[-HKEY_CURRENT_USER\Control Panel\Desktop\PerMonitorSettings]

[HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics]
"AppliedDPI"=dword:00000060

; Disable transparency
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize]
"EnableTransparency"=dword:00000000

; Sound communications do nothing
[HKEY_CURRENT_USER\Software\Microsoft\Multimedia\Audio]
"UserDuckingPreference"=dword:00000003

; Disable startup sound
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation]
"DisableStartupSound"=dword:00000001

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\EditionOverrides]
"UserSetting_DisableStartupSound"=dword:00000001

; Turn off enhance pointer precision
[HKEY_CURRENT_USER\Control Panel\Mouse]
"MouseSpeed"="0"
"MouseThreshold1"="0"
"MouseThreshold2"="0"

[HKEY_USERS\.DEFAULT\Control Panel\Mouse]
"MouseSpeed"="0"
"MouseThreshold1"="0"
"MouseThreshold2"="0"

; Disable lock
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings]
"ShowLockOption"=dword:00000000

; Disable sleep
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings]
"ShowSleepOption"=dword:00000000

; Disable hibernate
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power]
"HibernateEnabled"=dword:00000000

; Set system responsiveness to 10
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile]
"SystemResponsiveness"=dword:0000000a

; Disable network throttling
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile]
"NetworkThrottlingIndex"=dword:ffffffff

; Set appearance options to custom
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects]
"VisualFXSetting"=dword:3

[HKEY_CURRENT_USER\Control Panel\Desktop]
"UserPreferencesMask"=hex(2):90,12,02,80,10,01,00,00

[HKEY_USERS\.DEFAULT\Control Panel\Desktop]
"UserPreferencesMask"=hex(2):90,12,02,80,10,01,00,00

; Disable animate windows when minimizing and maximizing
[HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics]
"MinAnimate"="0"

; Turn on hardware accelerated GPU scheduling
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers]
"HwSchMode"=dword:00000002

; Disable animations in the taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarAnimations"=dword:0

; Disable enable peek
[HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM]
"EnableAeroPeek"=dword:0

; Disable save taskbar thumbnail previews
[HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM]
"AlwaysHibernateThumbnails"=dword:0

; Enable show thumbnails instead of icons
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"IconsOnly"=dword:0

; Enable show translucent selection rectangle
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ListviewAlphaSelect"=dword:1

; Enable show window contents while dragging
[HKEY_CURRENT_USER\Control Panel\Desktop]
"DragFullWindows"="1"

; Enable smooth edges of screen fonts
[HKEY_CURRENT_USER\Control Panel\Desktop]
"FontSmoothing"="2"

; Disable use drop shadows for icon labels on the desktop
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ListviewShadow"=dword:0

; Adjust for best performance of programs
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl]
"Win32PrioritySeparation"=dword:00000026

; Disable remote assistance
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Remote Assistance]
"fAllowToGetHelp"=dword:00000000

; Disable game bar
[HKEY_CURRENT_USER\System\GameConfigStore]
"GameDVR_Enabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\GameDVR]
"AppCaptureEnabled"=dword:00000000

; Disable enable open XBOX game bar using game controller
[HKEY_CURRENT_USER\Software\Microsoft\GameBar]
"UseNexusForGameBarEnabled"=dword:00000000

; Enable game mode
[HKEY_CURRENT_USER\Software\Microsoft\GameBar]
"AutoGameModeEnabled"=dword:00000001

; Disable XBOX capture
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\GameDVR]
"AudioEncodingBitrate"=dword:0001f400
"AudioCaptureEnabled"=dword:00000000
"HistoricalCaptureEnabled"=dword:00000000
"EchoCancellationEnabled"=dword:00000001
"CursorCaptureEnabled"=dword:00000000
"VKToggleGameBar"=dword:00000000
"VKMToggleGameBar"=dword:00000000
"VKSaveHistoricalVideo"=dword:00000000
"VKMSaveHistoricalVideo"=dword:00000000
"VKToggleRecording"=dword:00000000
"VKMToggleRecording"=dword:00000000
"VKTakeScreenshot"=dword:00000000
"VKMTakeScreenshot"=dword:00000000
"VKToggleRecordingIndicator"=dword:00000000
"VKMToggleRecordingIndicator"=dword:00000000
"VKToggleMicrophoneCapture"=dword:00000000
"VKMToggleMicrophoneCapture"=dword:00000000
"VKToggleCameraCapture"=dword:00000000
"VKMToggleCameraCapture"=dword:00000000
"VKToggleBroadcast"=dword:00000000
"VKMToggleBroadcast"=dword:00000000
"MicrophoneCaptureEnabled"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\GameDVR]
"AllowGameDVR"=dword:00000000

; Privacy deny location
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location]
"Value"="Deny"
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\UserLocationOverridePrivacySetting]
"Value"=dword:00000000

; Privacy deny passkeys
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeys]
"Value"="Deny"

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeysEnumeration]
"Value"="Deny"

; Privacy deny camera
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam]
"Value"="Deny"

; Privacy deny voice activation
[HKEY_CURRENT_USER\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps]
"AgentActivationEnabled"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps]
"AgentActivationLastUsed"=dword:00000000

; Privacy deny notifications
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener]
"Value"="Deny"

; Privacy deny account info
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation]
"Value"="Deny"

; Privacy deny contacts
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\contacts]
"Value"="Deny"

; Privacy deny calendar
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments]
"Value"="Deny"

; Privacy deny phone calls
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCall]
"Value"="Deny"

; Privacy deny call history
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCallHistory]
"Value"="Deny"

; Privacy deny email
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\email]
"Value"="Deny"

; Privacy deny tasks
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userDataTasks]
"Value"="Deny"

; Privacy deny messaging
[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\chat]
"Value"="Deny"

; Privacy deny radios
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\radios]
"Value"="Deny"

; Privacy deny bluetooth sync and other devices
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync]
"Value"="Deny"

; Privacy deny app diagnostics
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics]
"Value"="Deny"

; Privacy deny documents
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\documentsLibrary]
"Value"="Deny"

; Privacy deny downloads folder
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\downloadsFolder]
"Value"="Deny"

; Privacy deny music library
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\musicLibrary]
"Value"="Deny"

; Privacy deny pictures
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\picturesLibrary]
"Value"="Deny"

; Privacy deny videos
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\videosLibrary]
"Value"="Deny"

; Privacy deny file system
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess]
"Value"="Deny"

; Privacy deny foreground text access
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\foregroundTextAccess]
"Value"="Deny"

; Privacy deny text and image generation
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy]
"LetAppsAccessSystemAIModels"=dword:00000002

; Privacy deny human presence
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy]
"LetAppsAccessHumanPresence"=dword:00000002

; Privacy deny background spatial perception
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy]
"LetAppsAccessBackgroundSpatialPerception"=dword:00000002

; Privacy deny eye tracker
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy]
"LetAppsAccessGazeInput"=dword:00000002

; Privacy deny get diagnostic info
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy]
"LetAppsGetDiagnosticInfo"=dword:00000002

; Privacy deny motion
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy]
"LetAppsAccessMotion"=dword:00000002

; Privacy deny background apps
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy]
"LetAppsRunInBackground"=dword:00000002

; Disable background apps global
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Search]
"BackgroundAppGlobalToggle"=dword:00000000
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications]
"GlobalUserDisabled"=dword:00000001

; Disable let websites show me locally relevant content by accessing my language list
[HKEY_CURRENT_USER\Control Panel\International\User Profile]
"HttpAcceptLanguageOptOut"=dword:00000001

; Disable let windows improve start and search results by tracking app launches
[HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\EdgeUI]
"DisableMFUTracking"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\EdgeUI]
"DisableMFUTracking"=dword:00000001

; Disable personal inking and typing dictionary
[HKEY_CURRENT_USER\Software\Microsoft\InputPersonalization]
"RestrictImplicitInkCollection"=dword:00000001
"RestrictImplicitTextCollection"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\InputPersonalization\TrainedDataStore]
"HarvestContacts"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Personalization\Settings]
"AcceptedPrivacyPolicy"=dword:00000000

; Feedback frequency never
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Siuf\Rules]
"NumberOfSIUFInPeriod"=dword:00000000
"PeriodInNanoSeconds"=-

; Disable store my activity history on this device
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\System]
"PublishUserActivities"=dword:00000000

; Disable all search suggestions
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings]
"SafeSearchMode"=dword:00000000
"IsAADCloudSearchEnabled"=dword:00000000
"IsMSACloudSearchEnabled"=dword:00000000
"IsWebSuggestionsEnabled"=dword:00000000
"IsStoreSuggestionsEnabled"=dword:00000000
"IsDynamicSearchBoxEnabled"=dword:00000000
"IsDeviceSearchHistoryEnabled"=dword:00000000

; Disable notifications
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\PushNotifications]
"ToastEnabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications]
"EnableAccountNotifications"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings]
"NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK"=dword:00000000
"NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK"=dword:00000000
"NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND"=dword:00000000
"NOC_GLOBAL_SETTING_SUPRESS_TOASTS_WHILE_DUPLICATING"=dword:00000000
"NOC_GLOBAL_SETTING_ALLOW_ACTION_CENTER_ABOVE_LOCK"=dword:00000000
"NOC_GLOBAL_SETTING_HIDE_NOTIFICATION_CONTENT"=dword:00000000
"NOC_GLOBAL_SETTING_TOASTS_ENABLED"=dword:00000000
"NOC_GLOBAL_SETTING_BADGE_ENABLED"=dword:00000000
"NOC_GLOBAL_SETTING_GLEAM_ENABLED"=dword:00000000
"NOC_GLOBAL_SETTING_ALLOW_HMD_NOTIFICATIONS"=dword:00000000
"NOC_GLOBAL_SETTING_ALLOW_CONTROL_CENTER_ABOVE_LOCK"=dword:00000000

; Disable subscribed content
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager]
"SubscribedContent-338389Enabled"=dword:00000000
"SubscribedContent-338388Enabled"=dword:00000000
"SubscribedContent-310093Enabled"=dword:00000000
"SubscribedContent-338393Enabled"=dword:00000000
"SubscribedContent-353694Enabled"=dword:00000000
"SubscribedContent-353696Enabled"=dword:00000000
"SubscribedContent-353698Enabled"=dword:00000000
"SubscribedContent-338387Enabled"=dword:00000000
"SubscribedContent-314563Enabled"=dword:00000000
"SubscribedContent-314559Enabled"=dword:00000000
"SubscribedContent-202914Enabled"=dword:00000000
"SubscribedContent-280810Enabled"=dword:00000000
"SubscribedContent-280811Enabled"=dword:00000000
"SubscribedContent-280815Enabled"=dword:00000000
"SubscribedContent-310091Enabled"=dword:00000000
"SubscribedContent-88000045Enabled"=dword:00000000
"SubscribedContent-88000161Enabled"=dword:00000000
"SubscribedContent-88000163Enabled"=dword:00000000
"SubscribedContent-88000165Enabled"=dword:00000000
"SubscribedContent-88000325Enabled"=dword:00000000
"SubscribedContent-88000326Enabled"=dword:00000000
"SubscribedContent-338380Enabled"=dword:00000000
"SubscribedContent-338382Enabled"=dword:00000000
"SubscribedContent-338381Enabled"=dword:00000000
"SubscribedContent-338386Enabled"=dword:00000000
"SubscribedContent-353697Enabled"=dword:00000000
"SubscribedContent-353695Enabled"=dword:00000000
"SubscribedContent-88000106Enabled"=dword:00000000
"SubscribedContent-88000105Enabled"=dword:00000000
"SubscribedContent-314566Enabled"=dword:00000000
"SubscribedContent-314567Enabled"=dword:00000000
"SubscribedContent-310094Enabled"=dword:00000000
"SubscribedContent-280812Enabled"=dword:00000000
"SubscribedContent-310092Enabled"=dword:00000000
"SubscribedContent-280814Enabled"=dword:00000000
"SubscribedContent-202913Enabled"=dword:00000000
"SubscribedContent-314562Enabled"=dword:00000000
"SubscribedContent-314558Enabled"=dword:00000000
"SubscribedContent-88000531Enabled"=dword:00000000
"SubscribedContent-88000530Enabled"=dword:00000000
"SubscribedContent-353699Enabled"=dword:00000000
"SubscribedContent-88000044Enabled"=dword:00000000
"SubscribedContent-280797Enabled"=dword:00000000
"SubscribedContent-280817Enabled"=dword:00000000
"SubscribedContent-88000162Enabled"=dword:00000000
"SubscribedContent-88000164Enabled"=dword:00000000
"SubscribedContent-88000166Enabled"=dword:00000000
"SystemPaneSuggestionsEnabled"=dword:00000000
"OemPreInstalledAppsEnabled"=dword:00000000
"PreInstalledAppsEnabled"=dword:00000000
"SilentInstalledAppsEnabled"=dword:00000000
"SoftLandingEnabled"=dword:00000000
"ContentDeliveryAllowed"=dword:00000000
"PreInstalledAppsEverEnabled"=dword:00000000
"SubscribedContentEnabled"=dword:00000000
"SubscribedContent-LocksreenEnabled"=dword:00000000

[-HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions]

; Remove logons
[-HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run]

[-HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run]

; Disable magnifier settings
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\ScreenMagnifier]
"FollowCaret"=dword:00000000
"FollowNarrator"=dword:00000000
"FollowMouse"=dword:00000000
"FollowFocus"=dword:00000000

; Disable narrator settings
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Narrator]
"IntonationPause"=dword:00000000
"ReadHints"=dword:00000000
"ErrorNotificationType"=dword:00000000
"EchoChars"=dword:00000000
"EchoWords"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Narrator\NarratorHome]
"MinimizeType"=dword:00000000
"AutoStart"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Narrator\NoRoam]
"EchoToggleKeys"=dword:00000000

; Disable narrator
[HKEY_CURRENT_USER\Software\Microsoft\Narrator\NoRoam]
"DuckAudio"=dword:00000000
"WinEnterLaunchEnabled"=dword:00000000
"ScriptingEnabled"=dword:00000000
"OnlineServicesEnabled"=dword:00000000
"CheckForScriptsEnabled"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Narrator]
"NarratorCursorHighlight"=dword:00000000
"CoupleNarratorCursorKeyboard"=dword:00000000

; Disable driver searching
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching]
"SearchOrderConfig"=dword:00000000

; Disable automatic maintenance
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance]
"MaintenanceDisabled"=dword:00000001

; Disable use my sign-in info after restart
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System]
"DisableAutomaticRestartSignOn"=dword:00000001

; Disable automatically update maps
[HKEY_LOCAL_MACHINE\SYSTEM\Maps]
"AutoUpdateEnabled"=dword:00000000

; Alt-tab open windows only
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"MultiTaskingAltTabFilter"=dword:00000003

; Show hidden files
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Hidden"=dword:00000001

; Remove wallpaper
[HKEY_CURRENT_USER\Control Panel\Desktop]
"WallPaper"=""

; Set background color to black
[HKEY_CURRENT_USER\Control Panel\Colors]
"Background"="0 0 0"

; Disable finish setting up your device
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement]
"ScoobeSystemSettingEnabled"=dword:00000000

; Disable language hotkey
[HKEY_CURRENT_USER\Keyboard Layout\Toggle]
"Language Hotkey"="3"
"Hotkey"="3"
"Layout Hotkey"="3"

; Disable language bar
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\CTF\LangBar]
"ExtraIconsOnMinimized"=dword:00000000
"Label"=dword:00000000
"ShowStatus"=dword:00000003
"Transparency"=dword:000000ff

; Disable lock screen image
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\System]
"DisableLogonBackgroundImage"=dword:00000001

; Disable search web results
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Search]
"BingSearchEnabled"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"DisableSearchBoxSuggestions"=dword:00000001

; Disable autoplay
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers]
"DisableAutoplay"=dword:00000001

; Task manager always on top

; Disable web search
[HKEY_LOCAL_MACHINE\Software\Policies\Microsoft\Windows\Windows Search]
"ConnectedSearchUseWeb"=dword:00000000
"DisableWebSearch"=dword:00000001

; Disable co installers
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer]
"DisableCoInstallers"=dword:00000001

; Disable Windows automatic folder type
[HKEY_CURRENT_USER\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell]
"FolderType"="NotSpecified"

; Disable Windows spotlight
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings]
"EnabledState"=dword:00000000

; Disable last access time
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem]
"NtfsDisableLastAccessUpdate"=dword:00000001

; Respect power modes search indexer

; Disable fault tolerant heap
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\FTH]
"Enabled"=dword:00000000

; Increase icon cache size
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer]
"MaxCachedIcons"="4096"

; More info on blue screen of death
[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\CrashControl]
"DisplayParameters"=dword:00000001

; Enable long paths
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem]
"LongPathsEnabled"=dword:00000001

; Black PowerShell console
[HKEY_CURRENT_USER\Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe]
"ScreenColors"=dword:0000000F
"ColorTable06"=dword:00ffffff
"ColorTable15"=dword:00ffffff
"ColorTable00"=dword:00000000
"FaceName"="Consolas"

[HKEY_CURRENT_USER\Console\%SystemRoot%_system32_cmd.exe]
"ColorTable07"=dword:00ffffff
"ColorTable00"=dword:00000000

; Disable Windows platform binary table
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\Session Manager]
"DisableWpbtExecution"=dword:00000001

; No web services in explorer
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"NoWebServices"=dword:00000001

; No document history tracking
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"NoRecentDocsHistory"=dword:00000001
"ClearRecentDocsOnExit"=dword:00000001

; Disable low disk space checks
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"NoLowDiskSpaceChecks"=dword:00000001

; Disable publish to web
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"NoPublishingWizard"=dword:00000001

; Disable home page in settings
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"SettingsPageVisibility"="hide:home;"

; Show all taskbar icons
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer]
"EnableAutoTray"=dword:00000000

[HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotify]
"SystemTrayChevronVisibility"=dword:00000000

; Disable track my device
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\MdmCommon\SettingValues]
"LocationSyncEnabled"=dword:00000000

; Disable personalized offers
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy]
"TailoredExperiencesWithDiagnosticDataEnabled"=dword:00000000

[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\TailoredExperiencesWithDiagnosticDataEnabled]
"Value"=dword:00000000

; Disable data collection
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection]
"AllowTelemetry"=dword:00000001
"MaxTelemetryAllowed"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\AllowTelemetry]
"Value"=dword:00000001

; Disable start menu recommended section
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"Start_IrisRecommendations"=dword:00000000
"Start_AccountNotifications"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\current\device\Start]
"HideRecommendedSection"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PolicyManager\current\device\Education]
"IsEducationEnvironment"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer]
"HideRecommendedSection"=dword:00000001

; Set start menu apps view to list
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start]
"AllAppsViewMode"=dword:00000002

; Disable explorer open in new tab
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer]
"OpenFolderInNewTab"=dword:00000000

; Disable sleep study
[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Power]
"SleepStudyDisabled"=dword:00000001

; Disable use view + menu as guide button in apps
[HKEY_CURRENT_USER\Software\Microsoft\GameBar]
"GamepadNexusChordEnabled"=dword:00000000

; Disable drag tray
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CDP]
"DragTrayEnabled"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\3895955085]
"EnabledState"=dword:00000001

; Disable device usage
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\business]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\creative]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\developer]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\DeviceMetaDataBackup]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\entertainment]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\family]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\gaming]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\IntroIneligible]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\IntroPostponed]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\IntroSkipped]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\OffDeviceConsent]
"Intent"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\schoolwork]
"Intent"=dword:00000000

; Disable store settings

; Disable app actions

; Disable Windows backup
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\SettingSync]
"DisableAccessibilitySettingSync"=dword:00000002
"DisableAccessibilitySettingSyncUserOverride"=dword:00000001
"DisableAppSyncSettingSync"=dword:00000002
"DisableAppSyncSettingSyncUserOverride"=dword:00000001
"DisableApplicationSettingSync"=dword:00000002
"DisableApplicationSettingSyncUserOverride"=dword:00000001
"DisableCredentialsSettingSync"=dword:00000002
"DisableCredentialsSettingSyncUserOverride"=dword:00000001
"DisableDesktopThemeSettingSync"=dword:00000002
"DisableDesktopThemeSettingSyncUserOverride"=dword:00000001
"DisableLanguageSettingSync"=dword:00000002
"DisableLanguageSettingSyncUserOverride"=dword:00000001
"DisablePersonalizationSettingSync"=dword:00000002
"DisablePersonalizationSettingSyncUserOverride"=dword:00000001
"DisableSettingSync"=dword:00000002
"DisableSettingSyncUserOverride"=dword:00000001
"DisableStartLayoutSettingSync"=dword:00000002
"DisableStartLayoutSettingSyncUserOverride"=dword:00000001
"DisableSyncOnPaidNetwork"=dword:00000001
"DisableWebBrowserSettingSync"=dword:00000002
"DisableWebBrowserSettingSyncUserOverride"=dword:00000001
"DisableWindowsSettingSync"=dword:00000002
"DisableWindowsSettingSyncUserOverride"=dword:00000001
"EnableWindowsBackup"=dword:00000000

; Disable jump list when hovering inactive apps
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"JumplistOnHover"=dword:00000000

; Disable do not disturb
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentpresentation]
"Data"=hex(3):43,42,01,00,0A,02,01,00,2A,06,E2,F3,AA,CC,06,2A,2B,0E,5A,43,\
42,01,00,C2,0A,01,D2,1E,26,4D,00,69,00,63,00,72,00,6F,00,73,00,6F,00,66,00,\
74,00,2E,00,51,00,75,00,69,00,65,00,74,00,48,00,6F,00,75,00,72,00,73,00,50,\
00,72,00,6F,00,66,00,69,00,6C,00,65,00,2E,00,41,00,6C,00,61,00,72,00,6D,00,\
73,00,4F,00,6E,00,6C,00,79,00,CA,50,00,00,00,00,00

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentgame]
"Data"=hex(3):43,42,01,00,0A,02,01,00,2A,06,E1,F3,AA,CC,06,2A,2B,0E,5E,43,\
42,01,00,C2,0A,01,D2,1E,28,4D,00,69,00,63,00,72,00,6F,00,73,00,6F,00,66,00,\
74,00,2E,00,51,00,75,00,69,00,65,00,74,00,48,00,6F,00,75,00,72,00,73,00,50,\
00,72,00,6F,00,66,00,69,00,6C,00,65,00,2E,00,50,00,72,00,69,00,6F,00,72,00,\
69,00,74,00,79,00,4F,00,6E,00,6C,00,79,00,CA,50,00,00,00,00,00

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentfullscreen]
"Data"=hex(3):43,42,01,00,0A,02,01,00,2A,06,E0,F3,AA,CC,06,2A,2B,0E,5A,43,\
42,01,00,C2,0A,01,D2,1E,26,4D,00,69,00,63,00,72,00,6F,00,73,00,6F,00,66,00,\
74,00,2E,00,51,00,75,00,69,00,65,00,74,00,48,00,6F,00,75,00,72,00,73,00,50,\
00,72,00,6F,00,66,00,69,00,6C,00,65,00,2E,00,41,00,6C,00,61,00,72,00,6D,00,\
73,00,4F,00,6E,00,6C,00,79,00,CA,50,00,00,00,00,00

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentpostoobe]
"Data"=hex(3):43,42,01,00,0A,02,01,00,2A,06,DF,F3,AA,CC,06,2A,2B,0E,5E,43,\
42,01,00,C2,0A,01,D2,1E,28,4D,00,69,00,63,00,72,00,6F,00,73,00,6F,00,66,00,\
74,00,2E,00,51,00,75,00,69,00,65,00,74,00,48,00,6F,00,75,00,72,00,73,00,50,\
00,72,00,6F,00,66,00,69,00,6C,00,65,00,2E,00,50,00,72,00,69,00,6F,00,72,00,\
69,00,74,00,79,00,4F,00,6E,00,6C,00,79,00,CA,50,00,00,00,00,00

; Disable dynamic lock
[HKEY_CURRENT_USER\Software\Microsoft\Windows NT\CurrentVersion\Winlogon]
"EnableGoodbye"=dword:00000000

; Disable sticky keys
[HKEY_CURRENT_USER\Control Panel\Accessibility\StickyKeys]
"Flags"="26"

; Disable filter keys
[HKEY_CURRENT_USER\Control Panel\Accessibility\Keyboard Response]
"AutoRepeatDelay"="0"
"AutoRepeatRate"="0"
"DelayBeforeAcceptance"="0"
"Flags"="26"

; Expand calendar

; Show big clock in notification center
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowClockInNotificationCenter"=dword:00000001

; Enable file explorer prelaunch
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShouldPrelaunchFileExplorer"=dword:00000001

; Remove resume from taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"IsEnabled"=dword:00000000

; Disable show me suggested apps in share
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\CDP]
"EnablePromotionalAppsForShare"=dword:00000000

; Increase wallpaper quality
[HKEY_CURRENT_USER\Control Panel\Desktop]
"JPEGImportQuality"=dword:00000064

; Disable automatic troubleshooting
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsMitigation]
"UserPreference"=dword:00000001

; Disable write with fingertip
[HKEY_CURRENT_USER\Software\Microsoft\TabletTip\EmbeddedInkControl]
"EnableInkingWithTouch"=dword:00000000

; Disable share window from taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarSn"=dword:00000000

; Disable small taskbar buttons
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"IconSizePreference"=dword:00000001

; Disable touch keyboard
[HKEY_CURRENT_USER\Software\Microsoft\TabletTip\1.7]
"EnableAutoShiftEngage"=dword:00000000
"EnableDoubleTapSpace"=dword:00000000
"EnableKeyAudioFeedback"=dword:00000000
"TouchKeyboardTapInvoke"=dword:00000000
"TipbandDesiredVisibility"=dword:00000000

[HKEY_CURRENT_USER\Software\Microsoft\input\Settings]
"IsVoiceTypingKeyEnabled"=dword:00000000

; Disable auto correction
[HKEY_CURRENT_USER\Software\Microsoft\TabletTip\1.7]
"EnableAutocorrection"=dword:00000000

; Disable touch indicator
[HKEY_CURRENT_USER\Control Panel\Cursors]
"ContactVisualization"=dword:00000000
"GestureVisualization"=dword:00000018

; Disable keyboard shortcut for contrast themes
[HKEY_CURRENT_USER\Control Panel\Accessibility\HighContrast]
"Flags"="4128"

; Disable notification for sticky, filter or toggle keys
[HKEY_CURRENT_USER\Control Panel\Accessibility]
"Sound on Activation"=dword:00000000
"Warning Sounds"=dword:00000000

; Disable USB error notifications
[HKEY_CURRENT_USER\Software\Microsoft\Shell\USB]
"NotifyOnUsbErrors"=dword:00000000

; Disable delivery optimization
[HKEY_USERS\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings]
"DownloadMode"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization]
"DODownloadMode"=dword:00000000

; Disable XBOX mode
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\GamingConfiguration]
"GamingHomeApp"=""

; Enable last open window in taskbar
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"LastActiveClick"=dword:00000001

; Hide removable drives from navigation pane
[-HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\DelegateFolders\{F5FB2C77-0E2F-4A16-A381-3E560C68BC83}]

; Disable Priority Notifications

; Minimize keyboard repeat delay
[HKEY_CURRENT_USER\Control Panel\Keyboard]
"KeyboardDelay"="0"

; Small start menu size
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start]
"StartMenuSize"=dword:00000001

; Disable HelpPane.exe in safemode
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\HelpPane.exe]
"Debugger"="systray.exe"

; Disable show sync provider notifications
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"ShowSyncProviderNotifications"=dword:00000000

; Disable use Sharing Wizard
[HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"SharingWizardOn"=dword:00000000

; Disable Toggle Keys shortcut
[HKEY_CURRENT_USER\Control Panel\Accessibility\ToggleKeys]
"Flags"="58"

; Disable allow themes to change desktop icons
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes]
"ThemeChangesDesktopIcons"=dword:00000000

; Disable automatically download maufacturers apps for devices
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata]
"PreventDeviceMetadataFromNetwork"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Device Metadata]
"PreventDeviceMetadataFromNetwork"=dword:00000001

; Disable auto read/scan in Ease of Access Center
[HKEY_CURRENT_USER\Software\Microsoft\Ease of Access]
"selfscan"=dword:00000000
"selfvoice"=dword:00000000

; Disable visual warning for Sound Sentry
[HKEY_CURRENT_USER\Control Panel\Accessibility\SoundSentry]
"WindowsEffect"="0"

; Disable accessibility tool shortcut
[HKEY_CURRENT_USER\Control Panel\Accessibility\SlateLaunch]
"LaunchAT"=dword:00000000

; Hide Network Icon in File Explorer 
[HKEY_CURRENT_USER\Software\Classes\CLSID\{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}]
"System.IsPinnedToNameSpaceTree"=dword:00000000

; Disable recently added apps in start menu
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start]
"ShowRecentSection"=dword:00000000

; Hide start menu pinned section 
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start]
"ShowPinnedSection"=dword:00000000

; Disable Turn off HDR on battery
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\VideoSettings]
"DisableHDROnBattery"=dword:00000000

; Set Control Panel view to large icons
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel]
"StartupPage"=dword:00000001
'@

# Telemetry policy rows from upstream gpTweaks (gpTel). Service starts are handled separately below.
$TelemetryRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableGraphRecentItems' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowCrossDeviceClipboard' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'DontSendAdditionalData' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowDeviceNameInTelemetry' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'MaxTelemetryAllowed' 0 'DWord'
    New-Tweak 'HKLM\System\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener' 'Start' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\AppV\CEIP' 'CEIPEnable' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0 'DWord'
    New-Tweak 'HKCU\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\DevicePolicy\AllowTelemetry' 'DefaultValue' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\AllowTelemetry' 'Value' 0 'DWord'
    New-Tweak 'HKLM\Software\Policies\Microsoft\Windows\DataCollection' 'AllowCommercialDataPipeline' 0 'DWord'
    New-Tweak 'HKLM\Software\Policies\Microsoft\Windows\DataCollection' 'LimitEnhancedDiagnosticDataWindowsAnalytics' 0 'DWord'
    New-Tweak 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 'DWord'
    New-Tweak 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\TextInput' 'AllowLinguisticDataCollection' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Bluetooth' 'AllowAdvertising' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\System' 'AllowExperimentation' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\PolicyManager\default\Wifi\AllowAutoConnectToWiFiSenseHotspots' 'value' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\PolicyManager\default\Wifi\AllowWiFiHotSpotReporting' 'value' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config' 'AutoConnectAllowedOEM' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\WMDRM' 'DisableOnline' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'AITEnable' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisablePCA' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisablePcaRecording' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableScriptedDiagnosticLogging' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableUAR' 1 'DWord'
    New-Tweak 'HKLM\SYSTEM\ControlSet001\Control\StorPort' 'TelemetryDeviceHealthEnabled' 0 'DWord'
    New-Tweak 'HKLM\SYSTEM\ControlSet001\Control\StorPort' 'TelemetryErrorDataEnabled' 0 'DWord'
    New-Tweak 'HKLM\SYSTEM\ControlSet001\Control\StorPort' 'TelemetryPerformanceEnabled' 0 'DWord'
)
$BiometricsRegs = @(
    New-Tweak 'HKLM\Software\Policies\Microsoft\Biometrics' 'Enabled' 0 'DWord'
)
$TelemetryServices = @('DiagTrack', 'dmwappushservice')
$CdpServices = @('CDPSvc', 'CDPUserSvc')

# Service groups from upstream disable-services. Each key is the option that switches the group on.
$ServiceGroups = [ordered]@{
    SvcOther = @('Fax', 'shpamsvc', 'RemoteRegistry', 'PhoneSvc', 'wisvc', 'TabletInputService', 'AssignedAccessManagerSvc', 'MapsBroker', 'lfsvc', 'Netlogon', 'WpcMonSvc', 'WalletService', 'whesvc', 'wuqisvc', 'WSAIFabricSvc')
    SvcExtra = @('PimIndexMaintenanceSvc', 'UnistoreSvc', 'UserDataSvc', 'SSDPSRV', 'smphost', 'RasMan', 'SstpSvc')
    SvcDefrag = @('defragsvc')
    SvcBiometrics = @('WbioSrvc')
    SvcSmartCard = @('SCardSvr', 'ScDeviceEnum', 'SCPolicySvc')
    SvcDiagnostics = @('diagsvc', 'DPS', 'WdiServiceHost', 'WdiSystemHost')
    SvcBluetooth = @('BTAGService', 'BthAvctpSvc', 'bthserv', 'BluetoothUserService')
    SvcPrinting = @('Spooler', 'PrintWorkflowUserSvc', 'PrintNotify')
    SvcDeliveryOpt = @('DoSvc')
    SvcRadio = @('RmSvc')
}

# Domain lists from upstream (Get-TeleDomains, Razer and ASUS blocks).
$TelemetryDomains = @(
    'v10.events.data.microsoft.com'
    'v10c.events.data.microsoft.com'
    'v10.vortex-win.data.microsoft.com'
    'watson.telemetry.microsoft.com'
    'umwatsonc.events.data.microsoft.com'
    'ceuswatcab01.blob.core.windows.net'
    'ceuswatcab02.blob.core.windows.net'
    'eaus2watcab01.blob.core.windows.net'
    'eaus2watcab02.blob.core.windows.net'
    'weus2watcab01.blob.core.windows.net'
    'weus2watcab02.blob.core.windows.net'
    'oca.telemetry.microsoft.com'
    'oca.microsoft.com'
    'kmwatsonc.events.data.microsoft.com'
    'au.vortex-win.data.microsoft.com'
    'au-v10.events.data.microsoft.com'
    'au-v20.events.data.microsoft.com'
    'eu-v10.events.data.microsoft.com'
    'eu-v20.events.data.microsoft.com'
    'in-v10.events.data.microsoft.com'
    'in-v20.events.data.microsoft.com'
    'jp-v10.events.data.microsoft.com'
    'jp-v20.events.data.microsoft.com'
    'uk.vortex-win.data.microsoft.com'
    'uk-v20.events.data.microsoft.com'
    'us4-v20.events.data.microsoft.com'
    'us5-v20.events.data.microsoft.com'
    'us-v10.events.data.microsoft.com'
    'us-v20.events.data.microsoft.com'
    'v20.events.data.microsoft.com'
)
$RazerDomains = @(
    'synapse3ui-common.razerzone.com'
    'bespoke-analytics.razerapi.com'
    'discovery.razerapi.com'
    'manifest.razerapi.com'
    'cdn.razersynapse.com'
    'assets.razerzone.com'
    'assets2.razerzone.com'
    'deals-assets-cdn.razerzone.com'
    'synapse-3-webservice.razerzone.com'
    'albedozero.razerapi.com'
    'gms.razersynapse.com'
    'fs.razersynapse.com'
    'id.razer.com'
)
$AsusDomains = @(
    'liveupdate01s.asus.com'
    'asusactivateservice.azurewebsites.net'
    'rog-live-service.asus.com'
    'dlcdn-rogboxbu1.asus.com'
    'dlcdn-rogboxbu2.asus.com'
    'mymessage.asus.com'
    'gaming-config.asus.com'
    'rog-content-platform.asus.com'
    'nomos.asus.com'
    'dlcdnrog.asus.com'
    'account.asus.com'
)

# Mouse profiles per display scaling, from upstream opNoMouseAccel. X and Y are SmoothMouse curves.
$MouseProfiles = @{
    100 = @{ Speed = '0'; T1 = '0'; T2 = '0'; X = $null; Y = $null; LogPixels = 96; PerProc = 0 }
    125 = @{ Speed = '1'; T1 = '6'; T2 = '10'; X = '00,00,00,00,00,00,00,00,00,00,10,00,00,00,00,00,00,00,20,00,00,00,00,00,00,00,30,00,00,00,00,00,00,00,40,00,00,00,00,00'; Y = '00,00,00,00,00,00,00,00,00,00,38,00,00,00,00,00,00,00,70,00,00,00,00,00,00,00,a8,00,00,00,00,00,00,00,e0,00,00,00,00,00'; LogPixels = 120; PerProc = 1 }
    150 = @{ Speed = '1'; T1 = '6'; T2 = '10'; X = '00,00,00,00,00,00,00,00,30,33,13,00,00,00,00,00,60,66,26,00,00,00,00,00,90,99,39,00,00,00,00,00,c0,cc,4c,00,00,00,00,00'; Y = '00,00,00,00,00,00,00,00,00,00,38,00,00,00,00,00,00,00,70,00,00,00,00,00,00,00,a8,00,00,00,00,00,00,00,e0,00,00,00,00,00'; LogPixels = 144; PerProc = 1 }
    175 = @{ Speed = '1'; T1 = '6'; T2 = '10'; X = '00,00,00,00,00,00,00,00,60,66,16,00,00,00,00,00,c0,cc,2c,00,00,00,00,00,20,33,43,00,00,00,00,00,80,99,59,00,00,00,00,00'; Y = '00,00,00,00,00,00,00,00,00,00,38,00,00,00,00,00,00,00,70,00,00,00,00,00,00,00,a8,00,00,00,00,00,00,00,e0,00,00,00,00,00'; LogPixels = 168; PerProc = 1 }
    200 = @{ Speed = '1'; T1 = '6'; T2 = '10'; X = '00,00,00,00,00,00,00,00,90,99,19,00,00,00,00,00,20,33,33,00,00,00,00,00,b0,cc,4c,00,00,00,00,00,40,66,66,00,00,00,00,00'; Y = '00,00,00,00,00,00,00,00,00,00,38,00,00,00,00,00,00,00,70,00,00,00,00,00,00,00,a8,00,00,00,00,00,00,00,e0,00,00,00,00,00'; LogPixels = 192; PerProc = 1 }
    225 = @{ Speed = '1'; T1 = '6'; T2 = '10'; X = '00,00,00,00,00,00,00,00,c0,cc,1c,00,00,00,00,00,80,99,39,00,00,00,00,00,40,66,56,00,00,00,00,00,00,33,73,00,00,00,00,00'; Y = '00,00,00,00,00,00,00,00,00,00,38,00,00,00,00,00,00,00,70,00,00,00,00,00,00,00,a8,00,00,00,00,00,00,00,e0,00,00,00,00,00'; LogPixels = 216; PerProc = 1 }
}

# Windows Update option data from upstream (noDriversInUpdate, opSecUpdatesOnly, oppauseUpdates).
$DriverExclusionRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ExcludeWUDriversInQualityUpdate' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState' 'ExcludeWUDrivers' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' 'SearchOrderConfig' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'EnableFeaturedSoftware' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'IncludeRecommendedUpdates' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'SetAllowOptionalContent' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'AllowTemporaryEnterpriseFeatureControl' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' 'DisableSendGenericDriverNotFoundToWER' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' 'DisableSendRequestAdditionalSoftwareToWER' 1 'DWord'
)
$SecurityUpdatesRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'SetAllowOptionalContent' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferFeatureUpdates' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferFeatureUpdatesPeriodInDays' 730 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferQualityUpdates' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferQualityUpdatesPeriodInDays' 730 'DWord'
)
$PauseRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'SetAllowOptionalContent' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferFeatureUpdates' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferFeatureUpdatesPeriodInDays' 365 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferQualityUpdates' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DeferQualityUpdatesPeriodInDays' 365 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ExcludeWUDriversInQualityUpdate' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' 'DontPromptForWindowsUpdate' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' 'DontSearchWindowsUpdate' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' 'DriverUpdateWizardWuSearchEnabled' 0 'DWord'
)
$UpdateClassifications = @('{e6cf1350-c01b-414d-a61f-263d3d4dd9f9}', '{e0789628-ce08-4437-be74-2495b842f43b}', '{b54e7d24-7add-49f4-88bb-9837d47477fb}', '{68c5b0a3-d1a6-4553-ae49-01d3a7827828}', '{b4832bd8-e735-4766-9727-7d0ffa644277}', '{28bc8804-5382-4bae-93aa-13c905f28542}', '{cd5ffd1e-e257-4a05-9d88-c83a7125d4c9}', '{0f1afbec-90ef-4651-9e37-030fedc944c8}', '{ebfc1fc5-71a4-4f7b-9aca-3b9a503104a0}', '{9920c092-3d99-4a1b-865a-673135c5a4fc}')
$UpdateTaskPaths = @('\Microsoft\Windows\InstallService\*', '\Microsoft\Windows\UpdateOrchestrator\*', '\Microsoft\Windows\UpdateAssistant\*', '\Microsoft\Windows\WaaSMedic\*', '\Microsoft\Windows\WindowsUpdate\*', '\Microsoft\WindowsUpdate\*')

# Empty Windows 11 Start menu layout (start2.bin) from upstream Unpin.ps1, base64.
$EmptyStartLayout = @(
    '4nrhSwH8TRucAIEL3m5RhU5aX0cAW7FJilySr5CE+V40mv9utV7aAZARAABc9u55'
    'LN8F4borYyXEGl8Q5+RZ+qERszeqUhhZXDvcjTF6rgdprauITLqPgMVMbSZbRsLN'
    '/O5uMjSLEr6nWYIwsMJkZMnZyZrhR3PugUhUKOYDqwySCY6/CPkL/Ooz/5j2R2hw'
    'WRGqc7ZsJxDFM1DWofjUiGjDUny+Y8UjowknQVaPYao0PC4bygKEbeZqCqRvSgPa'
    'lSc53OFqCh2FHydzl09fChaos385QvF40EDEgSO8U9/dntAeNULwuuZBi7BkWSIO'
    'mWN1l4e+TZbtSJXwn+EINAJhRHyCSNeku21dsw+cMoLorMKnRmhJMLvE+CCdgNKI'
    'aPo/Krizva1+bMsI8bSkV/CxaCTLXodb/NuBYCsIHY1sTvbwSBRNMPvccw43RJCU'
    'KZRkBLkCVfW24ANbLfHXofHDMLxxFNUpBPSgzGHnueHknECcf6J4HCFBqzvSH1Tj'
    'Q3S6J8tq2yaQ+jFNkxGRMushdXNNiTNjDFYMJNvgRL2lu606PZeypEjvPg7SkGR2'
    '7a42GDSJ8n6HQJXFkOQPJ1mkU4qpA78U+ZAo9ccw8XQPPqE1eG7wzMGihTWfEMVs'
    'K1nsKyEZCLYFmKwYqdIF0somFBXaL/qmEHxwlPCjwRKpwLOue0Y8fgA06xk+DMti'
    'zWahOZNeZ54MN3N14S22D75riYEccVe3CtkDoL+4Oc2MhVdYEVtQcqtKqZ+DmmoI'
    '5BqkECeSHZ4OCguheFckK5Eq5Yf0CKRN+RY2OJ0ZCPUyxQnWdnOi9oBcZsz2NGzY'
    'g8ifO5s5UGscSDMQWUxPJQePDh8nPUittzJ+iplQqJYQ/9p5nKoDukzHHkSwfGms'
    '1GiSYMUZvaze7VSWOHrgZ6dp5qc1SQy0FSacBaEu4ziwx1H7w5NZj+zj2ZbxAZhr'
    '7Wfvt9K1xp58H66U4YT8Su7oq5JGDxuwOEbkltA7PzbFUtq65m4P4LvS4QUIBUqU'
    '0+JRyppVN5HPe11cCPaDdWhcr3LsibWXQ7f0mK8xTtPkOUb5pA2OUIkwNlzmwwS1'
    'Nn69/13u7HmPSyofLck77zGjjqhSV22oHhBSGEr+KagMLZlvt9pnD/3I1R1BqItW'
    'KF3woyb/QizAqScEBsOKj7fmGA7f0KKQkpSpenF1Q/LNdyyOc77wbu2aywLGLN7H'
    'BCdwwjjMQ43FHSQPCA3+5mQDcfhmsFtORnRZWqVKwcKWuUJ7zLEIxlANZ7rDcC30'
    'FKmeUJuKk0Upvhsz7UXzDtNmqYmtg6vY/yPtG5Cc7XXGJxY2QJcbg1uqYI6gKtue'
    '00Mfpjw7XpUMQbIW9rXMA9PSWX6h2ln2TwlbrRikqdQXACZyhtuzSNLK7ifSqw4O'
    'JcZ8JrQ/xePmSd0z6O/MCTiUTFwG0E6WS1XBV1owOYi6jVif1zg75DTbXQGTNRvK'
    'KarodfnpYg3sgTe/8OAI1YSwProuGNNh4hxK+SmljqrYmEj8BNK3MNCyIskCcQ4u'
    'cyoJJHmsNaGFyiKp1543PktIgcs8kpF/SN86/SoB/oI7KECCCKtHNdFV8p9HO3t8'
    '5OsgGUYgvh7Z/Z+P7UGgN1iaYn7El9XopQ/XwK9zc9FBr73+xzE5Hh4aehNVIQdM'
    'Mb+Rfm11R0Jc4WhqBLCC3/uBRzesyKUzPoRJ9IOxCwzeFwGQ202XVlPvklXQwgHx'
    'BfEAWZY1gaX6femNGDkRldzImxF87Sncnt9Y9uQty8u0IY3lLYNcAFoTobZmFkAQ'
    'vuNcXxObmHk3rZNAbRLFsXnWUKGjuK5oP2TyTNlm9fMmnf/E8deez3d8KOXW9YMZ'
    'DkA/iElnxcCKUFpwI+tWqHQ0FT96sgIP/EyhhCq6o/RnNtZvch9zW8sIGD7Lg0cq'
    'SzPYghZuNVYwr90qt7UDekEei4CHTzgWwlSWGGCrP6Oxjk1Fe+KvH4OYwEiDwyRc'
    'l7NRJseqpW1ODv8c3VLnTJJ4o3QPlAO6tOvon7vA1STKtXylbjWARNcWuxT41jtC'
    'CzrAroK2r9bCij4VbwHjmpQnhYbF/hCE1r71Z5eHdWXqpSgIWeS/1avQTStsehwD'
    '2+NGFRXI8mwLBLQN/qi8rqmKPi+fPVBjFoYDyDc35elpdzvqtN/mEp+xDrnAbwXU'
    'yfhkZvyo2+LXFMGFLdYtWTK/+T/4n03OJH1gr6j3zkoosewKTiZeClnK/qfc8YLw'
    'bCdwBm4uHsZ9I14OFCepfHzmXp9nN6a3u0sKi4GZpnAIjSreY4rMK8c+0FNNDLi5'
    'DKuck7+WuGkcRrB/1G9qSdpXqVe86uNojXk9P6TlpXyL/noudwmUhUNTZyOGcmhJ'
    'EBiaNbT2Awx5QNssAlZFuEfvPEAixBz476U8/UPb9ObHbsdcZjXNV89WhfYX04DM'
    '9qcMhCnGq25sJPc5VC6XnNHpFeWhvV/edYESdeEVwxEcExKEAwmEZlGJdxzoAH+K'
    'Y+xAZdgWjPPL5FaYzpXc5erALUfyT+n0UTLcjaR4AKxLnpbRqlNzrWa6xqJN9NwA'
    '+xa38I6EXbQ5Q2kLcK6qbJAbkEL76WiFlkc5mXrGouukDvsjYdxG5Rx6OYxb41Ep'
    '1jEtinaNfXwt/JiDZxuXCMHdKHSH40aZCRlwdAI1C5fqoUkgiDdsxkEq+mGWxMVE'
    'Zd0Ch9zgQLlA6gYlK3gt8+dr1+OSZ0dQdp3ABqb1+0oP8xpozFc2bK3OsJvucpYB'
    'OdmS+rfScY+N0PByGJoKbdNUHIeXv2xdhXnVjM5G3G6nxa3x8WFMJsJs2ma1xRT1'
    '8HKqjX9Ha072PD8Zviu/bWdf5c4RrphVqvzfr9wNRpfmnGOoOcbkRE4QrL5CqrPb'
    'VRujOBMPGAxNlvwq0w1XDOBDawZgK7660yd4MQFZk7iyZgUSXIo3ikleRSmBs+Mt'
    'r+3Og54Cg9QLPHbQQPmiMsu21IJUh0rTgxMVBxNUNbUaPJI1lmbkTcc7HeIk0Wtg'
    'RxwYc8aUn0f/V//c+2ZAlM6xmXmj6jIkOcfkSBd0B5z63N4trypD3m+w34bZkV1I'
    'cQ8h7SaUUqYO5RkjStZbvk2IDFSPUExvqhCstnJf7PZGilbsFPN8lYqcIvDZdaAU'
    'MunNh6f/RnhFwKHXoyWtNI6yK6dm1mhwy+DgPlA2nAevO+FC7Vv98Sl9zaVjaPPy'
    '3BRyQ6kISCL065AKVPEY0ULHqtIyfU5gMvBeUa5+xbU+tUx4ZeP/BdB48/LodyYV'
    'kkgqTafVxCvz4vgmPbnPjm/dlRbVGbyygN0Noq8vo2Ea8Z5zwO32coY2309AC7wv'
    'Pp2wJZn6LKRmzoLWJMFm1A1Oa4RUIkEpA3AAL+5TauxfawpdtTjicoWGQ5gGNwum'
    '+evTnGEpDimE5kUU6uiJ0rotjNpB52I+8qmbgIPkY0Fwwal5Z5yvZJ8eepQjvdZ2'
    'UcdvlTS8oA5YayGi+ASmnJSbsr/v1OOcLmnpwPI+hRgPP+Hwu5rWkOT+SDomF1TO'
    'n/k7NkJ967X0kPx6XtxTPgcG1aKJwZBNQDKDP17/dlZ869W3o6JdgCEvt1nIOPty'
    'lGgvGERC0jCNRJpGml4/py7AtP0WOxrs+YS60sPKMATtiGzp34++dAmHyVEmelhK'
    'apQBuxFl6LQN33+2NNn6L5twI4IQfnm6Cvly9r3VBO0Bi+rpjdftr60scRQM1qw+'
    '9dEz4xL9VEL6wrnyAERLY58wmS9Zp73xXQ1mdDB+yKkGOHeIiA7tCwnNZqClQ8Mf'
    'RnZIAeL1jcqrIsmkQNs4RTuE+ApcnE5DMcvJMgEd1fU3JDRJbaUv+w7kxj4/+G5b'
    'IU2bfh52jUQ5gOftGEFs1LOLj4Bny2XlCiP0L7XLJTKSf0t1zj2ohQWDT5BLo0EV'
    '5rye4hckB4QCiNyiZfavwB6ymStjwnuaS8qwjaRLw4JEeNDjSs/JC0G2ewulUyHt'
    'kEobZO/mQLlhso2lnEaRtK1LyoD1b4IEDbTYmjaWKLR7J64iHKUpiQYPSPxcWyei'
    'o4kcyGw+QvgmxGaKsqSBVGogOV6YuEyoaM0jlfUmi2UmQkju2iY5tzCObNQ41nsL'
    'dKwraDrcjrn4CAKPMMfeUSvYWP559EFfDhDSK6Os6Sbo8R6Zoa7C2NdAicA1jPbt'
    '5ENSrVKf7TOrthvNH9vb1mZC1X2RBmriowa/iT+LEbmQnAkA6Y1tCbpzvrL+cX8K'
    'pUTOAovaiPbab0xzFP7QXc1uK0XA+M1wQ9OF3XGp8PS5QRgSTwMpQXW2iMqihYPv'
    'Hu6U1hhkyfzYZzoJCjVsY2xghJmjKiKEfX0w3RaxfrJkF8ePY9SexnVUNXJ1654/'
    'PQzDKsW58Au9QpIH9VSwKNpv003PksOpobM6G52ouCFOk6HFzSLfnlGZW0yyUQL3'
    'RRyEE2PP0LwQEuk2gxrW8eVy9elqn43S8CG2h2NUtmQULc/IeX63tmCOmOS0emW9'
    '66EljNdMk/e5dTo5XplTJRxRydXcQpgy9bQuntFwPPoo0fXfXlirKsav2rPSWayw'
    'KQK4NxinT+yQh//COeQDYkK01urc2G7SxZ6H0k6uo8xVp9tDCYqHk/lbvukoN0RF'
    'tUI4aLWuKet1O1s1uUAxjd50ELks5iwoqLJ/1bzSmTRMifehP07sbK/N1f4hLae+'
    'jykYgzDWNfNvmPEiz0DwO/rCQTP6x69g+NJaFlmPFwGsKfxP8HqiNWQ6D3irZYcQ'
    'R5Mt2Iwzz2ZWA7B2WLYZWndRCosRVWyPdGhs7gkmLPZ+WWo/Yb7O1kIiWGfVuPNA'
    'MKmgPPjZy8DhZfq5kX20KF6uA0JOZOciXhc0PPAUEy/iQAtzSDYjmJ8HR7l4mYsT'
    'O3Mg3QibMK8MGGa4tEM8OPGktAV5B2J2QOe0f1r3vi3QmM+yukBaabwlJ+dUDQGm'
    '+Ll/1mO5TS+BlWMEAi13cB5bPRsxkzpabxq5kyQwh4vcMuLI0BOIfE2pDKny5jhW'
    '0C4zzv3avYaJh2ts6kvlvTKiSMeXcnK6onKHT89fWQ7Hzr/W8QbR/GnIWBbJMoTc'
    'WcgmW4fO3AC+YlnLVK4kBmnBmsLzLh6M2LOabhxKN8+0Oeoouww7g0HgHkDyt+MS'
    '97po6SETwrdqEFslylLo8+GifFI1bb68H79iEwjXojxQXcD5qqJPxdHsA32eWV0b'
    'qXAVojyAk7kQJfDIK+Y1q9T6KI4ew4t6iauJ8iVJyClnHt8z/4cXdMX37EvJ+2BS'
    'YKHv5OAfS7/9ZpKgILT8NxghgvguLB7G9sWNHntExPtuRLL4/asYFYSAJxUPm7U2'
    'xnp35Zx5jCXesd5OlKNdmhXq519cLl0RGZfH2ZIAEf1hNZqDuKesZ2enykjFlIec'
    'hZsLvEW/pJQnW0+LFz9N3x3vJwxbC7oDgd7A2u0I69Tkdzlc6FFJcfGabT5C3eF2'
    'EAC+toIobJY9hpxdkeukSuxVwin9zuBoUM4X9x/FvgfIE0dKLpzsFyMNlO4taCLc'
    'v1zbgUk2sR91JmbiCbqHglTzQaVMLhPwd8GU55AvYCGMOsSg3p952UkeoxRSeZRp'
    'jQHr4bLN90cqNcrD3h5knmC61nDKf8e+vRZO8CVYR1eb3LsMz12vhTJGaQ4jd0Kz'
    'QyosjcB73wnE9b/rxfG1dRactg7zRU2BfBK/CHpIFJH+XztwMJxn27foSvCY6ktd'
    'uJorJvkGJOgwg0f+oHKDvOTWFO1GSqEZ5BwXKGH0t0udZyXQGgZWvF5s/ojZVcK3'
    'IXz4tKhwrI1ZKnZwL9R2zrpMJ4w6smQgipP0yzzi0ZvsOXRksQJNCn4UPLBhbu+C'
    'eFBbpfe9wJFLD+8F9EY6GlY2W9AKD5/zNUCj6ws8lBn3aRfNPE+Cxy+IKC1NdKLw'
    'eFdOGZr2y1K2IkdefmN9cLZQ/CVXkw8Qw2nOr/ntwuFV/tvJoPW2EOzRmF2XO8mQ'
    'DQv51k5/v4ZE2VL0dIIvj1M+KPw0nSs271QgJanYwK3CpFluK/1ilEi7JKDikT8X'
    'TSz1QZdkum5Y3uC7wc7paXh1rm11nwluCC7jiA=='
)

# winget package IDs. 7-Zip is installed before the NVIDIA step, which needs it.
$PackageIds = @(
    'Microsoft.VCRedist.2015+.x64'
    'Microsoft.VCRedist.2015+.x86'
    'Microsoft.DirectX'
    '7zip.7zip'
    'Mozilla.Firefox'
    'Orbmu2k.nvidiaProfileInspector'
    'Microsoft.Sysinternals.Autoruns'
)
# Installed only when an NVIDIA GPU is present.
$NvidiaOnlyPackages = @('Orbmu2k.nvidiaProfileInspector')

# NVIDIA global (Base Profile) settings for NvidiaProfile, from FR33THY Ultimate "5 Nvidia Settings" (MIT), imported
# with Profile Inspector's merge import so nothing else in the profile changes. Left out on purpose: G-SYNC, V-Sync and
# the frame rate limiter (people rely on them), forced antialiasing and anisotropic overrides (they override what games
# ask for), and the preferred OpenGL GPU (its value names one specific card).
$NvidiaBaseSettings = @(
    @{ Name = 'Maximum Pre-Rendered Frames'; Id = 8102046; Value = 1 }
    @{ Name = 'Preferred Refresh Rate'; Id = 6600001; Value = 1 }          # highest available
    @{ Name = 'Ultra Low Latency - CPL State'; Id = 390467; Value = 2 }     # Ultra
    @{ Name = 'Ultra Low Latency - Enabled'; Id = 277041152; Value = 1 }
    @{ Name = 'Texture Filtering - Quality'; Id = 13510289; Value = 20 }    # high performance
    @{ Name = 'Texture Filtering - Trilinear Optimization'; Id = 3066610; Value = 0 }
    @{ Name = 'Texture Filtering - Negative LOD Bias'; Id = 1686376; Value = 0 }
    @{ Name = 'Anisotropic Filter - Optimization'; Id = 8703344; Value = 1 }
    @{ Name = 'Anisotropic Filter - Sample Optimization'; Id = 15151633; Value = 1 }
    @{ Name = 'CUDA - Force P2 State'; Id = 1343646814; Value = 0 }         # keep full clocks under CUDA
    @{ Name = 'CUDA - Sysmem Fallback Policy'; Id = 283962569; Value = 1 }  # prefer no system memory fallback
    @{ Name = 'Power Management - Mode'; Id = 274197361; Value = 1 }        # prefer maximum performance
    @{ Name = 'Shader Cache - Cache Size'; Id = 11306135; Value = 4294967295 } # unlimited
    @{ Name = 'Threaded Optimization'; Id = 549528094; Value = 1 }
)
# Resizable BAR forced on for every application (NvidiaReBar), from Ultimate "7 ReBar Force".
$NvidiaReBarSettings = @(
    @{ Name = 'rBAR - Enable'; Id = 983226; Value = 1 }
)
$NvidiaDrsDir = Join-Path $env:ProgramData 'NVIDIA Corporation\Drs'

# Apps removed by the debloat step (wildcards allowed). Anything matching $KeepApps is never removed.
$AppsToRemove = @(
    'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch',
    'Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People',
    'Microsoft.Todos', 'Microsoft.PowerAutomateDesktop', 'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps', 'Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice',
    'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'MicrosoftTeams', 'MSTeams',
    'Microsoft.OutlookForWindows', 'Microsoft.Copilot', 'Microsoft.549981C3F5F10',
    'Microsoft.MixedReality.Portal', 'Microsoft.SkypeApp', 'Microsoft.MicrosoftJournal',
    'Microsoft.Microsoft3DViewer', 'Microsoft.3DBuilder', 'Microsoft.Print3D', 'Microsoft.OneConnect',
    'Microsoft.Wallet', 'Microsoft.MicrosoftStickyNotes', 'Microsoft.WindowsSoundRecorder',
    'Microsoft.WindowsAlarms', 'Microsoft.Windows.DevHome', 'Microsoft.MicrosoftTeamsforSurfaceHub',
    '*Spotify*', '*Disney*', '*Netflix*', '*TikTok*', '*Instagram*', '*Facebook*', '*Twitter*',
    '*LinkedIn*', '*CandyCrush*', 'king.com.*', '*AmazonPrimeVideo*', '*Amazon.com.Amazon*',
    '*Hulu*', '*Duolingo*', '*Pinterest*', '*WhatsApp*'
)

# Never removed, whatever else is listed. Photos needs the image codec extensions kept below.
$KeepApps = @(
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.Xbox*', 'Microsoft.GamingApp',
    'Microsoft.GamingServices', '*MicrosoftEdge*', 'Microsoft.Paint', 'Microsoft.Windows.Photos',
    'Microsoft.WindowsCalculator', 'Microsoft.WindowsNotepad', 'Microsoft.WindowsTerminal',
    'Microsoft.ScreenSketch', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI',
    '*ImageExtension*', '*VideoExtension*', '*MediaExtensions*'
)

# Never deleted by TaskMode Delete, whatever the profile says: no speed gain, real breakage.
$TaskKeepBuiltIn = @(
    '\Microsoft\Windows\Time Synchronization\*'
    '\Microsoft\Windows\Defrag\*'
    '\Microsoft\Windows\TPM\*'
    '\Microsoft\Windows\BitLocker\*'
    # Triggered by a Windows state notification (WNF): Task Scheduler refuses to register it again from its export
    # ("Element not found"), so deleting it could never be undone.
    '\Microsoft\Windows\Application Experience\SdbinstMergeDbTask'
    '\Microsoft\Windows\UpdateOrchestrator\StartOobeAppsScanAfterUpdate'   # same: "Element not found" on restore
    # docs/AUDIT.md A-03: deleting these stops protection or updates without a word: Defender scans, cache upkeep and
    # verification, the System Restore point schedule, certificate enrolment and renewal, and the browser updaters
    # (Edge, Google, Firefox). Telemetry tasks next to them, such as the Firefox Default Browser Agent, still go.
    '\Microsoft\Windows\Windows Defender\*'
    '\Microsoft\Windows\SystemRestore\SR'
    '\Microsoft\Windows\CertificateServicesClient\*'
    '\MicrosoftEdgeUpdate*'
    '\GoogleUpdateTask*'
    '\GoogleSystem\GoogleUpdater\*'
    '\Mozilla\Firefox Background Update*'
)
# Upstream sets NtfsDisableLastAccessUpdate to the legacy value 1, which current Windows replaces at boot with
# 0x80000002 (system managed, last access ON). 0x80000001 is the user managed "off" that stays (fsutil writes it).
$LastAccessRegs = @(
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsDisableLastAccessUpdate' -2147483647 'DWord'
)
$TimeSyncTask = @{ Path = '\Microsoft\Windows\Time Synchronization\'; Name = 'SynchronizeTime' }

# Telemetry scheduled tasks, used by -TaskMode Disable.
$TelemetryTasks = @(
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' }
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' }
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'StartupAppTask' }
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'PcaPatchDbTask' }
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' }
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' }
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'KernelCeipTask' }
    @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient' }
    @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload' }
    @{ Path = '\Microsoft\Windows\Autochk\'; Name = 'Proxy' }
    @{ Path = '\Microsoft\Windows\DiskDiagnostic\'; Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' }
    @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting' }
)

$PowerPlanBase = 'Tweaked Performance'
$HighPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$BalancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
$UsbSubGuid = '2a737441-1930-4402-8d77-b2bebba308a3'
$UsbSuspendGuid = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$UltimatePerformanceGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$PowerProfiles = @{
    High   = @{
        # Ultimate Performance first (hidden scheme, present on Windows 10 1803 and later), then High Performance.
        Base     = @($UltimatePerformanceGuid, $HighPerformanceGuid)
        Settings = @(
            @('SUB_PROCESSOR', 'PROCTHROTTLEMIN', '100'),
            @('SUB_PROCESSOR', 'PROCTHROTTLEMAX', '100'),
            @('54533251-82be-4824-96c1-47b60b740d00', '0cc5b647-c1df-4637-891a-dec35c318583', '100'),  # core parking, minimum cores
            @('54533251-82be-4824-96c1-47b60b740d00', 'ea062031-0e34-4ff1-9b6d-eb1059334028', '100'),  # core parking, maximum cores
            @('54533251-82be-4824-96c1-47b60b740d00', '94d3a615-a899-4ac5-ae2b-e4d8f634367f', '1'),    # cooling policy: active
            @('SUB_DISK', 'DISKIDLE', '0'),
            @('SUB_PCIEXPRESS', 'ASPM', '0'),
            @($UsbSubGuid, $UsbSuspendGuid, '0'),                                                       # USB selective suspend off
            @($UsbSubGuid, '0853a681-27c8-4100-a2fd-82013e970683', '0'),                                # hub selective suspend timeout
            @($UsbSubGuid, 'd4e98f31-5ffe-4ce1-be31-1b38b384c009', '0'),                                # USB 3 link power management off
            @('19cbb8fa-5279-450e-9fac-8a3d5fedd0c1', '12bbebe6-58d6-4636-95bb-3217ef867c1a', '0'),   # wireless adapter: maximum performance
            @('238c9fa8-0aad-41ed-83f4-97be242c8f20', 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d', '0')    # wake timers off
        )
    }
    Medium = @{
        Base     = @($BalancedGuid)
        Settings = @(
            @('SUB_PROCESSOR', 'PROCTHROTTLEMIN', '50'),
            @('SUB_PROCESSOR', 'PROCTHROTTLEMAX', '100'),
            @('SUB_PCIEXPRESS', 'ASPM', '1'),
            @($UsbSubGuid, $UsbSuspendGuid, '0')
        )
    }
}

# Quiet Defender: protection stays on, only reporting and notifications stop. Policy values, so -Revert restores them.
$DefenderQuietRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SpynetReporting' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 2 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\MRT' 'DontReportInfectionInformation' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Reporting' 'DisableEnhancedNotifications' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' 'DisableNotifications' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' 'DisableEnhancedNotifications' 1 'DWord'
)

# Network adapter driver keywords (from Ultimate, 6 Windows\26). Only keywords a driver already exposes are changed.
$NetAdapterClassKey = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$NetPowerKeywords = @('SipsEnabled', 'ULPMode', 'GigaLite', 'EnableGreenEthernet', 'PowerSavingMode')
$NetEeeKeywords = @('AdvancedEEE', '*EEE', 'EEELinkAdvertisement')

# Spectre and Meltdown mitigations off (from Ultimate, 8 Advanced\3).
$MitigationRegs = @(
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'FeatureSettingsOverride' 3 'DWord'
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'FeatureSettingsOverrideMask' 3 'DWord'
)

# Timer resolution service (reduced from Ultimate, 6 Windows\30): sets the finest timer resolution at start and holds it.
# Windows 10 2004 and later honour the request per process, so GlobalTimerResolutionRequests makes it system wide.
# A 0.5 ms timer fires about 2000 times a second, which costs battery: laptop profiles should skip this option.
$TimerServiceName = 'FocusedTimerResolution'
$TimerGlobalRegs = @(
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1 'DWord'
)
$TimerServiceSource = @'
using System;
using System.Runtime.InteropServices;
using System.ServiceProcess;

public class TimerResolutionService : ServiceBase
{
    [DllImport("ntdll.dll")]
    static extern int NtQueryTimerResolution(out uint minimum, out uint maximum, out uint actual);
    [DllImport("ntdll.dll")]
    static extern int NtSetTimerResolution(uint desired, bool set, out uint current);

    public TimerResolutionService() { ServiceName = "FocusedTimerResolution"; }

    protected override void OnStart(string[] args)
    {
        uint minimum, maximum, actual;
        NtQueryTimerResolution(out minimum, out maximum, out actual);
        NtSetTimerResolution(maximum, true, out actual);
    }

    protected override void OnStop()
    {
        uint current;
        NtSetTimerResolution(0, false, out current);
    }

    public static void Main() { ServiceBase.Run(new TimerResolutionService()); }
}
'@

# Device power saving and wake (from Ultimate, 6 Windows\25). Values go under each device's 'Device Parameters' key.
$DeviceEnumRoots = @('ACPI', 'HID', 'PCI', 'USB')
$DevicePowerValues = @(
    @{ Name = 'EnhancedPowerManagementEnabled'; Value = 0; Type = 'DWord' }
    @{ Name = 'SelectiveSuspendEnabled'; Value = [byte[]]@(0); Type = 'Binary' }
    @{ Name = 'SelectiveSuspendOn'; Value = 0; Type = 'DWord' }
)

# Multiplane overlay off (from Ultimate, 8 Advanced\11). Only the overlay switch: Ultimate also rewrites the per user
# DirectX settings string, which would drop any other per app GPU preference stored in it.
$MpoRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5 'DWord'
)

# Faster shutdown (from ZOICWARE, optional tweaks).
$FastShutdownRegs = @(
    New-Tweak 'HKCU\Control Panel\Desktop' 'WaitToKillAppTimeout' '1500' 'String'
    New-Tweak 'HKCU\Control Panel\Desktop' 'AutoEndTasks' '1' 'String'
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' '1500' 'String'
)

# Time server (from ZOICWARE, optional tweaks). Written to the registry so -Revert restores the old servers.
$TimeServerRegs = @(
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' 'NtpServer' '0.pool.ntp.org,0x9 1.pool.ntp.org,0x9 2.pool.ntp.org,0x9 3.pool.ntp.org,0x9' 'String'
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' 'Type' 'NTP' 'String'
)

# Right click menu entries (from ZOICWARE, UltimateContextMenu\killTasks.reg, AddRestartExplorer.reg and Take Ownership).
$MenuKillRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\KillNotResponding' 'MUIVerb' 'Kill not responding tasks' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\KillNotResponding' 'Icon' '%SystemRoot%\System32\imageres.dll,-98' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\KillNotResponding' 'Position' 'Top' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\KillNotResponding\command' '' 'cmd.exe /K taskkill.exe /F /FI "status eq NOT RESPONDING"' 'String'
)
$MenuRestartExplorerRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\RestartExplorer' 'MUIVerb' 'Restart Explorer' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\RestartExplorer' 'Icon' 'explorer.exe' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\RestartExplorer' 'Position' 'Bottom' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\RestartExplorer' 'SeparatorBefore' '' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\RestartExplorer\command' '' 'cmd.exe /c taskkill /f /im explorer.exe && start explorer.exe' 'String'
)
$TakeOwnFile = 'cmd.exe /c takeown /f "%1" && icacls "%1" /grant *S-1-5-32-544:F'
$TakeOwnDir = 'cmd.exe /c takeown /f "%1" /r /d y && icacls "%1" /grant *S-1-5-32-544:F /t'
$MenuTakeOwnershipRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Classes\*\shell\runas' '' 'Take Ownership' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\*\shell\runas\command' '' $TakeOwnFile 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\*\shell\runas\command' 'IsolatedCommand' $TakeOwnFile 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\Directory\shell\runas' '' 'Take Ownership' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\Directory\shell\runas\command' '' $TakeOwnDir 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\Directory\shell\runas\command' 'IsolatedCommand' $TakeOwnDir 'String'
)

# Power mode overlays that powercfg accepts by name, keyed by the GUID Windows stores for the active overlay.
$PowerOverlayNames = @{
    '00000000-0000-0000-0000-000000000000' = 'OVERLAY_SCHEME_NONE'
    '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'OVERLAY_SCHEME_MIN'
    '3af9b8d9-7c97-431d-ad78-34a8bfea439f' = 'OVERLAY_SCHEME_HIGH'
    'ded574b5-45a0-4f42-8737-46345c09c238' = 'OVERLAY_SCHEME_MAX'
}

# Lock screen off (from ZOICWARE, optional tweaks).
$LockScreenRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1 'DWord'
)

# Right click menu entries hidden by blocking their shell extension (from ZOICWARE, optional tweaks). A blocked value is
# removed again by -Revert, which ZOICWARE's key deletions could not undo. Quick access verbs are hidden instead.
$BlockedExt = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
$MenuBlocks = [ordered]@{
    MenuNoShare        = @(New-Tweak $BlockedExt '{e2bf9676-5f8f-435c-97eb-11607a5bedf7}' '' 'String')
    MenuNoGiveAccess   = @(New-Tweak $BlockedExt '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}' '' 'String')
    MenuNoCast         = @(New-Tweak $BlockedExt '{7AD84985-87B4-4a16-BE58-8B72A5B390F7}' '' 'String')
    MenuNoLibrary      = @(New-Tweak $BlockedExt '{3dad6c5d-2167-4cae-9914-f99e41c12cfa}' '' 'String')
    MenuNoQuickAccess  = @(
        New-Tweak 'HKLM\SOFTWARE\Classes\Folder\shell\pintohome' 'ProgrammaticAccessOnly' '' 'String'
        New-Tweak 'HKLM\SOFTWARE\Classes\Drive\shell\pintohome' 'ProgrammaticAccessOnly' '' 'String'
        New-Tweak 'HKLM\SOFTWARE\Classes\*\shell\pintohomefile' 'ProgrammaticAccessOnly' '' 'String'
    )
    MenuNoPinToStart   = @(New-Tweak $BlockedExt '{470C0EBD-5D73-4d58-9CED-E91E22E23282}' '' 'String')
    MenuNoPrevVersions = @(New-Tweak $BlockedExt '{596AB062-B4D2-4215-9F74-E9109B0A8153}' '' 'String')
    MenuNoTroubleshoot = @(New-Tweak $BlockedExt '{1d27f844-3a1f-4410-85ac-14651078412d}' '' 'String')
    MenuNoDefenderScan = @(New-Tweak $BlockedExt '{09A47860-11B0-4DA5-AFA5-26D86198A780}' '' 'String')
    MenuNoOneDrive     = @(New-Tweak 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' '{1FA0E654-C9F2-4A1F-9800-B9A75D744B00}' '' 'String')
    MenuNoTerminal     = @(New-Tweak $BlockedExt '{9F156763-7844-4DC4-B2B1-901F640F5155}' '' 'String')
}

# Run as administrator for scripts and installers (from ZOICWARE, UltimateContextMenu\runAsAdmin.reg).
$MenuRunAsAdminRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\runas' 'HasLUAShield' '' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\runas\command' '' 'powershell.exe "-Command" "if((Get-ExecutionPolicy ) -ne ''AllSigned'') { Set-ExecutionPolicy -Scope Process Bypass }; & ''%1''"' 'ExpandString'
    New-Tweak 'HKLM\SOFTWARE\Classes\Msi.Package\shell\runas' 'HasLUAShield' '' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\Msi.Package\shell\runas\command' '' '"%SystemRoot%\System32\msiexec.exe" /i "%1" %*' 'ExpandString'
    New-Tweak 'HKLM\SOFTWARE\Classes\VBSFile\Shell\runas' 'HasLUAShield' '' 'String'
    New-Tweak 'HKLM\SOFTWARE\Classes\VBSFile\Shell\runas\command' '' '"%SystemRoot%\System32\WScript.exe" "%1" %*' 'ExpandString'
)

# Native NVMe driver (from Ultimate, 8 Advanced\19): feature overrides plus Safe Mode entries so Safe Mode still boots.
$NvmeRegs = @(
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' '735209102' 1 'DWord'
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' '3244671118' 1 'DWord'
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' '1853569164' 1 'DWord'
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' '156965516' 1 'DWord'
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\{75416E63-5912-4DFA-AE8F-3EFACCAFFB14}' '' 'Storage disks' 'String'
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal\{75416E63-5912-4DFA-AE8F-3EFACCAFFB14}' '' 'Storage disks' 'String'
)

# Values Windows protects even from TrustedInstaller. A mismatch here is reported as a note, not a warning.
$KnownStuckValues = @('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener|Start')
# Values Windows recomputes on its own after a revert (the accent colours follow the theme once Explorer restarts),
# so the revert check reports them as notes instead of differences.
$WindowsRewrittenValues = @(
    'HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM|AccentColor'
    'HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM|ColorizationColor'
    'HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM|ColorizationAfterglow'
    # Start menu "All apps" list view: Windows 11 build 26200 resets it to its own default after a restart.
    'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start|AllAppsViewMode'
)

# Policy values that Microsoft documents for some editions only. Honoured and Ignored are EditionID wildcards
# (Core* is every Home edition). An edition in neither list gets 'unknown', and so does every other value under a
# Policies key on an edition outside $EditionFullPolicy: nothing here guesses (docs/AUDIT.md A-09 and U-07).
$EditionRules = @(
    # Diagnostic data level 0 (Security) exists on Enterprise, Education and Server; Home and Pro treat it as 1 (Required).
    @{ Names = @('AllowTelemetry'); Value = 0; Label = 'Enterprise, Education and Server'
        Honoured = @('Enterprise*', 'IoTEnterprise*', 'Education*', 'Server*'); Ignored = @('Core*', 'Professional', 'ProfessionalN') }
    # Windows Update for Business (deferrals, target version) is documented for Pro, Enterprise and Education.
    @{ Names = @('DeferFeatureUpdates', 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdates', 'DeferQualityUpdatesPeriodInDays', 'ProductVersion', 'TargetReleaseVersion', 'TargetReleaseVersionInfo')
        Label = 'Pro, Enterprise and Education'
        Honoured = @('Professional*', 'Enterprise*', 'IoTEnterprise*', 'Education*'); Ignored = @('Core*') }
)
# Editions on which Group Policy values are taken as honoured when no rule above says otherwise.
$EditionFullPolicy = @('Enterprise*', 'IoTEnterprise*', 'Education*', 'Server*')
#endregion

#region Infrastructure --------------------------------------------------------------------
$StateFile = Join-Path $StateDir 'state.json'
# One JSON line per recorded change, written and flushed before the change is made (docs/AUDIT.md A-01, A-11).
$JournalFile = Join-Path $StateDir 'journal.jsonl'
# 2: the state file records JournalSeq, the last journal line it holds. Files without it are version 1 (v7.4 and older).
$StateVersion = 2
$LogFile = Join-Path $StateDir ('run-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

$script:Failures = 0
$script:Warnings = 0
$script:TiCount = 0
$script:ShellDirty = $false
$script:JournalSeq = 0      # number of the last journal line written or read
$script:StepId = 0
$script:StepName = ''
$script:JournalOption = ''  # option the current change belongs to, written into each journal line
$script:StepEvents = [System.Collections.Generic.List[object]]::new()
$script:StopRun = $false
$script:State = @{
    Registry   = [System.Collections.Generic.List[object]]::new()
    KeyBackups = [System.Collections.Generic.List[object]]::new()
    Tasks      = [System.Collections.Generic.List[object]]::new()
    Removed    = [System.Collections.Generic.List[object]]::new()
    Hosts      = [System.Collections.Generic.List[object]]::new()
    Power      = $null
    Defender   = $false
    DefenderPrefs = $null
    Hibernate  = $null
    MemCompress = $null
    SleepStudy = $false
    PwAge      = $false
    ConsentDb  = $null
    Run        = $null
    StartLayout = $null
    Dep        = $null
    TimerService = $null
    PowerOverlay = $null
    PowerOverlaySet = $null
    PowerOverlaySource = $null
    NvidiaDrs  = $false
    DesktopMoved = [System.Collections.Generic.List[object]]::new()
    CreatedKeys = [System.Collections.Generic.List[object]]::new()
    NetBindings = [System.Collections.Generic.List[object]]::new()
    Features   = [System.Collections.Generic.List[object]]::new()
}
$script:RecordedReg = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if ($Level -eq 'WARN') { $script:Warnings++ }
    $line = '{0:HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    $colour = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    # With -Json the console gets only the result object; the log file still gets every line.
    if (-not $Json) { Write-Host $line -ForegroundColor $colour }
    Add-Content -Path $LogFile -Value $line
}

# docs/AUDIT.md C-5: exit codes, also in the README and in the -Json result.
$ExitCodes = @{ 0 = 'ok'; 1 = 'failures'; 2 = 'cancelled'; 3 = 'pre flight refused'; 4 = 'state unreadable' }
$script:PreflightResults = @()

function Get-RunMode {
    if ($Revert) { return 'revert' }
    if ($RestoreTask.Count -gt 0) { return 'restoretask' }
    if ($HealthCheck) { return 'healthcheck' }
    if ($Benchmark) { return 'benchmark' }
    if ($StartupReview) { return 'startupreview' }
    if ($script:DryRun) { return 'dryrun' }
    return 'apply'
}

function Get-RunResult {
    # The object -Json prints: what ran, how it ended, and where the details are.
    param([int]$Code, [string]$Reason = '')
    $health = $null
    if ($script:HealthItems.Count -gt 0) { $health = [ordered]@{ Counts = $script:Health; Items = @($script:HealthItems) } }
    $journal = $null
    if (Test-Path -LiteralPath $JournalFile) { $journal = $JournalFile }
    return [ordered]@{
        ExitCode = $Code; Result = $ExitCodes[$Code]; Reason = $Reason; Mode = (Get-RunMode)
        Failures = $script:Failures; Warnings = $script:Warnings; Preflight = @($script:PreflightResults); Health = $health
        Log = $LogFile; Journal = $journal; StateDir = $StateDir
    }
}

function Exit-Run {
    # Every exit after start up goes through here, so -Json always prints exactly one result object.
    param([int]$Code, [string]$Reason = '')
    if ($Json) { Write-Output (ConvertTo-Json -InputObject (Get-RunResult -Code $Code -Reason $Reason) -Depth 6) }
    exit $Code
}

function Test-DryRun {
    param([Parameter(Mandatory)][string]$Action)
    if ($script:DryRun) { Write-Log "DRY RUN, would: $Action"; return $true }
    return $false
}

function ConvertTo-StoredRecord {
    # PowerShell 7 turns ISO date strings into dates when it reads JSON, which would corrupt restored registry
    # strings. Registry records in the state file and the journal therefore carry an 's:' prefix on string values,
    # which ConvertFrom-StoredRecord removes again. Anything that is not a registry record is returned unchanged.
    param($Record)
    if ($null -eq $Record -or -not $Record.PSObject.Properties['Kind']) { return $Record }
    if (($Record.Kind -eq 'String' -or $Record.Kind -eq 'ExpandString') -and $Record.Value -is [string]) {
        return [pscustomobject]@{ Path = $Record.Path; Name = $Record.Name; Existed = $Record.Existed; Kind = $Record.Kind; Value = ('s:' + $Record.Value) }
    }
    return $Record
}

function ConvertFrom-StoredRecord {
    param($Record)
    if ($null -eq $Record -or -not $Record.PSObject.Properties['Kind']) { return $Record }
    if (($Record.Kind -eq 'String' -or $Record.Kind -eq 'ExpandString') -and $Record.Value -is [string] -and $Record.Value.StartsWith('s:')) {
        $Record.Value = $Record.Value.Substring(2)
    }
    return $Record
}

function Save-State {
    if ($script:DryRun) { return }
    $copy = @{}
    foreach ($entry in $script:State.GetEnumerator()) { $copy[$entry.Key] = $entry.Value }
    $copy.Registry = @($script:State.Registry | ForEach-Object { ConvertTo-StoredRecord $_ })
    $copy.StateVersion = $StateVersion
    $copy.JournalSeq = $script:JournalSeq
    # Written to a temporary file and swapped in, so a crash during the write cannot leave a truncated state file.
    # The version before it stays as state.json.bak, which Read-StateFile falls back to.
    $temp = "$StateFile.tmp"
    ConvertTo-Json -InputObject $copy -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    if (Test-Path -LiteralPath $StateFile) { [IO.File]::Replace($temp, $StateFile, "$StateFile.bak") }
    else { [IO.File]::Move($temp, $StateFile) }
}

function Read-StateFile {
    # The parsed state from state.json or, when that cannot be read, from state.json.bak (one step older).
    $problems = @()
    foreach ($file in $StateFile, "$StateFile.bak") {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $raw = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($null -eq $raw) { throw 'the file is empty.' }
            if ($problems.Count -gt 0) { Write-Log "The state file could not be read ($($problems -join ' ')). Using the previous version, $file; the journal fills in what that version lacks." 'WARN' }
            return $raw
        }
        catch { $problems += "$(Split-Path $file -Leaf): $($_.Exception.Message)" }
    }
    throw "The saved state in $StateDir cannot be read, so nothing was changed and -Revert cannot use it ($($problems -join ' ')). Keep the folder as it is: the task, registry key and hosts backups in it are intact."
}

function Add-StateItem {
    # Adds one record to a list in the state. The same rules apply live and when the journal is replayed.
    param([string]$Section, $Item)
    if ($Section -eq 'Registry') {
        if ($script:RecordedReg.Add("$($Item.Path)|$($Item.Name)")) { $script:State.Registry.Add($Item) }
        return
    }
    if ($Section -in 'CreatedKeys', 'Hosts', 'Features') {
        if (@($script:State[$Section]) -notcontains $Item) { $script:State[$Section].Add($Item) }
        return
    }
    $script:State[$Section].Add($Item)
}

function Invoke-JournalEvent {
    # Applies one journal event to the state. Change, Result and Rollback lines are the change log and alter nothing.
    param($JournalEvent)
    switch ($JournalEvent.Op) {
        'Add' { Add-StateItem -Section $JournalEvent.Section -Item $JournalEvent.Item }
        'Set' { $script:State[$JournalEvent.Name] = $JournalEvent.Value }
        'Task' {
            $r = $JournalEvent.Record
            $e = Get-TaskRecord -Path $r.Path -Name $r.Name
            if (-not $e) { $script:State.Tasks.Add($r) }
            elseif ($JournalEvent.Mode -eq 'upgraded') { $e.Action = 'Deleted'; $e.XmlFile = $r.XmlFile }
        }
        'TaskUndo' {
            # A delete that failed must not leave a record claiming the task was removed.
            $e = Get-TaskRecord -Path $JournalEvent.Path -Name $JournalEvent.Name
            if ($e -and $JournalEvent.Outcome -eq 'new') { [void]$script:State.Tasks.Remove($e) }
            elseif ($e -and $JournalEvent.Outcome -eq 'upgraded') { $e.Action = 'Disabled'; $e.XmlFile = $null }
        }
    }
}

function Add-JournalEvents {
    # Writes the events to the journal with one flushed write, and only then applies them to the state: a record of
    # every change is on disk before the change is made. Each event is an ordered hashtable; it gets its Seq here.
    # Dry runs and -Revert write no journal.
    param([AllowEmptyCollection()][object[]]$Events = @())
    if ($Events.Count -eq 0) { return }
    if (-not ($script:DryRun -or $Revert)) {
        $text = New-Object Text.StringBuilder
        foreach ($e in $Events) {
            $script:JournalSeq++
            $e['Seq'] = $script:JournalSeq
            $line = [ordered]@{ Seq = $script:JournalSeq; T = (Get-Date).ToString('o'); Step = $script:StepId; StepName = $script:StepName; Option = $script:JournalOption }
            foreach ($k in @($e.Keys)) {
                if ($k -eq 'Seq') { continue }
                if ($k -eq 'Item' -or $k -eq 'Before') { $line[$k] = ConvertTo-StoredRecord $e[$k] } else { $line[$k] = $e[$k] }
            }
            [void]$text.Append((ConvertTo-Json -InputObject $line -Depth 6 -Compress)).Append("`n")
        }
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text.ToString())
        $stream = [IO.FileStream]::new($JournalFile, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
    }
    foreach ($e in $Events) {
        Invoke-JournalEvent -JournalEvent $e
        $script:StepEvents.Add($e)
    }
}

function Set-StateValue {
    param([Parameter(Mandatory)][string]$Name, $Value)
    Add-JournalEvents @([ordered]@{ Op = 'Set'; Name = $Name; Value = $Value })
}

function Add-StateRecord {
    param([Parameter(Mandatory)][string]$Section, $Item)
    Add-JournalEvents @([ordered]@{ Op = 'Add'; Section = $Section; Item = $Item })
}

function New-ChangeResult {
    # The outcome of one change, as a journal line that refers to the line that announced it.
    param([Parameter(Mandatory)]$Change, [Parameter(Mandatory)][string]$Result, [string]$Now = '')
    $ref = 0
    if ($Change.Contains('Seq')) { $ref = $Change['Seq'] }
    return [ordered]@{ Op = 'Result'; Ref = $ref; Kind = $Change['Kind']; Target = $Change['Target']; Result = $Result; Now = $Now }
}

function Import-Journal {
    # Replays the journal lines the state file does not hold yet (Seq above its JournalSeq). They exist when a run
    # stopped during a step, after it recorded originals but before the state file was saved again.
    param([long]$After = 0)
    $script:JournalSeq = $After
    if (-not (Test-Path -LiteralPath $JournalFile)) { return }
    $replayed = 0; $bad = 0
    foreach ($text in [IO.File]::ReadAllLines($JournalFile)) {
        if (-not $text.Trim()) { continue }
        try { $e = $text | ConvertFrom-Json }
        catch { $bad++; continue }   # a line cut off when a run was killed while writing it
        $seq = [long]$e.Seq
        if ($seq -gt $script:JournalSeq) { $script:JournalSeq = $seq }
        if ($seq -le $After) { continue }
        foreach ($field in 'Item', 'Before') { if ($e.PSObject.Properties[$field]) { [void](ConvertFrom-StoredRecord $e.$field) } }
        Invoke-JournalEvent -JournalEvent $e
        if ($e.Op -in 'Add', 'Set', 'Task', 'TaskUndo') { $replayed++ }
    }
    if ($bad -gt 0) { Write-Log "$bad journal line(s) could not be read and were skipped (a run stopped while writing them)." 'WARN' }
    if ($replayed -gt 0) { Write-Log "Recovered $replayed record(s) from the journal that the state file did not hold yet: the previous run stopped during a step. -Revert can undo those changes too." 'WARN' }
}

function Undo-CreatedKey {
    # Removes one key the run created, only when it is empty again: anything added to it since is left alone.
    param([string]$Full)
    try { $key = Open-RegKey -Full $Full }
    catch { Write-Log "Could not open the created key $Full. $($_.Exception.Message)" 'WARN'; return }
    if (-not $key) { return }
    $empty = ($key.ValueCount -eq 0) -and ($key.SubKeyCount -eq 0)
    $key.Close()
    if (-not $empty) { Write-Log "Key kept, it holds data added after the run: $Full"; return }
    $parts = Split-RegPath $Full
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($script:Hives[$parts[0].ToUpperInvariant()], [Microsoft.Win32.RegistryView]::Default)
    try { $base.DeleteSubKey($parts[1], $false) }
    catch { Write-Log "Could not remove the created key $Full. $($_.Exception.Message)" 'WARN' }
    finally { $base.Close() }
}

function Test-RollbackSafe {
    # Registry values, registry keys, keys the run created and scheduled tasks can be put back exactly from the
    # journal. Other records (hosts file, power plan, features, files, Defender and more) cannot.
    param($JournalEvent)
    switch ($JournalEvent.Op) {
        'Change' { return ($JournalEvent.Kind -in 'Registry', 'RegistryKey', 'Task') }
        'Add' { return ($JournalEvent.Section -in 'Registry', 'KeyBackups', 'CreatedKeys') }
        'Set' { return $false }
        default { return $true }   # Task, TaskUndo, Result and Rollback lines only describe
    }
}

function Undo-FailedStep {
    # docs/AUDIT.md A-04: a step that failed is put back from its own journal lines, newest first, so it is not left
    # half done. When the step changed something the journal cannot put back, the run stops instead: nothing more is
    # built on a half done step, and -Revert still undoes everything recorded.
    param([string]$Name)
    $changes = @($script:StepEvents | Where-Object { $_.Op -ne 'Result' -and $_.Op -ne 'Rollback' })
    if ($changes.Count -eq 0) { Write-Log "Rollback of '$Name': the step recorded no changes, nothing to undo."; return }
    $unsafe = @($changes | Where-Object { -not (Test-RollbackSafe $_) })
    if ($unsafe.Count -gt 0) {
        $script:StopRun = $true
        $what = @($unsafe | ForEach-Object { if ($_.Op -eq 'Set') { $_.Name } elseif ($_.Op -eq 'Add') { $_.Section } else { $_.Kind } } | Select-Object -Unique) -join ', '
        Write-Log "Rollback of '$Name' is not safe: the step also changed $what, which the journal cannot put back. The run stops here. Everything recorded so far is saved, so -Revert undoes it." 'ERROR'
        return
    }
    $failedTasks = @($script:StepEvents | Where-Object { $_.Op -eq 'Result' -and $_.Kind -eq 'Task' -and $_.Result -eq 'FAILED' } | ForEach-Object { $_.Ref })
    $tasks = [System.Collections.Generic.List[object]]::new()
    $undone = 0; $problems = 0
    [array]::Reverse($changes)
    foreach ($e in $changes) {
        try {
            if ($e.Op -eq 'Change' -and $e.Kind -eq 'Registry') { Restore-RegValue -Entry $e.Before; $undone++ }
            elseif ($e.Op -eq 'Change' -and $e.Kind -eq 'RegistryKey') {
                $null = & cmd.exe /d /c "reg.exe import `"$($e.Before)`" >nul 2>&1"
                if ($LASTEXITCODE -ne 0) { throw "reg.exe import failed ($LASTEXITCODE)." }
                $undone++
            }
            elseif ($e.Op -eq 'Change' -and $e.Kind -eq 'Task' -and $failedTasks -notcontains $e.Seq) { $tasks.Add($e.Before) }
            elseif ($e.Op -eq 'Add' -and $e.Section -eq 'CreatedKeys') { Undo-CreatedKey -Full $e.Item }
        }
        catch { $problems++; Write-Log "Rollback of '$Name': could not put back $($e.Target). $($_.Exception.Message)" 'WARN' }
    }
    if ($tasks.Count -gt 0) { Restore-Tasks -Tasks $tasks.ToArray(); $undone += $tasks.Count }
    $outcome = 'OK'; if ($problems -gt 0) { $outcome = 'PARTIAL' }
    Add-JournalEvents @([ordered]@{ Op = 'Rollback'; Kind = 'Step'; Target = $Name; Result = $outcome; Now = "$undone change(s) put back" })
    if ($problems -eq 0) { Write-Log "Rolled back '$Name': $undone change(s) put back from the journal." 'WARN' }
    else {
        $script:StopRun = $true
        Write-Log "Rollback of '$Name' put back $undone change(s) but $problems could not be put back (listed above). The run stops here; -Revert undoes what is recorded." 'ERROR'
    }
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action, [string]$Option = '')
    if ($script:StopRun) { Write-Log "Skipped: $Name. The run stopped after a step that could not be rolled back." 'WARN'; return }
    $script:StepId++
    $script:StepName = $Name
    $script:JournalOption = $Option
    $script:StepEvents.Clear()
    $failuresBefore = $script:Failures
    Write-Log "Starting: $Name"
    try {
        & $Action
        if ($script:Failures -eq $failuresBefore) { Write-Log "Completed: $Name" 'OK' }
        else { Write-Log "Failed: $Name. $($script:Failures - $failuresBefore) change(s) in it failed, listed above." 'ERROR' }
    }
    catch {
        $script:Failures++
        Write-Log "Failed: $Name. $($_.Exception.Message)" 'ERROR'
    }
    finally {
        if ($script:Failures -gt $failuresBefore -and -not $Revert -and -not $script:DryRun) { Undo-FailedStep -Name $Name }
        if (-not $Revert) { Save-State }
        $script:JournalOption = ''
    }
}

function Import-State {
    $after = 0
    if ((Test-Path -LiteralPath $StateFile) -or (Test-Path -LiteralPath "$StateFile.bak")) {
        $raw = Read-StateFile
        foreach ($section in 'Registry', 'KeyBackups', 'Tasks', 'Removed', 'Hosts', 'DesktopMoved', 'CreatedKeys', 'NetBindings', 'Features') {
            if ($raw.PSObject.Properties[$section] -and $raw.$section) {
                foreach ($item in @($raw.$section)) {
                    if ($section -eq 'Registry') { $item = ConvertFrom-StoredRecord $item }
                    Add-StateItem -Section $section -Item $item
                }
            }
        }
        foreach ($scalar in 'Power', 'Defender', 'DefenderPrefs', 'Hibernate', 'MemCompress', 'SleepStudy', 'PwAge', 'ConsentDb', 'Run', 'StartLayout', 'Dep', 'TimerService', 'PowerOverlay', 'PowerOverlaySet', 'PowerOverlaySource', 'NvidiaDrs') {
            if ($raw.PSObject.Properties[$scalar]) { $script:State[$scalar] = $raw.$scalar }
        }
        # Version 1 files (v7.4 and older) have no JournalSeq; there was no journal then, so every line is newer.
        if ($raw.PSObject.Properties['JournalSeq']) { $after = [long]$raw.JournalSeq }
    }
    Import-Journal -After $after
}

function Test-RecordedFirst {
    param([System.Collections.Generic.List[object]]$List, [scriptblock]$Predicate)
    foreach ($item in $List) { if (& $Predicate $item) { return $true } }
    return $false
}

function Initialize-StateDir {
    # The state file is read back by -Revert and -HealthCheck and drives file, service and TrustedInstaller actions, and
    # C:\ProgramData lets standard users create folders. So the folder must belong to administrators and be closed to
    # everyone else before anything is read from it. A folder someone else owns or filled is refused, not repaired.
    $sid = { param($s) [Security.Principal.SecurityIdentifier]$s }
    $admins = & $sid 'S-1-5-32-544'
    $system = & $sid 'S-1-5-18'
    $trusted = @($admins, $system, (& $sid 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'), [Security.Principal.WindowsIdentity]::GetCurrent().User)
    # Order matters: check who owns the folder, close it, and only then look inside. Checking the contents first would
    # leave a gap in which another user could still add a file that the check never sees.
    $isForeign = { param($item) (Test-ReparsePoint $item) -or ($trusted -notcontains (Get-Acl -LiteralPath $item.FullName).GetOwner([Security.Principal.SecurityIdentifier])) }
    $refuse = { param($item) throw "The state folder $StateDir holds an item that is a link or not owned by an administrator ($($item.FullName)). Delete the folder or pass another -StateDir, then run again." }
    # New-Item -Force also succeeds on a folder someone created a moment earlier, so the owner is checked either way.
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $folder = Get-Item -LiteralPath $StateDir -Force
    if (& $isForeign $folder) { & $refuse $folder }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($owner in $admins, $system) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($owner, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $StateDir -AclObject $acl
    # Closed now, so nobody can add anything while the contents are checked.
    $children = @(Get-CleanupTree -Path $StateDir)
    foreach ($child in $children) { if (& $isForeign $child) { & $refuse $child } }
    # Make existing files and folders inherit the closed permissions instead of the old open ones. Only the children are
    # reset: resetting the folder itself would give back the inherited, open permissions.
    if ($children.Count -gt 0) {
        & icacls.exe (Join-Path $StateDir '*') /reset /T /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls could not reset the permissions inside $StateDir ($LASTEXITCODE)." }
    }
}

function Test-NameMatch {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    return $false
}
#endregion

#region Registry primitives (full key names, .NET API, TrustedInstaller fallback) ----------
$script:Hives = @{
    'HKEY_LOCAL_MACHINE' = [Microsoft.Win32.RegistryHive]::LocalMachine
    'HKEY_CURRENT_USER'  = [Microsoft.Win32.RegistryHive]::CurrentUser
    'HKEY_USERS'         = [Microsoft.Win32.RegistryHive]::Users
    'HKEY_CLASSES_ROOT'  = [Microsoft.Win32.RegistryHive]::ClassesRoot
}

function ConvertTo-FullRegPath {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path -replace '^Registry::', ''
    $p = $p -replace '^HKLM:?\\', 'HKEY_LOCAL_MACHINE\'
    $p = $p -replace '^HKCU:?\\', 'HKEY_CURRENT_USER\'
    $p = $p -replace '^HKU:?\\', 'HKEY_USERS\'
    $p = $p -replace '^HKCR:?\\', 'HKEY_CLASSES_ROOT\'
    # Upstream writes to ControlSet001, which is only the active set on most machines. CurrentControlSet always is.
    $p = $p -replace '^HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\', 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\'
    return $p.TrimEnd('\')
}

function Split-RegPath {
    param([string]$Full)
    $i = $Full.IndexOf('\')
    if ($i -lt 0) { return @($Full, '') }
    return @($Full.Substring(0, $i), $Full.Substring($i + 1))
}

function Open-RegKey {
    param([string]$Full, [switch]$Write, [switch]$Create)
    $parts = Split-RegPath $Full
    $hive = $script:Hives[$parts[0].ToUpperInvariant()]
    if ($null -eq $hive) { throw "Unsupported registry root: $($parts[0])" }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
    try {
        if ($Create) { return $base.CreateSubKey($parts[1], $true) }
        return $base.OpenSubKey($parts[1], [bool]$Write)
    }
    finally { $base.Close() }
}

function ConvertTo-StoredValue {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'Binary' { return (($Value | ForEach-Object { '{0:x2}' -f $_ }) -join '') }
        'None' { return '' }
        default { return $Value }
    }
}

function ConvertFrom-StoredValue {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'Binary' {
            $s = [string]$Value
            $bytes = New-Object byte[] ($s.Length / 2)
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($s.Substring($i * 2, 2), 16) }
            , $bytes
        }
        'MultiString' { , ([string[]]$Value) }
        'DWord' { [int]$Value }
        'QWord' { [long]$Value }
        default { $Value }
    }
}

function Get-RegSnapshot {
    param([string]$Full, [string]$Name)
    $existed = $false; $kind = $null; $value = $null
    $key = Open-RegKey -Full $Full
    if ($key) {
        try {
            if ($key.GetValueNames() -contains $Name) {
                $existed = $true
                $kind = $key.GetValueKind($Name).ToString()
                $value = ConvertTo-StoredValue -Value $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') -Kind $kind
            }
        }
        finally { $key.Close() }
    }
    [pscustomobject]@{ Path = $Full; Name = $Name; Existed = $existed; Kind = $kind; Value = $value }
}

function Get-MissingKeyEvents {
    # Journal events for the keys a write is about to create, so -Revert can remove them again. Restoring the values
    # alone would leave empty keys behind, and an empty right click menu key still shows up as a menu entry.
    param([string]$Full)
    $missing = @()
    $path = $Full
    while ($path.Contains('\')) {
        try { $key = Open-RegKey -Full $path }
        catch { break }   # exists but is not readable, so it was not created by this run
        if ($key) { $key.Close(); break }
        $missing += $path
        $path = $path.Substring(0, $path.LastIndexOf('\'))
    }
    # Shallowest first, so a rollback, which goes newest first, removes the deepest key before its parent.
    [array]::Reverse($missing)
    foreach ($m in $missing) { if (@($script:State.CreatedKeys) -notcontains $m) { [ordered]@{ Op = 'Add'; Section = 'CreatedKeys'; Item = $m } } }
}

function New-RegChangeEvents {
    # The journal lines that announce one registry write or removal, in the order they apply: the keys it creates, the
    # original value the first time this value is seen (a set gives a fast test; device options record thousands),
    # and last the change itself, which keeps the value as it is right now for a rollback of the step.
    param([string]$Full, [string]$Name, [string]$After, [switch]$SkipKeys)
    $before = Get-RegSnapshot -Full $Full -Name $Name
    if (-not $SkipKeys) { Get-MissingKeyEvents -Full $Full }
    if (-not $script:RecordedReg.Contains("$Full|$Name")) { [ordered]@{ Op = 'Add'; Section = 'Registry'; Item = $before } }
    [ordered]@{ Op = 'Change'; Kind = 'Registry'; Target = "$Full\$(Show-RegName $Name)"; Before = $before; After = $After }
}

function Format-RegIntent {
    param($Value, [string]$Kind)
    if ($Kind -eq 'Binary') { return '<binary> (Binary)' }
    return '{0} ({1})' -f (@($Value) -join ','), $Kind
}

function Complete-RegChange {
    # docs/AUDIT.md A-06: every write is read back. Returns the journal line with OK or MISMATCH; a mismatch is also
    # logged, unless -Quiet (the batched device writes report one summary instead).
    param([Parameter(Mandatory)]$Change, [string]$Full, [string]$Name, $Value, [string]$Kind, [switch]$Quiet)
    $expected = Format-RegIntent -Value $Value -Kind $Kind
    if (Test-RegValueNow -Full $Full -Name $Name -Value $Value -Kind $Kind) { return New-ChangeResult -Change $Change -Result 'OK' -Now $expected }
    $now = Format-RegValueShort (Get-RegSnapshot -Full $Full -Name $Name)
    if (-not $Quiet) { Write-Log "MISMATCH: $Full\$(Show-RegName $Name) reads back as $now, expected $expected. Windows or security software may protect it." 'WARN' }
    return New-ChangeResult -Change $Change -Result 'MISMATCH' -Now $now
}

function Remove-CreatedKeys {
    # Deepest first, and only keys that are empty again: anything added to them since is left alone.
    foreach ($full in @($script:State.CreatedKeys | Sort-Object { $_.Length } -Descending)) { Undo-CreatedKey -Full $full }
}

function Show-RegName { param([string]$Name) if ($Name -eq '') { '(default)' } else { $Name } }

function Invoke-Native {
    # Runs a native command and returns its stdout and stderr as one string; $LASTEXITCODE is set as usual.
    # Windows PowerShell 5.1 turns redirected stderr into error records, which stop the script under 'Stop' as soon
    # as a command prints any error text (2>&1 and *> $null alike), so the redirect runs under 'Continue' here.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }) -join "`n" }
    finally { $ErrorActionPreference = $saved }
}

function Test-AccessDenied {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e) {
        if ($e -is [System.UnauthorizedAccessException] -or $e -is [System.Security.SecurityException]) { return $true }
        if ($e.Message -match 'denied|not allowed|privilege') { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Invoke-AsTI {
    # Runs a PowerShell command as TrustedInstaller by briefly pointing the TrustedInstaller service at it.
    # The service path is always restored to the default afterwards.
    param([Parameter(Mandatory)][string]$PsCommand)
    $script:TiCount++
    $flag = Join-Path $env:TEMP ('ft-ti-{0}.done' -f [guid]::NewGuid().ToString('N'))
    $wrapped = "try { $PsCommand } catch { } ; New-Item -ItemType File -Force -Path '$flag' | Out-Null"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapped))
    $tiExe = Join-Path $env:SystemRoot 'servicing\TrustedInstaller.exe'
    $stopTi = {
        try { Stop-Service -Name TrustedInstaller -Force -ErrorAction Stop -WarningAction Stop }
        catch { $null = Invoke-Native taskkill.exe @('/im', 'trustedinstaller.exe', '/f') }
    }
    & $stopTi
    & sc.exe config TrustedInstaller binPath= "cmd.exe /c powershell.exe -NoProfile -EncodedCommand $b64" | Out-Null
    $ok = $false
    try {
        & sc.exe start TrustedInstaller | Out-Null
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path -LiteralPath $flag) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    }
    finally {
        & sc.exe config TrustedInstaller binPath= "`"$tiExe`"" | Out-Null
        & $stopTi
        $ok = Test-Path -LiteralPath $flag
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
    return $ok
}

function Repair-TrustedInstallerPath {
    # Invoke-AsTI points the TrustedInstaller service at a command for a moment. If a run was killed in that moment
    # (window closed, power cut), the service keeps that command and Windows servicing and updates fail. Put it back.
    $default = Join-Path $env:SystemRoot 'servicing\TrustedInstaller.exe'
    $snap = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\TrustedInstaller' -Name 'ImagePath'
    if (-not $snap.Existed) { return }
    $now = [Environment]::ExpandEnvironmentVariables([string]$snap.Value).Trim().Trim('"')
    if ($now -ieq $default) { return }
    if (Test-DryRun "repair the TrustedInstaller service path, which points at '$now'") { return }
    & sc.exe config TrustedInstaller binPath= "`"$default`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not repair the TrustedInstaller service path ($LASTEXITCODE). It points at '$now'." }
    Write-Log "TrustedInstaller service path repaired. It pointed at '$now', left by an interrupted run." 'WARN'
}

function ConvertTo-PsLiteral {
    # Single quoted PowerShell string. PowerShell also treats the typographic single quotes as quotes, so they are doubled too.
    param([AllowEmptyString()][string]$Text)
    $quotes = "'" + [string]::Join('', [char[]](0x2018, 0x2019, 0x201A, 0x201B))
    return "'" + [regex]::Replace($Text, '([' + [regex]::Escape($quotes) + '])', '$1$1') + "'"
}

function Format-TiRegAdd {
    param([string]$Full, [string]$Name, $Value, [string]$Kind)
    $q = { param($s) ConvertTo-PsLiteral ([string]$s) }
    $nameArg = if ($Name -eq '') { '/ve' } else { '/v ' + (& $q $Name) }
    switch ($Kind) {
        'DWord' { $t = 'REG_DWORD'; $d = '/d ' + [uint32]([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Value), 0)) }
        'QWord' { $t = 'REG_QWORD'; $d = '/d ' + [uint64]([BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$Value), 0)) }
        'String' { $t = 'REG_SZ'; $d = '/d ' + (& $q $Value) }
        'ExpandString' { $t = 'REG_EXPAND_SZ'; $d = '/d ' + (& $q $Value) }
        'Binary' { $t = 'REG_BINARY'; $d = '/d ' + (& $q (ConvertTo-StoredValue -Value $Value -Kind 'Binary')) }
        'None' { $t = 'REG_NONE'; $d = '' }
        default { throw "Registry type $Kind is not supported through TrustedInstaller." }
    }
    return "& reg.exe add $(& $q $Full) $nameArg /t $t $d /f | Out-Null"
}

function Write-RegRaw {
    param([string]$Full, [string]$Name, $Value, [string]$Kind)
    if ($Kind -eq 'None') {
        $nameArgs = if ($Name -eq '') { @('/ve') } else { @('/v', $Name) }
        & reg.exe add $Full @nameArgs /t REG_NONE /f | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg.exe add failed for $Full ($LASTEXITCODE)" }
        return
    }
    $key = Open-RegKey -Full $Full -Create
    try { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) }
    finally { $key.Close() }
}

function Test-RegValueNow {
    param([string]$Full, [string]$Name, $Value, [string]$Kind)
    $now = Get-RegSnapshot -Full $Full -Name $Name
    if (-not $now.Existed) { return $false }
    $expected = ConvertTo-StoredValue -Value $Value -Kind $Kind
    return (@($now.Value) -join ',') -eq (@($expected) -join ',')
}

function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'ExpandString', 'QWord', 'Binary', 'MultiString', 'None')][string]$Type = 'DWord'
    )
    $full = ConvertTo-FullRegPath $Path
    if (Test-DryRun "set $full\$(Show-RegName $Name) = $(if ($Type -eq 'Binary') { '<binary>' } else { $Value }) ($Type)") { return }
    $change = $null
    try {
        $events = @(New-RegChangeEvents -Full $full -Name $Name -After (Format-RegIntent -Value $Value -Kind $Type))
        $change = $events[-1]
        Add-JournalEvents $events
        try { Write-RegRaw -Full $full -Name $Name -Value $Value -Kind $Type }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            [void](Invoke-AsTI -PsCommand (Format-TiRegAdd -Full $full -Name $Name -Value $Value -Kind $Type))
        }
        Add-JournalEvents @(Complete-RegChange -Change $change -Full $full -Name $Name -Value $Value -Kind $Type)
    }
    catch {
        $script:Failures++
        Write-Log "Registry write failed: $full\$(Show-RegName $Name). $($_.Exception.Message)" 'ERROR'
        if ($change) { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'FAILED' -Now $_.Exception.Message) }
    }
}

function Remove-RegValueRaw {
    # Deletes one value, falling back to TrustedInstaller when administrators may read the key but not write it. The
    # key is opened inside the try: OpenSubKey(..., $true) itself throws on such keys, and that must reach the fallback.
    param([Parameter(Mandatory)][string]$Full, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if (-not (Get-RegSnapshot -Full $Full -Name $Name).Existed) { return }
    $key = $null
    try {
        $key = Open-RegKey -Full $Full -Write
        if ($key) { $key.DeleteValue($Name, $false) }
    }
    catch {
        if (-not (Test-AccessDenied $_)) { throw }
        $nameArg = if ($Name -eq '') { '/ve' } else { '/v ' + (ConvertTo-PsLiteral $Name) }
        [void](Invoke-AsTI -PsCommand "& reg.exe delete $(ConvertTo-PsLiteral $Full) $nameArg /f | Out-Null")
    }
    finally { if ($key) { $key.Close() } }
    if ((Get-RegSnapshot -Full $Full -Name $Name).Existed) { throw 'The value is still there, even after trying as TrustedInstaller.' }
}

function Remove-RegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $full = ConvertTo-FullRegPath $Path
    if (Test-DryRun "delete value $full\$(Show-RegName $Name)") { return }
    $change = $null
    try {
        $events = @(New-RegChangeEvents -Full $full -Name $Name -After '<missing>' -SkipKeys)
        $change = $events[-1]
        Add-JournalEvents $events
        Remove-RegValueRaw -Full $full -Name $Name
        Add-JournalEvents @(New-ChangeResult -Change $change -Result 'OK' -Now '<missing>')
    }
    catch {
        $script:Failures++
        Write-Log "Registry value removal failed: $full\$(Show-RegName $Name). $($_.Exception.Message)" 'ERROR'
        if ($change) { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'FAILED' -Now $_.Exception.Message) }
    }
}

function Remove-RegKey {
    param([Parameter(Mandatory)][string]$Path)
    $full = ConvertTo-FullRegPath $Path
    if (Test-DryRun "delete key $full (a backup is exported first)") { return }
    $change = $null
    try {
        $probe = Open-RegKey -Full $full
        if (-not $probe) { return }
        $probe.Close()
        $dir = Join-Path $StateDir 'keys'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # docs/AUDIT.md A-02: every deletion gets its own export, also on a later run, because the key may hold entries
        # added since the last one. -Revert imports them all, newest first, so the oldest (the original) wins.
        $file = Join-Path $dir ('{0}-{1:yyyyMMdd-HHmmss-fff}.reg' -f ($full -replace '[\\/:*?"<>| {}]', '_'), (Get-Date))
        & reg.exe export $full $file /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not back up $full, so it was not deleted." }
        $change = [ordered]@{ Op = 'Change'; Kind = 'RegistryKey'; Target = $full; Before = $file; After = '<deleted>' }
        Add-JournalEvents @([ordered]@{ Op = 'Add'; Section = 'KeyBackups'; Item = [pscustomobject]@{ Path = $full; File = $file } }, $change)
        $parts = Split-RegPath $full
        $hive = $script:Hives[$parts[0].ToUpperInvariant()]
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
        try { $base.DeleteSubKeyTree($parts[1], $false) }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            [void](Invoke-AsTI -PsCommand "& reg.exe delete $(ConvertTo-PsLiteral $full) /f | Out-Null")
        }
        finally { $base.Close() }
        $gone = $null -eq (Open-RegKey -Full $full)
        Add-JournalEvents @(New-ChangeResult -Change $change -Result $(if ($gone) { 'OK' } else { 'MISMATCH' }) -Now $(if ($gone) { '<deleted>' } else { 'still present' }))
        if (-not $gone) { Write-Log "MISMATCH: the key $full is still present after deleting it." 'WARN' }
    }
    catch {
        $script:Failures++
        Write-Log "Registry key removal failed: $full. $($_.Exception.Message)" 'ERROR'
        if ($change) { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'FAILED' -Now $_.Exception.Message) }
    }
}

function Restore-KeyBackups {
    # Newest export first: where exports of the same key overlap, the oldest one, the original, is imported last and
    # wins, while entries that only a later export holds come back too. reg.exe reports success on stderr, which
    # Windows PowerShell 5.1 turns into an error record that stops the step even when redirected, so cmd.exe
    # swallows the output and only the exit code counts.
    $backups = @($script:State.KeyBackups)
    [array]::Reverse($backups)
    foreach ($k in $backups) {
        if (-not (Test-Path -LiteralPath $k.File)) { Write-Log "Registry key backup $($k.File) is missing, so $($k.Path) cannot be restored from it." 'WARN'; continue }
        $null = & cmd.exe /d /c "reg.exe import `"$($k.File)`" >nul 2>&1"
        if ($LASTEXITCODE -ne 0) { Write-Log "Could not import $($k.File) (reg.exe exit $LASTEXITCODE)" 'WARN' }
    }
}

function Restore-RegValue {
    param($Entry)
    if ($Entry.Existed) {
        $value = ConvertFrom-StoredValue -Value $Entry.Value -Kind $Entry.Kind
        try { Write-RegRaw -Full $Entry.Path -Name $Entry.Name -Value $value -Kind $Entry.Kind }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            [void](Invoke-AsTI -PsCommand (Format-TiRegAdd -Full $Entry.Path -Name $Entry.Name -Value $value -Kind $Entry.Kind))
        }
    }
    else { Remove-RegValueRaw -Full $Entry.Path -Name $Entry.Name }
}

function Set-TweakList {
    param([object[]]$Tweaks)
    foreach ($t in $Tweaks) { Set-RegValue -Path $t.Path -Name $t.Name -Value $t.Value -Type $t.Type }
}

#endregion

#region Upstream registry file parser -----------------------------------------------------
function ConvertFrom-RegHex {
    param([string]$Body)
    $out = [System.Collections.Generic.List[byte]]::new()
    foreach ($tok in ($Body -split ',')) {
        $t = $tok.Trim()
        if ($t) { $out.Add([Convert]::ToByte($t, 16)) }
    }
    , $out.ToArray()
}

function ConvertFrom-RegText {
    param([Parameter(Mandatory)][string]$Text)
    $ops = [System.Collections.Generic.List[object]]::new()
    $rawLines = ($Text -replace "`r`n", "`n" -replace "`r", "`n") -split "`n"

    # Join hex values that continue over several lines with a trailing backslash.
    $lines = [System.Collections.Generic.List[string]]::new()
    $cont = $null
    foreach ($raw in $rawLines) {
        $line = $raw.Trim()
        if ($null -ne $cont) {
            if ($line.EndsWith('\')) { $cont += $line.Substring(0, $line.Length - 1) }
            else { $lines.Add($cont + $line); $cont = $null }
            continue
        }
        if ($line -match '^(?:"[^"]*"|@)=hex(?:\([0-9a-fA-F]+\))?:.*\\$') { $cont = $line.Substring(0, $line.Length - 1); continue }
        $lines.Add($line)
    }

    $group = ''; $key = $null
    foreach ($line in $lines) {
        if (-not $line -or $line.StartsWith('Windows Registry Editor')) { continue }
        if ($line.StartsWith(';')) { $group = $line.TrimStart(';').Trim(); continue }
        if ($line -match '^\[(-?)(.+)\]$') {
            if ($Matches[1] -eq '-') {
                $ops.Add([pscustomobject]@{ Group = $group; Action = 'DeleteKey'; Path = $Matches[2]; Name = $null; Type = $null; Value = $null })
                $key = $null
            }
            else { $key = $Matches[2] }
            continue
        }
        if ($null -eq $key) { continue }
        if ($line -notmatch '^(?:"((?:[^"\\]|\\.)*)"|@)=(.*)$') { continue }
        $name = if ($line[0] -eq '@') { '' } else { [regex]::Replace($Matches[1], '\\(.)', '$1') }
        $rhs = $Matches[2].Trim()
        $op = [pscustomobject]@{ Group = $group; Action = 'Set'; Path = $key; Name = $name; Type = $null; Value = $null }
        if ($rhs -eq '-') { $op.Action = 'DeleteValue' }
        elseif ($rhs -match '^dword:([0-9a-fA-F]{1,8})$') {
            $op.Type = 'DWord'
            $op.Value = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]::Parse($Matches[1], 'AllowHexSpecifier')), 0)
        }
        elseif ($rhs -match '^"(.*)"$') { $op.Type = 'String'; $op.Value = [regex]::Replace($Matches[1], '\\(.)', '$1') }
        elseif ($rhs -match '^hex(?:\(([0-9a-fA-F]+)\))?:(.*)$') {
            $code = if ($Matches[1]) { $Matches[1].ToLowerInvariant() } else { '3' }
            $bytes = ConvertFrom-RegHex $Matches[2]
            $supported = $true
            switch ($code) {
                '3' { $op.Type = 'Binary'; $op.Value = $bytes }
                '0' { $op.Type = 'None'; $op.Value = $bytes }
                '2' { $op.Type = 'ExpandString'; $op.Value = [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) }
                '7' { $op.Type = 'MultiString'; $op.Value = [string[]]([Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) -split [char]0) }
                'b' { $op.Type = 'QWord'; $op.Value = [BitConverter]::ToInt64(($bytes + (New-Object byte[] 8))[0..7], 0) }
                default { $supported = $false }
            }
            if (-not $supported) { continue }
        }
        else { continue }
        $ops.Add($op)
    }
    , $ops
}

function Get-RegGroupOption {
    param([string]$Title)
    switch -Wildcard ($Title) {
        'Disable core isolation*' { return 'CoreIsolation' }
        'Disable user account control' { return 'Uac' }
        'Remove logons' { return 'RunKeys' }
        'Privacy deny*' { return 'PrivacyDenials' }
        'Disable lock' { return 'HideLockOption' }
        'Disable sleep' { return 'HideSleepOption' }
        'Disable hibernate' { return 'RegHibernateOff' }
        'Enable end task*' { return 'TaskbarEndTask' }
        '100% DPI scaling' { return 'ForceDpi100' }
        'Disable fix scaling for apps' { return 'ForceDpi100' }
        'Disable automatic maintenance' { return 'NoAutoMaintenance' }
        # Upstream groups that do the same job as an existing option belong to it, so skipping the option
        # really keeps the feature (before, the Registry option still applied them).
        'Turn off enhance pointer precision' { return 'MouseAccel' }
        'Disable notifications' { return 'NotificationSettings' }
        'Disable sleep study' { return 'SleepStudy' }
        'Disable background apps global' { return 'PrivacyDenials' }
        'Disable fault tolerant heap' { return 'FaultTolerantHeap' }
        'Disable delivery optimization' { return 'SvcDeliveryOpt' }
        'Turn on hardware accelerated GPU scheduling' { return 'HardwareGpuScheduling' }
        default { return 'Registry' }
    }
}

# A single upstream value can need its own option when its side effect is out of proportion to its group.
# NoRecentDocsHistory sits in two unrelated groups and quietly breaks Quick Access pins.
function Get-RegOpOption {
    param($Op)
    if ($Op.Name -eq 'NoRecentDocsHistory') { return 'NoRecentDocsHistory' }
    return Get-RegGroupOption $Op.Group
}

function Show-RegGroups {
    $ops = ConvertFrom-RegText -Text $UpstreamRegText
    $ops | Group-Object Group | ForEach-Object {
        Write-Host ('{0,-22} {1,3} item(s)  {2}' -f (Get-RegGroupOption $_.Name), $_.Count, $_.Name)
    }
}

function Test-HagsDriverSupport {
    # Hardware accelerated GPU scheduling needs a WDDM 2.7 driver (DirectX blog, June 2020). The first field of a
    # display driver's version is the WDDM version it is built for (27 = WDDM 2.7, 31 = WDDM 3.1); the Microsoft Basic
    # Display Adapter reports 10.x. One capable adapter is enough, so hybrid graphics laptops qualify.
    param([string[]]$DriverVersions = @())
    foreach ($v in $DriverVersions) {
        $m = [regex]::Match([string]$v, '^(\d+)\.')
        if ($m.Success -and [int]$m.Groups[1].Value -ge 27) { return $true }
    }
    return $false
}

function Get-GatedRegOptions {
    # Upstream registry options that this machine cannot use, with the reason. Their values are not written, and the
    # health check notes them instead of judging them.
    $gated = @{}
    if ($Opt['HardwareGpuScheduling']) {
        $versions = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.DriverVersion } | Where-Object { $_ })
        if (-not (Test-HagsDriverSupport -DriverVersions $versions)) {
            $found = 'none'; if ($versions.Count -gt 0) { $found = $versions -join ', ' }
            $gated['HardwareGpuScheduling'] = "no display driver is WDDM 2.7 or later (driver versions found: $found)"
        }
    }
    return $gated
}

function Import-UpstreamRegistry {
    $ops = ConvertFrom-RegText -Text $UpstreamRegText
    $applied = 0; $byOption = 0; $byGroup = 0
    $gated = Get-GatedRegOptions
    foreach ($g in $gated.Keys) { Write-Log "$g skipped on this PC: $($gated[$g])." 'WARN' }
    foreach ($op in $ops) {
        $script:JournalOption = Get-RegOpOption $op
        if (-not $Opt[$script:JournalOption]) { $byOption++; continue }
        if ($gated.ContainsKey($script:JournalOption)) { $byOption++; continue }
        if (Test-NameMatch $op.Group $SkipRegGroup) { $byGroup++; continue }
        switch ($op.Action) {
            'Set' { Set-RegValue -Path $op.Path -Name $op.Name -Value $op.Value -Type $op.Type }
            'DeleteValue' { Remove-RegValue -Path $op.Path -Name $op.Name }
            'DeleteKey' { Remove-RegKey -Path $op.Path }
        }
        $applied++
    }
    Write-Log "Registry import: $applied item(s) processed, $byOption left out by option, $byGroup left out by -SkipRegGroup."
}
#endregion

if ($ListRegGroups) { Show-RegGroups; exit 0 }

#region Hosts file ------------------------------------------------------------------------
function Remove-HostsText {
    param([string]$Text, [string]$Name)
    $n = [regex]::Escape($Name)
    return [regex]::Replace($Text, "(?ms)^# FocusedTweaks BEGIN $n\r?\n.*?^# FocusedTweaks END $n\r?\n?", '')
}

function Write-HostsFile {
    param([string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    for ($i = 1; $i -le 5; $i++) {
        try { [IO.File]::WriteAllText($HostsPath, $Text, $enc); return }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds 600 }
    }
    throw 'The hosts file is locked or protected (security software can block this).'
}

function Set-HostsBlock {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Domains)
    if (Test-DryRun "add $($Domains.Count) entries to the hosts file ($Name)") { return }
    $backup = Join-Path $StateDir 'hosts.original'
    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $HostsPath -Destination $backup -Force }
    $text = Remove-HostsText -Text ([IO.File]::ReadAllText($HostsPath)) -Name $Name
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
    $block = "# FocusedTweaks BEGIN $Name`r`n" + (($Domains | ForEach-Object { "0.0.0.0 $_" }) -join "`r`n") + "`r`n# FocusedTweaks END $Name`r`n"
    if (-not (Test-RecordedFirst $script:State.Hosts { param($e) $e -eq $Name })) { Add-StateRecord -Section 'Hosts' -Item $Name }
    Write-HostsFile -Text ($text + $block)
    Write-Log "Hosts file: blocked $($Domains.Count) domain(s) ($Name)." 'OK'
}
#endregion

#region Software: packages, debloat, NVIDIA ----------------------------------------------
function ConvertFrom-DmtfDate {
    # System Restore stores times as DMTF text (yyyyMMddHHmmss.ffffff+UUU, UUU = minutes from UTC). Local time, or $null.
    param($Value)
    if ($Value -is [DateTime]) { return $Value }
    $m = [regex]::Match([string]$Value, '^(\d{14})\.\d{6}([+-])(\d{3})$')
    if (-not $m.Success) { return $null }
    $clock = [DateTime]::ParseExact($m.Groups[1].Value, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $offset = [TimeSpan]::FromMinutes([int]$m.Groups[3].Value)
    if ($m.Groups[2].Value -eq '-') { $offset = $offset.Negate() }
    return ([DateTimeOffset]::new($clock, $offset)).LocalDateTime
}

function Get-RestorePoints {
    # Through CIM, which works in Windows PowerShell 5.1 and PowerShell 7 alike (Get-ComputerRestorePoint is 5.1 only).
    return @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue)
}

function Test-RestorePointSince {
    param([DateTime]$Since, [object[]]$Points = @())
    foreach ($p in $Points) {
        $made = ConvertFrom-DmtfDate $p.CreationTime
        if ($made -and $made -ge $Since.AddSeconds(-2)) { return $true }
    }
    return $false
}

function Invoke-Checkpoint {
    # Asks Windows for a restore point and returns what it said when it refused: the error, or the warning Windows
    # gives when one was made in the last 24 hours. Empty when it said nothing.
    $said = $null
    try { Checkpoint-Computer -Description 'Before FocusedTweaks' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable said }
    catch { return $_.Exception.Message }
    return ((@($said) | ForEach-Object { "$_" }) -join ' ').Trim()
}

function New-SafetyRestorePoint {
    # docs/AUDIT.md A-07: a restore point counts only when System Restore lists one made since this step started, so a
    # refusal that arrives as a warning (one per 24 hours) is not mistaken for success. Returns Created and Reason.
    $start = Get-Date
    $reason = Invoke-Checkpoint
    if (Test-RestorePointSince -Since $start -Points (Get-RestorePoints)) {
        Write-Log 'Restore point created (System Restore lists it).' 'OK'
        return [pscustomobject]@{ Created = $true; Reason = '' }
    }
    if (-not $reason) { $reason = 'Checkpoint-Computer reported nothing, but System Restore lists no restore point made since the run started.' }
    if ($Opt['EnableSystemRestore']) {
        Write-Log "Restore point not created. Windows said: $reason Turning System Protection on for $env:SystemDrive and trying again (EnableSystemRestore)."
        try {
            # Same approach as the Ultimate repo: allow several restore points per day, switch System Protection on, retry.
            Set-RegValue -Path 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Value 0
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        }
        catch { $reason = "$reason Turning System Protection on failed: $($_.Exception.Message)" }
        $retry = Invoke-Checkpoint
        if (Test-RestorePointSince -Since $start -Points (Get-RestorePoints)) {
            Write-Log 'Restore point created after turning System Protection on (-Revert does not turn it off again).' 'OK'
            return [pscustomobject]@{ Created = $true; Reason = '' }
        }
        if ($retry) { $reason = $retry }
    }
    $hint = " Run with -Enable EnableSystemRestore to turn System Protection on for $env:SystemDrive and allow more than one restore point a day."
    if ($Opt['EnableSystemRestore']) { $hint = ' The System Restore or Volume Shadow Copy service may be disabled on this machine.' }
    Write-Log "Restore point NOT created. Windows said: $reason$hint" 'WARN'
    return [pscustomobject]@{ Created = $false; Reason = $reason }
}

function Confirm-NoRestorePoint {
    # A run that turns off mitigations and deletes tasks should not start without a way back unless the user agrees.
    param([string]$Reason)
    if ($Force) { Write-Log "Continuing without a restore point because of -Force. Reason it failed: $Reason" 'WARN'; return $true }
    $answer = Read-Host "No restore point was created ($Reason). -Revert still undoes what this script records. Type YES to continue without one"
    return ($answer -ceq 'YES')
}

function Install-RuntimePackages {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Log 'winget not found in this session (common on a fresh VM). Update App Installer from the Microsoft Store, open a new elevated window and run again.' 'WARN'
        return
    }
    $acceptable = @(0, -1978335189, -1978335135)
    $nvidia = Test-NvidiaGpu
    foreach ($id in $PackageIds) {
        if ($NvidiaOnlyPackages -contains $id -and -not $nvidia) { Write-Log "Package $id skipped: no NVIDIA GPU."; continue }
        if (Test-DryRun "winget install $id") { continue }
        # Tools this script later runs elevated go into an administrator-only folder (see Find-ProfileInspector).
        $scope = @()
        if ($NvidiaOnlyPackages -contains $id) { $scope = @('--scope', 'machine') }
        & winget.exe install --id $id --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements @scope | Out-Null
        if ($acceptable -contains $LASTEXITCODE) { Write-Log "Package ready: $id" 'OK' }
        else { $script:Failures++; Write-Log "Package $id returned exit code $LASTEXITCODE (check the ID with: winget search $id)" 'ERROR' }
    }
}

function Remove-BloatApps {
    if ($PSVersionTable.PSEdition -eq 'Core') { Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue }
    $removed = 0
    foreach ($pkg in @(Get-AppxPackage -AllUsers | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable })) {
        if (-not (Test-NameMatch $pkg.Name $AppsToRemove)) { continue }
        if (Test-NameMatch $pkg.Name $KeepApps) { Write-Log "Kept (protected): $($pkg.Name)"; continue }
        if (Test-DryRun "remove app $($pkg.Name)") { continue }
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Add-StateRecord -Section 'Removed' -Item $pkg.Name; $removed++
            Write-Log "Removed app: $($pkg.Name)" 'OK'
        }
        catch { Write-Log "Could not remove $($pkg.Name). $($_.Exception.Message)" 'WARN' }
    }
    foreach ($prov in @(Get-AppxProvisionedPackage -Online)) {
        if (-not (Test-NameMatch $prov.DisplayName $AppsToRemove)) { continue }
        if (Test-NameMatch $prov.DisplayName $KeepApps) { continue }
        if (Test-DryRun "remove provisioned app $($prov.DisplayName)") { continue }
        try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null; Write-Log "Removed provisioned app: $($prov.DisplayName)" 'OK' }
        catch { Write-Log "Could not remove provisioned $($prov.DisplayName). $($_.Exception.Message)" 'WARN' }
    }
    if (-not $script:DryRun) { Write-Log "Debloat removed $removed installed app(s). Not reversible by -Revert, reinstall from the Store or winget." 'WARN' }
}

function Get-NvidiaInstallerPath {
    if ($NvidiaInstaller) {
        if (-not (Test-Path -LiteralPath $NvidiaInstaller -PathType Leaf)) { throw "Installer not found: $NvidiaInstaller" }
        return $NvidiaInstaller
    }
    # Same lookup service and URL patterns as upstream NvidiaAutoinstall.ps1 (GeForce desktop and notebook DCH drivers).
    $uri = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php' +
    '?func=DriverManualLookup&psid=120&pfid=929&osID=57&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=4'
    $version = $NvidiaVersion
    if (-not $version) {
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing
        $versions = @($resp.IDS.downloadInfo.Version)
        if ($versions.Count -eq 0) { throw 'Could not read the driver list from NVIDIA. Pass -NvidiaVersion (for example 576.80) or -NvidiaInstaller.' }
        $version = $versions[0]
    }
    $num = $version -replace 'hf', ''
    $kind = if ($NvidiaNotebook) { 'notebook' } else { 'desktop' }
    $base = "https://international.download.nvidia.com/Windows/$version"
    $candidates = if ($version -like '*hf') {
        @("$base/$num-$kind-win10-win11-64bit-international-dch-hf.exe", "$base/$num-desktop-notebook-win10-win11-64bit-international-dch.hf.exe")
    }
    else { @("$base/$version-$kind-win10-win11-64bit-international-dch-whql.exe") }

    if (Test-DryRun "download the NVIDIA $kind driver $version from $($candidates[0])") { return $null }
    $dest = Join-Path $env:TEMP "nvidia-driver-$version.exe"
    foreach ($url in $candidates) {
        try {
            Write-Log "Downloading $url"
            try { Start-BitsTransfer -Source $url -Destination $dest -ErrorAction Stop }
            catch { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop }
            if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt 100MB) { return $dest }
        }
        catch { Write-Log "Download failed for $url. $($_.Exception.Message)" 'WARN' }
    }
    throw "Could not download NVIDIA driver $version. Try -NvidiaVersion with another version, or download it from nvidia.com and use -NvidiaInstaller."
}

function Remove-NvidiaTelemetry {
    $store = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    $dirs = @(Get-ChildItem -Path (Join-Path $store 'nv_dispi*') -Directory -ErrorAction SilentlyContinue)
    if ($dirs.Count -eq 0) { $dirs = @(Get-ChildItem -Path (Join-Path $store 'nvmdi*') -Directory -ErrorAction SilentlyContinue) }
    $plugins = '_DisplayDriverRAS.dll', '_NvMsgBusBroadcast.dll', '_nvtopps.dll', 'nvprofileupdaterplugin.dll', 'wksServicePlugin.dll', 'wksServicePluginZ.dll', '_NvGSTPlugin.dll'
    Stop-Service NVDisplay.ContainerLocalSystem -Force -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        $targets = @()
        $dll = Join-Path $d.FullName 'NvTelemetry64.dll'
        if (Test-Path -LiteralPath $dll) { $targets += $dll }
        $pluginDir = Join-Path $d.FullName 'Display.NvContainer\plugins'
        if (Test-Path -LiteralPath $pluginDir) {
            $targets += @(Get-ChildItem -LiteralPath $pluginDir -Recurse -File | Where-Object { $plugins -contains $_.Name } | ForEach-Object { $_.FullName })
        }
        foreach ($f in $targets) {
            $null = Invoke-Native takeown.exe @('/f', $f)
            $null = Invoke-Native icacls.exe @($f, '/grant', '*S-1-5-32-544:F', '/t')
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $f) { Write-Log "Could not remove NVIDIA telemetry file: $f" 'WARN' }
            else { Write-Log "Removed NVIDIA telemetry file: $(Split-Path $f -Leaf)" 'OK' }
        }
    }
    foreach ($pattern in '*NvDriverUpdateCheckDaily*', '*NVIDIA GeForce Experience SelfUpdate*', '*NvProfileUpdaterDaily*', '*NvProfileUpdaterOnLogon*', '*NvTmRep_CrashReport*') {
        # Recorded like every other task change, so -Revert turns them back on.
        foreach ($task in @(Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue)) { Disable-TaskRecorded -Task $task }
    }
    Start-Service NVDisplay.ContainerLocalSystem -ErrorAction SilentlyContinue
}

function Test-NvidiaGpu {
    return @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.PNPDeviceID -like 'PCI\VEN_10DE*' }).Count -gt 0
}

function Find-ProfileInspector {
    # This runs elevated, so only folders that need administrator rights to write are searched: never PATH or
    # %LOCALAPPDATA%, where any program running as the user could plant a file named like Profile Inspector.
    # Packages installs it per machine (winget --scope machine); Ultimate uses its own folder under Program Files.
    $candidates = @(
        @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WinGet\Packages\Orbmu2k.nvidiaProfileInspector_*') -Directory -ErrorAction SilentlyContinue)
        @(Get-Item -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Nvidia Profile Inspector') -ErrorAction SilentlyContinue)
    )
    foreach ($dir in $candidates) {
        $hit = Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(nvidiaProfileInspector|Nvidia Profile Inspector)\.exe$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Save-NvidiaDrs {
    # The driver keeps every profile setting in its DRS database. A copy taken before the first import is what
    # -Revert puts back, so the import is fully undone. Taken once: later runs must not overwrite the original.
    if ($script:State.NvidiaDrs) { return }
    $backup = Join-Path $StateDir 'nvidia-drs'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $files = @(Get-ChildItem -LiteralPath $NvidiaDrsDir -Filter 'nvdrsdb*.bin' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { throw "No NVIDIA settings database found in $NvidiaDrsDir. Is the NVIDIA driver installed?" }
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $backup -Force }
    Set-StateValue -Name 'NvidiaDrs' -Value $true
}

function Import-NvidiaSettings {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][object[]]$Settings)
    if (-not (Test-NvidiaGpu)) { Write-Log "$Label skipped: no NVIDIA GPU."; return }
    $list = ($Settings | ForEach-Object { "$($_.Name) = $($_.Value)" }) -join ', '
    if (Test-DryRun "import into the NVIDIA global profile with Profile Inspector ($Label): $list") { return }
    $npi = Find-ProfileInspector
    if (-not $npi) { throw 'NVIDIA Profile Inspector not found in an administrator-only folder. Keep the Packages option on, or install it with: winget install Orbmu2k.nvidiaProfileInspector --scope machine' }
    Save-NvidiaDrs
    $rows = foreach ($s in $Settings) {
        "      <ProfileSetting>`r`n        <SettingNameInfo>$($s.Name)</SettingNameInfo>`r`n        <SettingID>$($s.Id)</SettingID>`r`n        <SettingValue>$($s.Value)</SettingValue>`r`n        <ValueType>Dword</ValueType>`r`n      </ProfileSetting>"
    }
    $nip = "<?xml version=`"1.0`" encoding=`"utf-16`"?>`r`n<ArrayOfProfile>`r`n  <Profile>`r`n    <ProfileName>Base Profile</ProfileName>`r`n    <Executables />`r`n    <Settings>`r`n" + ($rows -join "`r`n") + "`r`n    </Settings>`r`n  </Profile>`r`n</ArrayOfProfile>"
    $file = Join-Path $StateDir ("nvidia-$Label.nip" -replace '\s', '-')
    Set-Content -LiteralPath $file -Value $nip -Encoding Unicode
    Get-ChildItem -LiteralPath $NvidiaDrsDir -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $npi -ArgumentList '-silentImport', '-mergeImport', '-silent', "`"$file`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Profile Inspector returned exit code $($proc.ExitCode) importing $Label." }
    Write-Log "NVIDIA global profile updated ($Label): $list. Takes effect for games started from now on." 'OK'
}

function Restore-NvidiaDrs {
    # Fixed backup path, never one read from the state file.
    $backup = Join-Path $StateDir 'nvidia-drs'
    $files = @(Get-ChildItem -LiteralPath $backup -Filter 'nvdrsdb*.bin' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Log "No NVIDIA settings backup in $backup, nothing to restore." 'WARN'; return }
    # The display container holds the database open; stop it while the files are put back.
    $svc = Get-Service -Name NVDisplay.ContainerLocalSystem -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { [void](Stop-ServiceBounded -Name $svc.Name) }
    try { foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $NvidiaDrsDir -Force } }
    finally { if ($svc) { Start-Service -Name $svc.Name -ErrorAction SilentlyContinue } }
    Write-Log 'NVIDIA settings database restored from before the run. Restart Windows so every app sees it.' 'OK'
}

function Install-NvidiaDriver {
    if (-not (Test-NvidiaGpu)) { Write-Log 'No NVIDIA GPU detected, skipping the driver install.' 'WARN'; return }
    $installer = Get-NvidiaInstallerPath
    if (Test-DryRun "extract and install the NVIDIA driver ($(if ($installer) { $installer } else { 'the downloaded package' }))") { return }

    $sig = Get-AuthenticodeSignature -FilePath $installer
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'NVIDIA Corporation') {
        throw 'The installer is not validly signed by NVIDIA Corporation. Refusing to run it.'
    }
    $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path -LiteralPath $sevenZip)) { throw '7-Zip is required to unpack the driver. Keep the Packages option on, or install 7-Zip first.' }

    # Same component selection as upstream: display driver, installer core and setup files.
    $files = @('Display.Driver', 'NVI2', 'EULA.txt', 'ListDevices.txt', 'setup.cfg', 'setup.exe')
    if ($NvidiaApp) {
        $num = $null
        try { $num = [version](($NvidiaVersion -replace 'hf', '')) } catch { }
        $files += $(if ($num -and $num -lt [version]'566.36') { 'GFExperience' } else { 'NvApp' })
    }
    if ($NvidiaHdAudio) { $files += 'HDAudio' }

    $work = Join-Path $env:TEMP ('nvidia-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Log "Extracting: $($files -join ', ')"
        & $sevenZip x $installer "-o$work" -y @files | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed with exit code $LASTEXITCODE" }
        $setup = Join-Path $work 'setup.exe'
        if (-not (Test-Path -LiteralPath $setup)) { throw 'setup.exe not found in the extracted package.' }
        $setupArgs = @('-s', '-noreboot', '-noeula', '-nofinish')
        if (-not $NvidiaNoClean) { $setupArgs += '-clean' }
        $proc = Start-Process -FilePath $setup -ArgumentList $setupArgs -WorkingDirectory $work -Wait -PassThru
        if (@(0, 1, 1641, 3010) -contains $proc.ExitCode) { Write-Log "NVIDIA driver installed (exit code $($proc.ExitCode)). Restart before gaming." 'OK' }
        else { throw "NVIDIA setup returned exit code $($proc.ExitCode)" }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

    if ($Opt['NvidiaTelemetryStrip']) { Remove-NvidiaTelemetry }
    if (-not $NvidiaInstaller) { Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue }
}
#endregion

#region Services and scheduled tasks ------------------------------------------------------
function Set-ServiceStart {
    param([Parameter(Mandatory)][string]$Name, [ValidateSet('Disabled', 'Manual')][string]$Mode = 'Disabled')
    $reg = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$Name"
    $probe = Open-RegKey -Full $reg
    if (-not $probe) { Write-Log "Service not present: $Name"; return }
    $probe.Close()
    Set-RegValue -Path $reg -Name 'Start' -Value $(if ($Mode -eq 'Disabled') { 4 } else { 3 }) -Type DWord
    if ($Mode -eq 'Disabled' -and -not $script:DryRun) {
        foreach ($svc in @(Get-Service -Name $Name, "${Name}_*" -ErrorAction SilentlyContinue)) {
            # Disabled is what counts; a service that will not stop now stays stopped after the next restart.
            if (-not (Stop-ServiceBounded -Name $svc.Name)) { Write-Log "Service $($svc.Name) is disabled but did not stop within 30 s. It stops at the next restart." }
        }
    }
}

function Disable-ServiceGroups {
    foreach ($g in $ServiceGroups.Keys) {
        if (-not $Opt[$g]) { Write-Log "Services kept (option $g is off): $($ServiceGroups[$g] -join ', ')" }
    }
    $done = @()
    foreach ($g in $ServiceGroups.Keys) {
        if (-not $Opt[$g]) { continue }
        $script:JournalOption = $g
        foreach ($name in $ServiceGroups[$g]) { if ($done -notcontains $name) { Set-ServiceStart -Name $name -Mode Disabled; $done += $name } }
    }
}

function Get-TaskRecord {
    param([string]$Path, [string]$Name)
    return @($script:State.Tasks | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name }) | Select-Object -First 1
}

function Save-TaskState {
    # Returns what it did: 'new', 'upgraded' (a Disabled record became Deleted) or 'kept'. The first record keeps the
    # original WasEnabled; a task disabled by one run and deleted by a later one must still be restorable from XML.
    param($Task, [string]$Action, [string]$XmlFile = $null)
    $e = Get-TaskRecord -Path $Task.TaskPath -Name $Task.TaskName
    $mode = 'kept'
    if (-not $e) { $mode = 'new' }
    elseif ($Action -eq 'Deleted' -and $e.Action -eq 'Disabled') { $mode = 'upgraded' }
    if ($mode -eq 'kept') { return 'kept' }
    $wasEnabled = ($Task.State -ne 'Disabled')
    if ($e) { $wasEnabled = [bool]$e.WasEnabled }
    $record = [pscustomobject]@{ Path = $Task.TaskPath; Name = $Task.TaskName; Action = $Action; WasEnabled = $wasEnabled; XmlFile = $XmlFile }
    Add-JournalEvents @([ordered]@{ Op = 'Task'; Mode = $mode; Record = $record })
    return $mode
}

function Undo-TaskRecord {
    # A delete that failed must not leave a record claiming the task was removed.
    param($Task, [string]$Outcome)
    if ($Outcome -notin 'new', 'upgraded') { return }
    Add-JournalEvents @([ordered]@{ Op = 'TaskUndo'; Path = $Task.TaskPath; Name = $Task.TaskName; Outcome = $Outcome })
}

function New-TaskChange {
    # The journal line announcing one task change. Before is what a rollback of the step registers or enables again:
    # the task as it is right now, from the export that holds it.
    param($Task, [string]$Action, [string]$XmlFile = $null)
    $before = [pscustomobject]@{ Path = $Task.TaskPath; Name = $Task.TaskName; Action = $Action; WasEnabled = ($Task.State -ne 'Disabled'); XmlFile = $XmlFile }
    return [ordered]@{ Op = 'Change'; Kind = 'Task'; Target = "$($Task.TaskPath)$($Task.TaskName)"; Before = $before; After = $Action }
}

function Disable-TaskRecorded {
    param($Task)
    $full = "$($Task.TaskPath)$($Task.TaskName)"
    if ($Task.State -eq 'Disabled') { return }
    if (Test-DryRun "disable task $full") { return }
    [void](Save-TaskState -Task $Task -Action 'Disabled')
    $change = New-TaskChange -Task $Task -Action 'Disabled'
    Add-JournalEvents @($change)
    try { Disable-ScheduledTask -InputObject $Task -ErrorAction Stop | Out-Null }
    catch {
        # Through cmd.exe: schtasks reports failure on stderr, which stops the step under 'Stop' in PowerShell 5.1.
        $null = & cmd.exe /d /c "schtasks.exe /Change /TN `"$full`" /Disable >nul 2>&1"
        if ($LASTEXITCODE -ne 0) {
            # Tasks that belong to SYSTEM, such as the Update Orchestrator tasks UsoSvc registers again, need SYSTEM.
            [void](Invoke-AsTI -PsCommand "Disable-ScheduledTask -TaskPath $(ConvertTo-PsLiteral $Task.TaskPath) -TaskName $(ConvertTo-PsLiteral $Task.TaskName) | Out-Null")
        }
    }
    $now = Get-ScheduledTask -TaskPath $Task.TaskPath -TaskName $Task.TaskName -ErrorAction SilentlyContinue
    if ($now -and $now.State -ne 'Disabled') {
        Write-Log "Could not disable task $full, not even as TrustedInstaller." 'WARN'
        Add-JournalEvents @(New-ChangeResult -Change $change -Result 'MISMATCH' -Now ([string]$now.State))
    }
    else { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'OK' -Now 'Disabled') }
}

function Disable-TelemetryTasks {
    foreach ($t in $TelemetryTasks) {
        $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($task) { Disable-TaskRecorded -Task $task }
    }
}

function Remove-AllScheduledTasks {
    # Upstream behaviour: unregister every task except three. Each task is exported first so -Revert can restore it.
    # The built-in keep list survives on top: deleting those gains no speed but stops time sync, TPM upkeep,
    # BitLocker and SSD retrim.
    $dir = Join-Path $StateDir 'tasks'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $tasks = @(Get-ScheduledTask | Where-Object {
            $_.TaskName -notin @('SvcRestartTask', 'MsCtfMonitor') -and "$($_.TaskPath)$($_.TaskName)" -ne '\Microsoft\Windows\Shell\CreateObjectTask'
        })
    $deleted = 0; $failed = 0; $seen = 0
    foreach ($t in $tasks) {
        $full = "$($t.TaskPath)$($t.TaskName)"
        if (Test-NameMatch $full $TaskKeepBuiltIn) { continue }
        if (Test-NameMatch $full $TaskKeep) { continue }
        if (Test-DryRun "delete task $full (exported first)") { continue }
        # Each task takes about a second (export, then delete), so say that the step is still working.
        $seen++
        if ($seen % 40 -eq 0) { Write-Log "Scheduled tasks: $seen of $($tasks.Count) processed, still working." }
        $file = Join-Path $dir (($full -replace '[\\/:*?"<>| ]', '_') + '.xml')
        $outcome = $null
        $change = $null
        try {
            # The first export is the original. A later run may meet a copy that Windows registered again (UsoSvc
            # after the cache cleanup) and the script then disabled; exporting that would overwrite the original.
            $prior = Get-TaskRecord -Path $t.TaskPath -Name $t.TaskName
            $haveOriginal = $prior -and $prior.Action -eq 'Deleted' -and $prior.XmlFile -and (Test-Path -LiteralPath $prior.XmlFile)
            if (-not $haveOriginal) {
                Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Set-Content -LiteralPath $file -Encoding Unicode
                $outcome = Save-TaskState -Task $t -Action 'Deleted' -XmlFile $file
            }
            else { $file = [string]$prior.XmlFile }
            $change = New-TaskChange -Task $t -Action 'Deleted' -XmlFile $file
            Add-JournalEvents @($change)
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Add-JournalEvents @(New-ChangeResult -Change $change -Result 'OK' -Now 'Deleted')
            $deleted++
        }
        catch {
            $failed++
            if ($outcome) { Undo-TaskRecord -Task $t -Outcome $outcome }
            if ($change) { Add-JournalEvents @(New-ChangeResult -Change $change -Result 'FAILED' -Now $_.Exception.Message) }
            Write-Log "Task $full not deleted: $($_.Exception.Message)"
        }
    }
    if (-not $script:DryRun) {
        $level = 'OK'; if ($failed -gt 0) { $level = 'WARN' }
        Write-Log "Scheduled tasks deleted: $deleted (backups in $dir). $failed could not be removed (protected by the system, listed above)." $level
    }
}

function Invoke-TaskMode {
    switch ($TaskMode) {
        'Delete' { Remove-AllScheduledTasks }
        'Disable' { Disable-TelemetryTasks }
        'None' { Write-Log 'Scheduled tasks left untouched (-TaskMode None).' }
    }
}

function Set-TaskEnabledState {
    # Brings a task back to enabled or disabled as it was before the run.
    param([string]$Path, [string]$Name, [bool]$Enabled)
    $now = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop
    if ($Enabled -and $now.State -eq 'Disabled') { Enable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null }
    elseif (-not $Enabled -and $now.State -ne 'Disabled') { Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null }
}

function Restore-Tasks {
    param([object[]]$Tasks = @($script:State.Tasks))
    $denied = [System.Collections.Generic.List[object]]::new()
    $problems = 0
    foreach ($t in $Tasks) {
        try {
            if ($t.Action -eq 'Deleted') {
                if (-not $t.XmlFile -or -not (Test-Path -LiteralPath $t.XmlFile)) {
                    Write-Log "Could not restore task $($t.Path)$($t.Name): its backup file is missing ($($t.XmlFile))." 'WARN'
                    $problems++
                    continue
                }
                Register-ScheduledTask -Xml (Get-Content -LiteralPath $t.XmlFile -Raw) -TaskName $t.Name -TaskPath $t.Path -Force -ErrorAction Stop | Out-Null
            }
            # The export may hold a disabled copy (a task disabled by one run, deleted by a later one).
            Set-TaskEnabledState -Path $t.Path -Name $t.Name -Enabled ([bool]$t.WasEnabled)
        }
        catch {
            # Tasks whose principal is SYSTEM or a service (BitLocker, DeviceDirectoryClient, the Update Orchestrator
            # and more) can be deleted or disabled by an administrator but only registered or enabled again by
            # SYSTEM. Retry those as TrustedInstaller.
            if (Test-AccessDenied $_) { $denied.Add($t) }
            else { Write-Log "Could not restore task $($t.Path)$($t.Name). $($_.Exception.Message)" 'WARN'; $problems++ }
        }
    }
    if ($denied.Count -gt 0) { $problems += Restore-ProtectedTasks -Tasks $denied }
    if ($problems -eq 0) { Write-Log "Scheduled tasks restored: $(@($Tasks).Count)." 'OK' }
    else { Write-Log "Scheduled tasks restored with $problems problem(s), listed above." 'WARN' }
}

function Restore-SelectedTasks {
    # -RestoreTask: bring back only the deleted or disabled tasks whose full path matches, leaving the rest of the run
    # in place. Entries stay in the state file, so a later full -Revert still covers them (registering again is harmless).
    $picked = @($script:State.Tasks | Where-Object { Test-NameMatch "$($_.Path)$($_.Name)" $RestoreTask })
    if ($picked.Count -eq 0) { Write-Log "No recorded task matches $($RestoreTask -join ', '). The task backups are in $(Join-Path $StateDir 'tasks')." 'WARN'; return }
    foreach ($t in $picked) { Write-Log "Restoring task $($t.Path)$($t.Name) ($($t.Action.ToLowerInvariant()) by the run)." }
    Restore-Tasks -Tasks $picked
}

function Restore-ProtectedTasks {
    param([object[]]$Tasks)
    # One TrustedInstaller call for all of them (each call stops and restarts the service). The commands go into a
    # file in the state folder, because the service command line goes through cmd.exe and its 8191 character limit.
    # Each line registers the task again (Deleted) and sets it enabled or disabled as it was; the result is checked
    # below, so a failure inside the batch still shows up as a warning.
    $calls = foreach ($t in $Tasks) {
        $register = ''
        if ($t.Action -eq 'Deleted') {
            $register = 'Register-ScheduledTask -Xml (Get-Content -LiteralPath {0} -Raw) -TaskName {1} -TaskPath {2} -Force -ErrorAction Stop | Out-Null; ' -f
                (ConvertTo-PsLiteral $t.XmlFile), (ConvertTo-PsLiteral $t.Name), (ConvertTo-PsLiteral $t.Path)
        }
        $state = 'Disable-ScheduledTask'; if ($t.WasEnabled) { $state = 'Enable-ScheduledTask' }
        'try {{ {0}{1} -TaskPath {2} -TaskName {3} -ErrorAction Stop | Out-Null }} catch {{ }}' -f $register, $state, (ConvertTo-PsLiteral $t.Path), (ConvertTo-PsLiteral $t.Name)
    }
    $file = Join-Path $StateDir 'restore-protected-tasks.ps1'
    Set-Content -LiteralPath $file -Value $calls -Encoding UTF8
    # Read and run as a script block, not as a .ps1 file, so the execution policy does not block it.
    try { [void](Invoke-AsTI -PsCommand ". ([scriptblock]::Create((Get-Content -LiteralPath $(ConvertTo-PsLiteral $file) -Raw)))") }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    $restored = 0
    foreach ($t in $Tasks) {
        $now = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($now -and (($now.State -ne 'Disabled') -eq [bool]$t.WasEnabled)) { $restored++ }
        elseif ($now) { Write-Log "Task $($t.Path)$($t.Name) is back but still $($now.State), not even TrustedInstaller could change it." 'WARN' }
        else { Write-Log "Could not restore task $($t.Path)$($t.Name), not even as TrustedInstaller." 'WARN' }
    }
    $level = 'OK'; if ($restored -lt @($Tasks).Count) { $level = 'WARN' }
    Write-Log "Protected tasks restored as TrustedInstaller: $restored of $(@($Tasks).Count)." $level
    return @($Tasks).Count - $restored
}
#endregion

#region Telemetry, updates, vendor blocks -------------------------------------------------
function Invoke-TelemetryTweaks {
    if ($Opt['TelemetryPolicy']) {
        $script:JournalOption = 'TelemetryPolicy'
        Set-TweakList $TelemetryRegs
        foreach ($s in $TelemetryServices) { Set-ServiceStart -Name $s -Mode Disabled }
        # Stop every logger under the DiagTrack autologger.
        $logger = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener'
        $k = Open-RegKey -Full $logger
        if ($k) {
            try { foreach ($sub in $k.GetSubKeyNames()) { Set-RegValue -Path "$logger\$sub" -Name 'Enabled' -Value 0 } }
            finally { $k.Close() }
        }
    }
    if ($Opt['BiometricsPolicy']) { $script:JournalOption = 'BiometricsPolicy'; Set-TweakList $BiometricsRegs }
    if ($Opt['Cdp']) {
        $script:JournalOption = 'Cdp'
        foreach ($s in $CdpServices) { Set-ServiceStart -Name $s -Mode Disabled }
        $cdpCache = Join-Path $env:LOCALAPPDATA 'ConnectedDevicesPlatform'
        if ((Test-Path -LiteralPath $cdpCache) -and -not (Test-DryRun "delete the Connected Devices Platform cache $cdpCache (not reversible, Windows rebuilds it)")) {
            Remove-Item -LiteralPath $cdpCache -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($Opt['TelemetryHosts']) { $script:JournalOption = 'TelemetryHosts'; Set-HostsBlock -Name 'telemetry' -Domains $TelemetryDomains }
}

function Set-UpdatePolicies {
    $classifications = @($UpdateClassifications)
    if ($Opt['KeepDefinitionUpdates']) { $classifications = @($classifications | Where-Object { $_ -notlike '*e0789628-ce08-4437-be74-2495b842f43b*' }) }
    $classString = $classifications -join ';'
    $wu = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $ux = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

    if ($Opt['DriverExclusion']) { $script:JournalOption = 'DriverExclusion'; Set-TweakList $DriverExclusionRegs }
    if ($Opt['SecurityUpdatesOnly']) {
        $script:JournalOption = 'SecurityUpdatesOnly'
        Set-TweakList $SecurityUpdatesRegs
        Set-RegValue -Path $wu -Name 'ExcludeUpdateClassifications' -Value $classString -Type String
        Write-Log 'Update policy: long deferrals set and update classifications excluded (upstream behaviour).' 'WARN'
    }
    if ($Opt['PauseUpdates']) {
        $script:JournalOption = 'PauseUpdates'
        $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $now = [DateTime]::UtcNow
        $start = $now.ToString($fmt, $inv)
        $end = $now.AddDays($PauseDays).ToString($fmt, $inv)
        foreach ($n in 'PauseUpdatesStartTime', 'PauseFeatureUpdatesStartTime', 'PauseQualityUpdatesStartTime') { Set-RegValue -Path $ux -Name $n -Value $start -Type String }
        foreach ($n in 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesEndTime') { Set-RegValue -Path $ux -Name $n -Value $end -Type String }
        foreach ($s in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc') { Set-ServiceStart -Name $s -Mode Manual }
        $deferDays = [Math]::Min($PauseDays, 365)
        foreach ($t in $PauseRegs) {
            $v = $t.Value
            if ($t.Name -in 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdatesPeriodInDays') { $v = $deferDays }
            Set-RegValue -Path $t.Path -Name $t.Name -Value $v -Type $t.Type
        }
        # ExcludeUpdateClassifications belongs to SecurityUpdatesOnly only: it never expires, unlike the pause.
        if ($Opt['PauseStopsUpdateTasks']) { $script:JournalOption = 'PauseStopsUpdateTasks'; Disable-UpdateTasks }
        if (-not $script:DryRun) { Write-Log "Updates paused until $end (-PauseDays $PauseDays). Security patches are delayed for that period." 'WARN' }
    }
}

function Disable-UpdateTasks {
    foreach ($pattern in $UpdateTaskPaths) {
        foreach ($task in @(Get-ScheduledTask -TaskPath $pattern -ErrorAction SilentlyContinue)) {
            if ($task.State -ne 'Disabled') { Disable-TaskRecorded -Task $task }
        }
    }
}

function Set-RazerAsusBlock {
    Set-HostsBlock -Name 'razer-asus' -Domains ($RazerDomains + $AsusDomains)
}
#endregion

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

#region Mouse and registry helper actions -------------------------------------------------
function Sync-MouseSettings {
    if ($script:DryRun) { return }
    if (-not ('Native.User32' -as [type])) {
        Add-Type -Namespace Native -Name User32 -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);
'@
    }
    $key = 'HKCU:\Control Panel\Mouse'
    $read = {
        param($n, $default)
        $p = Get-ItemProperty -LiteralPath $key -Name $n -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties[$n]) { [int]$p.$n } else { $default }
    }
    $values = [int[]]@((& $read 'MouseThreshold1' 6), (& $read 'MouseThreshold2' 10), (& $read 'MouseSpeed' 1))
    [void][Native.User32]::SystemParametersInfo(0x0004, 0, $values, 0x03)
}

function Disable-MouseAcceleration {
    # Upstream logic: pick the profile that matches the current display scaling.
    $metrics = Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue
    $dpi = if ($metrics -and $metrics.PSObject.Properties['AppliedDPI']) { [int]$metrics.AppliedDPI } else { 96 }
    $scaling = [int]([Math]::Round(($dpi / 96) * 100))
    $mouse = $MouseProfiles[$scaling]
    if (-not $mouse) { Write-Log "Display scaling $scaling% is not supported by the mouse profiles (100, 125, 150, 175, 200, 225). Change it in Display settings, restart and run again." 'WARN'; return }
    Write-Log "Mouse profile for $scaling% display scaling."
    foreach ($path in 'HKEY_CURRENT_USER\Control Panel\Mouse', 'HKEY_USERS\.DEFAULT\Control Panel\Mouse') {
        Set-RegValue -Path $path -Name 'MouseSensitivity' -Value '10' -Type String
        Set-RegValue -Path $path -Name 'MouseSpeed' -Value $mouse.Speed -Type String
        Set-RegValue -Path $path -Name 'MouseThreshold1' -Value $mouse.T1 -Type String
        Set-RegValue -Path $path -Name 'MouseThreshold2' -Value $mouse.T2 -Type String
        if ($mouse.X) {
            Set-RegValue -Path $path -Name 'SmoothMouseXCurve' -Value (ConvertFrom-RegHex $mouse.X) -Type Binary
            Set-RegValue -Path $path -Name 'SmoothMouseYCurve' -Value (ConvertFrom-RegHex $mouse.Y) -Type Binary
        }
        else {
            Remove-RegValue -Path $path -Name 'SmoothMouseXCurve'
            Remove-RegValue -Path $path -Name 'SmoothMouseYCurve'
        }
    }
    Set-RegValue -Path 'HKEY_CURRENT_USER\Control Panel\Desktop' -Name 'Win8DpiScaling' -Value 0
    Set-RegValue -Path 'HKEY_CURRENT_USER\Control Panel\Desktop' -Name 'LogPixels' -Value $mouse.LogPixels
    Set-RegValue -Path 'HKEY_CURRENT_USER\Control Panel\Desktop' -Name 'EnablePerProcessSystemDPI' -Value $mouse.PerProc
    Sync-MouseSettings
}

function Set-MsiMode {
    foreach ($dev in @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)) {
        $p = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        Set-RegValue -Path $p -Name 'MSISupported' -Value 1
    }
}

# docs/AUDIT.md B-05: below this much RAM, compression avoids page file reads under load, so it stays on.
$MemoryCompressionMinGB = 32

function Test-MemoryCompressionTarget {
    param([double]$RamGB)
    return $RamGB -ge $MemoryCompressionMinGB
}

function Disable-MemoryCompression {
    $ram = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
    if (-not (Test-MemoryCompressionTarget -RamGB $ram)) { Write-Log "Memory compression kept (RAM is $([Math]::Round($ram, 1)) GB, the change needs $MemoryCompressionMinGB GB or more)."; return }
    if (Test-DryRun 'disable memory compression') { return }
    if ($null -eq $script:State.MemCompress) { Set-StateValue -Name 'MemCompress' -Value ([bool](Get-MMAgent).MemoryCompression) }
    Disable-MMAgent -MemoryCompression
    Write-Log 'Memory compression disabled (takes effect after a restart).' 'OK'
}

$SleepStudyLogs = 'Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic'

function Disable-SleepStudy {
    if (Test-DryRun 'turn off the Sleep Study and power diagnostic event logs') { return }
    # Record which logs were on, the first time only, so -Revert turns back on exactly those and no more.
    if ($script:State.SleepStudy -eq $false) {
        Set-StateValue -Name 'SleepStudy' -Value @($SleepStudyLogs | Where-Object { ((& wevtutil.exe gl $_) | Out-String) -match 'enabled:\s*true' })
    }
    foreach ($log in $SleepStudyLogs) {
        & wevtutil.exe sl $log /e:false | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "wevtutil could not turn off $log ($LASTEXITCODE)." 'WARN' }
    }
}

function Get-MaxPasswordAge {
    # Days, or 'unlimited'. net accounts prints localised labels and words, but its line order is fixed: the third
    # line is the maximum password age, and a number there is days while any word means unlimited.
    $lines = @(& net.exe accounts)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -lt 3) { throw "net accounts failed ($LASTEXITCODE)." }
    $value = ($lines[2] -split ':')[-1].Trim()
    if ($value -match '^\d+$') { return $value }
    return 'unlimited'
}

function Set-PasswordExpiry {
    if ([Environment]::OSVersion.Version.Build -le 19045) { Write-Log 'Password expiry change skipped (Windows 11 only).'; return }
    if (Test-DryRun 'set the maximum local password age to unlimited') { return }
    if ($script:State.PwAge -eq $false) { Set-StateValue -Name 'PwAge' -Value (Get-MaxPasswordAge) }
    & net.exe accounts /maxpwage:unlimited | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "net accounts /maxpwage:unlimited failed ($LASTEXITCODE)." }
}

function Reset-FaultTolerantHeap {
    if (Test-DryRun 'reset the fault tolerant heap') { return }
    Start-Process rundll32.exe -ArgumentList 'fthsvc.dll, FthSysprepSpecialize' -WindowStyle Hidden
}

function Disable-NotificationSettings {
    $root = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    $key = Open-RegKey -Full $root
    if (-not $key) { return }
    $subs = @()
    try {
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push(@($key, $root))
        while ($stack.Count -gt 0) {
            $item = $stack.Pop(); $k = $item[0]; $p = $item[1]
            $subs += $p
            foreach ($n in $k.GetSubKeyNames()) {
                $child = $k.OpenSubKey($n)
                if ($child) { $stack.Push(@($child, "$p\$n")) }
            }
            if ($k -ne $key) { $k.Close() }
        }
    }
    finally { $key.Close() }
    foreach ($p in ($subs | Where-Object { $_ -ne $root })) { Set-RegValue -Path $p -Name 'Enabled' -Value 0 }
}

function Reset-ConsentDatabase {
    # Upstream clears the stored app permissions so the privacy denials apply to apps that were already allowed.
    $dir = Join-Path $env:ProgramData 'Microsoft\Windows\CapabilityAccessManager'
    $files = @(Get-ChildItem -Path (Join-Path $dir 'CapabilityConsentStorage.db*') -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return }
    if (Test-DryRun 'back up and delete the capability consent database') { return }
    $backup = Join-Path $StateDir 'consent-db'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    if (-not $script:State.ConsentDb) {
        foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $backup -Force }
        Set-StateValue -Name 'ConsentDb' -Value $backup
    }
    Stop-Service -Name camsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    foreach ($f in $files) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
        catch { [void](Invoke-AsTI -PsCommand "Remove-Item -LiteralPath $(ConvertTo-PsLiteral $f.FullName) -Force") }
    }
    Write-Log 'Capability consent database reset (backup kept).' 'OK'
}

function Update-UserVisuals {
    if ($script:DryRun) { Write-Log 'DRY RUN, would: refresh user settings and restart Explorer.'; return }
    1..5 | ForEach-Object { & rundll32.exe user32.dll, UpdatePerUserSystemParameters, 1, True; Start-Sleep -Milliseconds 5 }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
}
#endregion

#region Start menu and Quick Assist -------------------------------------------------------
$script:StartLayoutDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState'

function Get-DesktopFolders {
    $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))
    return @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Clear-DesktopIcons {
    $panel = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons'
    # Recycle Bin, This PC, user files, Network, Control Panel.
    $system = '{645FF040-5081-101B-9F08-00AA002F954E}', '{20D04FE0-3AEA-1069-A2D8-08002B30309D}', '{59031a47-3f72-44a7-89c5-5595fe6b30ee}', '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}', '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}'
    foreach ($p in 'NewStartPanel', 'ClassicStartMenu') {
        foreach ($g in $system) { Set-RegValue -Path "$panel\$p" -Name $g -Value 1 }
    }
    if ($Opt['HideAllDesktopIcons']) {
        Set-RegValue -Path 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideIcons' -Value 1
    }
    # Shortcuts are moved (not deleted) so -Revert can put them back. Other files and folders are never touched.
    $moved = 0; $left = 0
    foreach ($dir in Get-DesktopFolders) {
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            if ($item.PSIsContainer -or $item.Extension -notin '.lnk', '.url') { $left++; continue }
            if (Test-DryRun "move the shortcut $($item.FullName) out of the desktop") { continue }
            $target = Join-Path $StateDir ('desktop-backup\' + (($dir -replace '[\\/:*?"<>| ]', '_')))
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            $to = Join-Path $target $item.Name
            # Recorded first: Restore-DesktopIcons only moves back what really arrived in the backup folder.
            Add-StateRecord -Section 'DesktopMoved' -Item ([pscustomobject]@{ From = $item.FullName; To = $to })
            Move-Item -LiteralPath $item.FullName -Destination $to -Force
            $moved++
        }
    }
    if (-not $script:DryRun) {
        Write-Log "Desktop cleared: $moved shortcut(s) moved to the backup folder. $left file or folder item(s) were left on the desktop untouched." 'OK'
        $script:ShellDirty = $true
    }
}

function Restore-DesktopIcons {
    foreach ($m in $script:State.DesktopMoved) {
        if ((Test-Path -LiteralPath $m.To) -and -not (Test-Path -LiteralPath $m.From)) {
            New-Item -ItemType Directory -Path (Split-Path $m.From -Parent) -Force | Out-Null
            Move-Item -LiteralPath $m.To -Destination $m.From -Force
        }
    }
    Write-Log 'Desktop shortcuts restored.' 'OK'
    $script:ShellDirty = $true
}

function Clear-StartPins {
    if ([Environment]::OSVersion.Version.Build -le 19045) { Write-Log 'Start pin reset is for Windows 11 only, skipped.'; return }
    if (-not (Test-Path -LiteralPath $script:StartLayoutDir)) { Write-Log 'Start menu data folder not found, skipped.' 'WARN'; return }
    if (Test-DryRun 'clear every pinned app in the Start menu (the current layout is backed up first)') { return }
    $file = Join-Path $script:StartLayoutDir 'start2.bin'
    $backup = Join-Path $StateDir 'start2.bin.original'
    # Backed up once per run cycle, keyed on the state: a backup left by an earlier, reverted cycle is outdated.
    if (-not $script:State.StartLayout -and (Test-Path -LiteralPath $file)) {
        Copy-Item -LiteralPath $file -Destination $backup -Force
        Set-StateValue -Name 'StartLayout' -Value $backup
    }
    $bytes = [Convert]::FromBase64String(($EmptyStartLayout -join ''))
    # Same approach as upstream: stop the shell host, replace the layout file, let the Start menu reload.
    Stop-Process -Name sihost -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    [IO.File]::WriteAllBytes($file, $bytes)
    Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
    Write-Log 'Start menu pins cleared. If old pins still show, sign out and back in. All apps are still under All apps.' 'OK'
}

function Restore-StartPins {
    if (-not $script:State.StartLayout -or -not (Test-Path -LiteralPath $script:State.StartLayout)) { return }
    Stop-Process -Name sihost -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Copy-Item -LiteralPath $script:State.StartLayout -Destination (Join-Path $script:StartLayoutDir 'start2.bin') -Force
    Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
    # Used up: the next run takes a fresh backup of whatever layout exists then.
    Remove-Item -LiteralPath $script:State.StartLayout -Force -ErrorAction SilentlyContinue
    Write-Log 'Start menu layout restored.' 'OK'
}

# Optional features turned off by LegacyFeatures and HypervisorFeatures. Turning a feature off removes it from the
# running system; -Revert turns back on only the ones the run turned off. Names missing on a build are skipped.
$FeatureGroups = [ordered]@{
    LegacyFeatures     = @('SMB1Protocol', 'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2', 'Recall', 'WorkFolders-Client', 'WindowsMediaPlayer')
    HypervisorFeatures = @('Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'HypervisorPlatform', 'Microsoft-Windows-Subsystem-Linux', 'Containers-DisposableClientVM')
}

function Get-EnabledFeatureNames {
    param([string[]]$Names)
    $present = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { $Names -contains $_.FeatureName -and $_.State -eq 'Enabled' })
    return @($present | ForEach-Object { $_.FeatureName })
}

function Disable-FeatureGroup {
    param([Parameter(Mandatory)][string]$Group)
    $on = @(Get-EnabledFeatureNames -Names $FeatureGroups[$Group])
    if ($on.Count -eq 0) { Write-Log "$Group`: none of $($FeatureGroups[$Group] -join ', ') is turned on."; return }
    foreach ($name in $on) {
        if (Test-DryRun "turn off the optional feature $name") { continue }
        if (@($script:State.Features) -notcontains $name) { Add-StateRecord -Section 'Features' -Item $name }
        try {
            Disable-WindowsOptionalFeature -Online -FeatureName $name -NoRestart -ErrorAction Stop | Out-Null
            Write-Log "Optional feature turned off: $name (finishes at the next restart)." 'OK'
        }
        catch { Write-Log "Could not turn off the optional feature $name. $($_.Exception.Message)" 'WARN' }
    }
}

function Restore-Features {
    foreach ($name in @($script:State.Features)) {
        # Only names this script knows, never whatever a state file says.
        if (-not (@($FeatureGroups.Values | ForEach-Object { $_ }) -contains $name)) { Write-Log "Unexpected feature '$name' in the state file, not restoring it." 'WARN'; continue }
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop | Out-Null
            Write-Log "Optional feature turned back on: $name (finishes at the next restart)." 'OK'
        }
        catch { Write-Log "Could not turn the optional feature $name back on. $($_.Exception.Message)" 'WARN' }
    }
}

function Remove-QuickAssist {
    if (Test-DryRun 'remove Quick Assist (Windows capability, package and app)') { return }
    $removed = 0
    foreach ($cap in @(Get-WindowsCapability -Online | Where-Object { $_.Name -like 'App.Support.QuickAssist~~~~*' -and $_.State -eq 'Installed' })) {
        try { Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null; $removed++; Write-Log "Removed capability: $($cap.Name)" 'OK' }
        catch { Write-Log "Could not remove capability $($cap.Name). $($_.Exception.Message)" 'WARN' }
    }
    foreach ($pkg in @(Get-WindowsPackage -Online | Where-Object { $_.PackageName -like 'Microsoft-Windows-QuickAssist-Package*' -and $_.PackageName -notlike '*wow64*' -and $_.PackageState -eq 'Installed' })) {
        try { Remove-WindowsPackage -Online -PackageName $pkg.PackageName -NoRestart -ErrorAction Stop | Out-Null; $removed++; Write-Log "Removed package: $($pkg.PackageName)" 'OK' }
        catch { Write-Log "Could not remove package $($pkg.PackageName). $($_.Exception.Message)" 'WARN' }
    }
    if ($PSVersionTable.PSEdition -eq 'Core') { Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue }
    foreach ($app in @(Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*QuickAssist*' })) {
        try { Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop; $removed++; Write-Log "Removed app: $($app.Name)" 'OK' }
        catch { Write-Log "Could not remove app $($app.Name). $($_.Exception.Message)" 'WARN' }
    }
    if ($removed -eq 0) { Write-Log 'Quick Assist was not found, nothing to remove.' }
    else { Write-Log 'Quick Assist removed. To get it back: Add-WindowsCapability -Online -Name App.Support.QuickAssist~~~~0.0.1.0, or install it from the Store.' 'WARN' }
}
#endregion

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

#region Quiet Defender, network, cleanup, mitigations, timer ------------------------------
function Wait-TamperProtectionOff {
    # Tamper Protection exists to stop software from changing Defender, so a script cannot and must not switch it off.
    # Ask for it up front instead, with the right Windows Security page open. -Force skips the question.
    if ($script:DryRun -or $Force) { return }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { $tamper = [bool](Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected }
        catch { Write-Log "Defender status is not available, so Tamper Protection was not checked. $($_.Exception.Message)"; return }
        if (-not $tamper) { return }
        Write-Log 'Tamper Protection is on. Defender settings changed by this run (policy values, real time protection) may be ignored or reverted.' 'WARN'
        try { Start-Process 'windowsdefender://threatsettings/' }
        catch { Write-Log "Could not open Windows Security. Open it yourself: Virus and threat protection, Manage settings. $($_.Exception.Message)" 'WARN' }
        $answer = Read-Host 'Turn Tamper Protection off in Windows Security, then press Enter to check again (type SKIP to continue anyway)'
        if ($answer -ceq 'SKIP') { return }
    }
    Write-Log 'Tamper Protection is still on, continuing. Defender changes may not stick; the health check will say so.' 'WARN'
}

function Set-DefenderQuiet {
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if ($status.PSObject.Properties['IsTamperProtected'] -and $status.IsTamperProtected) {
            Write-Log 'Tamper Protection is on, so Defender may ignore or revert these policy values. Turn it off in Windows Security first for a reliable result.' 'WARN'
        }
    }
    catch { Write-Log "Defender status is not available, so Tamper Protection was not checked. $($_.Exception.Message)" }
    Set-TweakList $DefenderQuietRegs
    if (-not $script:DryRun) { Write-Log 'Defender cloud reporting, sample submission, infection reports and notifications are off by policy. Protection stays on.' 'OK' }
}

function Get-NetAdapterTweaks {
    # One tweak per value to write, for the physical adapters only (matched through the adapter GUID).
    param([string[]]$Keywords, [switch]$AllowOff)
    $tweaks = [System.Collections.Generic.List[object]]::new()
    $guids = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceGuid })
    $class = Open-RegKey -Full $NetAdapterClassKey
    if (-not $class) { return $tweaks }
    try {
        foreach ($sub in $class.GetSubKeyNames()) {
            if ($sub -notmatch '^\d{4}$') { continue }
            $child = $class.OpenSubKey($sub)
            if (-not $child) { continue }
            try {
                if ($guids -notcontains [string]$child.GetValue('NetCfgInstanceId', '')) { continue }
                $full = "$NetAdapterClassKey\$sub"
                if ($AllowOff) { $tweaks.Add((New-Tweak $full 'PnPCapabilities' 24 'DWord')) }
                $names = @($child.GetValueNames())
                foreach ($kw in $Keywords) {
                    if ($names -notcontains $kw) { continue }
                    if ($child.GetValueKind($kw) -eq [Microsoft.Win32.RegistryValueKind]::DWord) { $tweaks.Add((New-Tweak $full $kw 0 'DWord')) }
                    else { $tweaks.Add((New-Tweak $full $kw '0' 'String')) }
                }
            }
            finally { $child.Close() }
        }
    }
    finally { $class.Close() }
    return $tweaks
}

function Set-NetAdapterOff {
    # The adapter is not restarted here: a restart would drop a remote desktop session. A reboot applies the values.
    param([string]$Label, [string[]]$Keywords, [switch]$AllowOff)
    $tweaks = @(Get-NetAdapterTweaks -Keywords $Keywords -AllowOff:$AllowOff)
    if ($tweaks.Count -eq 0) { Write-Log "$Label`: no matching values on the physical network adapters." 'WARN'; return }
    Set-TweakList $tweaks
    if ($script:DryRun) { return }
    $adapters = @($tweaks | ForEach-Object { $_.Path } | Select-Object -Unique).Count
    Write-Log "$Label`: $($tweaks.Count) value(s) set on $adapters adapter(s). They apply after a restart." 'OK'
}

function Test-ProtectedPath {
    # Never delete the running script, the state folder, or a folder that holds either.
    param([string]$Path, [string[]]$Keep = @($PSCommandPath, $StateDir))
    foreach ($keep in $Keep) {
        if (-not $keep) { continue }
        if ($keep -ieq $Path) { return $true }
        if ($keep.StartsWith($Path.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Path.StartsWith($keep.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-ReparsePoint {
    param([Parameter(Mandatory)]$Item)
    return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-CleanupTree {
    # Lists everything below a folder without entering junctions or symbolic links. Windows PowerShell 5.1 follows them
    # with -Recurse, and Windows\Temp is writable by standard users, who could plant a link to files elsewhere.
    param([Parameter(Mandatory)][string]$Path)
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        foreach ($child in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction SilentlyContinue)) {
            $child
            if ($child.PSIsContainer -and -not (Test-ReparsePoint $child)) { $pending.Push($child.FullName) }
        }
    }
}

function Remove-CleanupEntry {
    # Files and links go first. A link is removed as a link only, so its target is never touched.
    param([Parameter(Mandatory)]$Item)
    if (-not (Test-ReparsePoint $Item) -and ($Item.Attributes -band [IO.FileAttributes]::ReadOnly)) {
        [IO.File]::SetAttributes($Item.FullName, [IO.FileAttributes]::Normal)
    }
    if ($Item.PSIsContainer) { [IO.Directory]::Delete($Item.FullName, $false) }
    else { [IO.File]::Delete($Item.FullName) }
}

function Clear-FolderContents {
    param([string]$Label, [string]$Path, [string[]]$Skip = @())
    if (-not (Test-Path -LiteralPath $Path)) { Write-Log "$Label`: $Path does not exist, nothing to do."; return }
    $top = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-NameMatch $_.Name $Skip) -and -not (Test-ProtectedPath $_.FullName) })
    $all = @(foreach ($item in $top) {
            $item
            if ($item.PSIsContainer -and -not (Test-ReparsePoint $item)) { Get-CleanupTree -Path $item.FullName }
        })
    $leaves = @($all | Where-Object { -not $_.PSIsContainer -or (Test-ReparsePoint $_) })
    $folders = @($all | Where-Object { $_.PSIsContainer -and -not (Test-ReparsePoint $_) } | Sort-Object { $_.FullName.Length } -Descending)
    # Summed by hand: Measure-Object returns no Sum property for empty input, which fails under StrictMode
    # whenever the folder holds only empty subfolders (a fresh SoftwareDistribution\Download, for example).
    [long]$bytes = 0
    foreach ($leaf in $leaves) { if (-not $leaf.PSIsContainer) { $bytes += $leaf.Length } }
    $mb = [Math]::Round($bytes / 1MB, 1)
    if (Test-DryRun "$Label`: delete $($top.Count) item(s), $mb MB, from $Path (links are removed as links, never followed)") { return }
    $kept = 0
    foreach ($entry in @($leaves) + @($folders)) {
        try { Remove-CleanupEntry -Item $entry }
        catch { $kept++ }   # in use, or changed meanwhile: left in place and counted
    }
    Write-Log "$Label`: cleaned $Path ($($top.Count) top level item(s), $mb MB before). $kept entr(ies) in use and kept." 'OK'
}

function Clear-TempFiles {
    # C:\XboxGames is deliberately not touched: installed Xbox games live there.
    foreach ($path in @($env:TEMP, (Join-Path $env:SystemRoot 'Temp') | Select-Object -Unique)) {
        Clear-FolderContents -Label 'Temp cleanup' -Path $path -Skip 'ft-ti-*'
    }
}

function Stop-ServiceBounded {
    # Stop-Service waits forever for a service that will not stop. Returns $true once it is stopped.
    param([Parameter(Mandatory)][string]$Name, [int]$Seconds = 30)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -eq 'Stopped') { return $true }
    try {
        if ($svc.Status -ne 'StopPending') { $svc.Stop() }
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($Seconds))
        return $true
    }
    catch { return $false }   # timed out, or the service refused the stop request
}

function Clear-UpdateDownloadCache {
    $path = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $stopped = @()
    if (Test-DryRun "stop UsoSvc, wuauserv and bits for up to 30 s each while the cache is cleared, then start them again") { $notStopped = @() }
    else {
        # UsoSvc first: while it runs it starts wuauserv again, which made this step wait forever.
        $notStopped = @(foreach ($name in 'UsoSvc', 'wuauserv', 'bits') {
                $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                if (-not $svc -or $svc.Status -eq 'Stopped') { continue }
                $stopped += $name
                if (-not (Stop-ServiceBounded -Name $name)) { $name }
            })
    }
    if ($notStopped.Count -gt 0) {
        Write-Log "Update cache cleanup skipped: $($notStopped -join ', ') did not stop within 30 s. Windows Update may be installing something; run it again later." 'WARN'
    }
    try { if ($notStopped.Count -eq 0) { Clear-FolderContents -Label 'Update cache cleanup' -Path $path } }
    finally {
        foreach ($name in $stopped) {
            try { Start-Service -Name $name -ErrorAction Stop }
            catch { Write-Log "Could not start service $name again. $($_.Exception.Message)" 'WARN' }
        }
    }
}

function Disable-SpectreMeltdownMitigations {
    Set-TweakList $MitigationRegs
    if (-not $script:DryRun) { Write-Log 'Spectre and Meltdown mitigations are switched off. Restart Windows to apply.' 'WARN' }
}

function Get-BcdValue {
    # Value of one element of the current boot entry, or $null when the entry does not set it.
    param([Parameter(Mandatory)][string]$Name)
    $out = Invoke-Native bcdedit.exe @('/enum', '{current}')
    if ($LASTEXITCODE -ne 0) { throw "bcdedit /enum failed: $($out.Trim())" }
    $m = [regex]::Match($out, "(?m)^$([regex]::Escape($Name))\s+(\S+)\s*$")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Disable-Dep {
    if (Test-DryRun 'set the boot option nx to AlwaysOff (Data Execution Prevention off, Secure Boot must be off)') { return }
    if (-not $script:State.Dep) { Set-StateValue -Name 'Dep' -Value ([pscustomobject]@{ Previous = (Get-BcdValue 'nx') }) }
    $out = Invoke-Native bcdedit.exe @('/set', 'nx', 'AlwaysOff')
    if ($LASTEXITCODE -ne 0) { throw "bcdedit could not set nx (Secure Boot must be off for this): $($out.Trim())" }
    Write-Log 'Data Execution Prevention is switched off. Restart Windows to apply.' 'WARN'
}

function Restore-Dep {
    # The saved value comes from a file, so only values bcdedit accepts for nx are passed on.
    $previous = $script:State.Dep.Previous
    if ($previous -and @('OptIn', 'OptOut', 'AlwaysOn', 'AlwaysOff') -notcontains [string]$previous) { throw "Unexpected saved nx value '$previous', not restoring it." }
    if ($previous) { $out = Invoke-Native bcdedit.exe @('/set', 'nx', $previous) }
    else { $out = Invoke-Native bcdedit.exe @('/deletevalue', 'nx') }
    if ($LASTEXITCODE -ne 0 -and ($previous -or (Get-BcdValue 'nx'))) { throw "bcdedit could not restore nx: $($out.Trim())" }
    Write-Log "Data Execution Prevention restored ($(if ($previous) { $previous } else { 'value removed' })). Restart Windows to apply." 'OK'
}

function Get-TimerSkipReason {
    # docs/AUDIT.md B-03: the timer service stays on by default, but only where it pays. Windows 10 ignores the global
    # flag, so the service would raise the resolution for itself only; on a battery machine the 0.5 ms tick keeps the
    # CPU out of deep idle states all the time. -ForcePowerPlanOnLaptop overrides the battery rule, as for the power plan.
    param([int]$Build, [bool]$HasBattery, [bool]$Force)
    if ($Build -lt 22000) { return "Windows 10 (build $Build) honours timer requests per process only, so a service cannot set the timer for other programs" }
    if ($HasBattery -and -not $Force) { return 'a battery was found, and a 0.5 ms timer held all the time drains it (use -ForcePowerPlanOnLaptop to install it anyway)' }
    return $null
}

function Get-TimerSkipReasonHere {
    return Get-TimerSkipReason -Build ([Environment]::OSVersion.Version.Build) -HasBattery ([bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)) -Force ([bool]$ForcePowerPlanOnLaptop)
}

function Install-TimerResolutionService {
    $dir = Join-Path $env:ProgramFiles 'FocusedTweaks'
    $exe = Join-Path $dir 'TimerResolution.exe'
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $skip = Get-TimerSkipReasonHere
    if ($skip) { Write-Log "Timer resolution service skipped: $skip." 'WARN'; return }
    if (Test-DryRun "build $exe with csc.exe, install and start the service '$TimerServiceName', set GlobalTimerResolutionRequests 1") { return }
    if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe was not found at $csc (.NET Framework 4 is required)." }
    Set-StateValue -Name 'TimerService' -Value ([pscustomobject]@{ Name = $TimerServiceName; Dir = $dir; Exe = $exe })
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $existing = Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Status -ne 'Stopped') { Stop-Service -Name $TimerServiceName -Force }
    $source = Join-Path $dir 'TimerResolution.cs'
    Set-Content -LiteralPath $source -Value $TimerServiceSource -Encoding ASCII
    try {
        $out = Invoke-Native $csc @('/nologo', '/target:exe', "/out:$exe", '/reference:System.ServiceProcess.dll', $source)
        if ($LASTEXITCODE -ne 0) { throw "csc.exe failed: $($out.Trim())" }
    }
    finally { Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue }
    if (-not $existing) {
        & sc.exe create $TimerServiceName binPath= "`"$exe`"" start= auto DisplayName= 'Set Timer Resolution (FocusedTweaks)' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe create failed ($LASTEXITCODE)." }
    }
    Set-TweakList $TimerGlobalRegs
    Start-Service -Name $TimerServiceName
    Write-Log "Timer resolution service '$TimerServiceName' installed and running ($exe)." 'OK'
}

function Remove-TimerResolutionService {
    # Name and paths are fixed, never read from the saved state file, so a planted state file cannot point this at other files.
    $dir = Join-Path $env:ProgramFiles 'FocusedTweaks'
    $t = [pscustomobject]@{ Name = $TimerServiceName; Dir = $dir; Exe = (Join-Path $dir 'TimerResolution.exe') }
    if (Get-Service -Name $t.Name -ErrorAction SilentlyContinue) {
        Stop-Service -Name $t.Name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $t.Name | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "sc.exe delete returned $LASTEXITCODE for $($t.Name)." 'WARN' }
    }
    Remove-Item -LiteralPath $t.Exe -Force -ErrorAction SilentlyContinue
    if ((Test-Path -LiteralPath $t.Dir) -and -not (Get-ChildItem -LiteralPath $t.Dir -Force)) { Remove-Item -LiteralPath $t.Dir -Force }
    Write-Log 'Timer resolution service removed.' 'OK'
}
#endregion

#region Devices, shutdown, updates, search, time, right click menu ------------------------
function Set-TweakListBatched {
    # For long lists (one entry per device). Values that need TrustedInstaller are written together in a few calls,
    # because each call restarts a service and takes seconds. A dry run prints one summary line, not every value.
    # The journal gets one flushed write per registry key before its values change and one for their results, instead
    # of two per value: device options touch thousands of values.
    param([string]$Label, [object[]]$Tweaks)
    if ($Tweaks.Count -eq 0) { Write-Log "$Label`: nothing to change on this machine."; return }
    $keys = @($Tweaks | ForEach-Object { $_.Path } | Select-Object -Unique).Count
    if (Test-DryRun "$Label`: set $($Tweaks.Count) value(s) under $keys registry key(s)") { return }
    $denied = [System.Collections.Generic.List[object]]::new()
    $failed = 0
    foreach ($group in @($Tweaks | Group-Object { ConvertTo-FullRegPath $_.Path })) {
        $full = $group.Name
        $events = [System.Collections.Generic.List[object]]::new()
        $pending = [System.Collections.Generic.List[object]]::new()
        foreach ($e in @(Get-MissingKeyEvents -Full $full)) { $events.Add($e) }
        foreach ($t in $group.Group) {
            $change = $null
            foreach ($e in @(New-RegChangeEvents -Full $full -Name $t.Name -After (Format-RegIntent -Value $t.Value -Kind $t.Type) -SkipKeys)) { $events.Add($e); $change = $e }
            $pending.Add([pscustomobject]@{ Full = $full; Tweak = $t; Change = $change })
        }
        Add-JournalEvents $events.ToArray()
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $pending) {
            try {
                Write-RegRaw -Full $full -Name $p.Tweak.Name -Value $p.Tweak.Value -Kind $p.Tweak.Type
                $r = Complete-RegChange -Change $p.Change -Full $full -Name $p.Tweak.Name -Value $p.Tweak.Value -Kind $p.Tweak.Type -Quiet
                if ($r.Result -ne 'OK') { $failed++ }
                $results.Add($r)
            }
            catch {
                if (Test-AccessDenied $_) { $denied.Add($p); continue }
                $script:Failures++
                Write-Log "Registry write failed: $full\$(Show-RegName $p.Tweak.Name). $($_.Exception.Message)" 'ERROR'
                $results.Add((New-ChangeResult -Change $p.Change -Result 'FAILED' -Now $_.Exception.Message))
            }
        }
        if ($results.Count -gt 0) { Add-JournalEvents $results.ToArray() }
    }
    # About 30 commands keep the encoded command well below the service command line limit.
    for ($i = 0; $i -lt $denied.Count; $i += 30) {
        $chunk = @($denied[$i..([Math]::Min($i + 29, $denied.Count - 1))])
        [void](Invoke-AsTI -PsCommand (($chunk | ForEach-Object { Format-TiRegAdd -Full $_.Full -Name $_.Tweak.Name -Value $_.Tweak.Value -Kind $_.Tweak.Type }) -join '; '))
    }
    if ($denied.Count -gt 0) {
        $results = @(foreach ($p in $denied) { Complete-RegChange -Change $p.Change -Full $p.Full -Name $p.Tweak.Name -Value $p.Tweak.Value -Kind $p.Tweak.Type -Quiet })
        $failed += @($results | Where-Object { $_.Result -ne 'OK' }).Count
        Add-JournalEvents $results
    }
    if ($failed -gt 0) { Write-Log "$Label`: $failed of $($Tweaks.Count) value(s) did not read back as set (MISMATCH in the journal), even as TrustedInstaller." 'WARN' }
    Write-Log "$Label`: $($Tweaks.Count - $failed) value(s) set under $keys registry key(s). They apply after a restart." 'OK'
}

function Get-DeviceParameterKeys {
    # The 'Device Parameters' key of every device instance under the given Enum roots (present or not).
    param([string[]]$Roots, [string]$HardwareLike = '*')
    foreach ($root in $Roots) {
        $rootPath = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$root"
        $rootKey = Open-RegKey -Full $rootPath
        if (-not $rootKey) { continue }
        try {
            foreach ($hw in @($rootKey.GetSubKeyNames() | Where-Object { $_ -like $HardwareLike })) {
                $hwKey = $rootKey.OpenSubKey($hw)
                if (-not $hwKey) { continue }
                try {
                    foreach ($inst in $hwKey.GetSubKeyNames()) {
                        try { $params = $hwKey.OpenSubKey("$inst\Device Parameters") }
                        catch { continue }   # a few instance keys are readable by SYSTEM only, nothing to change there
                        if (-not $params) { continue }
                        [pscustomobject]@{ Path = "$rootPath\$hw\$inst\Device Parameters"; HasWdf = (@($params.GetSubKeyNames()) -contains 'WDF') }
                        $params.Close()
                    }
                }
                finally { $hwKey.Close() }
            }
        }
        finally { $rootKey.Close() }
    }
}

function Get-DeviceTweaks {
    param([switch]$Power, [switch]$Wake)
    foreach ($d in @(Get-DeviceParameterKeys -Roots $DeviceEnumRoots)) {
        if ($Power) {
            foreach ($v in $DevicePowerValues) { New-Tweak $d.Path $v.Name $v.Value $v.Type }
            if ($d.HasWdf) { New-Tweak "$($d.Path)\WDF" 'IdleInWorkingState' 0 'DWord' }
        }
        if ($Wake) { New-Tweak $d.Path 'WaitWakeEnabled' 0 'DWord' }
    }
}

function Get-WriteCacheTweaks {
    # Disks only: Enum\SCSI also lists optical drives, which Ultimate changes as well.
    foreach ($d in @(Get-DeviceParameterKeys -Roots 'SCSI', 'NVME' -HardwareLike 'Disk*')) { New-Tweak "$($d.Path)\Disk" 'CacheIsPowerProtected' 1 'DWord' }
}

function Set-DevicePowerSaving {
    if ((Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) -and -not $ForcePowerPlanOnLaptop) {
        Write-Log 'Battery detected, device power saving kept. Use -ForcePowerPlanOnLaptop to override.' 'WARN'
        return
    }
    Set-TweakListBatched -Label 'Device power saving' -Tweaks @(Get-DeviceTweaks -Power)
}

function Get-FeatureUpgradeTweaks {
    # Same policy as upstream: pin the current product and version, so Windows Update offers no newer version.
    $nt = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $version = if ($nt.PSObject.Properties['DisplayVersion']) { [string]$nt.DisplayVersion } elseif ($nt.PSObject.Properties['ReleaseId']) { [string]$nt.ReleaseId } else { '' }
    if (-not $version) { throw 'Could not read the current Windows version (DisplayVersion).' }
    $product = if ([Environment]::OSVersion.Version.Build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    $wu = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    New-Tweak $wu 'ProductVersion' $product 'String'
    New-Tweak $wu 'TargetReleaseVersion' 1 'DWord'
    New-Tweak $wu 'TargetReleaseVersionInfo' $version 'String'
}

function Set-FeatureUpgradeBlock {
    $tweaks = @(Get-FeatureUpgradeTweaks)
    Set-TweakList $tweaks
    if (-not $script:DryRun) { Write-Log "Windows stays on $($tweaks[0].Value) $($tweaks[2].Value). Remove this before that version reaches end of support." 'WARN' }
}

function Update-TimeService {
    # Makes the time service read its settings again and sync. A failed sync is not fatal: it retries on its own.
    Start-Service -Name W32Time -ErrorAction SilentlyContinue
    $out = Invoke-Native w32tm.exe @('/config', '/update')
    if ($LASTEXITCODE -ne 0) { Write-Log "w32tm /config /update failed: $($out.Trim())" 'WARN'; return }
    $out = Invoke-Native w32tm.exe @('/resync', '/nowait')
    if ($LASTEXITCODE -ne 0) { Write-Log "w32tm /resync failed, Windows will retry on its own: $($out.Trim())" 'WARN' }
}

function Set-TimeServer {
    Set-TweakList $TimeServerRegs
    if ($script:DryRun) { return }
    Update-TimeService
    Write-Log 'Time is now synced from pool.ntp.org.' 'OK'
}
#endregion

#region NVMe, IPv4, startup review, benchmark ------------------------------------------------
function Set-NvmeNativeDriver {
    # The native NVMe stack ships with Windows 11 24H2 (build 26100). On older builds the overrides do nothing useful.
    if ([Environment]::OSVersion.Version.Build -lt 26100) { Write-Log 'Native NVMe driver needs Windows 11 24H2 (build 26100) or later, skipped.' 'WARN'; return }
    Set-TweakList $NvmeRegs
    if (-not $script:DryRun) { Write-Log 'Native NVMe driver switched on. It takes effect after a restart; -Revert switches it off again.' 'WARN' }
}

function Set-IPv4Only {
    # Only IPv6 is unbound. Ultimate also unbinds file sharing, the SMB client and QoS, which breaks network shares.
    $bindings = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
            Get-NetAdapterBinding -Name $_.Name -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
        } | Where-Object { $_.Enabled })
    if ($bindings.Count -eq 0) { Write-Log 'IPv4 only: IPv6 is already off on every physical adapter.'; return }
    foreach ($b in $bindings) {
        if (Test-DryRun "turn off IPv6 on adapter '$($b.Name)' (the connection drops for a moment)") { continue }
        if (-not (Test-RecordedFirst $script:State.NetBindings { param($e) $e.Name -eq $b.Name })) {
            Add-StateRecord -Section 'NetBindings' -Item ([pscustomobject]@{ Name = $b.Name; ComponentId = 'ms_tcpip6' })
        }
        Disable-NetAdapterBinding -Name $b.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop
        Write-Log "IPv6 turned off on '$($b.Name)'." 'OK'
    }
}

function Restore-NetBindings {
    foreach ($b in $script:State.NetBindings) {
        if ($b.ComponentId -ne 'ms_tcpip6') { Write-Log "Unexpected saved binding '$($b.ComponentId)', not restoring it." 'WARN'; continue }
        try { Enable-NetAdapterBinding -Name $b.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop; Write-Log "IPv6 turned back on for '$($b.Name)'." 'OK' }
        catch { Write-Log "Could not turn IPv6 back on for '$($b.Name)' (adapter renamed or removed?). $($_.Exception.Message)" 'WARN' }
    }
}

function Show-StartupReview {
    # Lists what starts with Windows, for a person to review. Changes nothing (RunKeys is the option that clears).
    $rows = [System.Collections.Generic.List[object]]::new()
    $runKeys = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    foreach ($k in $runKeys) {
        $key = Open-RegKey -Full $k
        if (-not $key) { continue }
        try { foreach ($n in $key.GetValueNames()) { $rows.Add([pscustomobject]@{ Kind = 'Run key'; Name = $n; Command = [string]$key.GetValue($n); Where = $k }) } }
        finally { $key.Close() }
    }
    foreach ($dir in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $rows.Add([pscustomobject]@{ Kind = 'Startup folder'; Name = $f.Name; Command = $f.FullName; Where = $dir })
        }
    }
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' })) {
        $triggers = @($t.Triggers | ForEach-Object { $_.CimClass.CimClassName })
        if (-not ($triggers -match 'Logon|Boot')) { continue }
        $rows.Add([pscustomobject]@{ Kind = 'Task'; Name = "$($t.TaskPath)$($t.TaskName)"; Command = (@($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join '; '); Where = ($triggers -join ', ') })
    }
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -Filter "StartMode = 'Auto'" -ErrorAction SilentlyContinue)) {
        $exe = ([string]$s.PathName) -replace '^"([^"]+)".*$', '$1' -replace '^(\S+\.exe).*$', '$1'
        $company = ''
        try { $company = [string](Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo.CompanyName } catch { $company = '' }   # driver paths and svchost groups have no readable file here
        if ($company -match 'Microsoft') { continue }
        $rows.Add([pscustomobject]@{ Kind = 'Service'; Name = "$($s.Name) ($($s.DisplayName))"; Command = $s.PathName; Where = $(if ($company) { $company } else { 'unknown publisher' }) })
    }
    $file = Join-Path $StateDir ('startup-review-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
    $text = ($rows | Sort-Object Kind, Name | Format-Table Kind, Name, Command, Where -AutoSize -Wrap | Out-String -Width 220)
    Set-Content -LiteralPath $file -Value $text -Encoding UTF8
    if (-not $Json) { Write-Host $text }
    Write-Log "Startup review: $($rows.Count) entr(ies), nothing was changed. Saved to $file. Autoruns (installed by Packages) shows more detail."
}

function Get-TimerResolution {
    if (-not ('Native.NtTimer' -as [type])) {
        Add-Type -Namespace Native -Name NtTimer -MemberDefinition @'
[DllImport("ntdll.dll")]
public static extern int NtQueryTimerResolution(out uint minimum, out uint maximum, out uint actual);
'@
    }
    $min = [uint32]0; $max = [uint32]0; $now = [uint32]0
    [void][Native.NtTimer]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$now)
    # Units of 100 ns; reported in milliseconds.
    return [pscustomobject]@{ CurrentMs = [Math]::Round($now / 10000, 3); FinestMs = [Math]::Round($max / 10000, 3); CoarsestMs = [Math]::Round($min / 10000, 3) }
}

function Get-Stats {
    # Median, minimum, maximum and mean of a set of samples, so one noisy sample cannot pass for a result.
    param([double[]]$Values)
    $v = @($Values | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $mid = [int][Math]::Floor($v.Count / 2)
    $median = if ($v.Count % 2) { $v[$mid] } else { ($v[$mid - 1] + $v[$mid]) / 2 }
    $sum = 0.0; foreach ($x in $v) { $sum += $x }
    return [ordered]@{ Median = [Math]::Round($median, 3); Min = [Math]::Round($v[0], 3); Max = [Math]::Round($v[-1], 3); Mean = [Math]::Round($sum / $v.Count, 3); Samples = $v.Count }
}

function Test-VirtualMachine {
    param([string]$Manufacturer, [string]$Model)
    return ("$Manufacturer $Model" -match 'VMware|VirtualBox|innotek|Virtual Machine|QEMU|KVM|Xen|Parallels|Bochs|BHYVE')
}

function Get-BenchmarkMachine {
    # What must be the same for two benchmarks to be comparable.
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)[0]
    return [ordered]@{
        CPU               = $(if ($cpu) { ([string]$cpu.Name).Trim() } else { 'unknown' })
        LogicalProcessors = $(if ($cs) { [int]$cs.NumberOfLogicalProcessors } else { 0 })
        RamGB             = $(if ($cs) { [Math]::Round([double]$cs.TotalPhysicalMemory / 1GB) } else { 0 })
        VirtualMachine    = $(if ($cs) { [bool](Test-VirtualMachine -Manufacturer $cs.Manufacturer -Model $cs.Model) } else { $false })
        PowerSource       = (Get-PowerSource)
    }
}

function Get-BenchmarkSettings {
    # What the options change. Recorded with every benchmark and shown when it differs, but it does not block a
    # comparison: comparing before and after a run is the point.
    $mm = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'FeatureSettingsOverride'
    $mpo = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode'
    $overlay = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name "ActiveOverlay$(Get-PowerSource)PowerScheme"
    $overlayGuid = '00000000-0000-0000-0000-000000000000'
    if ($overlay.Existed -and $overlay.Value) { $overlayGuid = ([string]$overlay.Value).ToLowerInvariant() }
    $vbs = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction SilentlyContinue)[0]
    $vbsText = 'unknown'
    if ($vbs) { $vbsText = switch ([int]$vbs.VirtualizationBasedSecurityStatus) { 0 { 'off' } 1 { 'enabled, not running' } 2 { 'running' } default { 'unknown' } } }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $mode = $PowerOverlayNames[$overlayGuid]
    if (-not $mode) { $mode = $overlayGuid }
    return [ordered]@{
        'Power plan'                   = ((powercfg /getactivescheme) | Out-String).Trim() -replace '^.*\(([^)]*)\)\s*$', '$1'
        'Power mode'                   = $mode
        'VBS (core isolation)'         = $vbsText
        'Hypervisor present'           = $(if ($cs) { [bool]$cs.HypervisorPresent } else { $false })
        'Spectre/Meltdown mitigations' = $(if ($mm.Existed -and [int]$mm.Value -eq 3) { 'off' } else { 'on' })
        'Multiplane overlay'           = $(if ($mpo.Existed -and [int]$mpo.Value -eq 5) { 'off' } else { 'on' })
        'Timer service'                = $(if (Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }) { 'running' } else { 'not running' })
    }
}

function Measure-MicroOnce {
    # One repetition of the short measurements. They time a PowerShell loop, so they show changes in timer,
    # scheduling and kernel call overhead, not application speed.
    $watch = [Diagnostics.Stopwatch]::new(); $sleeps = 100
    $watch.Start(); for ($i = 0; $i -lt $sleeps; $i++) { [Threading.Thread]::Sleep(1) }; $watch.Stop()
    $sleep = $watch.Elapsed.TotalMilliseconds / $sleeps
    $probe = Join-Path $env:SystemRoot 'System32\kernel32.dll'; $calls = 20000
    $watch.Restart(); for ($i = 0; $i -lt $calls; $i++) { [void][IO.File]::Exists($probe) }; $watch.Stop()
    $kernel = $watch.Elapsed.TotalMilliseconds * 1000 / $calls
    $watch.Restart(); $x = 0; for ($i = 0; $i -lt 3000000; $i++) { $x = ($x + $i) % 1000003 }; $watch.Stop()
    return @($sleep, $kernel, $watch.Elapsed.TotalMilliseconds)
}

function Get-BenchmarkComparison {
    # Compares two benchmark results. Refuses when the machine context differs (another CPU, RAM size, power source,
    # VM or not), because then the numbers say nothing about the options. Settings that differ are listed.
    param([Parameter(Mandatory)]$Now, [Parameter(Mandatory)]$Before)
    $result = [pscustomobject]@{ Refused = $false; Reason = ''; Rows = @(); SettingChanges = @() }
    if (-not $Before.PSObject.Properties['Format'] -or [int]$Before.Format -lt 2) {
        $result.Refused = $true; $result.Reason = 'it uses the old format (one sample per measurement, no machine context)'; return $result
    }
    $diff = @(foreach ($p in $Now.Machine.PSObject.Properties) {
            $old = $Before.Machine.PSObject.Properties[$p.Name]
            if (-not $old -or [string]$old.Value -ne [string]$p.Value) { '{0}: {1} -> {2}' -f $p.Name, $(if ($old) { $old.Value } else { '?' }), $p.Value }
        })
    if ($diff.Count -gt 0) { $result.Refused = $true; $result.Reason = "the machine context differs ($($diff -join '; '))"; return $result }
    $result.SettingChanges = @(foreach ($p in $Now.Settings.PSObject.Properties) {
            $old = $Before.Settings.PSObject.Properties[$p.Name]
            if ($old -and [string]$old.Value -ne [string]$p.Value) { '{0}: {1} -> {2}' -f $p.Name, $old.Value, $p.Value }
        })
    $result.Rows = @(foreach ($p in $Now.Metrics.PSObject.Properties) {
            $n = $p.Value; $o = $null
            if ($Before.Metrics.PSObject.Properties[$p.Name]) { $o = $Before.Metrics.($p.Name) }
            if ($null -eq $n -or $null -eq $o) { continue }
            # Invariant culture: the log reads the same on every system, whatever its decimal separator.
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $change = ''
            if ([double]$o.Median -ne 0) { $change = [string]::Format($inv, '{0:+0.0;-0.0;0}%', (([double]$n.Median - [double]$o.Median) / [double]$o.Median) * 100) }
            $overlap = ([double]$n.Min -le [double]$o.Max) -and ([double]$o.Min -le [double]$n.Max)
            [pscustomobject]@{ Measurement = $p.Name; Now = [string]::Format($inv, '{0} [{1}..{2}]', [double]$n.Median, [double]$n.Min, [double]$n.Max); Before = [string]::Format($inv, '{0} [{1}..{2}]', [double]$o.Median, [double]$o.Min, [double]$o.Max); Change = $change; Note = $(if ($overlap) { 'within noise (ranges overlap)' } else { '' }) }
        })
    return $result
}

function Invoke-Benchmark {
    # docs/AUDIT.md B-01: repeated measurements with median and range, the idle footprint over a fixed window, and the
    # context that decides whether two benchmarks can be compared. Changes nothing.
    $machine = Get-BenchmarkMachine
    Write-Log "Benchmark: $BenchmarkRuns repetition(s), then $BenchmarkIdleSeconds s of idle sampling. Close other programs and leave the PC alone."
    if ($machine.VirtualMachine) { Write-Log 'This is a virtual machine: the hypervisor decides timers and interrupts here, so these numbers check that options took effect and are not performance evidence.' 'WARN' }
    if ($machine.PowerSource -eq 'Dc') { Write-Log 'Running on battery: compare only with benchmarks also taken on battery.' 'WARN' }
    $settings = Get-BenchmarkSettings
    $timer = Get-TimerResolution
    $micro = @(for ($r = 1; $r -le $BenchmarkRuns; $r++) { , (Measure-MicroOnce) })
    $process = @(Get-Process -ErrorAction SilentlyContinue).Count
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }).Count
    $memory = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    # Processor counters through WMI: the class and property names are the same in every Windows language.
    $idle = @(for ($i = 0; $i -lt $BenchmarkIdleSeconds; $i++) { Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name = '_Total'"; Start-Sleep -Seconds 1 })
    $boots = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents $BenchmarkRuns -ErrorAction SilentlyContinue | ForEach-Object {
            [double](@(([xml]$_.ToXml()).Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' })[0].'#text') / 1000
        })
    $m = [ordered]@{}
    $m['Timer resolution now (ms)'] = Get-Stats @($timer.CurrentMs)
    $m['Sleep(1) actual (ms)'] = Get-Stats @($micro | ForEach-Object { $_[0] })
    $m['Kernel call cost, file check (us)'] = Get-Stats @($micro | ForEach-Object { $_[1] })
    $m['CPU loop, 3M steps (ms)'] = Get-Stats @($micro | ForEach-Object { $_[2] })
    $m["Idle CPU over $BenchmarkIdleSeconds s (%)"] = Get-Stats @($idle | ForEach-Object { [double]$_.PercentProcessorTime })
    # Time share of the CPU spent in DPCs and interrupts, one sample per second. This is not their latency.
    $m['DPC time share (%)'] = Get-Stats @($idle | ForEach-Object { [double]$_.PercentDPCTime })
    $m['Interrupt (ISR) time share (%)'] = Get-Stats @($idle | ForEach-Object { [double]$_.PercentInterruptTime })
    $m['DPCs queued per s'] = Get-Stats @($idle | ForEach-Object { [double]$_.DPCsQueuedPersec })
    $m['Interrupts per s'] = Get-Stats @($idle | ForEach-Object { [double]$_.InterruptsPersec })
    $m['Processes at idle'] = Get-Stats @($process)
    $m['Running services'] = Get-Stats @($services)
    $m['Committed memory (MB)'] = $(if ($memory) { Get-Stats @([double]$memory.CommittedBytes / 1MB) } else { $null })
    $m["Boot time, last $($boots.Count) restart(s) (s)"] = $(if ($boots.Count -gt 0) { Get-Stats $boots } else { $null })
    if ($boots.Count -eq 1) { Write-Log 'Only one boot time is recorded, so the boot time is a single sample.' 'WARN' }
    $now = [pscustomobject]@{
        Format = 2; When = (Get-Date).ToString('o'); Runs = $BenchmarkRuns; IdleSeconds = $BenchmarkIdleSeconds
        ValidForPerformance = (-not $machine.VirtualMachine); Machine = [pscustomobject]$machine; Settings = [pscustomobject]$settings
        Metrics = [pscustomobject]$m
    }
    # Through JSON once, so the run is compared in the same shape as a saved one.
    $now = ConvertTo-Json -InputObject $now -Depth 5 | ConvertFrom-Json
    $baselineFile = $null
    if ($BenchmarkBaseline) { $baselineFile = Join-Path $StateDir "benchmark-baseline-$BenchmarkBaseline.json" }
    $before = $null; $beforeName = ''
    if ($baselineFile -and (Test-Path -LiteralPath $baselineFile)) { $before = Get-Content -LiteralPath $baselineFile -Raw | ConvertFrom-Json; $beforeName = "baseline '$BenchmarkBaseline'" }
    elseif (-not $baselineFile) {
        $previous = Get-ChildItem -Path (Join-Path $StateDir 'benchmark-2*.json') -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if ($previous) { $before = Get-Content -LiteralPath $previous.FullName -Raw | ConvertFrom-Json; $beforeName = "the benchmark of $($previous.Name -replace '^benchmark-|\.json$', '')" }
    }
    $table = @(foreach ($p in $now.Metrics.PSObject.Properties) { if ($p.Value) { [pscustomobject]@{ Measurement = $p.Name; Median = $p.Value.Median; Min = $p.Value.Min; Max = $p.Value.Max; Samples = $p.Value.Samples } } })
    if (-not $Json) {
        Write-Host ($table | Format-Table -AutoSize | Out-String)
        Write-Host ($settings.GetEnumerator() | ForEach-Object { '{0,-30} {1}' -f $_.Key, $_.Value } | Out-String)
    }
    if ($before) {
        $cmp = Get-BenchmarkComparison -Now $now -Before $before
        if ($cmp.Refused) { Write-Log "Not compared with $beforeName`: $($cmp.Reason). Compare only runs on the same machine and power source." 'WARN' }
        else {
            if (-not $Json) { Write-Host ($cmp.Rows | Format-Table -AutoSize | Out-String) }
            Write-Log "Compared with $beforeName (median [min..max]; lower is better for every measurement; 'within noise' means the ranges overlap)."
            foreach ($c in $cmp.SettingChanges) { Write-Log "  Setting changed since then: $c" }
        }
    }
    elseif ($baselineFile) {
        ConvertTo-Json -InputObject $now -Depth 5 | Set-Content -LiteralPath $baselineFile -Encoding UTF8
        Write-Log "Saved as baseline '$BenchmarkBaseline'. Run -Benchmark -BenchmarkBaseline $BenchmarkBaseline again after a run and a restart to compare with it." 'OK'
    }
    else { Write-Log 'First benchmark on this machine. Run it again after a run and a restart to compare.' }
    $file = Join-Path $StateDir ('benchmark-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    ConvertTo-Json -InputObject $now -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Log "Benchmark saved to $file" 'OK'
}
#endregion

#region Health check ---------------------------------------------------------------------
$script:Health = @{ PASS = 0; WARN = 0; FAIL = 0; INFO = 0 }
$script:HealthItems = [System.Collections.Generic.List[object]]::new()
$script:SoftRuntime = $false
$script:PostApply = $false
$script:AppliedAt = $null

function Write-Health {
    param([ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Area, [string]$Message)
    $script:Health[$Status]++
    $script:HealthItems.Add([pscustomobject]@{ Status = $Status; Area = $Area; Message = $Message })
    $colour = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    $line = '{0:HH:mm:ss} [{1}] {2,-9} {3}' -f (Get-Date), $Status, $Area, $Message
    if (-not $Json) { Write-Host $line -ForegroundColor $colour }
    Add-Content -Path $LogFile -Value $line
}

# Runtime state (running services, memory compression) lags behind the registry until a restart.
function Get-RuntimeStatus { if ($script:SoftRuntime) { return 'INFO' } return 'FAIL' }

function Invoke-HealthArea {
    param([string]$Name, [scriptblock]$Check)
    try { & $Check }
    catch { Write-Health 'WARN' $Name "This check could not run: $($_.Exception.Message)" }
}

function Get-ServiceStartNow {
    param([string]$Name)
    $s = Get-RegSnapshot -Full "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$Name" -Name 'Start'
    if ($s.Existed) { return [int]$s.Value }
    return $null
}

function Test-RegMatchesOp {
    param($Snap, $Op)
    if (-not $Snap.Existed) { return $false }
    if ($Op.Type -eq 'None') { return $Snap.Kind -eq 'None' }
    if ($Snap.Kind -ne $Op.Type) { return $false }
    $expected = ConvertTo-StoredValue -Value $Op.Value -Kind $Op.Type
    return ((@($Snap.Value) -join ',') -ieq (@($expected) -join ','))
}

function Format-RegValueShort {
    param($Snap)
    if (-not $Snap.Existed) { return '<missing>' }
    if ($Snap.Kind -eq 'Binary') { return '<binary>' }
    return [string]$Snap.Value
}

function Test-ServiceStartChanged {
    # True when this script recorded a different original Start value, so it was the one that disabled the service.
    param([string]$Name)
    $path = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$Name"
    return Test-RecordedFirst $script:State.Registry { param($e) $e.Path -ieq $path -and $e.Name -eq 'Start' -and $e.Existed -and [int]$e.Value -ne 4 }
}

function Test-HealthServices {
    foreach ($g in $ServiceGroups.Keys) {
        $present = 0; $wrong = @(); $native = @()
        foreach ($name in $ServiceGroups[$g]) {
            $start = Get-ServiceStartNow $name
            if ($null -eq $start) { continue }
            $present++
            if ($Opt[$g] -eq ($start -eq 4)) { continue }
            # A service that is disabled although the option is off only counts when this script disabled it.
            # Some (RemoteRegistry, shpamsvc) are disabled by Windows itself.
            if ($Opt[$g] -or (Test-ServiceStartChanged $name)) { $wrong += $name } else { $native += $name }
        }
        if ($present -eq 0) { continue }
        if ($Opt[$g]) {
            if ($wrong.Count -eq 0) { Write-Health 'PASS' 'Services' "$g`: all $present service(s) are disabled." }
            else { Write-Health 'WARN' 'Services' "$g`: still enabled: $($wrong -join ', '). Protected services may need a restart." }
        }
        elseif ($wrong.Count -eq 0) {
            if ($present -gt $native.Count) { Write-Health 'PASS' 'Services' "$g`: $($present - $native.Count) service(s) kept, as you asked." }
            if ($native.Count -gt 0) { Write-Health 'INFO' 'Services' "$g`: $($native -join ', ') disabled by Windows itself or an earlier tool, not by this script, so they are left alone." }
        }
        else { Write-Health 'FAIL' 'Services' "$g`: disabled although you asked to keep them: $($wrong -join ', ')." }
    }
    $core = @('BITS', 'CryptSvc', 'Winmgmt', 'StorSvc', 'AppXSvc', 'ClipSVC', 'InstallService', 'LicenseManager', 'BFE', 'mpssvc', 'Dnscache', 'NlaSvc', 'wuauserv', 'UsoSvc', 'WaaSMedicSvc')
    if ($Defender -ne 'Disable') { $core += 'WinDefend' }
    $disabledCore = @($core | Where-Object { (Get-ServiceStartNow $_) -eq 4 })
    if ($disabledCore.Count -eq 0) { Write-Health 'PASS' 'Services' 'Store, Windows Update, BITS, Delivery Optimization path and firewall services are not disabled.' }
    else { Write-Health 'FAIL' 'Services' "Core services are disabled: $($disabledCore -join ', '). Store installs or updates may fail." }
}

function Test-HealthApps {
    $installed = @(Get-AppxPackage -AllUsers | ForEach-Object { $_.Name })
    $expect = [ordered]@{
        'Microsoft Store'      = 'Microsoft.WindowsStore'
        'Xbox app'             = 'Microsoft.GamingApp'
        'Xbox identity'        = 'Microsoft.XboxIdentityProvider'
        'Gaming services'      = 'Microsoft.GamingServices'
        'Photos'               = 'Microsoft.Windows.Photos'
        'Paint'                = 'Microsoft.Paint'
        'App Installer/winget' = 'Microsoft.DesktopAppInstaller'
    }
    foreach ($k in $expect.Keys) {
        if ($installed -contains $expect[$k]) { Write-Health 'PASS' 'Apps' "$k is installed." }
        else { Write-Health 'WARN' 'Apps' "$k not found. Ignore this if it was never on the image, otherwise reinstall it from the Store." }
    }
    $edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edge) { Write-Health 'PASS' 'Apps' 'Microsoft Edge is installed.' } else { Write-Health 'WARN' 'Apps' 'Microsoft Edge was not found.' }
    if ($Opt['Debloat'] -and $script:State.Removed.Count -gt 0) {
        $back = @($script:State.Removed | Sort-Object -Unique | Where-Object { $installed -contains $_ })
        if ($back.Count -eq 0) { Write-Health 'PASS' 'Apps' "Debloat holds: $(@($script:State.Removed | Sort-Object -Unique).Count) removed app(s) are gone." }
        else { Write-Health 'WARN' 'Apps' "Removed apps came back: $($back -join ', '). A feature update can reinstall them." }
    }
}

function Test-HealthTweakTable {
    param([string]$Label, [object[]]$Tweaks)
    $bad = @(); $stuck = @()
    foreach ($t in $Tweaks) {
        $full = ConvertTo-FullRegPath $t.Path
        $snap = Get-RegSnapshot -Full $full -Name $t.Name
        if (-not (Test-RegMatchesOp -Snap $snap -Op ([pscustomobject]@{ Type = $t.Type; Value = $t.Value }))) {
            $text = '{0}\{1} is {2}, expected {3}' -f $full, $t.Name, (Format-RegValueShort $snap), $t.Value
            if ($KnownStuckValues -contains "$full|$($t.Name)") { $stuck += $text } else { $bad += $text }
        }
    }
    foreach ($s in $stuck) { Write-Health 'INFO' 'Registry' "$Label`: $s. Windows protects this value, even from TrustedInstaller." }
    if ($bad.Count -eq 0) { Write-Health 'PASS' 'Registry' "$Label`: $($Tweaks.Count - $stuck.Count) of $($Tweaks.Count) value(s) match, none unexpected." }
    else {
        Write-Health 'WARN' 'Registry' "$Label`: $($bad.Count) of $($Tweaks.Count) differ. First: $($bad[0])"
        foreach ($b in $bad) { Add-Content -Path $LogFile -Value "          differs: $b" }
    }
}

function Get-LaterOverrideKeys {
    # Upstream sets some values twice (for example telemetry level 1 in RegTweaks, then 0 in its telemetry block).
    # The later step wins, so the earlier one is not judged against its own value.
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $tables = @()
    if ($Opt['TelemetryPolicy']) { $tables += $TelemetryRegs }
    if ($Opt['Registry']) { $tables += $LastAccessRegs }
    if ($Opt['BiometricsPolicy']) { $tables += $BiometricsRegs }
    if ($Opt['DriverExclusion']) { $tables += $DriverExclusionRegs }
    if ($Opt['SecurityUpdatesOnly']) { $tables += $SecurityUpdatesRegs }
    if ($Opt['PauseUpdates']) { $tables += $PauseRegs }
    foreach ($t in $tables) { [void]$set.Add((ConvertTo-FullRegPath $t.Path) + '|' + $t.Name) }
    if ($Opt['MouseAccel']) {
        foreach ($p in 'HKEY_CURRENT_USER\Control Panel\Mouse', 'HKEY_USERS\.DEFAULT\Control Panel\Mouse') {
            foreach ($n in 'MouseSensitivity', 'MouseSpeed', 'MouseThreshold1', 'MouseThreshold2', 'SmoothMouseXCurve', 'SmoothMouseYCurve') { [void]$set.Add("$p|$n") }
        }
        foreach ($n in 'Win8DpiScaling', 'LogPixels', 'EnablePerProcessSystemDPI') { [void]$set.Add("HKEY_CURRENT_USER\Control Panel\Desktop|$n") }
    }
    return , $set
}

function Test-HealthRegistry {
    $ops = ConvertFrom-RegText -Text $UpstreamRegText
    $later = Get-LaterOverrideKeys
    $checked = 0; $overridden = 0; $bad = [System.Collections.Generic.List[string]]::new(); $runEntries = 0
    $gated = Get-GatedRegOptions
    foreach ($g in $gated.Keys) { Write-Health 'INFO' 'Registry' "$g is not applied on this PC: $($gated[$g])." }
    foreach ($op in $ops) {
        $optName = Get-RegOpOption $op
        if (-not $Opt[$optName]) { continue }
        if ($gated.ContainsKey($optName)) { continue }
        if (Test-NameMatch $op.Group $SkipRegGroup) { continue }
        $full = ConvertTo-FullRegPath $op.Path
        if ($op.Action -ne 'DeleteKey' -and $later.Contains("$full|$($op.Name)")) { $overridden++; continue }
        $checked++
        switch ($op.Action) {
            'Set' {
                $snap = Get-RegSnapshot -Full $full -Name $op.Name
                if (-not (Test-RegMatchesOp -Snap $snap -Op $op)) {
                    if ($WindowsRewrittenValues -contains "$full|$($op.Name)") {
                        Write-Health 'INFO' 'Registry' "$full\$(Show-RegName $op.Name) is $(Format-RegValueShort $snap): Windows resets this value itself."
                    }
                    else { $bad.Add(('[{0}] {1}\{2} is {3}' -f $op.Group, $full, (Show-RegName $op.Name), (Format-RegValueShort $snap))) }
                }
            }
            'DeleteValue' {
                if ((Get-RegSnapshot -Full $full -Name $op.Name).Existed) { $bad.Add("[$($op.Group)] $full\$($op.Name) is still present") }
            }
            'DeleteKey' {
                $k = Open-RegKey -Full $full
                if ($k) {
                    $n = @($k.GetValueNames()).Count
                    $k.Close()
                    if ($optName -eq 'RunKeys') { $runEntries += $n } else { $bad.Add("[$($op.Group)] $full still exists") }
                }
            }
        }
    }
    if ($bad.Count -eq 0) { Write-Health 'PASS' 'Registry' "Upstream registry import: all $checked item(s) match." }
    else {
        Write-Health 'WARN' 'Registry' "Upstream registry import: $($checked - $bad.Count) of $checked match, $($bad.Count) differ (protected keys, other user profiles, or Windows rewrote them). First: $($bad[0])"
        foreach ($b in $bad) { Add-Content -Path $LogFile -Value "          differs: $b" }
    }
    if ($overridden -gt 0) { Write-Health 'INFO' 'Registry' "$overridden upstream registry item(s) are set again by a later step (telemetry, update or mouse options) and are verified there." }
    if ($Opt['RunKeys']) {
        if ($runEntries -eq 0) { Write-Health 'PASS' 'Registry' 'Startup Run keys are clear.' }
        else { Write-Health 'INFO' 'Registry' "$runEntries startup entr(ies) were added to the Run keys since the cleanup. This is expected after installing software." }
    }
    if ($Opt['TelemetryPolicy']) { Test-HealthTweakTable -Label 'Telemetry policy' -Tweaks $TelemetryRegs }
    if ($Opt['Registry']) { Test-HealthTweakTable -Label 'Last access time off' -Tweaks $LastAccessRegs }
    if ($Opt['BiometricsPolicy']) { Test-HealthTweakTable -Label 'Biometrics policy' -Tweaks $BiometricsRegs }
    if ($Opt['DriverExclusion']) { Test-HealthTweakTable -Label 'Driver exclusion' -Tweaks $DriverExclusionRegs }
    if ($Opt['SecurityUpdatesOnly'] -and -not $Opt['PauseUpdates']) { Test-HealthTweakTable -Label 'Update deferral' -Tweaks $SecurityUpdatesRegs }
    if ($Opt['PauseUpdates']) {
        $deferDays = [Math]::Min($PauseDays, 365)
        $effective = foreach ($t in $PauseRegs) {
            $v = $t.Value
            if ($t.Name -in 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdatesPeriodInDays') { $v = $deferDays }
            New-Tweak $t.Path $t.Name $v $t.Type
        }
        Test-HealthTweakTable -Label 'Update pause policy' -Tweaks @($effective)
    }
    if ($Opt['DefenderQuiet']) { Test-HealthTweakTable -Label 'Quiet Defender policy' -Tweaks $DefenderQuietRegs }
    if ($Opt['SpectreMeltdownOff']) { Test-HealthTweakTable -Label 'Spectre and Meltdown mitigations off' -Tweaks $MitigationRegs }
    if ($Opt['TimerResolution'] -and -not (Get-TimerSkipReasonHere)) { Test-HealthTweakTable -Label 'Global timer resolution requests' -Tweaks $TimerGlobalRegs }
    if ($Opt['NetAdapterPower'] -or $Opt['NetAdapterEee']) {
        $keywords = @(); if ($Opt['NetAdapterPower']) { $keywords += $NetPowerKeywords }; if ($Opt['NetAdapterEee']) { $keywords += $NetEeeKeywords }
        $net = @(Get-NetAdapterTweaks -Keywords $keywords -AllowOff:([bool]$Opt['NetAdapterPower']))
        if ($net.Count -gt 0) { Test-HealthTweakTable -Label 'Network adapter power settings' -Tweaks $net }
        else { Write-Health 'INFO' 'Registry' 'No physical network adapter keys were found, so the adapter power settings could not be checked.' }
    }
    # Device lists change when hardware is added, so only the values the run itself recorded are checked.
    $recorded = { param($list) @($list | Where-Object { $script:RecordedReg.Contains("$(ConvertTo-FullRegPath $_.Path)|$($_.Name)") }) }
    if ($Opt['DevicePowerSaving']) {
        $dev = @(& $recorded @(Get-DeviceTweaks -Power))
        if ($dev.Count -gt 0) { Test-HealthTweakTable -Label 'Device power saving' -Tweaks $dev }
        else { Write-Health 'INFO' 'Registry' 'Device power saving: no recorded values (skipped on battery, or not run yet).' }
    }
    if ($Opt['DeviceWakeOff']) {
        $wake = @(& $recorded @(Get-DeviceTweaks -Wake))
        if ($wake.Count -gt 0) { Test-HealthTweakTable -Label 'Device wake' -Tweaks $wake }
    }
    if ($Opt['WriteCacheFlushOff']) {
        $cache = @(& $recorded @(Get-WriteCacheTweaks))
        if ($cache.Count -gt 0) { Test-HealthTweakTable -Label 'Write cache buffer flushing off' -Tweaks $cache }
    }
    if ($Opt['MpoOff']) { Test-HealthTweakTable -Label 'Multiplane overlay off' -Tweaks $MpoRegs }
    if ($Opt['FastShutdown']) { Test-HealthTweakTable -Label 'Faster shutdown' -Tweaks $FastShutdownRegs }
    if ($Opt['BlockFeatureUpgrades']) { Test-HealthTweakTable -Label 'Feature upgrade block' -Tweaks @(Get-FeatureUpgradeTweaks) }
    if ($Opt['TimeServerPool']) {
        Test-HealthTweakTable -Label 'Time server' -Tweaks $TimeServerRegs
        # Without this task the time service is never started on a PC outside a domain, so the server setting is moot.
        if (Get-ScheduledTask -TaskPath $TimeSyncTask.Path -TaskName $TimeSyncTask.Name -ErrorAction SilentlyContinue) {
            Write-Health 'PASS' 'System' 'Time sync task is present, so the clock is kept in sync.'
        }
        else { Write-Health 'WARN' 'System' "Time sync task $($TimeSyncTask.Path)$($TimeSyncTask.Name) is missing, so the clock is not synced. Restore it from the task backups or with -Revert." }
    }
    if ($Opt['MenuKillNotResponding']) { Test-HealthTweakTable -Label 'Kill not responding menu' -Tweaks $MenuKillRegs }
    if ($Opt['MenuRestartExplorer']) { Test-HealthTweakTable -Label 'Restart Explorer menu' -Tweaks $MenuRestartExplorerRegs }
    if ($Opt['MenuTakeOwnership']) { Test-HealthTweakTable -Label 'Take ownership menu' -Tweaks $MenuTakeOwnershipRegs }
    if ($Opt['MenuRunAsAdmin']) { Test-HealthTweakTable -Label 'Run as administrator menu' -Tweaks $MenuRunAsAdminRegs }
    foreach ($m in $MenuBlocks.Keys) { if ($Opt[$m]) { Test-HealthTweakTable -Label "Right click menu ($m)" -Tweaks $MenuBlocks[$m] } }
    if ($Opt['LockScreenOff']) { Test-HealthTweakTable -Label 'Lock screen off' -Tweaks $LockScreenRegs }
    if ($Opt['NvmeNativeDriver']) { Test-HealthTweakTable -Label 'Native NVMe driver' -Tweaks $NvmeRegs }
}

function Test-HealthHosts {
    $text = [IO.File]::ReadAllText($HostsPath)
    $expected = @()
    if ($Opt['TelemetryHosts']) { $expected += , @('telemetry', $TelemetryDomains) }
    if ($Opt['RazerAsusHosts']) { $expected += , @('razer-asus', @($RazerDomains + $AsusDomains)) }
    foreach ($e in $expected) {
        $n = [regex]::Escape($e[0])
        $m = [regex]::Match($text, "(?ms)^# FocusedTweaks BEGIN $n\r?\n(.*?)^# FocusedTweaks END $n")
        if (-not $m.Success) { Write-Health 'FAIL' 'Hosts' "Block '$($e[0])' is missing from the hosts file (security software may have reverted it)."; continue }
        $count = ([regex]::Matches($m.Groups[1].Value, '(?m)^0\.0\.0\.0 ')).Count
        if ($count -eq @($e[1]).Count) { Write-Health 'PASS' 'Hosts' "Block '$($e[0])' is present with $count entries." }
        else { Write-Health 'WARN' 'Hosts' "Block '$($e[0])' has $count entries, expected $(@($e[1]).Count)." }
    }
    $blockedAddr = '0.0.0.0', '127.0.0.1', '::', '::1'
    $resolve = {
        param($h)
        try { @([System.Net.Dns]::GetHostAddresses($h) | ForEach-Object { $_.ToString() }) } catch { @() }
    }
    if ($Opt['TelemetryHosts']) {
        $answer = @(& $resolve $TelemetryDomains[0])
        if ($answer.Count -gt 0 -and @($answer | Where-Object { $blockedAddr -notcontains $_ }).Count -eq 0) { Write-Health 'PASS' 'Hosts' "$($TelemetryDomains[0]) resolves to $($answer[0]), so the block is in effect." }
        elseif ($answer.Count -gt 0) { Write-Health 'WARN' 'Hosts' "$($TelemetryDomains[0]) still resolves to $($answer[0]). The DNS cache, a VPN or secure DNS may bypass the hosts file." }
    }
    $must = 'login.live.com', 'www.microsoft.com', 'displaycatalog.mp.microsoft.com', 'licensing.mp.microsoft.com', 'user.auth.xboxlive.com'
    $blocked = @(); $silent = 0
    foreach ($h in $must) {
        $a = @(& $resolve $h)
        if ($a.Count -eq 0) { $silent++ }
        elseif (@($a | Where-Object { $blockedAddr -contains $_ }).Count -gt 0) { $blocked += $h }
    }
    if ($blocked.Count -gt 0) { Write-Health 'FAIL' 'Hosts' "Store or Xbox sign in hosts are blocked: $($blocked -join ', ')." }
    elseif ($silent -eq $must.Count) { Write-Health 'INFO' 'Hosts' 'No DNS answers for the Store and Xbox hosts (offline?), so they could not be checked.' }
    else { Write-Health 'PASS' 'Hosts' 'Store and Xbox sign in hosts resolve normally.' }
}

function Test-HealthTasks {
    switch ($TaskMode) {
        'Delete' {
            $deleted = @($script:State.Tasks | Where-Object { $_.Action -eq 'Deleted' })
            $missing = @($deleted | Where-Object { -not $_.XmlFile -or -not (Test-Path -LiteralPath $_.XmlFile) })
            Write-Health 'INFO' 'Tasks' "$($deleted.Count) scheduled task(s) deleted, $(@(Get-ScheduledTask).Count) remain."
            if ($missing.Count -gt 0) { Write-Health 'FAIL' 'Tasks' "$($missing.Count) deleted task(s) have no backup XML, so -Revert cannot restore them." }
            elseif ($deleted.Count -gt 0) { Write-Health 'PASS' 'Tasks' 'Every deleted task has a backup XML, so -Revert can restore it.' }
        }
        'Disable' { Write-Health 'INFO' 'Tasks' "$(@($script:State.Tasks | Where-Object { $_.Action -eq 'Disabled' }).Count) telemetry task(s) disabled." }
        default { Write-Health 'INFO' 'Tasks' 'Scheduled tasks were left untouched.' }
    }
    if ($Opt['PauseUpdates'] -and $Opt['PauseStopsUpdateTasks']) {
        $active = @()
        foreach ($p in $UpdateTaskPaths) { $active += @(Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' } | ForEach-Object { $_.TaskName }) }
        if ($active.Count -eq 0) { Write-Health 'PASS' 'Tasks' 'Update Orchestrator, WaaSMedic and Windows Update tasks are disabled or gone.' }
        else { Write-Health 'WARN' 'Tasks' "$($active.Count) update task(s) are still active: $((@($active) | Select-Object -First 4) -join ', ')." }
    }
}

function Test-HealthUpdates {
    if ($Opt['PauseUpdates']) {
        $p = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesExpiryTime'
        $expiry = [DateTime]::MinValue
        if ($p.Existed -and [DateTime]::TryParse([string]$p.Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$expiry)) {
            $left = [int][Math]::Floor(($expiry - [DateTime]::UtcNow).TotalDays)
            if ($left -lt 0) { Write-Health 'WARN' 'Updates' "The update pause ended $(-$left) day(s) ago. Updates are running again. Run the script again to pause."; }
            elseif ($left -le 14) { Write-Health 'WARN' 'Updates' "The update pause ends in $left day(s) ($($expiry.ToString('yyyy-MM-dd'))). Run the script again to extend it." }
            else { Write-Health 'PASS' 'Updates' "Updates are paused for another $left day(s) (until $($expiry.ToString('yyyy-MM-dd')))." }
        }
        else { Write-Health 'WARN' 'Updates' 'The pause expiry value is missing, so updates are not paused.' }
    }
    $hot = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1)
    if ($hot.Count -gt 0) {
        $age = [int]((Get-Date) - [DateTime]$hot[0].InstalledOn).TotalDays
        if ($Opt['PauseUpdates'] -or $Opt['SecurityUpdatesOnly']) { Write-Health 'INFO' 'Updates' "Last Windows update was installed $age day(s) ago ($($hot[0].HotFixID)). Updates are restricted by your settings." }
        elseif ($age -gt 60) { Write-Health 'WARN' 'Updates' "Last Windows update was installed $age day(s) ago, and updates are not restricted. Check Windows Update." }
        else { Write-Health 'PASS' 'Updates' "Last Windows update was installed $age day(s) ago." }
    }
}

function Test-HealthDefender {
    $st = $null
    try { $st = Get-MpComputerStatus -ErrorAction Stop } catch { }
    if (-not $st) { Write-Health 'WARN' 'Defender' 'Defender status is not available (another antivirus may be registered).'; return }
    $rt = $false
    if ($st.PSObject.Properties['RealTimeProtectionEnabled']) { $rt = [bool]$st.RealTimeProtectionEnabled }
    if ($Defender -eq 'Disable') {
        if (-not $rt) { Write-Health 'WARN' 'Defender' 'Real time protection is off, as you chose. Windows may switch it back on after updates.' }
        else { Write-Health (Get-RuntimeStatus) 'Defender' 'Real time protection is still on although you chose to disable it.' }
    }
    elseif ($rt) { Write-Health 'PASS' 'Defender' 'Real time protection is on.' }
    else { Write-Health 'WARN' 'Defender' 'Real time protection is off. If you did not choose that, run with -Defender Enable.' }

    if ($Opt['DefenderQuiet']) {
        $pref = Get-MpPreference -ErrorAction Stop
        if ([int]$pref.MAPSReporting -eq 0 -and [int]$pref.SubmitSamplesConsent -eq 2) { Write-Health 'PASS' 'Defender' 'Cloud reporting is off and sample submission is set to never send.' }
        else { Write-Health 'WARN' 'Defender' "Defender still reports to the cloud (MAPSReporting $($pref.MAPSReporting), SubmitSamplesConsent $($pref.SubmitSamplesConsent)). Tamper Protection can block the policy; turn it off and run again." }
    }

    if ($st.PSObject.Properties['AntivirusSignatureLastUpdated'] -and $st.AntivirusSignatureLastUpdated) {
        $age = [int]((Get-Date) - [DateTime]$st.AntivirusSignatureLastUpdated).TotalDays
        if ($rt -and $age -gt 7) {
            $predates = $script:AppliedAt -and ($age -gt (((Get-Date) - $script:AppliedAt).TotalDays + 1))
            $excluded = ($Opt['SecurityUpdatesOnly'] -or $Opt['PauseUpdates']) -and -not $Opt['KeepDefinitionUpdates']
            $why = if ($predates) { ' That is older than this run, so the base image was already out of date.' } else { '' }
            if ($excluded) { $why += ' Your update options also exclude definition updates, so Windows Update will not refresh them.' }
            Write-Health 'WARN' 'Defender' "Signatures are $age day(s) old.$why Fix: Update-MpSignature, or run again with -Enable KeepDefinitionUpdates."
        }
        else { Write-Health 'PASS' 'Defender' "Signatures were updated $age day(s) ago." }
    }
}

function Test-HealthSystem {
    if ($Opt['Uac']) {
        $s = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
        if ($s.Existed -and [int]$s.Value -eq 0) {
            if ($script:SoftRuntime) { Write-Health 'INFO' 'System' 'UAC is set to off. It takes effect after a restart, and some Store apps behave differently without it.' }
            else { Write-Health 'PASS' 'System' 'UAC is off (EnableLUA 0, active since the last restart).' }
        }
        else { Write-Health 'WARN' 'System' 'UAC was meant to be off but EnableLUA is not 0.' }
    }
    if ($PowerProfile -ne 'Off' -and -not (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)) {
        $active = (powercfg /getactivescheme) | Out-String
        if ($active -match [regex]::Escape($PowerPlanBase)) { Write-Health 'PASS' 'System' "Active power plan is '$PowerPlanBase ($PowerProfile)'." }
        else { Write-Health 'WARN' 'System' "The tweaked power plan is not active. Current: $($active.Trim())" }
    }
    if ($Opt['DisableHibernate'] -or $Opt['RegHibernateOff']) {
        $h = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
        if ($h.Existed -and [int]$h.Value -eq 0) { Write-Health 'PASS' 'System' 'Hibernation is off.' } else { Write-Health (Get-RuntimeStatus) 'System' 'Hibernation is still on.' }
    }
    if ($Opt['MemoryCompression']) {
        $ram = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
        if (Test-MemoryCompressionTarget -RamGB $ram) {
            if (-not (Get-MMAgent).MemoryCompression) { Write-Health 'PASS' 'System' 'Memory compression is off.' }
            else { Write-Health 'INFO' 'System' 'Memory compression is still on. It changes after a restart.' }
        }
    }
    if ($Opt['SleepStudy']) {
        $on = @($SleepStudyLogs | Where-Object { ((& wevtutil.exe gl $_) | Out-String) -match 'enabled:\s*true' })
        if ($on.Count -eq 0) { Write-Health 'PASS' 'System' 'Sleep Study and power diagnostic logs are off.' } else { Write-Health 'WARN' 'System' "$($on.Count) power diagnostic log(s) are still enabled." }
    }
    if (($Opt['NvidiaProfile'] -or $Opt['NvidiaReBar']) -and (Test-NvidiaGpu)) {
        # Profile Inspector has no command to read settings back, so compare the driver database with the backup.
        $backup = Join-Path $StateDir 'nvidia-drs'
        $changed = @(Get-ChildItem -LiteralPath $backup -Filter 'nvdrsdb*.bin' -File -ErrorAction SilentlyContinue | Where-Object {
                $live = Join-Path $NvidiaDrsDir $_.Name
                (Test-Path -LiteralPath $live) -and (Get-FileHash -LiteralPath $live).Hash -ne (Get-FileHash -LiteralPath $_.FullName).Hash
            })
        if ($script:State.NvidiaDrs -ne $true) { Write-Health 'WARN' 'NVIDIA' 'The NVIDIA profile was not imported (no backup of the driver settings was taken). Check the run log.' }
        elseif ($changed.Count -gt 0) { Write-Health 'PASS' 'NVIDIA' 'The NVIDIA global profile was imported (driver settings differ from the backup). Open Profile Inspector to see the values.' }
        else { Write-Health 'WARN' 'NVIDIA' 'The NVIDIA driver settings are identical to the backup, so the import did not take, or was undone.' }
    }
    foreach ($g in $FeatureGroups.Keys) {
        if (-not $Opt[$g]) { continue }
        $still = @(Get-EnabledFeatureNames -Names $FeatureGroups[$g])
        if ($still.Count -eq 0) { Write-Health 'PASS' 'System' "$g`: none of the listed optional features is turned on." }
        else { Write-Health 'WARN' 'System' "$g`: still turned on: $($still -join ', '). A restart may be pending." }
    }
    $svcChecks = [ordered]@{}
    if ($Opt['TelemetryPolicy']) { $svcChecks['Telemetry services'] = $TelemetryServices }
    if ($Opt['Cdp']) { $svcChecks['Connected Devices Platform services'] = $CdpServices }
    foreach ($label in $svcChecks.Keys) {
        $present = @($svcChecks[$label] | Where-Object { $null -ne (Get-ServiceStartNow $_) })
        $on = @($present | Where-Object { (Get-ServiceStartNow $_) -ne 4 })
        if ($present.Count -eq 0) { continue }
        if ($on.Count -eq 0) { Write-Health 'PASS' 'Services' "$label are disabled: $($present -join ', ')." }
        else { Write-Health 'WARN' 'Services' "$label are not disabled: $($on -join ', ')." }
    }
    if ($Opt['NotificationSettings']) {
        # Only the apps the run switched off: apps installed since then were never touched.
        $root = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
        $touched = @($script:RecordedReg | Where-Object { $_ -like "$root\*|Enabled" } | ForEach-Object { $_.Substring(0, $_.Length - '|Enabled'.Length) })
        $back = @($touched | Where-Object { $s = Get-RegSnapshot -Full $_ -Name 'Enabled'; -not ($s.Existed -and [int]$s.Value -eq 0) })
        if ($touched.Count -eq 0) { Write-Health 'INFO' 'System' 'No app notifications were switched off by a run, so there is nothing to check.' }
        elseif ($back.Count -eq 0) { Write-Health 'PASS' 'System' "Notifications are off for the $($touched.Count) app(s) the run switched off." }
        else { Write-Health 'WARN' 'System' "Notifications are back on for $($back.Count) of $($touched.Count) app(s), first: $(Split-Path $back[0] -Leaf)." }
    }
    if ($script:State.PowerOverlaySet) {
        # powercfg sets the overlay of the power source active at the time, so either the AC or the DC value counts.
        $want = @($PowerOverlayNames.Keys | Where-Object { $PowerOverlayNames[$_] -eq $script:State.PowerOverlaySet })[0]
        $schemes = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
        $now = foreach ($n in 'ActiveOverlayAcPowerScheme', 'ActiveOverlayDcPowerScheme') {
            $s = Get-RegSnapshot -Full $schemes -Name $n
            if ($s.Existed -and $s.Value) { ([string]$s.Value).ToLowerInvariant() } else { '00000000-0000-0000-0000-000000000000' }
        }
        if (@($now) -contains $want) { Write-Health 'PASS' 'Power' "Power mode is $($script:State.PowerOverlaySet), as the run set it." }
        else { Write-Health 'WARN' 'Power' "Power mode is no longer $($script:State.PowerOverlaySet) (Settings or the laptop's own power tool may have changed it)." }
    }
    if ($Opt['PasswordExpiry'] -and [Environment]::OSVersion.Version.Build -gt 19045) {
        $age = Get-MaxPasswordAge
        if ($age -eq 'unlimited') { Write-Health 'PASS' 'System' 'Local passwords never expire.' }
        else { Write-Health 'WARN' 'System' "Local passwords still expire after $age days." }
    }
    if ($Opt['MsiMode']) {
        $display = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)
        $off = @($display | Where-Object {
                $s = Get-RegSnapshot -Full "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" -Name 'MSISupported'
                -not ($s.Existed -and [int]$s.Value -eq 1)
            })
        if ($display.Count -eq 0) { Write-Health 'INFO' 'System' 'No display adapter found, so MSI mode could not be checked.' }
        elseif ($off.Count -eq 0) { Write-Health 'PASS' 'System' "MSI interrupts are on for $($display.Count) display adapter(s)." }
        else { Write-Health 'WARN' 'System' "MSI interrupts are off for: $(($off | ForEach-Object { $_.FriendlyName }) -join ', ')." }
    }
    if ($Opt['MouseAccel']) {
        $m = Get-RegSnapshot -Full 'HKEY_CURRENT_USER\Control Panel\Mouse' -Name 'MouseSpeed'
        $d = Get-RegSnapshot -Full 'HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics' -Name 'AppliedDPI'
        $scale = if ($d.Existed) { [int]([Math]::Round(([int]$d.Value / 96) * 100)) } else { 100 }
        $want = $MouseProfiles[$scale]
        if ($want -and $m.Existed -and [string]$m.Value -eq $want.Speed) { Write-Health 'PASS' 'System' "Mouse profile for $scale% scaling is in place." }
        elseif ($want) { Write-Health 'WARN' 'System' "Mouse acceleration settings do not match the $scale% profile. Display scaling may have changed, run the script again." }
    }
    if ($Opt['ClearDesktopIcons']) {
        $shortcuts = @(foreach ($d in Get-DesktopFolders) { Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.Extension -in '.lnk', '.url' } })
        $bin = Get-RegSnapshot -Full 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Name '{645FF040-5081-101B-9F08-00AA002F954E}'
        if ($shortcuts.Count -eq 0 -and $bin.Existed -and [int]$bin.Value -eq 1) { Write-Health 'PASS' 'System' 'Desktop is clear: system icons hidden and no shortcuts on it.' }
        else { Write-Health 'INFO' 'System' "Desktop has $($shortcuts.Count) shortcut(s) again. This is normal after installing software, which adds its own." }
    }
    if ($Opt['ClearStartPins'] -and [Environment]::OSVersion.Version.Build -gt 19045) {
        $f = Join-Path $script:StartLayoutDir 'start2.bin'
        if (Test-Path -LiteralPath $f) {
            $want = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Convert]::FromBase64String(($EmptyStartLayout -join ''))))
            $have = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($f)))
            if ($want -eq $have) { Write-Health 'PASS' 'System' 'Start menu pins are cleared.' }
            else { Write-Health 'INFO' 'System' 'Start pins were cleared, but Windows rewrites the layout file once Start reloads, so this cannot be confirmed automatically. Open Start to check.' }
        }
    }
    if ($Opt['RemoveQuickAssist']) {
        $qa = @(Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*QuickAssist*' })
        if ($qa.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $env:windir 'System32\quickassist.exe'))) { Write-Health 'PASS' 'System' 'Quick Assist is removed.' }
        else { Write-Health 'WARN' 'System' 'Quick Assist is still present. A restart may finish the removal.' }
    }
    if ($Opt['DepOff']) {
        $nx = Get-BcdValue 'nx'
        if ($nx -eq 'AlwaysOff') { Write-Health 'PASS' 'System' 'Data Execution Prevention is off in the boot configuration (nx AlwaysOff).' }
        else { Write-Health 'WARN' 'System' "Data Execution Prevention is not off (nx is $(if ($nx) { $nx } else { 'not set' })). Secure Boot must be off for bcdedit to accept the change." }
    }
    if ($Opt['IPv4Only']) {
        $v6 = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { Get-NetAdapterBinding -Name $_.Name -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue } | Where-Object { $_.Enabled })
        if ($v6.Count -eq 0) { Write-Health 'PASS' 'System' 'IPv6 is off on every physical network adapter.' }
        else { Write-Health 'WARN' 'System' "IPv6 is still on for: $(@($v6 | ForEach-Object { $_.Name }) -join ', ')." }
    }
    if ($Opt['SearchIndexingOff']) {
        if ((Get-ServiceStartNow 'WSearch') -eq 4) { Write-Health 'PASS' 'System' 'Windows Search indexing is disabled.' }
        else { Write-Health 'WARN' 'System' 'Windows Search indexing was meant to be disabled, but the WSearch service is not.' }
    }
    $timerSkip = $null
    if ($Opt['TimerResolution']) { $timerSkip = Get-TimerSkipReasonHere }
    if ($timerSkip) { Write-Health 'INFO' 'System' "Timer resolution service not installed on this PC: $timerSkip." }
    elseif ($Opt['TimerResolution']) {
        $svc = Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { Write-Health 'PASS' 'System' "Timer resolution service '$TimerServiceName' is running." }
        elseif ($svc) { Write-Health 'WARN' 'System' "Timer resolution service '$TimerServiceName' is installed but $($svc.Status)." }
        else { Write-Health 'WARN' 'System' "Timer resolution service '$TimerServiceName' is not installed." }
    }
    if ((Test-RebootPending) -or $script:SoftRuntime) { Write-Health 'INFO' 'System' 'A restart is pending or needed, so some results above show the state before it.' }
}

function Test-HealthEvents {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Level = 2; StartTime = $boot } -ErrorAction SilentlyContinue)
    if ($events.Count -eq 0) { Write-Health 'PASS' 'Events' "No service errors since the last start ($($boot.ToString('yyyy-MM-dd HH:mm')))."; return }
    $tiPattern = 'Windows Modules Installer|TrustedInstaller'
    $own = @($events | Where-Object { $_.Message -match $tiPattern })
    $other = @($events | Where-Object { $_.Message -notmatch $tiPattern })
    if ($own.Count -gt 0) {
        if ($script:TiCount -gt 0) {
            Write-Health 'INFO' 'Events' "$($own.Count) Windows Modules Installer service error(s) (7000, 7009, 7031) come from this script's TrustedInstaller helper, used $($script:TiCount) time(s) in this run. This is expected and harmless."
        }
        else {
            Write-Health 'WARN' 'Events' "$($own.Count) Windows Modules Installer service error(s) since the last start. If you ran this script since the last restart they come from its TrustedInstaller helper and are harmless. Otherwise Windows servicing may have a problem."
        }
    }
    if ($other.Count -eq 0) { return }
    $top = $other | Group-Object { '{0}: {1}' -f $_.Id, (($_.Message -split "`r?`n")[0]) } | Sort-Object Count -Descending | Select-Object -First 5
    Write-Health 'WARN' 'Events' "$($other.Count) service error(s) since the last start. A disabled service that something depends on is the usual cause."
    foreach ($t in $top) { Write-Health 'INFO' 'Events' ("{0}x {1}" -f $t.Count, $t.Name.Substring(0, [Math]::Min(150, $t.Name.Length))) }
}

function Test-HealthAppLaunch {
    # Best effort: opens each app, waits for its process, then closes it again.
    $apps = @(
        @{ Name = 'Settings'; Uri = 'ms-settings:'; Process = 'SystemSettings'; Package = $null },
        @{ Name = 'Microsoft Store'; Uri = 'ms-windows-store:'; Process = 'WinStore.App'; Package = 'Microsoft.WindowsStore' },
        @{ Name = 'Photos'; Uri = 'ms-photos:'; Process = 'Photos'; Package = 'Microsoft.Windows.Photos' },
        @{ Name = 'Paint'; Uri = 'ms-paint:'; Process = 'mspaint'; Package = 'Microsoft.Paint' },
        @{ Name = 'Xbox'; Uri = 'xbox:'; Process = 'XboxPcApp'; Package = 'Microsoft.GamingApp' }
    )
    foreach ($a in $apps) {
        if ($a.Package -and -not (Get-AppxPackage -Name $a.Package -ErrorAction SilentlyContinue)) { Write-Health 'INFO' 'Launch' "$($a.Name) is not installed, skipped."; continue }
        $wasRunning = [bool](Get-Process -Name $a.Process -ErrorAction SilentlyContinue)
        Start-Process $a.Uri
        $up = $false
        for ($i = 0; $i -lt 30 -and -not $up; $i++) { Start-Sleep -Milliseconds 500; $up = [bool](Get-Process -Name $a.Process -ErrorAction SilentlyContinue) }
        if ($up) { Write-Health 'PASS' 'Launch' "$($a.Name) opened." }
        else { Write-Health 'WARN' 'Launch' "$($a.Name) did not start within 15 seconds (or its process name differs on this build)." }
        if ($up -and -not $wasRunning) { Start-Sleep -Seconds 1; Stop-Process -Name $a.Process -Force -ErrorAction SilentlyContinue }
    }
}

function Test-HealthEdition {
    # The registry checks above only prove a value is set. This says which policy values the edition does not honour.
    $edition = Get-EditionId
    $gaps = @(Get-EditionReport -Edition $edition)
    $notApplicable = @($gaps | Where-Object { $_.Verdict -eq 'not applicable' })
    foreach ($gap in $notApplicable) {
        Write-Health 'INFO' 'Edition' "$($gap.Path)\$($gap.Name) is not applicable on this edition ($edition): it is honoured on $($gap.Honoured) only, so Windows ignores it even though the registry value is set."
    }
    $unknown = $gaps.Count - $notApplicable.Count
    if ($unknown -gt 0) { Write-Health 'INFO' 'Edition' "$unknown policy value(s) have no confirmed effect on this edition ($edition). A matching registry value does not prove that Windows applies them." }
    if ($gaps.Count -eq 0) { Write-Health 'PASS' 'Edition' "Every policy value the options write is honoured on this edition ($edition)." }
}

function Restore-SavedRunSettings {
    # Standalone checks judge the state against the options used for the last run.
    $run = $script:State.Run
    if (-not $run) { Write-Log 'No saved run found, checking against the defaults and the options you passed now.' 'WARN'; return }
    foreach ($p in $run.Options.PSObject.Properties) { if ($Opt.ContainsKey($p.Name)) { $Opt[$p.Name] = [bool]$p.Value } }
    if ($run.TaskMode) { $script:TaskMode = $run.TaskMode }
    if ($run.Defender) { $script:Defender = $run.Defender }
    if ($run.PowerProfile) { $script:PowerProfile = $run.PowerProfile }
    if ($run.PauseDays) { $script:PauseDays = [int]$run.PauseDays }
    if ($run.SkipRegGroup) { $script:SkipRegGroup = @($run.SkipRegGroup) }
    Write-Log "Using the options saved from the run on $($run.When)."
}

function Save-ResultJson {
    # Results as JSON next to the log, so tools/Test-InVm.ps1 can summarise a run without parsing log text.
    param([string]$Kind, [hashtable]$Counts, [object[]]$Items)
    $file = Join-Path $StateDir ('{0}-{1:yyyyMMdd-HHmmss}.json' -f $Kind, (Get-Date))
    $data = [pscustomobject]@{ When = (Get-Date).ToString('o'); Build = [Environment]::OSVersion.Version.Build; Counts = $Counts; Items = @($Items) }
    ConvertTo-Json -InputObject $data -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
}

function Invoke-HealthCheck {
    $script:Health = @{ PASS = 0; WARN = 0; FAIL = 0; INFO = 0 }
    $script:HealthItems.Clear()
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $applied = $null
    if ($script:State.Run -and $script:State.Run.When) {
        $w = $script:State.Run.When
        try { $applied = if ($w -is [DateTime]) { $w } else { [DateTime]::Parse([string]$w, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } } catch { }
    }
    $script:AppliedAt = $applied
    $script:SoftRuntime = $script:PostApply -or ($applied -and $boot -lt $applied)
    Write-Log "Health check starting$(if ($script:SoftRuntime) { ' (no restart since the tweaks, so runtime state may lag)' })."

    Invoke-HealthArea 'Services' { Test-HealthServices }
    Invoke-HealthArea 'Apps' { Test-HealthApps }
    Invoke-HealthArea 'Registry' { Test-HealthRegistry }
    Invoke-HealthArea 'Edition' { Test-HealthEdition }
    Invoke-HealthArea 'Hosts' { Test-HealthHosts }
    Invoke-HealthArea 'Tasks' { Test-HealthTasks }
    Invoke-HealthArea 'Updates' { Test-HealthUpdates }
    Invoke-HealthArea 'Defender' { Test-HealthDefender }
    Invoke-HealthArea 'System' { Test-HealthSystem }
    Invoke-HealthArea 'Events' { Test-HealthEvents }
    if ($HealthCheckLaunch) { Invoke-HealthArea 'Launch' { Test-HealthAppLaunch } }

    $h = $script:Health
    Write-Log ("Health result: {0} passed, {1} warning(s), {2} failed, {3} note(s)." -f $h.PASS, $h.WARN, $h.FAIL, $h.INFO) $(if ($h.FAIL -gt 0) { 'ERROR' } elseif ($h.WARN -gt 0) { 'WARN' } else { 'OK' })
    if ($h.FAIL -gt 0) { Write-Log 'Failures mean something you asked to keep is broken. Undo one item with -Skip <Option>, or everything with -Revert.' 'ERROR' }
    if (-not $HealthCheckLaunch) { Write-Log 'Add -HealthCheckLaunch to also open Settings, Store, Photos, Paint and Xbox and confirm they start.' }
    if (-not $script:DryRun) { Save-ResultJson -Kind 'health' -Counts $h -Items $script:HealthItems.ToArray() }
}

function Test-RevertResult {
    # Proves -Revert worked: every recorded registry value must be back to what it was before the first run, deleted
    # tasks must exist again, the hosts blocks must be gone and the timer service removed.
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $checked = 0; $rewritten = 0
    foreach ($e in $script:State.Registry) {
        # The first entry per value is the original; later duplicates come from older key spellings.
        if (-not $seen.Add("$($e.Path)|$($e.Name)")) { continue }
        $checked++
        $now = Get-RegSnapshot -Full $e.Path -Name $e.Name
        $was = if ($e.Existed) { '{0} ({1})' -f (@($e.Value) -join ','), $e.Kind } else { '<missing>' }
        $is = if ($now.Existed) { '{0} ({1})' -f (@($now.Value) -join ','), $now.Kind } else { '<missing>' }
        if ($was -eq $is) { continue }
        if ($WindowsRewrittenValues -contains "$($e.Path)|$($e.Name)") {
            $rewritten++
            Add-Content -Path $LogFile -Value "          revert check: [Note] $($e.Path)\$(Show-RegName $e.Name) was $was, is $is (Windows recomputes this value)"
            continue
        }
        $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Registry'; Message = "$($e.Path)\$(Show-RegName $e.Name) was $was, is $is" })
    }
    if ($rewritten -gt 0) { Write-Log "Revert check: $rewritten value(s) Windows recomputes itself (accent colours) differ, as expected." }
    $badReg = $items.Count
    foreach ($t in @($script:State.Tasks)) {
        $now = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if (-not $now) {
            if ($t.Action -eq 'Deleted') { $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Tasks'; Message = "Task not restored: $($t.Path)$($t.Name)" }) }
            continue
        }
        # Disabled by the run and still disabled, although it was enabled before.
        if ($t.WasEnabled -and $now.State -eq 'Disabled') {
            $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Tasks'; Message = "Task still disabled: $($t.Path)$($t.Name)" })
        }
    }
    if ($script:State.Features.Count -gt 0) {
        $states = @{}
        foreach ($f in @(Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue)) { $states[$f.FeatureName] = [string]$f.State }
        foreach ($name in @($script:State.Features)) {
            if ($states[$name] -notin 'Enabled', 'EnablePending') { $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Features'; Message = "Optional feature not back on: $name ($($states[$name]))" }) }
        }
    }
    $hosts = [IO.File]::ReadAllText($HostsPath)
    foreach ($name in $script:State.Hosts) {
        if ($hosts -match "# FocusedTweaks BEGIN $([regex]::Escape($name))") { $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'Hosts'; Message = "Hosts block still present: $name" }) }
    }
    if ($script:State.TimerService -and (Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue)) {
        $items.Add([pscustomobject]@{ Status = 'WARN'; Area = 'System'; Message = "Service $TimerServiceName still exists" })
    }
    foreach ($i in $items) { Add-Content -Path $LogFile -Value "          revert check: [$($i.Area)] $($i.Message)" }
    $level = if ($items.Count -eq 0) { 'OK' } else { 'WARN' }
    Write-Log "Revert check: $($checked - $badReg) of $checked registry value(s) are back to their original, $($items.Count) item(s) differ in total. Details in the log." $level
    Save-ResultJson -Kind 'revert-check' -Counts @{ Checked = $checked; Differ = $items.Count } -Items $items.ToArray()
}
#endregion

#region Orchestration ---------------------------------------------------------------------
# docs/AUDIT.md C-2 and A-08: checks run before a run, each with a name that -SkipCheck accepts.
$PreflightChecks = @('PendingReboot', 'WindowsUpdate', 'PowerSource', 'Managed', 'Edition', 'TamperProtection', 'SystemProtection')

function Test-RebootPending {
    return (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    ($null -ne (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue))
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
                    if ($provider -and $null -ne $state -and [int]$state -eq 1) { $facts.MdmProviders += $provider }
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
    $script:PreflightResults = @(Get-PreflightResults -Facts (Get-PreflightFacts) -Skip $SkipCheck -AllowManaged:$AllowManaged)
    foreach ($p in $script:PreflightResults) {
        $level = switch ($p.Status) { 'WARN' { 'WARN' } 'BLOCK' { 'ERROR' } default { 'INFO' } }
        Write-Log "Pre flight $($p.Check) [$($p.Status)]: $($p.Message)" $level
    }
    $blocks = @($script:PreflightResults | Where-Object { $_.Status -eq 'BLOCK' })
    if ($blocks.Count -eq 0) { return $true }
    if ($script:DryRun) { Write-Log 'A real run would stop here because of the pre flight check(s) above. The dry run goes on.' 'WARN'; return $true }
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
        SecurityUpdatesOnly = $SecurityUpdatesRegs; PauseUpdates = $PauseRegs; DefenderQuiet = $DefenderQuietRegs; LockScreenOff = $LockScreenRegs
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
    Write-Log "Mode: $(if ($script:DryRun) { 'DRY RUN (no changes)' } else { 'APPLY' }). State and logs: $StateDir"
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
    Write-Log "  Tasks: $TaskMode | Defender: $Defender | Power profile: $PowerProfile | Power mode: $PowerMode | Pause days: $PauseDays"
    if ($WantNvidia) { Write-Log "  NVIDIA: $(if ($NvidiaInstaller) { $NvidiaInstaller } else { 'download ' + $(if ($NvidiaVersion) { $NvidiaVersion } else { 'latest' }) })" }
    if ($ProfilePath) { Write-Log "  Profile: $ProfilePath (command line parameters win over it)" }
    $script:UserMismatch = Get-UserMismatch
    if ($script:UserMismatch) { Write-Log $script:UserMismatch 'WARN' }
}

function Confirm-Run {
    if ($Force -or $script:DryRun) { return $true }
    Write-Host ''
    $notes = @()
    if ($Opt['Debloat']) { $notes += 'App debloat cannot be undone by -Revert.' }
    if ($TaskMode -eq 'Delete') { $notes += 'Scheduled tasks will be deleted (backups are kept), except time sync, SSD retrim, TPM, BitLocker, Defender, System Restore, certificate and browser update tasks.' }
    if ($Opt['TempCleanup'] -or $Opt['UpdateCacheCleanup']) { $notes += 'Temp and update cache files are deleted for good.' }
    if ($Opt['SpectreMeltdownOff'] -or $Opt['DepOff']) { $notes += 'CPU and memory security mitigations will be turned off.' }
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
        PowerProfile = $mPower; PauseDays = $mDays; SkipRegGroup = @($mSkip | Select-Object -Unique)
    })
    if ([Environment]::OSVersion.Version.Build -lt 19041) { Write-Log 'This script targets Windows 10 2004 (19041) or later. Behaviour on older builds is untested.' 'WARN' }
    $windows10 = Get-Windows10Notice
    if ($windows10) { Write-Log $windows10 'WARN' }
    if (-not $SkipRestorePoint -and -not $script:DryRun) {
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

    if ($Opt['Packages']) { Invoke-Step 'Packages' -Option 'Packages' { Install-RuntimePackages } }
    if ($WantNvidia) { Invoke-Step 'NVIDIA driver' { Install-NvidiaDriver } }
    if ($Opt['NvidiaProfile']) { Invoke-Step 'NVIDIA global profile' -Option 'NvidiaProfile' { Import-NvidiaSettings -Label 'base profile' -Settings $NvidiaBaseSettings } }
    if ($Opt['NvidiaReBar']) { Invoke-Step 'NVIDIA Resizable BAR' -Option 'NvidiaReBar' { Import-NvidiaSettings -Label 'Resizable BAR' -Settings $NvidiaReBarSettings } }
    if ($Opt['Debloat']) { Invoke-Step 'App debloat' -Option 'Debloat' { Remove-BloatApps } }
    if ($Opt['PrivacyDenials']) { Invoke-Step 'Consent database reset' -Option 'PrivacyDenials' { Reset-ConsentDatabase } }
    if ($Opt['RemoveQuickAssist']) { Invoke-Step 'Remove Quick Assist' -Option 'RemoveQuickAssist' { Remove-QuickAssist } }
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
    if ($Opt['DepOff']) { Invoke-Step 'Data Execution Prevention' -Option 'DepOff' { Disable-Dep } }
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
    if ($Opt['RestartExplorer'] -or $script:ShellDirty) { Invoke-Step 'Refresh settings and restart Explorer' { Update-UserVisuals } }
    if ($Opt['HealthCheckAfter'] -and -not $script:DryRun) {
        $script:PostApply = $true
        Invoke-Step 'Health check' { Invoke-HealthCheck }
        # A run whose own health check fails must not end with "Finished without errors" and exit code 0.
        if ($script:Health.FAIL -gt 0) { $script:Failures++; Write-Log "The health check after the run reported $($script:Health.FAIL) failure(s)." 'ERROR' }
    }
}

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
            catch { $script:Failures++; Write-Log "Could not restore $($e.Path)\$(Show-RegName $e.Name). $($_.Exception.Message)" 'ERROR' }
        }
    }
    if ($script:State.CreatedKeys.Count -gt 0) { Invoke-Step 'Remove registry keys created by the run' { Remove-CreatedKeys } }
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
    if ($script:State.NetBindings.Count -gt 0) { Invoke-Step 'Turn IPv6 back on' { Restore-NetBindings } }
    if ($script:State.StartLayout) { Invoke-Step 'Restore Start menu layout' { Restore-StartPins } }
    if ($script:State.DesktopMoved.Count -gt 0) { Invoke-Step 'Restore desktop shortcuts' { Restore-DesktopIcons } }
    if (@($script:State.Registry | Where-Object { $_.Path -like '*Control Panel\Mouse' }).Count -gt 0) { Invoke-Step 'Refresh mouse settings' { Sync-MouseSettings } }
    if ($script:State.Removed.Count -gt 0) {
        Write-Log ('Apps removed earlier (reinstall from the Store or winget if wanted): ' + (($script:State.Removed | Sort-Object -Unique) -join ', ')) 'WARN'
    }
    if ($script:ShellDirty) { Update-UserVisuals }
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

#region Entry point -----------------------------------------------------------------------
if ($Revert -and $DryRun) { throw '-DryRun is not supported together with -Revert.' }
Initialize-StateDir
# An unreadable state file ends every mode here with one clear line, before anything is changed.
try { Import-State }
catch { Write-Log $_.Exception.Message 'ERROR'; Exit-Run 4 $_.Exception.Message }
try { Repair-TrustedInstallerPath }
catch { $script:Failures++; Write-Log $_.Exception.Message 'ERROR' }
if ($Benchmark) { Invoke-Benchmark; Exit-Run 0 }
if ($StartupReview) { Show-StartupReview; Exit-Run 0 }
if ($HealthCheck) {
    Restore-SavedRunSettings
    Invoke-HealthCheck
    Exit-Run ([int]($script:Health.FAIL -gt 0))
}
if ($RestoreTask.Count -gt 0) {
    if ($Revert -or $DryRun) { throw '-RestoreTask cannot be combined with -Revert or -DryRun.' }
    Invoke-Step 'Restore selected tasks' { Restore-SelectedTasks }
    Exit-Run ([int]($script:Failures -gt 0))
}
if ($Revert) { Invoke-Revert }
else {
    if ($Json -and -not $Force -and -not $script:DryRun) { Exit-Run 2 'A -Json run cannot answer questions. Add -Force for an unattended run.' }
    # Only a hint: the defaults trade battery and security for speed, and laptops usually want the laptop profile.
    if (-not $ProfilePath -and (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)) {
        Write-Log "Battery detected and no profile given. The defaults favour speed over battery life and security; on a laptop consider -ProfilePath $(Join-Path $PSScriptRoot 'profiles\laptop.json')." 'WARN'
    }
    Show-Plan
    if (-not (Invoke-Preflight)) { Exit-Run 3 "Refused by the pre flight check(s) $(@($script:PreflightResults | Where-Object { $_.Status -eq 'BLOCK' } | ForEach-Object { $_.Check }) -join ', ')." }
    if (-not (Confirm-Run)) { Write-Log 'Cancelled, nothing was changed.' 'WARN'; Exit-Run 2 'The run was not confirmed.' }
    Invoke-Apply
    Save-State
}

if ($script:DryRun) { Write-Log 'Dry run complete. Nothing was changed.' 'OK'; Exit-Run 0 'Dry run, nothing was changed.' }
if ($script:Failures -gt 0) { Write-Log "Finished with $($script:Failures) failure(s) and $($script:Warnings) warning(s). Review the log: $LogFile" 'WARN' }
else { Write-Log "Finished without errors ($($script:Warnings) warning(s)). Log: $LogFile" 'OK' }
if (-not $Revert -and (Test-Path -LiteralPath $JournalFile)) { Write-Log "Every change with its option, value before, value after and result (OK, MISMATCH, FAILED): $JournalFile" }
Write-Log 'Restart Windows so service, policy and power changes take full effect.'
Exit-Run ([int]($script:Failures -gt 0))
#endregion
