#region Data (generated from the upstream ZOICWARE source) ---------------------------------
function New-Tweak {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    [pscustomobject]@{ Path = $Path; Name = $Name; Value = $Value; Type = $Type }
}

#@@UPSTREAM_REG@@

#@@TELEMETRY@@

#@@DOMAINS@@

#@@MOUSE@@

#@@UPDATES@@

#@@STARTLAYOUT@@

# winget package IDs. 7-Zip is installed before the NVIDIA step, which needs it.
$PackageIds = @(
    'Microsoft.VCRedist.2015+.x64'
    'Microsoft.VCRedist.2015+.x86'
    'Microsoft.DirectX'
    '7zip.7zip'
    'Mozilla.Firefox'
    'Orbmu2k.nvidiaProfileInspector'
    'Microsoft.Sysinternals.Autoruns'
    # Not HWiNFO: its site removes each old installer on release, and winget's link breaks until its entry catches
    # up (HTTP 404 on 13 Nov 2026, version 8.60 out, winget still on 8.54). docs/GUIDE.md says how to get it.
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
    '*Hulu*', '*Duolingo*', '*Pinterest*', '*WhatsApp*',
    # From the coverage comparison (two or more other projects remove them). Microsoft.MSPaint is Paint 3D, not Paint;
    # StartExperiencesApp is the Widgets board feed and Client.WebExperience the Widgets board itself.
    'Microsoft.WindowsCamera', 'Microsoft.windowscommunicationsapps', 'Microsoft.Messaging', 'Microsoft.MSPaint',
    'Microsoft.NetworkSpeedTest', 'Microsoft.Office.OneNote', 'Microsoft.Office.Sway', 'Microsoft.RemoteDesktop',
    'Microsoft.StartExperiencesApp', 'MicrosoftWindows.Client.WebExperience', '*PhotoshopExpress*',
    # From the VM inventory of 14 Nov 2026: Edge's in-game browser overlay, installed for new users too.
    'Microsoft.Edge.GameAssist',
    # From the CI inventory of the Windows 11 runner (14 Nov 2026): the engine behind Widgets, idle once the Widgets board
    # and its feed above are gone.
    'Microsoft.WidgetsPlatformRuntime'
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
# VendorServices, from the advice in tools/Explain-Processes.ps1 (checked on a ThinkPad X1 Carbon, Nov 2026). Thermal,
# power, Fn key, audio, HDCP and display colour services are never touched: laptops misbehave without them.
$VendorServicesDisable = @('LenovoVantageService', 'ImControllerService', 'SmartSense', 'EPDService', 'IntelCstService')
$VendorServicesManual = @('LenovoSmartStandby', 'LvfInstallService', 'WMIRegistrationService', 'dptftcs', 'IntelGraphicsSoftwareService')

# Startup entries RunKeys never deletes: the Windows Security tray icon (its alerts), and the VMware Tools user
# process, without which a VM loses copy and paste, resizing and guest operations.
$StartupKeepBuiltIn = @('SecurityHealth', 'VMware User Process')

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
    # This script's own task that ends the update pause (Register-PauseEndTask).
    '\FocusedTweaks\*'
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

# Edge in the background: startup boost starts Edge processes at sign in, background mode keeps them after the last
# window closes. Both are Microsoft Edge policies that apply without a domain.
$EdgeBackgroundRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0 'DWord'
)

# The one-off task that removes NoAutoUpdate again when the pause ends (Register-PauseEndTask).
$PauseEndTaskPath = '\FocusedTweaks\'
$PauseEndTaskName = 'End update pause'

# While updates are paused: no automatic checks, downloads or installs. The Update Orchestrator registers and enables
# its Schedule Scan and Schedule Work tasks again at every start, so disabling them does not hold; this documented
# policy makes them do nothing instead. A policy has no end date, so a one-off task removes it when the pause ends and
# updates resume by themselves. Checking for updates by hand in Settings still works, and Defender definitions arrive.
$NoAutoUpdateRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1 'DWord'
)

# Windows AI per user. The WindowsAI policy CSP (Microsoft Learn, checked 12 Nov 2026) lists TurnOffWindowsCopilot as a
# user policy only, and DisableAIDataAnalysis and DisableClickToDo for device and user; the upstream group writes them
# under HKLM only. HubsSidebarEnabled 0 hides the Edge sidebar, where Copilot lives.
$WindowsAIRegs = @(
    New-Tweak 'HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 'DWord'
    New-Tweak 'HKCU\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 'DWord'
    New-Tweak 'HKCU\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0 'DWord'
    # From the coverage comparison (docs/COVERAGE.md, Nov 2026): the newer Recall policy name next to the older
    # DisableAIDataAnalysis, Paint's AI tools, and the Copilot pin screen after updates.
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1 'DWord'
    New-Tweak 'HKCU\Software\Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableGenerativeErase' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableRemoveBackground' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCopilotPinScreen' 1 'DWord'
)

# More telemetry off, from the coverage comparison (docs/COVERAGE.md, Nov 2026): values two or more of winutil,
# Win11Debloat, Sophia Script and privacy.sexy set that the upstream groups do not. Office, Visual Studio and NVIDIA
# values only matter where those are installed; -Revert removes the keys this creates.
$TelemetryExtraRegs = @(
    # Windows Error Reporting off (upstream only stops the extra data). The services are in SvcDiagnostics.
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'LoggingDisabled' 1 'DWord'
    # Advertising ID for this account (upstream sets the machine value), typing, inking and online speech data.
    New-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Input\TIPC' 'Enabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\Input\TIPC' 'Enabled' 0 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Speech_OneCore\Preferences' 'ModelDownloadAllowed' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports' 'PreventHandwritingErrorReports' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\TabletPC' 'PreventHandwritingDataSharing' 1 'DWord'
    # Customer experience program, feedback prompts, feature trials, licence check-ins, tips and suggestions.
    New-Tweak 'HKLM\SOFTWARE\Microsoft\SQMClient\Windows' 'CEIPEnable' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds' 'EnableConfigFlighting' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds' 'EnableExperimentation' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform' 'NoGenTicket' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowOnlineTips' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 1 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\Mobility' 'OptedIn' 0 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested' 'Enabled' 0 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.BackupReminder' 'Enabled' 0 'DWord'
    # Search: no Cortana, cloud results, highlights or location. The location policy matches SvcOther, which already
    # stops the location service.
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCloudSearch' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowSearchToUseLocation' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchPrivacy' 3 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWebOverMeteredConnections' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1 'DWord'
    # NVIDIA driver and control panel telemetry opt-out (next to NvidiaTelemetryStrip, which removes the files).
    New-Tweak 'HKLM\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client' 'OptInOrOutPreference' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID44231' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID64640' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS' 'EnableRID66610' 0 'DWord'
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup' 'SendTelemetryData' 0 'DWord'
    # Office (2016 and later) and Visual Studio telemetry, logging and feedback.
    New-Tweak 'HKCU\Software\Microsoft\Office\Common\ClientTelemetry' 'DisableTelemetry' 1 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Office\16.0\Common\ClientTelemetry' 'DisableTelemetry' 1 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Office\16.0\Common\ClientTelemetry' 'VerboseLogging' 0 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Office\16.0\Common\Feedback' 'Enabled' 0 'DWord'
    New-Tweak 'HKCU\Software\Policies\Microsoft\Office\16.0\Common' 'QMEnable' 0 'DWord'
    New-Tweak 'HKCU\Software\Policies\Microsoft\Office\16.0\OSM' 'EnableLogging' 0 'DWord'
    New-Tweak 'HKCU\Software\Policies\Microsoft\Office\16.0\OSM' 'EnableUpload' 0 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\VisualStudio\Telemetry' 'TurnOffSwitch' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\SQM' 'OptIn' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback' 'DisableFeedbackDialog' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback' 'DisableEmailInput' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback' 'DisableScreenshotCapture' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\IntelliCode' 'DisableRemoteAnalysis' 1 'DWord'
)

# Browser ads, telemetry and AI off by policy (Edge, Chrome, Brave, Firefox), from the coverage comparison. Values
# for a browser that is not installed do nothing. A browser with policies says it is managed by your organisation.
$BrowserPolicyRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'DiagnosticData' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'PersonalizationReportingEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'UserFeedbackAllowed' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'ConfigureDoNotTrack' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'AlternateErrorPagesEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'ShowRecommendationsEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'SpotlightExperiencesAndRecommendationsEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'EdgeShoppingAssistantEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'ShowMicrosoftRewards' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'WalletDonationEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'ShowAcrobatSubscriptionButton' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'HideFirstRunExperience' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'DefaultBrowserSettingEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'DefaultBrowserSettingsCampaignEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'MicrosoftEdgeInsiderPromotionEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'NewTabPageContentEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'NewTabPageHideDefaultTopSites' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'EdgeAssetDeliveryServiceEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'WebWidgetAllowed' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'CopilotPageContext' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'CopilotCDPPageContext' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'EdgeEntraCopilotPageContext' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'Microsoft365CopilotChatIconEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'NewTabPageBingChatEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'ComposeInlineEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'EdgeHistoryAISearchEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'GenAILocalFoundationalModelSettings' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault' 0 'DWord'
    # Chrome: Gemini and the other AI features. Each *Settings policy has its own scale (1 or 2 is "not allowed").
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'GeminiSettings' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'GeminiSparkSettings' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'AIModeSettings' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'GenAILocalFoundationalModelSettings' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'ChromeSuggestionsSettings' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'SearchContentSharingSettings' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'SmartTabSharingSettings' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'ThirdPartyAiChatSettings' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'AutofillPredictionSettings' 2 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'CreateThemesSettings' 2 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'DevToolsGenAiSettings' 2 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'FindAndFillWithGeminiSettings' 2 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'HelpMeWriteSettings' 2 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'HistorySearchSettings' 2 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'TabCompareSettings' 2 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Google\Chrome' 'VoiceTypingSettings' 2 'DWord'
    # Brave: rewards, wallet, VPN, news, Talk, AI chat, Tor windows and its usage pings.
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveRewardsDisabled' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveWalletDisabled' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveVPNDisabled' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveNewsDisabled' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveTalkDisabled' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveAIChatEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'TorDisabled' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveP3AEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'BraveStatsPingEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'MetricsReportingEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'SafeBrowsingExtendedReportingEnabled' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'UrlKeyedAnonymizedDataCollectionEnabled' 0 'DWord'
    # Firefox: telemetry and the default browser agent's reports.
    New-Tweak 'HKLM\SOFTWARE\Policies\Mozilla\Firefox' 'DisableTelemetry' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Mozilla\Firefox' 'DisableDefaultBrowserAgent' 1 'DWord'
)

# Windows 11 caps mouse raw input to windows in the background at about 125 reports a second; 0 lifts the cap (idea
# from FR33THY Ultimate, "Background Polling Rate Cap"). Check with tools/Test-Mouse.ps1.
$MouseFullRateRegs = @(
    New-Tweak 'HKCU\Control Panel\Mouse' 'RawMouseThrottleEnabled' 0 'DWord'
)

# Startup apps start at once instead of after Explorer's delay of about ten seconds.
$StartupDelayRegs = @(
    New-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0 'DWord'
    New-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'WaitForIdleState' 0 'DWord'
)

# Windows 11 turns on BitLocker device encryption by itself at setup or sign in on many PCs. This stops it doing
# that; a drive that is already encrypted stays encrypted (turn it off in Settings if wanted).
$NoDeviceEncryptionRegs = @(
    New-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1 'DWord'
)

# No automatic restart for updates while someone is signed in, and no early feature rollouts ("Get the latest
# updates as soon as they're available" off).
$UpdateNoRebootRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'IsContinuousInnovationOptedIn' 0 'DWord'
)

# Modern standby: no network while the PC sleeps (power setting "Networking connectivity in Standby", policy), so
# nothing downloads or syncs in sleep. PCs with classic S3 sleep ignore it.
$StandbyNetworkRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9' 'ACSettingIndex' 0 'DWord'
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9' 'DCSettingIndex' 0 'DWord'
)

# OneDrive: after the uninstall this policy stops it from setting itself up again or being used.
$OneDriveRegs = @(
    New-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1 'DWord'
)

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
    # Game Bar sets it again on its own: in the VM test of 11 Nov 2026 (build 26200) it was 0, the run wrote 0, and it
    # was 1 after -Revert, although nothing in this script writes 1.
    'HKEY_CURRENT_USER\System\GameConfigStore|GameDVR_Enabled'
    # The USB 3 root hub driver saves its own idle setting: in both VM tests (8 and 11 Nov 2026) every other device
    # took the original back on -Revert, the root hub kept the run's 0. Wildcard: the instance ID differs per PC.
    'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\USB\ROOT_HUB30\*\Device Parameters\WDF|IdleInWorkingState'
    # The policy store cache: Windows recomputes it from the policies in force. On the Windows 11 ARM runner (13 Nov
    # 2026) -Revert wrote the original 1 back and Windows had set it to 0 again from that image's own policy.
    'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\AllowTelemetry|Value'
    # Spotlight keeps its own on/off state: on the Windows 11 ARM runner about half the runs found 0 again right after
    # -Revert wrote the original 1 back, with the same code (CI, 13 and 14 Nov 2026).
    'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings|EnabledState'
)

function Test-WindowsRewritten {
    # Entries may hold wildcards (device instance IDs differ per PC).
    param([string]$Path, [string]$Name)
    $id = "$Path|$Name"
    foreach ($w in $WindowsRewrittenValues) { if ($id -like $w) { return $true } }
    return $false
}

# Tasks that UsoSvc registers, enables and disables itself (the run already handles the copies it registers again).
# After -Revert puts them back, UsoSvc may set their state to its own liking within minutes: in the VM test of
# 11 Nov 2026, 'Schedule Work' was enabled by the revert and disabled again four minutes later.
$WindowsManagedTasks = @('\Microsoft\Windows\UpdateOrchestrator\*')

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

