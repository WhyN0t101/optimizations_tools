#Requires -Version 5.1
<#
.SYNOPSIS
    Focused Windows 10/11 tweak script derived from ZOICWARE (MIT licence, copyright (c) 2024 zoicware). v6.

.DESCRIPTION
    A stripped down port of the ZOICWARE features in the supplied ZCONFIG, with every risky item exposed as a
    named option. Defaults follow upstream behaviour, except the four registry groups you excluded (core
    isolation, hide Lock, hide Sleep, hibernate off) and the services you asked to keep (Bluetooth, printing,
    Delivery Optimization, radio management).

    Everything that changes the registry, hosts file, services, scheduled tasks, power plan, hibernation,
    memory compression, sleep study logs, account password age and Defender is recorded first, and the state
    is saved after every step, so -Revert can restore it even after an interrupted run.

    Not reversible by -Revert: app debloat, software installed by winget or NVIDIA, NVIDIA driver files
    removed by the telemetry strip, the fault tolerant heap reset, and the temp and update cache cleanup.

    Performance options that lower security (SpectreMeltdownOff, DepOff) and the TimerResolution service are
    off by default. Switch them on with -Enable.

    Not ported from upstream (they edit per app settings.dat hives or are cosmetic): Store and App Actions
    settings, calendar expansion, priority notification blob, terminal and console colours, Task Manager
    always on top, HDR on battery, DDU and Safe Mode driver cleaning.

    Use -Only A,B to run just those options (for example -Only ClearStartPins,RemoveQuickAssist).
    Use -ListOptions to see every option and its default, -ListRegGroups to see the registry groups.
    Use -HealthCheck at any time (ideally after a restart) to verify the result against the options you chose;
    add -HealthCheckLaunch to also open Settings, Store, Photos, Paint and Xbox and confirm they start.
    Use -Skip Name1,Name2 to switch options off and -Enable Name1,Name2 to switch them on.

    Started without administrator rights (right click, Run with PowerShell), the script asks for elevation and runs
    again in a new elevated window with the same parameters.

    Use -ProfilePath file.json to keep a set of choices in a file (see profiles\example.json). Parameters given on
    the command line win over the profile.

.EXAMPLE
    .\FocusedTweaks.ps1 -ListOptions

.EXAMPLE
    .\FocusedTweaks.ps1 -ProfilePath .\profiles\example.json -DryRun

.EXAMPLE
    .\FocusedTweaks.ps1 -DryRun

.EXAMPLE
    .\FocusedTweaks.ps1 -Skip Uac,RunKeys -Enable KeepDefinitionUpdates -PauseDays 30

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
    [string]$StateDir = (Join-Path $env:ProgramData 'FocusedTweaks')
)

# Needs administrator rights, but a '#Requires -RunAsAdministrator' line would stop the script before any code runs, so
# right click, Run with PowerShell could never work. Instead start again elevated, with the same parameters.
# -ListOptions only prints, so it runs without elevation.
if (-not $ListOptions) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if (-not $PSCommandPath) { throw 'This script needs administrator rights. Start PowerShell as administrator and run it from a file.' }
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
# Name = default state, description. Defaults mirror upstream unless noted.
$OptionInfo = [ordered]@{
    Packages              = @($true, 'winget: runtimes, Firefox, 7-Zip, NVIDIA Profile Inspector, Autoruns')
    Debloat               = @($true, 'Remove consumer apps (keep list protects Store, Xbox, Edge, Paint, Photos and more)')
    Registry              = @($true, 'Upstream RegTweaks.txt (about 270 keys, 470 values), all groups except those with their own option below')
    Uac                   = @($true, 'Disable User Account Control (EnableLUA 0) and LUA file virtualization')
    RunKeys               = @($true, 'Delete the HKCU and HKLM Run keys once, clearing every startup entry')
    PrivacyDenials        = @($true, 'Deny app access to camera, location, radios, files and more, and reset the consent database')
    CoreIsolation         = @($false, 'Disable core isolation (VBS, HVCI, Credential Guard). Off, you excluded it')
    HideLockOption        = @($false, 'Hide Lock in the Start power menu. Off, you excluded it')
    HideSleepOption       = @($false, 'Hide Sleep in the Start power menu. Off, you excluded it')
    RegHibernateOff       = @($false, 'HibernateEnabled 0 in the registry. Off, you excluded it')
    TaskbarEndTask        = @($true, 'Add End task to the right click menu of taskbar apps (Windows 11, upstream registry group)')
    DisableHibernate      = @($false, 'powercfg /hibernate off (also removes Fast Startup). Upstream does this with its power plan')
    MsiMode               = @($true, 'Enable MSI interrupts for display adapters')
    MemoryCompression     = @($true, 'Disable memory compression when RAM is above 8 GB')
    SleepStudy            = @($true, 'Turn off Sleep Study and power diagnostic event logs')
    PasswordExpiry        = @($true, 'Local passwords never expire (Windows 11 only)')
    FaultTolerantHeap     = @($true, 'Reset the fault tolerant heap (not reversible)')
    NotificationSettings  = @($true, 'Turn off notifications for every app listed under Notifications settings')
    RestartExplorer       = @($true, 'Refresh user settings and restart Explorer at the end')
    TelemetryPolicy       = @($true, 'Telemetry, CEIP, app compatibility and advertising policy plus DiagTrack services')
    TelemetryHosts        = @($true, 'Block 30 Microsoft telemetry domains in the hosts file')
    BiometricsPolicy      = @($true, 'Policy that disables biometrics (Windows Hello fingerprint and face)')
    Cdp                   = @($true, 'Disable the Connected Devices Platform services and clear its cache')
    SvcOther              = @($true, 'Disable misc services: location, maps, Netlogon, defrag, tablet input, wallet and more')
    SvcBiometrics         = @($true, 'Disable the Windows Biometric Service')
    SvcSmartCard          = @($true, 'Disable smart card services')
    SvcDiagnostics        = @($true, 'Disable diagnostic policy and Wdi services (troubleshooters)')
    SvcBluetooth          = @($false, 'Disable Bluetooth services. Off, you asked to keep Bluetooth')
    SvcPrinting           = @($false, 'Disable print spooler services. Off, you asked to keep printing')
    SvcDeliveryOpt        = @($false, 'Disable Delivery Optimization. Off, you asked to keep it')
    SvcRadio              = @($false, 'Disable Radio Management (airplane mode and radio toggles). Off, it supports Bluetooth')
    DriverExclusion       = @($true, 'Exclude drivers from Windows Update and stop device metadata downloads')
    SecurityUpdatesOnly   = @($true, 'Upstream update block: long deferrals plus excluded update classifications')
    PauseUpdates          = @($true, 'Pause updates for -PauseDays and set update services to Manual')
    PauseStopsUpdateTasks = @($true, 'While pausing, also disable the Update Orchestrator, WaaSMedic and Windows Update tasks')
    KeepDefinitionUpdates = @($false, 'Leave Defender definition updates out of the excluded classifications')
    RazerAsusHosts        = @($true, 'Block Razer and ASUS software download servers in the hosts file')
    MouseAccel            = @($true, 'Turn off mouse acceleration using the profile for your display scaling')
    ClearDesktopIcons     = @($true, 'Hide Recycle Bin, This PC and other system icons and move shortcuts off the desktop (restorable)')
    HideAllDesktopIcons   = @($false, 'Also hide every other desktop icon (files stay on disk). Same as View, Show desktop icons')
    EnableSystemRestore   = @($false, 'If the restore point fails, turn System Protection on for the system drive and retry')
    ClearStartPins        = @($true, 'Clear all pinned apps from the Start menu (Windows 11, current user, layout is backed up)')
    RemoveQuickAssist     = @($true, 'Remove Quick Assist (Windows capability, package and app). Not reversible by -Revert')
    DefenderQuiet         = @($true, 'Keep Defender on but turn off cloud reporting, sample submission, infection reports and notifications (policy)')
    NetAdapterPower       = @($true, 'Turn off power saving on physical network adapters (allow-off and wake flags, green Ethernet, ultra low power)')
    NetAdapterEee         = @($true, 'Turn off Energy Efficient Ethernet on physical network adapters that expose it')
    TempCleanup           = @($true, 'Delete the contents of the user and Windows Temp folders (files in use are skipped). Not reversible')
    UpdateCacheCleanup    = @($true, 'Delete the Windows Update download cache (SoftwareDistribution\Download). Not reversible')
    SpectreMeltdownOff    = @($false, 'Turn off Spectre and Meltdown mitigations (FeatureSettingsOverride). Faster CPU, weaker security. Needs a restart')
    DepOff                = @($false, 'Turn off Data Execution Prevention (bcdedit nx AlwaysOff). Secure Boot must be off. Needs a restart')
    TimerResolution       = @($false, 'Compile and install a small service that holds the timer at its finest resolution (about 0.5 ms)')
    DevicePowerSaving     = @($true, 'Turn off power saving and selective suspend for ACPI, HID, PCI and USB devices (skipped on battery)')
    DeviceWakeOff         = @($false, 'Stop devices waking the PC (keyboard and mouse can no longer wake it from sleep)')
    MpoOff                = @($false, 'Turn off multiplane overlay (OverlayTestMode 5). Can fix flicker and stutter, can break some HDR setups')
    WriteCacheFlushOff    = @($false, 'Turn off write cache buffer flushing on SATA and NVMe disks. Faster, but a power cut can lose data')
    FastShutdown          = @($false, 'Shorter shutdown timeouts and end hung apps automatically. Unsaved work in hung apps is lost')
    BlockFeatureUpgrades  = @($false, 'Stay on the current Windows version (TargetReleaseVersion). Security updates continue until it ends')
    SearchIndexingOff     = @($false, 'Disable the Windows Search indexer service (search in Start and Explorer gets slower)')
    TimeServerPool        = @($true, 'Sync the clock from pool.ntp.org instead of time.windows.com')
    MenuKillNotResponding = @($true, 'Add "Kill not responding tasks" to the desktop right click menu')
    MenuRestartExplorer   = @($true, 'Add "Restart Explorer" to the desktop right click menu')
    MenuTakeOwnership     = @($false, 'Add "Take ownership" to the right click menu of files and folders (easy to misuse on system files)')
    HealthCheckAfter      = @($true, 'Run the health check at the end of a run (standalone: -HealthCheck)')
    NvidiaTelemetryStrip  = @($true, 'After an NVIDIA install, remove telemetry DLLs and container plugins')
}
$Opt = @{}
foreach ($k in $OptionInfo.Keys) { $Opt[$k] = [bool]$OptionInfo[$k][0] }

$BoundNames = @($PSBoundParameters.Keys)

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

$ExplicitTaskMode = $BoundNames -contains 'TaskMode'
$ExplicitPowerProfile = $BoundNames -contains 'PowerProfile'

function Resolve-Options {
    if ($Only.Count -gt 0) {
        # -Only runs just the options you name: everything else is switched off.
        foreach ($k in @($OptionInfo.Keys)) { $Opt[$k] = $false }
        if (-not $ExplicitTaskMode) { $script:TaskMode = 'None' }
        if (-not $ExplicitPowerProfile) { $script:PowerProfile = 'Off' }
    }
    foreach ($pair in @(@($Only, $true), @($Enable, $true), @($Skip, $false))) {
        foreach ($name in $pair[0]) {
            $match = $OptionInfo.Keys | Where-Object { $_ -ieq $name } | Select-Object -First 1
            if (-not $match) { throw "Unknown option '$name'. Run with -ListOptions to see the valid names." }
            $Opt[$match] = $pair[1]
        }
    }
}

if ($ListOptions) {
    Write-Host ('{0,-24} {1,-5} {2}' -f 'Option', 'Def.', 'What it does')
    foreach ($k in $OptionInfo.Keys) {
        Write-Host ('{0,-24} {1,-5} {2}' -f $k, $(if ($OptionInfo[$k][0]) { 'on' } else { 'off' }), $OptionInfo[$k][1])
    }
    Write-Host ''
    Write-Host 'Run only some options: -Only Name1,Name2 (everything else is switched off).'
    Write-Host 'Other choices: -TaskMode Delete|Disable|None (default Delete), -Defender Keep|Disable|Enable, -PowerProfile Off|Medium|High,'
    Write-Host '-PowerMode Keep|Balanced|Best, -PauseDays 1..730, -SkipRegGroup <title wildcards>, -TaskKeep <task path wildcards>.'
    Write-Host 'Keep a set of choices in a file: -ProfilePath file.json (see profiles\example.json).'
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
    SvcOther = @('Fax', 'shpamsvc', 'RemoteRegistry', 'PhoneSvc', 'defragsvc', 'wisvc', 'TabletInputService', 'AssignedAccessManagerSvc', 'MapsBroker', 'lfsvc', 'Netlogon', 'WpcMonSvc', 'WalletService', 'whesvc', 'wuqisvc', 'WSAIFabricSvc')
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

# Values Windows protects even from TrustedInstaller. A mismatch here is reported as a note, not a warning.
$KnownStuckValues = @('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener|Start')
#endregion

#region Infrastructure --------------------------------------------------------------------
$StateFile = Join-Path $StateDir 'state.json'
$LogFile = Join-Path $StateDir ('run-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

$script:Failures = 0
$script:Warnings = 0
$script:TiCount = 0
$script:ShellDirty = $false
$script:State = @{
    Registry   = [System.Collections.Generic.List[object]]::new()
    KeyBackups = [System.Collections.Generic.List[object]]::new()
    Tasks      = [System.Collections.Generic.List[object]]::new()
    Removed    = [System.Collections.Generic.List[object]]::new()
    Hosts      = [System.Collections.Generic.List[object]]::new()
    Power      = $null
    Defender   = $false
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
    DesktopMoved = [System.Collections.Generic.List[object]]::new()
    CreatedKeys = [System.Collections.Generic.List[object]]::new()
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
    Write-Host $line -ForegroundColor $colour
    Add-Content -Path $LogFile -Value $line
}

function Test-DryRun {
    param([Parameter(Mandatory)][string]$Action)
    if ($script:DryRun) { Write-Log "DRY RUN, would: $Action"; return $true }
    return $false
}

function Save-State {
    if ($script:DryRun) { return }
    # PowerShell 7 turns ISO date strings into dates when it reads JSON, which would corrupt restored registry
    # strings. Stored strings therefore carry an 's:' prefix, which Import-State removes again.
    $copy = @{}
    foreach ($entry in $script:State.GetEnumerator()) { $copy[$entry.Key] = $entry.Value }
    $copy.Registry = @($script:State.Registry | ForEach-Object {
            if (($_.Kind -eq 'String' -or $_.Kind -eq 'ExpandString') -and $_.Value -is [string]) {
                [pscustomobject]@{ Path = $_.Path; Name = $_.Name; Existed = $_.Existed; Kind = $_.Kind; Value = ('s:' + $_.Value) }
            }
            else { $_ }
        })
    ConvertTo-Json -InputObject $copy -Depth 8 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Log "Starting: $Name"
    try {
        & $Action
        Write-Log "Completed: $Name" 'OK'
    }
    catch {
        $script:Failures++
        Write-Log "Failed: $Name. $($_.Exception.Message)" 'ERROR'
    }
    finally {
        if (-not $Revert) { Save-State }
    }
}

function Import-State {
    if (-not (Test-Path -LiteralPath $StateFile)) { return }
    $raw = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    foreach ($section in 'Registry', 'KeyBackups', 'Tasks', 'Removed', 'Hosts', 'DesktopMoved', 'CreatedKeys') {
        if ($raw.PSObject.Properties[$section] -and $raw.$section) {
            foreach ($item in @($raw.$section)) {
                if ($section -eq 'Registry') {
                    if (($item.Kind -eq 'String' -or $item.Kind -eq 'ExpandString') -and $item.Value -is [string] -and $item.Value.StartsWith('s:')) {
                        $item.Value = $item.Value.Substring(2)
                    }
                    [void]$script:RecordedReg.Add("$($item.Path)|$($item.Name)")
                }
                $script:State[$section].Add($item)
            }
        }
    }
    foreach ($scalar in 'Power', 'Defender', 'Hibernate', 'MemCompress', 'SleepStudy', 'PwAge', 'ConsentDb', 'Run', 'StartLayout', 'Dep', 'TimerService', 'PowerOverlay') {
        if ($raw.PSObject.Properties[$scalar]) { $script:State[$scalar] = $raw.$scalar }
    }
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

function Save-RegSnapshot {
    # A set gives a fast "already recorded" test; device options record thousands of values.
    param([string]$Full, [string]$Name)
    if ($script:RecordedReg.Add("$Full|$Name")) { $script:State.Registry.Add((Get-RegSnapshot -Full $Full -Name $Name)) }
}

function Save-CreatedKeys {
    # Records the keys a write is about to create, so -Revert can remove them again. Restoring the values alone would
    # leave empty keys behind, and an empty right click menu key still shows up as a menu entry.
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
    foreach ($m in $missing) { if (@($script:State.CreatedKeys) -notcontains $m) { $script:State.CreatedKeys.Add($m) } }
}

function Remove-CreatedKeys {
    # Deepest first, and only keys that are empty again: anything added to them since is left alone.
    foreach ($full in @($script:State.CreatedKeys | Sort-Object { $_.Length } -Descending)) {
        try { $key = Open-RegKey -Full $full }
        catch { Write-Log "Could not open the created key $full. $($_.Exception.Message)" 'WARN'; continue }
        if (-not $key) { continue }
        $empty = ($key.ValueCount -eq 0) -and ($key.SubKeyCount -eq 0)
        $key.Close()
        if (-not $empty) { Write-Log "Key kept, it holds data added after the run: $full"; continue }
        $parts = Split-RegPath $full
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($script:Hives[$parts[0].ToUpperInvariant()], [Microsoft.Win32.RegistryView]::Default)
        try { $base.DeleteSubKey($parts[1], $false) }
        catch { Write-Log "Could not remove the created key $full. $($_.Exception.Message)" 'WARN' }
        finally { $base.Close() }
    }
}

function Show-RegName { param([string]$Name) if ($Name -eq '') { '(default)' } else { $Name } }

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
        catch { & taskkill.exe /im trustedinstaller.exe /f *> $null }
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
    try {
        Save-CreatedKeys -Full $full
        Save-RegSnapshot -Full $full -Name $Name
        try { Write-RegRaw -Full $full -Name $Name -Value $Value -Kind $Type }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            [void](Invoke-AsTI -PsCommand (Format-TiRegAdd -Full $full -Name $Name -Value $Value -Kind $Type))
            if (-not (Test-RegValueNow -Full $full -Name $Name -Value $Value -Kind $Type)) {
                Write-Log "Could not set $full\$(Show-RegName $Name), even as TrustedInstaller." 'WARN'
            }
        }
    }
    catch {
        $script:Failures++
        Write-Log "Registry write failed: $full\$(Show-RegName $Name). $($_.Exception.Message)" 'ERROR'
    }
}

function Remove-RegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $full = ConvertTo-FullRegPath $Path
    if (Test-DryRun "delete value $full\$(Show-RegName $Name)") { return }
    try {
        Save-RegSnapshot -Full $full -Name $Name
        $key = Open-RegKey -Full $full -Write
        if (-not $key) { return }
        try { $key.DeleteValue($Name, $false) }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            $nameArg = if ($Name -eq '') { '/ve' } else { '/v ' + (ConvertTo-PsLiteral $Name) }
            [void](Invoke-AsTI -PsCommand "& reg.exe delete $(ConvertTo-PsLiteral $full) $nameArg /f | Out-Null")
        }
        finally { $key.Close() }
    }
    catch {
        $script:Failures++
        Write-Log "Registry value removal failed: $full\$(Show-RegName $Name). $($_.Exception.Message)" 'ERROR'
    }
}

function Remove-RegKey {
    param([Parameter(Mandatory)][string]$Path)
    $full = ConvertTo-FullRegPath $Path
    if (Test-DryRun "delete key $full (a backup is exported first)") { return }
    try {
        $probe = Open-RegKey -Full $full
        if (-not $probe) { return }
        $probe.Close()
        $dir = Join-Path $StateDir 'keys'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir (($full -replace '[\\/:*?"<>| {}]', '_') + '.reg')
        $recorded = Test-RecordedFirst $script:State.KeyBackups { param($e) $e.Path -eq $full }
        if (-not $recorded) {
            & reg.exe export $full $file /y | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not back up $full, so it was not deleted." }
            $script:State.KeyBackups.Add([pscustomobject]@{ Path = $full; File = $file })
        }
        $parts = Split-RegPath $full
        $hive = $script:Hives[$parts[0].ToUpperInvariant()]
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
        try { $base.DeleteSubKeyTree($parts[1], $false) }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            [void](Invoke-AsTI -PsCommand "& reg.exe delete $(ConvertTo-PsLiteral $full) /f | Out-Null")
        }
        finally { $base.Close() }
    }
    catch {
        $script:Failures++
        Write-Log "Registry key removal failed: $full. $($_.Exception.Message)" 'ERROR'
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
    else {
        $key = Open-RegKey -Full $Entry.Path -Write
        if (-not $key) { return }
        try { $key.DeleteValue($Entry.Name, $false) }
        catch {
            if (-not (Test-AccessDenied $_)) { throw }
            $nameArg = if ($Entry.Name -eq '') { '/ve' } else { '/v ' + (ConvertTo-PsLiteral $Entry.Name) }
            [void](Invoke-AsTI -PsCommand "& reg.exe delete $(ConvertTo-PsLiteral $Entry.Path) $nameArg /f | Out-Null")
        }
        finally { $key.Close() }
    }
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
        default { return 'Registry' }
    }
}

function Show-RegGroups {
    $ops = ConvertFrom-RegText -Text $UpstreamRegText
    $ops | Group-Object Group | ForEach-Object {
        Write-Host ('{0,-22} {1,3} item(s)  {2}' -f (Get-RegGroupOption $_.Name), $_.Count, $_.Name)
    }
}

function Import-UpstreamRegistry {
    $ops = ConvertFrom-RegText -Text $UpstreamRegText
    $applied = 0; $byOption = 0; $byGroup = 0
    foreach ($op in $ops) {
        if (-not $Opt[(Get-RegGroupOption $op.Group)]) { $byOption++; continue }
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
    Write-HostsFile -Text ($text + $block)
    if (-not (Test-RecordedFirst $script:State.Hosts { param($e) $e -eq $Name })) { $script:State.Hosts.Add($Name) }
    Write-Log "Hosts file: blocked $($Domains.Count) domain(s) ($Name)." 'OK'
}
#endregion

#region Software: packages, debloat, NVIDIA ----------------------------------------------
function New-SafetyRestorePoint {
    try {
        Checkpoint-Computer -Description 'Before FocusedTweaks' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Restore point created.' 'OK'
        return
    }
    catch { $reason = $_.Exception.Message }
    if (-not $Opt['EnableSystemRestore']) {
        Write-Log "Restore point not created (System Protection may be off, or one was made in the last 24 hours). Continuing. Run with -Enable EnableSystemRestore to turn System Protection on for $env:SystemDrive and retry. $reason" 'WARN'
        return
    }
    try {
        # Same approach as the Ultimate repo: allow several restore points per day, switch System Protection on, retry.
        Set-RegValue -Path 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Value 0
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description 'Before FocusedTweaks' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Restore point created after turning System Protection on (-Revert does not turn it off again).' 'OK'
    }
    catch { Write-Log "Restore point still not created. The System Restore or Volume Shadow Copy service may be disabled on this machine. $($_.Exception.Message)" 'WARN' }
}

function Install-RuntimePackages {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Log 'winget not found in this session (common on a fresh VM). Update App Installer from the Microsoft Store, open a new elevated window and run again.' 'WARN'
        return
    }
    $acceptable = @(0, -1978335189, -1978335135)
    foreach ($id in $PackageIds) {
        if (Test-DryRun "winget install $id") { continue }
        & winget.exe install --id $id --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements | Out-Null
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
            $script:State.Removed.Add($pkg.Name); $removed++
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
            & takeown.exe /f $f *> $null
            & icacls.exe $f /grant '*S-1-5-32-544:F' /t *> $null
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $f) { Write-Log "Could not remove NVIDIA telemetry file: $f" 'WARN' }
            else { Write-Log "Removed NVIDIA telemetry file: $(Split-Path $f -Leaf)" 'OK' }
        }
    }
    foreach ($pattern in '*NvDriverUpdateCheckDaily*', '*NVIDIA GeForce Experience SelfUpdate*', '*NvProfileUpdaterDaily*', '*NvProfileUpdaterOnLogon*', '*NvTmRep_CrashReport*') {
        Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    }
    Start-Service NVDisplay.ContainerLocalSystem -ErrorAction SilentlyContinue
}

function Install-NvidiaDriver {
    $gpu = @(Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_ -and $_.PNPDeviceID -like 'PCI\VEN_10DE*' })
    if ($gpu.Count -eq 0) { Write-Log 'No NVIDIA GPU detected, skipping the driver install.' 'WARN'; return }
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
            Stop-Service -InputObject $svc -Force -ErrorAction SilentlyContinue
        }
    }
}

function Disable-ServiceGroups {
    $enabled = @()
    foreach ($g in $ServiceGroups.Keys) {
        if ($Opt[$g]) { $enabled += $ServiceGroups[$g] }
        else { Write-Log "Services kept (option $g is off): $($ServiceGroups[$g] -join ', ')" }
    }
    foreach ($name in ($enabled | Select-Object -Unique)) { Set-ServiceStart -Name $name -Mode Disabled }
}

function Save-TaskState {
    param($Task, [string]$Action, [string]$XmlFile = $null)
    $recorded = Test-RecordedFirst $script:State.Tasks { param($e) $e.Path -eq $Task.TaskPath -and $e.Name -eq $Task.TaskName }
    if (-not $recorded) {
        $script:State.Tasks.Add([pscustomobject]@{ Path = $Task.TaskPath; Name = $Task.TaskName; Action = $Action; WasEnabled = ($Task.State -ne 'Disabled'); XmlFile = $XmlFile })
    }
}

function Disable-TaskRecorded {
    param($Task)
    $full = "$($Task.TaskPath)$($Task.TaskName)"
    if ($Task.State -eq 'Disabled') { return }
    if (Test-DryRun "disable task $full") { return }
    Save-TaskState -Task $Task -Action 'Disabled'
    try { Disable-ScheduledTask -InputObject $Task -ErrorAction Stop | Out-Null }
    catch {
        & schtasks.exe /Change /TN $full /Disable *> $null
        if ($LASTEXITCODE -ne 0) { Write-Log "Could not disable task $full (protected by the system)." 'WARN' }
    }
}

function Disable-TelemetryTasks {
    foreach ($t in $TelemetryTasks) {
        $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($task) { Disable-TaskRecorded -Task $task }
    }
}

function Remove-AllScheduledTasks {
    # Upstream behaviour: unregister every task except three. Each task is exported first so -Revert can restore it.
    $dir = Join-Path $StateDir 'tasks'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $tasks = @(Get-ScheduledTask | Where-Object {
            $_.TaskName -notin @('SvcRestartTask', 'MsCtfMonitor') -and "$($_.TaskPath)$($_.TaskName)" -ne '\Microsoft\Windows\Shell\CreateObjectTask'
        })
    $deleted = 0; $failed = 0; $seen = 0
    foreach ($t in $tasks) {
        $full = "$($t.TaskPath)$($t.TaskName)"
        if (Test-NameMatch $full $TaskKeep) { continue }
        if (Test-DryRun "delete task $full (exported first)") { continue }
        # Each task takes about a second (export, then delete), so say that the step is still working.
        $seen++
        if ($seen % 40 -eq 0) { Write-Log "Scheduled tasks: $seen of $($tasks.Count) processed, still working." }
        $file = Join-Path $dir (($full -replace '[\\/:*?"<>| ]', '_') + '.xml')
        try {
            Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Set-Content -LiteralPath $file -Encoding Unicode
            Save-TaskState -Task $t -Action 'Deleted' -XmlFile $file
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            $deleted++
        }
        catch { $failed++ }
    }
    if (-not $script:DryRun) { Write-Log "Scheduled tasks deleted: $deleted (backups in $dir). $failed could not be removed (protected by the system)." 'OK' }
}

function Invoke-TaskMode {
    switch ($TaskMode) {
        'Delete' { Remove-AllScheduledTasks }
        'Disable' { Disable-TelemetryTasks }
        'None' { Write-Log 'Scheduled tasks left untouched (-TaskMode None).' }
    }
}

function Restore-Tasks {
    foreach ($t in $script:State.Tasks) {
        try {
            if ($t.Action -eq 'Deleted') {
                if ($t.XmlFile -and (Test-Path -LiteralPath $t.XmlFile)) {
                    Register-ScheduledTask -Xml (Get-Content -LiteralPath $t.XmlFile -Raw) -TaskName $t.Name -TaskPath $t.Path -Force -ErrorAction Stop | Out-Null
                }
            }
            elseif ($t.WasEnabled) { Enable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null }
        }
        catch { Write-Log "Could not restore task $($t.Path)$($t.Name). $($_.Exception.Message)" 'WARN' }
    }
    Write-Log 'Scheduled tasks restored.' 'OK'
}
#endregion

#region Telemetry, updates, vendor blocks -------------------------------------------------
function Invoke-TelemetryTweaks {
    if ($Opt['TelemetryPolicy']) {
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
    if ($Opt['BiometricsPolicy']) { Set-TweakList $BiometricsRegs }
    if ($Opt['Cdp']) {
        foreach ($s in $CdpServices) { Set-ServiceStart -Name $s -Mode Disabled }
        if (-not $script:DryRun) { Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'ConnectedDevicesPlatform') -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($Opt['TelemetryHosts']) { Set-HostsBlock -Name 'telemetry' -Domains $TelemetryDomains }
}

function Set-UpdatePolicies {
    $classifications = @($UpdateClassifications)
    if ($Opt['KeepDefinitionUpdates']) { $classifications = @($classifications | Where-Object { $_ -notlike '*e0789628-ce08-4437-be74-2495b842f43b*' }) }
    $classString = $classifications -join ';'
    $wu = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $ux = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

    if ($Opt['DriverExclusion']) { Set-TweakList $DriverExclusionRegs }
    if ($Opt['SecurityUpdatesOnly']) {
        Set-TweakList $SecurityUpdatesRegs
        Set-RegValue -Path $wu -Name 'ExcludeUpdateClassifications' -Value $classString -Type String
        Write-Log 'Update policy: long deferrals set and update classifications excluded (upstream behaviour).' 'WARN'
    }
    if ($Opt['PauseUpdates']) {
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
        Set-RegValue -Path $wu -Name 'ExcludeUpdateClassifications' -Value $classString -Type String
        if ($Opt['PauseStopsUpdateTasks']) {
            foreach ($pattern in $UpdateTaskPaths) {
                foreach ($task in @(Get-ScheduledTask -TaskPath $pattern -ErrorAction SilentlyContinue)) { Disable-TaskRecorded -Task $task }
            }
        }
        if (-not $script:DryRun) { Write-Log "Updates paused until $end (-PauseDays $PauseDays). Security patches are delayed for that period." 'WARN' }
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
            $guid = Get-GuidFromText ((powercfg /duplicatescheme $base 2>&1) | Out-String)
            if ($guid) { break }
        }
        if (-not $guid) {
            Write-Log 'Base scheme unavailable (common on Modern Standby systems), cloning the active scheme instead.' 'WARN'
            $guid = Get-GuidFromText ((powercfg /duplicatescheme $active 2>&1) | Out-String)
        }
        if (-not $guid) { throw 'Unable to create the custom power plan.' }
        powercfg /changename $guid $planName "Created by FocusedTweaks ($PowerProfile)" | Out-Null
    }
    if (-not $script:State.Power) {
        $previous = if ($active -and $active -ne $guid -and -not (@(Get-TweakedPlanGuids) -contains $active)) { $active } else { $BalancedGuid }
        $script:State.Power = [pscustomobject]@{ Previous = $previous; Custom = $guid }
    }
    else { $script:State.Power.Custom = $guid }
    foreach ($s in $spec.Settings) { Set-PlanValue -Guid $guid -Sub $s[0] -Setting $s[1] -Value $s[2] }
    powercfg /setactive $guid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'powercfg /setactive failed.' }
    Write-Log "Active power plan set to '$planName' ($guid)." 'OK'
    foreach ($old in @(Get-TweakedPlanGuids)) { if ($old -ne $guid) { powercfg /delete $old | Out-Null } }
}

function Set-PowerModeOverlay {
    $overlay = if ($PowerMode -eq 'Best') { 'OVERLAY_SCHEME_MAX' } else { 'OVERLAY_SCHEME_NONE' }
    if (Test-DryRun "set the Windows power mode overlay to $overlay") { return }
    if (-not $script:State.PowerOverlay) {
        # Recorded first so -Revert can put the previous power mode back. A missing value means Windows' default.
        $prev = Get-RegSnapshot -Full 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActiveOverlayAcPowerScheme'
        $script:State.PowerOverlay = $(if ($prev.Existed -and $prev.Value) { [string]$prev.Value } else { '00000000-0000-0000-0000-000000000000' })
    }
    powercfg /OverlaySetActive $overlay | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log 'Power mode overlays are not available on this Windows build.' 'WARN' } else { Write-Log "Power mode set ($PowerMode)." 'OK' }
}

function Restore-PowerMode {
    $guid = ([string]$script:State.PowerOverlay).ToLowerInvariant()
    $name = $PowerOverlayNames[$guid]
    if (-not $name) {
        if ($guid -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') { throw "Unexpected saved power mode '$guid', not restoring it." }
        $name = $guid
    }
    powercfg /OverlaySetActive $name | Out-Null
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
        $script:State.Hibernate = [bool]($p -and $p.PSObject.Properties['HibernateEnabled'] -and $p.HibernateEnabled -eq 1)
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

function Disable-MemoryCompression {
    $ram = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
    if ($ram -le 8) { Write-Log "Memory compression kept (RAM is $([Math]::Round($ram, 1)) GB, the change needs more than 8 GB)."; return }
    if (Test-DryRun 'disable memory compression') { return }
    if ($null -eq $script:State.MemCompress) { $script:State.MemCompress = [bool](Get-MMAgent).MemoryCompression }
    Disable-MMAgent -MemoryCompression
    Write-Log 'Memory compression disabled (takes effect after a restart).' 'OK'
}

function Disable-SleepStudy {
    if (Test-DryRun 'turn off the Sleep Study and power diagnostic event logs') { return }
    foreach ($log in 'Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic') {
        & wevtutil.exe sl $log /e:false | Out-Null
    }
    $script:State.SleepStudy = $true
}

function Set-PasswordExpiry {
    if ([Environment]::OSVersion.Version.Build -le 19045) { Write-Log 'Password expiry change skipped (Windows 11 only).'; return }
    if (Test-DryRun 'set the maximum local password age to unlimited') { return }
    & net.exe accounts /maxpwage:unlimited | Out-Null
    $script:State.PwAge = $true
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
        $script:State.ConsentDb = $backup
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
            Move-Item -LiteralPath $item.FullName -Destination $to -Force
            $script:State.DesktopMoved.Add([pscustomobject]@{ From = $item.FullName; To = $to })
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
    if ((Test-Path -LiteralPath $file) -and -not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $file -Destination $backup -Force }
    if (Test-Path -LiteralPath $backup) { $script:State.StartLayout = $backup }
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
    Write-Log 'Start menu layout restored.' 'OK'
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
        Set-RegValue -Path $root -Name 'DisableAntiSpyware' -Value 1
        foreach ($v in $rtpValues) { Set-RegValue -Path $rtp -Name $v -Value 1 }
        Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true -DisableIOAVProtection $true -ErrorAction Stop
        Write-Log 'Defender real time protection is now disabled. Windows may switch it back on after updates.' 'WARN'
    }
    else {
        if (Test-DryRun 'remove Defender policy blocks and enable real time protection') { return }
        Remove-RegValue -Path $root -Name 'DisableAntiSpyware'
        foreach ($v in $rtpValues) { Remove-RegValue -Path $rtp -Name $v }
        Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableIOAVProtection $false -ErrorAction Stop
        Write-Log 'Defender policy blocks removed and real time protection enabled.' 'OK'
    }
    $script:State.Defender = $true
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
    $mb = [Math]::Round([long](($leaves | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
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

function Clear-UpdateDownloadCache {
    $path = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $stopped = @()
    if (-not $script:DryRun) {
        foreach ($name in 'wuauserv', 'bits') {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') { $stopped += $name; Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
        }
    }
    try { Clear-FolderContents -Label 'Update cache cleanup' -Path $path }
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
    $out = (& bcdedit.exe /enum '{current}' 2>&1) | Out-String
    if ($LASTEXITCODE -ne 0) { throw "bcdedit /enum failed: $($out.Trim())" }
    $m = [regex]::Match($out, "(?m)^$([regex]::Escape($Name))\s+(\S+)\s*$")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Disable-Dep {
    if (Test-DryRun 'set the boot option nx to AlwaysOff (Data Execution Prevention off, Secure Boot must be off)') { return }
    if (-not $script:State.Dep) { $script:State.Dep = [pscustomobject]@{ Previous = (Get-BcdValue 'nx') } }
    $out = (& bcdedit.exe /set nx AlwaysOff 2>&1) | Out-String
    if ($LASTEXITCODE -ne 0) { throw "bcdedit could not set nx (Secure Boot must be off for this): $($out.Trim())" }
    Write-Log 'Data Execution Prevention is switched off. Restart Windows to apply.' 'WARN'
}

function Restore-Dep {
    # The saved value comes from a file, so only values bcdedit accepts for nx are passed on.
    $previous = $script:State.Dep.Previous
    if ($previous -and @('OptIn', 'OptOut', 'AlwaysOn', 'AlwaysOff') -notcontains [string]$previous) { throw "Unexpected saved nx value '$previous', not restoring it." }
    if ($previous) { $out = (& bcdedit.exe /set nx $previous 2>&1) | Out-String }
    else { $out = (& bcdedit.exe /deletevalue nx 2>&1) | Out-String }
    if ($LASTEXITCODE -ne 0 -and ($previous -or (Get-BcdValue 'nx'))) { throw "bcdedit could not restore nx: $($out.Trim())" }
    Write-Log "Data Execution Prevention restored ($(if ($previous) { $previous } else { 'value removed' })). Restart Windows to apply." 'OK'
}

function Install-TimerResolutionService {
    $dir = Join-Path $env:ProgramFiles 'FocusedTweaks'
    $exe = Join-Path $dir 'TimerResolution.exe'
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (Test-DryRun "build $exe with csc.exe, install and start the service '$TimerServiceName', set GlobalTimerResolutionRequests 1") { return }
    if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe was not found at $csc (.NET Framework 4 is required)." }
    $script:State.TimerService = [pscustomobject]@{ Name = $TimerServiceName; Dir = $dir; Exe = $exe }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $existing = Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Status -ne 'Stopped') { Stop-Service -Name $TimerServiceName -Force }
    $source = Join-Path $dir 'TimerResolution.cs'
    Set-Content -LiteralPath $source -Value $TimerServiceSource -Encoding ASCII
    try {
        $out = (& $csc /nologo /target:exe "/out:$exe" /reference:System.ServiceProcess.dll $source 2>&1) | Out-String
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
    param([string]$Label, [object[]]$Tweaks)
    if ($Tweaks.Count -eq 0) { Write-Log "$Label`: nothing to change on this machine."; return }
    $keys = @($Tweaks | ForEach-Object { $_.Path } | Select-Object -Unique).Count
    if (Test-DryRun "$Label`: set $($Tweaks.Count) value(s) under $keys registry key(s)") { return }
    $denied = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $Tweaks) {
        $full = ConvertTo-FullRegPath $t.Path
        try {
            Save-CreatedKeys -Full $full
            Save-RegSnapshot -Full $full -Name $t.Name
            Write-RegRaw -Full $full -Name $t.Name -Value $t.Value -Kind $t.Type
        }
        catch {
            if (Test-AccessDenied $_) { $denied.Add([pscustomobject]@{ Full = $full; Tweak = $t }) }
            else { $script:Failures++; Write-Log "Registry write failed: $full\$(Show-RegName $t.Name). $($_.Exception.Message)" 'ERROR' }
        }
    }
    # About 30 commands keep the encoded command well below the service command line limit.
    for ($i = 0; $i -lt $denied.Count; $i += 30) {
        $chunk = @($denied[$i..([Math]::Min($i + 29, $denied.Count - 1))])
        [void](Invoke-AsTI -PsCommand (($chunk | ForEach-Object { Format-TiRegAdd -Full $_.Full -Name $_.Tweak.Name -Value $_.Tweak.Value -Kind $_.Tweak.Type }) -join '; '))
    }
    $failed = @($denied | Where-Object { -not (Test-RegValueNow -Full $_.Full -Name $_.Tweak.Name -Value $_.Tweak.Value -Kind $_.Tweak.Type) }).Count
    if ($failed -gt 0) { Write-Log "$Label`: $failed of $($Tweaks.Count) value(s) could not be set, even as TrustedInstaller." 'WARN' }
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
    $out = (& w32tm.exe /config /update 2>&1) | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Log "w32tm /config /update failed: $($out.Trim())" 'WARN'; return }
    $out = (& w32tm.exe /resync /nowait 2>&1) | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Log "w32tm /resync failed, Windows will retry on its own: $($out.Trim())" 'WARN' }
}

function Set-TimeServer {
    Set-TweakList $TimeServerRegs
    if ($script:DryRun) { return }
    Update-TimeService
    Write-Log 'Time is now synced from pool.ntp.org.' 'OK'
}
#endregion

#region Health check ---------------------------------------------------------------------
$script:Health = @{ PASS = 0; WARN = 0; FAIL = 0; INFO = 0 }
$script:SoftRuntime = $false
$script:PostApply = $false
$script:AppliedAt = $null

function Write-Health {
    param([ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Area, [string]$Message)
    $script:Health[$Status]++
    $colour = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    $line = '{0:HH:mm:ss} [{1}] {2,-9} {3}' -f (Get-Date), $Status, $Area, $Message
    Write-Host $line -ForegroundColor $colour
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
    foreach ($op in $ops) {
        $optName = Get-RegGroupOption $op.Group
        if (-not $Opt[$optName]) { continue }
        if (Test-NameMatch $op.Group $SkipRegGroup) { continue }
        $full = ConvertTo-FullRegPath $op.Path
        if ($op.Action -ne 'DeleteKey' -and $later.Contains("$full|$($op.Name)")) { $overridden++; continue }
        $checked++
        switch ($op.Action) {
            'Set' {
                $snap = Get-RegSnapshot -Full $full -Name $op.Name
                if (-not (Test-RegMatchesOp -Snap $snap -Op $op)) {
                    $bad.Add(('[{0}] {1}\{2} is {3}' -f $op.Group, $full, (Show-RegName $op.Name), (Format-RegValueShort $snap)))
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
    if ($Opt['TimerResolution']) { Test-HealthTweakTable -Label 'Global timer resolution requests' -Tweaks $TimerGlobalRegs }
    if ($Opt['NetAdapterPower'] -or $Opt['NetAdapterEee']) {
        $keywords = @(); if ($Opt['NetAdapterPower']) { $keywords += $NetPowerKeywords }; if ($Opt['NetAdapterEee']) { $keywords += $NetEeeKeywords }
        $net = @(Get-NetAdapterTweaks -Keywords $keywords -AllowOff:([bool]$Opt['NetAdapterPower']))
        if ($net.Count -gt 0) { Test-HealthTweakTable -Label 'Network adapter power settings' -Tweaks $net }
        else { Write-Health 'INFO' 'Registry' 'No physical network adapter keys were found, so the adapter power settings could not be checked.' }
    }
    # Device lists change when hardware is added, so only the values the run itself recorded are checked.
    $recorded = { param($list) @($list | Where-Object { $script:RecordedReg.Contains("$(ConvertTo-FullRegPath $_.Path)|$($_.Name)") }) }
    if ($Opt['DevicePowerSaving']) {
        $dev = & $recorded @(Get-DeviceTweaks -Power)
        if ($dev.Count -gt 0) { Test-HealthTweakTable -Label 'Device power saving' -Tweaks $dev }
        else { Write-Health 'INFO' 'Registry' 'Device power saving: no recorded values (skipped on battery, or not run yet).' }
    }
    if ($Opt['DeviceWakeOff']) {
        $wake = & $recorded @(Get-DeviceTweaks -Wake)
        if ($wake.Count -gt 0) { Test-HealthTweakTable -Label 'Device wake' -Tweaks $wake }
    }
    if ($Opt['WriteCacheFlushOff']) {
        $cache = & $recorded @(Get-WriteCacheTweaks)
        if ($cache.Count -gt 0) { Test-HealthTweakTable -Label 'Write cache buffer flushing off' -Tweaks $cache }
    }
    if ($Opt['MpoOff']) { Test-HealthTweakTable -Label 'Multiplane overlay off' -Tweaks $MpoRegs }
    if ($Opt['FastShutdown']) { Test-HealthTweakTable -Label 'Faster shutdown' -Tweaks $FastShutdownRegs }
    if ($Opt['BlockFeatureUpgrades']) { Test-HealthTweakTable -Label 'Feature upgrade block' -Tweaks @(Get-FeatureUpgradeTweaks) }
    if ($Opt['TimeServerPool']) { Test-HealthTweakTable -Label 'Time server' -Tweaks $TimeServerRegs }
    if ($Opt['MenuKillNotResponding']) { Test-HealthTweakTable -Label 'Kill not responding menu' -Tweaks $MenuKillRegs }
    if ($Opt['MenuRestartExplorer']) { Test-HealthTweakTable -Label 'Restart Explorer menu' -Tweaks $MenuRestartExplorerRegs }
    if ($Opt['MenuTakeOwnership']) { Test-HealthTweakTable -Label 'Take ownership menu' -Tweaks $MenuTakeOwnershipRegs }
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
        if ($ram -gt 8) {
            if (-not (Get-MMAgent).MemoryCompression) { Write-Health 'PASS' 'System' 'Memory compression is off.' }
            else { Write-Health 'INFO' 'System' 'Memory compression is still on. It changes after a restart.' }
        }
    }
    if ($Opt['SleepStudy']) {
        $on = @('Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic' | Where-Object { ((& wevtutil.exe gl $_) | Out-String) -match 'enabled:\s*true' })
        if ($on.Count -eq 0) { Write-Health 'PASS' 'System' 'Sleep Study and power diagnostic logs are off.' } else { Write-Health 'WARN' 'System' "$($on.Count) power diagnostic log(s) are still enabled." }
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
    if ($Opt['SearchIndexingOff']) {
        if ((Get-ServiceStartNow 'WSearch') -eq 4) { Write-Health 'PASS' 'System' 'Windows Search indexing is disabled.' }
        else { Write-Health 'WARN' 'System' 'Windows Search indexing was meant to be disabled, but the WSearch service is not.' }
    }
    if ($Opt['TimerResolution']) {
        $svc = Get-Service -Name $TimerServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { Write-Health 'PASS' 'System' "Timer resolution service '$TimerServiceName' is running." }
        elseif ($svc) { Write-Health 'WARN' 'System' "Timer resolution service '$TimerServiceName' is installed but $($svc.Status)." }
        else { Write-Health 'WARN' 'System' "Timer resolution service '$TimerServiceName' is not installed." }
    }
    $pending = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    ($null -ne (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue))
    if ($pending -or $script:SoftRuntime) { Write-Health 'INFO' 'System' 'A restart is pending or needed, so some results above show the state before it.' }
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

function Invoke-HealthCheck {
    $script:Health = @{ PASS = 0; WARN = 0; FAIL = 0; INFO = 0 }
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
}
#endregion

#region Orchestration ---------------------------------------------------------------------
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

function Show-Plan {
    Write-Log "Mode: $(if ($script:DryRun) { 'DRY RUN (no changes)' } else { 'APPLY' }). State and logs: $StateDir"
    $on = @($OptionInfo.Keys | Where-Object { $Opt[$_] })
    $off = @($OptionInfo.Keys | Where-Object { -not $Opt[$_] })
    Write-Log "  Options on : $($on -join ', ')"
    Write-Log "  Options off: $($off -join ', ')"
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
    if ($TaskMode -eq 'Delete') { $notes += 'All scheduled tasks will be deleted (backups are kept).' }
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
    $script:State.Run = [pscustomobject]@{
        When = (Get-Date).ToString('o'); Options = [pscustomobject]$merged; TaskMode = $mTask; Defender = $mDef
        PowerProfile = $mPower; PauseDays = $mDays; SkipRegGroup = @($mSkip | Select-Object -Unique)
    }
    if ([Environment]::OSVersion.Version.Build -lt 19041) { Write-Log 'This script targets Windows 10 2004 (19041) or later. Behaviour on older builds is untested.' 'WARN' }
    $edition = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction SilentlyContinue
    if ($edition -and $edition.PSObject.Properties['EditionID'] -and $edition.EditionID -eq 'Core') {
        Write-Log 'Windows Home detected. Several policies (telemetry level, update deferral) may be ignored on this edition.' 'WARN'
    }
    if (-not $SkipRestorePoint -and -not $script:DryRun) { Invoke-Step 'Restore point' { New-SafetyRestorePoint } }
    if ($Opt['DefenderQuiet'] -or $Defender -eq 'Disable') { Wait-TamperProtectionOff }

    if ($Opt['Packages']) { Invoke-Step 'Packages' { Install-RuntimePackages } }
    if ($WantNvidia) { Invoke-Step 'NVIDIA driver' { Install-NvidiaDriver } }
    if ($Opt['Debloat']) { Invoke-Step 'App debloat' { Remove-BloatApps } }
    if ($Opt['PrivacyDenials']) { Invoke-Step 'Consent database reset' { Reset-ConsentDatabase } }
    if ($Opt['RemoveQuickAssist']) { Invoke-Step 'Remove Quick Assist' { Remove-QuickAssist } }
    if ($Opt['Registry'] -or $Opt['Uac'] -or $Opt['RunKeys'] -or $Opt['PrivacyDenials'] -or $Opt['CoreIsolation'] -or $Opt['HideLockOption'] -or $Opt['HideSleepOption'] -or $Opt['RegHibernateOff'] -or $Opt['TaskbarEndTask']) { Invoke-Step 'Registry tweaks' { Import-UpstreamRegistry } }
    if ($Opt['Uac']) { Invoke-Step 'LUA file virtualization' { Set-ServiceStart -Name 'luafv' -Mode Disabled } }
    if ($Opt['TelemetryPolicy'] -or $Opt['BiometricsPolicy'] -or $Opt['Cdp'] -or $Opt['TelemetryHosts']) { Invoke-Step 'Telemetry' { Invoke-TelemetryTweaks } }
    if (@($ServiceGroups.Keys | Where-Object { $Opt[$_] }).Count -gt 0) { Invoke-Step 'Service groups' { Disable-ServiceGroups } }
    if ($TaskMode -ne 'None') { Invoke-Step "Scheduled tasks ($TaskMode)" { Invoke-TaskMode } }
    if ($Opt['RazerAsusHosts']) { Invoke-Step 'Razer and ASUS hosts block' { Set-RazerAsusBlock } }
    if ($Opt['DriverExclusion'] -or $Opt['SecurityUpdatesOnly'] -or $Opt['PauseUpdates']) { Invoke-Step 'Windows Update policy' { Set-UpdatePolicies } }
    if ($PowerProfile -ne 'Off') { Invoke-Step "Power plan ($PowerProfile)" { Set-PerformancePowerPlan } }
    if ($PowerMode -ne 'Keep') { Invoke-Step "Power mode ($PowerMode)" { Set-PowerModeOverlay } }
    if ($Opt['DisableHibernate']) { Invoke-Step 'Disable hibernation' { Disable-Hibernation } }
    if ($Opt['MouseAccel']) { Invoke-Step 'Mouse acceleration' { Disable-MouseAcceleration } }
    if ($Opt['MsiMode']) { Invoke-Step 'MSI mode' { Set-MsiMode } }
    if ($Opt['MemoryCompression']) { Invoke-Step 'Memory compression' { Disable-MemoryCompression } }
    if ($Opt['SleepStudy']) { Invoke-Step 'Sleep Study logs' { Disable-SleepStudy } }
    if ($Opt['PasswordExpiry']) { Invoke-Step 'Password expiry' { Set-PasswordExpiry } }
    if ($Opt['FaultTolerantHeap']) { Invoke-Step 'Fault tolerant heap' { Reset-FaultTolerantHeap } }
    if ($Opt['NotificationSettings']) { Invoke-Step 'App notification settings' { Disable-NotificationSettings } }
    if ($Defender -eq 'Keep') { Write-Log 'Microsoft Defender left untouched.' } else { Invoke-Step "Defender ($Defender)" { Set-DefenderState -Mode $Defender } }
    if ($Opt['DefenderQuiet']) { Invoke-Step 'Quiet Defender' { Set-DefenderQuiet } }
    if ($Opt['NetAdapterPower']) { Invoke-Step 'Network adapter power saving' { Set-NetAdapterOff -Label 'Network adapter power saving' -Keywords $NetPowerKeywords -AllowOff } }
    if ($Opt['NetAdapterEee']) { Invoke-Step 'Energy Efficient Ethernet' { Set-NetAdapterOff -Label 'Energy Efficient Ethernet' -Keywords $NetEeeKeywords } }
    if ($Opt['SpectreMeltdownOff']) { Invoke-Step 'Spectre and Meltdown mitigations' { Disable-SpectreMeltdownMitigations } }
    if ($Opt['DepOff']) { Invoke-Step 'Data Execution Prevention' { Disable-Dep } }
    if ($Opt['TimerResolution']) { Invoke-Step 'Timer resolution service' { Install-TimerResolutionService } }
    if ($Opt['DevicePowerSaving']) { Invoke-Step 'Device power saving' { Set-DevicePowerSaving } }
    if ($Opt['DeviceWakeOff']) { Invoke-Step 'Device wake' { Set-TweakListBatched -Label 'Device wake off' -Tweaks @(Get-DeviceTweaks -Wake) } }
    if ($Opt['WriteCacheFlushOff']) { Invoke-Step 'Write cache buffer flushing' { Set-TweakListBatched -Label 'Write cache buffer flushing off' -Tweaks @(Get-WriteCacheTweaks) } }
    if ($Opt['MpoOff']) { Invoke-Step 'Multiplane overlay' { Set-TweakList $MpoRegs } }
    if ($Opt['FastShutdown']) { Invoke-Step 'Faster shutdown' { Set-TweakList $FastShutdownRegs } }
    if ($Opt['BlockFeatureUpgrades']) { Invoke-Step 'Feature upgrade block' { Set-FeatureUpgradeBlock } }
    if ($Opt['SearchIndexingOff']) { Invoke-Step 'Search indexing' { Set-ServiceStart -Name 'WSearch' -Mode Disabled } }
    if ($Opt['TimeServerPool']) { Invoke-Step 'Time server' { Set-TimeServer } }
    if ($Opt['MenuKillNotResponding']) { Invoke-Step 'Kill not responding menu' { Set-TweakList $MenuKillRegs } }
    if ($Opt['MenuRestartExplorer']) { Invoke-Step 'Restart Explorer menu' { Set-TweakList $MenuRestartExplorerRegs } }
    if ($Opt['MenuTakeOwnership']) { Invoke-Step 'Take ownership menu' { Set-TweakList $MenuTakeOwnershipRegs } }
    if ($Opt['ClearDesktopIcons']) { Invoke-Step 'Clear desktop icons' { Clear-DesktopIcons } }
    if ($Opt['ClearStartPins']) { Invoke-Step 'Clear Start menu pins' { Clear-StartPins } }
    if ($Opt['TempCleanup']) { Invoke-Step 'Temp cleanup' { Clear-TempFiles } }
    if ($Opt['UpdateCacheCleanup']) { Invoke-Step 'Update cache cleanup' { Clear-UpdateDownloadCache } }
    if ($Opt['RestartExplorer'] -or $script:ShellDirty) { Invoke-Step 'Refresh settings and restart Explorer' { Update-UserVisuals } }
    if ($Opt['HealthCheckAfter'] -and -not $script:DryRun) { $script:PostApply = $true; Invoke-Step 'Health check' { Invoke-HealthCheck } }
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
    Invoke-Step 'Restore deleted registry keys' {
        foreach ($k in $script:State.KeyBackups) {
            if (Test-Path -LiteralPath $k.File) { & reg.exe import $k.File *> $null; if ($LASTEXITCODE -ne 0) { Write-Log "Could not import $($k.File)" 'WARN' } }
        }
    }
    Invoke-Step 'Restore hosts file' {
        foreach ($name in $script:State.Hosts) {
            Write-HostsFile -Text (Remove-HostsText -Text ([IO.File]::ReadAllText($HostsPath)) -Name $name)
            Write-Log "Hosts block removed: $name" 'OK'
        }
    }
    if ($script:State.Tasks.Count -gt 0) { Invoke-Step 'Restore scheduled tasks' { Restore-Tasks } }
    Invoke-Step 'Restore power plan' { Restore-PowerPlan }
    if ($script:State.PowerOverlay) { Invoke-Step 'Restore power mode' { Restore-PowerMode } }
    if ($script:State.Hibernate -eq $true) { Invoke-Step 'Restore hibernation' { powercfg /hibernate on | Out-Null; Write-Log 'Hibernation re-enabled.' 'OK' } }
    if ($script:State.MemCompress -eq $true) { Invoke-Step 'Restore memory compression' { Enable-MMAgent -MemoryCompression; Write-Log 'Memory compression re-enabled.' 'OK' } }
    if ($script:State.SleepStudy -eq $true) {
        Invoke-Step 'Restore Sleep Study logs' {
            foreach ($log in 'Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic') { & wevtutil.exe sl $log /e:true | Out-Null }
        }
    }
    if ($script:State.PwAge -eq $true) { Invoke-Step 'Restore password expiry' { & net.exe accounts /maxpwage:42 | Out-Null; Write-Log 'Maximum password age set back to 42 days.' 'OK' } }
    if ($script:State.ConsentDb) {
        Invoke-Step 'Restore consent database' {
            Stop-Service -Name camsvc -Force -ErrorAction SilentlyContinue
            Copy-Item -Path (Join-Path $script:State.ConsentDb '*') -Destination (Join-Path $env:ProgramData 'Microsoft\Windows\CapabilityAccessManager') -Force
        }
    }
    if ($script:State.Defender -eq $true) {
        Invoke-Step 'Re-enable Defender real time protection' {
            Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableIOAVProtection $false -ErrorAction Stop
            Write-Log 'Defender real time protection enabled.' 'OK'
        }
    }
    if ($script:State.Dep) { Invoke-Step 'Restore Data Execution Prevention' { Restore-Dep } }
    if ($script:State.TimerService) { Invoke-Step 'Remove timer resolution service' { Remove-TimerResolutionService } }
    if ($script:State.StartLayout) { Invoke-Step 'Restore Start menu layout' { Restore-StartPins } }
    if ($script:State.DesktopMoved.Count -gt 0) { Invoke-Step 'Restore desktop shortcuts' { Restore-DesktopIcons } }
    if (@($script:State.Registry | Where-Object { $_.Path -like '*Control Panel\Mouse' }).Count -gt 0) { Invoke-Step 'Refresh mouse settings' { Sync-MouseSettings } }
    if ($script:State.Removed.Count -gt 0) {
        Write-Log ('Apps removed earlier (reinstall from the Store or winget if wanted): ' + (($script:State.Removed | Sort-Object -Unique) -join ', ')) 'WARN'
    }
    if ($script:ShellDirty) { Update-UserVisuals }
    $archive = Join-Path $StateDir ('state.reverted-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    Move-Item -LiteralPath $StateFile -Destination $archive -Force
    Write-Log "State archived to $archive"
}
#endregion

#region Entry point -----------------------------------------------------------------------
if ($Revert -and $DryRun) { throw '-DryRun is not supported together with -Revert.' }
Initialize-StateDir
Import-State
try { Repair-TrustedInstallerPath }
catch { $script:Failures++; Write-Log $_.Exception.Message 'ERROR' }
if ($HealthCheck) {
    Restore-SavedRunSettings
    Invoke-HealthCheck
    exit ([int]($script:Health.FAIL -gt 0))
}
if ($Revert) { Invoke-Revert }
else {
    Show-Plan
    if (-not (Confirm-Run)) { Write-Log 'Cancelled, nothing was changed.' 'WARN'; exit 2 }
    Invoke-Apply
    Save-State
}

if ($script:DryRun) { Write-Log 'Dry run complete. Nothing was changed.' 'OK'; exit 0 }
if ($script:Failures -gt 0) { Write-Log "Finished with $($script:Failures) failure(s) and $($script:Warnings) warning(s). Review the log: $LogFile" 'WARN' }
else { Write-Log "Finished without errors ($($script:Warnings) warning(s)). Log: $LogFile" 'OK' }
Write-Log 'Restart Windows so service, policy and power changes take full effect.'
exit ([int]($script:Failures -gt 0))
#endregion
