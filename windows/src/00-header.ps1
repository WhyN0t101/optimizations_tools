#Requires -Version 5.1
<#
.SYNOPSIS
    Focused Windows 10/11 tweak script derived from ZOICWARE (MIT licence, copyright (c) 2024 zoicware). v7.8.

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
    or battery for speed. Switch them off with -Skip. The former DepOff option is gone (no speed gain, and it needed
    Secure Boot off); -Revert still restores DEP for state files from runs that used it.

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
    [switch]$Reapply,
    [string[]]$Skip = @(),
    [string[]]$Enable = @(),
    [string[]]$Only = @(),
    [string[]]$SkipRegGroup = @(),
    [ValidateSet('Delete', 'Disable', 'None')][string]$TaskMode = 'Delete',
    [ValidateSet('Disable', 'Delete')][string]$ServiceMode = 'Disable',
    [string[]]$TaskKeep = @(),
    [string[]]$StartupKeep = @(),
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
    # Moved to tools\Measure-Performance.ps1; kept only to say so.
    [switch]$Benchmark,
    [switch]$FrameBenchmark,
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

