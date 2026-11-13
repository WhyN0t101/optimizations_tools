# FocusedTweaks

A focused, option driven Windows 10/11 tweak script derived from [ZOICWARE](https://github.com/zoicware/ZOICWARE) (MIT),
with ideas from [FR33THYFR33THY/Ultimate](https://github.com/FR33THYFR33THY/Ultimate) (MIT). Windows only.

## Quick start

The full walkthrough, from download to the maximum performance setup with an NVIDIA driver install, measuring,
keeping it after Windows updates and undoing it, is [`docs/GUIDE.md`](docs/GUIDE.md) (also `GUIDE.md` in the release
zip). The short version:

1. Download `FocusedTweaks.zip` from the repo's Releases page and unzip it. It holds the script, the profiles and
   the licence notices. Check the script against `FocusedTweaks.ps1.sha256` from the same release:
   `(Get-FileHash .\FocusedTweaks.ps1).Hash` must match (case does not matter). That detects a damaged download,
   but it does not protect against a compromised release: whoever can replace the script can replace the hash
   file too. To check that the script was built by this repository's release workflow from its source, verify
   its build provenance with the GitHub CLI (releases built after the provenance step was added):

       gh attestation verify .\FocusedTweaks.ps1 --repo WhyN0t101/optimizations_tools

2. Open Windows PowerShell (5.1) in that folder. The script asks for administrator rights itself.

       Set-ExecutionPolicy -Scope Process Bypass

3. Pick a profile, or none for the maximum performance defaults:
   `profiles\desktop-max.json` (the defaults, plus the Best power mode for a desktop), `profiles\laptop.json` (keeps security, battery life and Windows Update),
   `profiles\privacy.json` (privacy first: keeps UAC, mitigations, core isolation, Windows Update, driver updates
   and the Defender and update tasks; Defender stays on with cloud sample submission off).
4. See what it would do, then do it, then restart:

       .\FocusedTweaks.ps1 -ProfilePath .\profiles\laptop.json -DryRun
       .\FocusedTweaks.ps1 -ProfilePath .\profiles\laptop.json

5. After the restart, check the result. Undo everything, or only some deleted tasks, at any time:

       .\FocusedTweaks.ps1 -HealthCheck
       .\FocusedTweaks.ps1 -Revert
       .\FocusedTweaks.ps1 -RestoreTask '\Microsoft\Windows\Application Experience\*'
       .\FocusedTweaks.ps1 -Revert -Only SvcBackground,RunKeys

App removal, installed software and the temp cleanup cannot be undone; everything else can.

## More

    .\FocusedTweaks.ps1 -ListOptions
    .\FocusedTweaks.ps1 -HealthCheck -HealthCheckLaunch

Before every run the script checks for a pending restart, Windows Update at work, battery power, the Windows
edition, Tamper Protection and System Protection, and says why each warning fired. It refuses a PC that someone else
manages (domain, Microsoft Entra ID, MDM or domain Group Policy) unless you pass `-AllowManaged`; skip any check by
name with `-SkipCheck`, for example `-SkipCheck PendingReboot`.

For unattended use, run it from an elevated PowerShell with `-Json -Force`: the console then gets one JSON object
(exit code, reason, pre flight results, health results and the paths of the log and the change journal) and nothing
else; the log file still gets every line. Exit codes, with or without `-Json`:

| Code | Meaning |
|---|---|
| 0 | Finished without errors (or a dry run, `-StartupReview`, or `-Reapply` with nothing drifted) |
| 1 | Some changes failed, or the health check reported a failure |
| 2 | Cancelled: not confirmed, no restore point and not confirmed, or `-Json` without `-Force` |
| 3 | Refused by a pre flight check, or `-Json` without administrator rights |
| 4 | The saved state cannot be read (nothing was changed) |

Keep a set of choices in a file and pass it with `-ProfilePath`; `profiles\example.json` shows every setting.
Command line parameters win over the profile.

`-StartupReview` changes nothing: it lists everything that starts with Windows.

Measuring is a separate tool, `tools\Measure-Performance.ps1`, which changes nothing either (it used to be the
`-Benchmark` and `-FrameBenchmark` modes of the script, with the same parameters; they say where it moved). Without
parameters it repeats each short measurement (timer, `Sleep(1)`, kernel call cost, a CPU loop) `-BenchmarkRuns` times
(5) and reports median, minimum and maximum; it then samples the idle PC for `-BenchmarkIdleSeconds` (60): CPU use,
the share of CPU time spent in DPCs and interrupts (a time share, not their latency), processes, running services
and committed memory, plus the last boot times. It compares with the previous benchmark, or with a named one kept with
`-BenchmarkBaseline before`, and refuses when the machine context differs (CPU, RAM, power source, virtual machine);
settings the options change, such as VBS or the power plan, are listed instead. Results from a virtual machine are
marked as not valid for performance.

`tools\Measure-Performance.ps1 -FrameProcess game.exe` measures how smooth a game runs. Start the game, go to a scene you can
repeat (a built-in benchmark is best), then run it: after a 15 second warm-up it records `-FrameRuns` (3) times
`-FrameSeconds` (60) with [Intel PresentMon](https://github.com/GameTechDev/PresentMon) and reports average FPS, 1 %
and 0.1 % lows (the 99th and 99.9th percentile frame time), frame time spread, stutters per minute and frames never
shown. PresentMon only reads the Windows graphics event trace, so nothing is injected into the game. One pinned
release is downloaded into the state folder and checked against its SHA256 before every use. Give runs with the same
game settings the same `-FrameLabel` (for example `1440p-high`): a run is compared with the last one of the same game
and label, and refused when the GPU, resolution, refresh rate, CPU, RAM or power source differ. It warns when V-Sync
or a frame limiter caps the frame rate, and counts only rendered frames when frame generation is on. Loading screens
and pauses (frames over 1 s) are left out. It refuses to run in a virtual machine.

`-Reapply` puts back what a Windows update undid. It runs the steps of your last run again, but touches only what
changed: first it lists each drifted item, then asks before changing them (`-Reapply -DryRun` only lists). It uses the
options of the earlier run, not new ones, and leaves alone what would undo your later choices (startup entries,
Start pins, desktop shortcuts, app permissions, installed software) or only runs once (cleanup). It removes only apps
and tasks the earlier run removed that came back. It cannot tell an app Windows reinstalled from one you reinstalled
yourself: if you brought one back on purpose (an app, OneDrive, Edge), add `-Skip Debloat`, `-Skip RemoveOneDrive` or
`-Skip RemoveEdge`, or check the list in the first pass before typing YES. A pending restart or Windows Update at work blocks it. Everything it
changes is journaled, so `-Revert` still restores the state before your first run. `-HealthCheck` says when an
update installed since your run and something looks changed.

`tools\Explain-Processes.ps1` explains what is running and why, and changes nothing: the services inside each
svchost, which vendor each process belongs to, which app started each WebView, and Keep / Manual / Remove advice
for common Windows, Lenovo, Intel, Dolby, Realtek and Synaptics services. Compare two machines with
`-SaveSnapshot desktop.json` on one, then `-Compare desktop.json, laptop.json`.

Building it yourself needs only Python: `python tools/build.py --out FocusedTweaks.ps1` in this folder. The ZOICWARE
data comes from the copy in `upstream/zoicware/`, checked against pinned SHA256 values.

## Options

The defaults aim for maximum performance: Spectre and Meltdown mitigations off, core isolation off, the
timer resolution service on, non-essential services off, apps removed. Things are removed or left alone,
never half done. A few things are always left alone because removing them gains no speed or costs it:
SSD retrim, time sync, TPM and BitLocker tasks, and display scaling. `TaskMode Delete` also keeps the Defender,
System Restore, certificate and browser update tasks, so protection and updates keep running. OneDrive is
uninstalled unless an account is signed in to it, and Edge no longer starts at sign in or stays in the background
once closed. Service groups are disabled by default; `-ServiceMode Delete` (or `"ServiceMode": "Delete"` in a
profile) deletes those services instead, after exporting each one so `-Revert` brings it back. Opt in:
`SvcAggressive` (push notifications, data usage, AutoPlay) and `RemoveEdge` (the Edge browser, keeping WebView2;
only where Windows allows it, which means a device region in the EEA, and never while Edge is the default browser).
`RunKeys` removes startup entries one by one: name the ones to keep with `-StartupKeep` (or `"StartupKeep"` in a
profile; `-StartupReview` lists the names), and Windows Security always stays. `WindowsAIOff` also sets the Copilot,
Recall snapshot and Click to Do policies for your account, where Microsoft documents them, and hides the Edge
sidebar. `VendorServices` (on in the laptop profile) disables Lenovo Vantage and presence sensing services and sets
other Lenovo and Intel helpers to Manual, never thermal, power, Fn key, audio or display services.

`-Revert -Only A,B` undoes just those options from the change journal (registry values, deleted keys, services,
tasks, hosts blocks, optional features, the timer service) and keeps the rest. A value another option set too is
kept and named. Options whose changes cannot be undone alone (app removal, power plan, cleanup) are named as well. Use a profile to relax the defaults
per machine; `profiles/laptop.json` keeps the mitigations, core isolation, UAC, the power mode and Windows Update
(no pause, no update restriction) and skips the timer service
to save battery. On a machine with a battery and no profile, the script suggests the laptop profile.

Every option, with its default, whether `-Revert` undoes it and what evidence backs it (Documented with a link to
the vendor page, Folklore, or n/a for options that are not about speed), is in [`docs/OPTIONS.md`](docs/OPTIONS.md).
The evidence column is information only: options are chosen for speed, less bloat, less telemetry and smoothness.
That file is generated from the script by `tools/build.py`, so it always matches. `-ListOptions` prints the same list.
Every one of the 482 upstream ZOICWARE registry items (192 groups), with its key, value, data and the option that
applies it, is in [`docs/REGISTRY.md`](docs/REGISTRY.md), generated the same way.

Third party licence notices are in `NOTICE.md`.

## Testing

Every push builds the script, runs the static tests and runs it for real on a throwaway Windows Server 2025
runner (dry runs, apply, health check, task restore, revert); see `.github/workflows`. For a full Windows 11 check,
`tools\Test-InVm.ps1` automates a VMware Workstation VM, see `docs/VM-TESTING.md`. See `docs/SUMMARY.md` for
what it does and how far it has been tested, and `CLAUDE.md` for how the repo is built.
