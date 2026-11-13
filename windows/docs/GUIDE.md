# FocusedTweaks: the full walkthrough

From download to a tuned PC, then living with it: measuring, the maximum performance setup, an NVIDIA driver
install, checking the result, keeping it after Windows updates, and undoing it. The README is the short version;
`docs/OPTIONS.md` lists every option.

Everything below runs in **Windows PowerShell 5.1** (built into Windows; PowerShell 7 works too) from the folder you
unzipped. The script asks for administrator rights itself.

## 1. Before you start

| Check | Why |
|---|---|
| Windows 10 2004 or later, or Windows 11 | Older builds are untested. On Windows 10 the script reminds you that security updates now come only through ESU. |
| A PC you manage yourself | A PC joined to a domain, Entra ID or MDM is refused: its policies fight these changes. |
| No restart pending, Windows Update idle | Restart first and let updates finish. Windows can undo values changed while it installs. |
| System Protection on for C: (optional) | The script makes a restore point first. Fresh Windows 11 installs often have System Protection off; turn it on (Control Panel, System, System Protection) or add `-Enable EnableSystemRestore`. Without it the script asks before going on; `-Revert` works either way. |
| Sign out of OneDrive if you want it gone | `RemoveOneDrive` keeps OneDrive while an account is signed in, so files that live only in the cloud stay reachable. |
| Tamper Protection off (Windows Security, Virus and threat protection settings) | The quiet Defender settings are policies Tamper Protection may ignore. The script opens the page and waits; type `SKIP` to go on anyway. |
| About an hour, and internet | App removal, optional features and winget installs take time. The NVIDIA driver and PresentMon are downloads. |

Nothing here installs a background service of its own except the small timer resolution service, and everything it
changes is written to a journal first, so `-Revert` can put it back.

## 2. Download and verify

1. From the repository's Releases page, download `FocusedTweaks.zip` and `FocusedTweaks.ps1.sha256`. Unzip it, for
   example to `C:\Tools\FocusedTweaks`.
2. Open **Windows PowerShell** in that folder (in Explorer: File, Open Windows PowerShell, or type `powershell` in the
   address bar) and check the file:

       (Get-FileHash .\FocusedTweaks.ps1).Hash
       Get-Content .\FocusedTweaks.ps1.sha256

   Both must show the same value. With the GitHub CLI you can also prove the release workflow built it:
   `gh attestation verify .\FocusedTweaks.ps1 --repo WhyN0t101/optimizations_tools`.
3. Allow scripts for this window only:

       Set-ExecutionPolicy -Scope Process Bypass

## 3. Measure first (optional, recommended on a desktop)

Measure before, so you can see what changed afterwards. Close other programs.

**System benchmark** (timer, kernel call cost, idle CPU, processes, services, memory, boot time):

    .\tools\Measure-Performance.ps1 -BenchmarkBaseline before

**Game frame times** with PresentMon (average FPS, 1 % and 0.1 % lows, stutters). Start the game, go to a scene you
can repeat (a built-in benchmark is best), then:

    .\tools\Measure-Performance.ps1 -FrameProcess Cyberpunk2077.exe -FrameLabel 1440p-high

The process name is in Task Manager, Details tab. It records a 15 second warm-up, then three 60 second runs. Use the
same scene, settings and label later. Turn V-Sync, G-Sync or a frame cap off for the test if you want the average FPS
to show differences; the percentiles and stutter count work either way.

## 4. Choose the settings

| Machine | Profile | What it means |
|---|---|---|
| Gaming or work desktop, maximum performance | `profiles\desktop-max.json` | The defaults (everything below) plus the Best power mode. |
| Laptop | `profiles\laptop.json` | Keeps mitigations, core isolation, UAC, power mode and Windows Update; skips the timer service; trims Lenovo and Intel helpers. |
| Privacy first | `profiles\privacy.json` | Keeps the security features and updates; strongest on telemetry. |

**What the maximum performance defaults do** (`desktop-max.json`): Spectre and Meltdown mitigations off, core
isolation and UAC off, a tuned High Performance plan, the 0.5 ms timer service, hardware GPU scheduling, consumer
apps, Quick Assist, OneDrive and legacy features removed, Copilot and Windows AI off, Edge kept out of the
background, telemetry off and blocked, about 40 background services disabled, scheduled tasks deleted (time sync, SSD
retrim, TPM, BitLocker, Defender, System Restore, certificate and browser update tasks are kept), startup entries
cleared, Windows Update paused with automatic checks off, device and network power saving off, and visual effects
trimmed. Every option, its default and whether `-Revert` undoes it: `docs\OPTIONS.md`, or `-ListOptions`.

**Going further than the defaults.** These are off because each costs something you might use. Add the ones you
accept with `-Enable`, or put them in your own profile:

| Option | What you give up |
|---|---|
| `SvcAggressive` | Notifications, the data usage page, AutoPlay, and scanners or camera import through WIA |
| `RemoveEdge` | The Edge browser (WebView2 stays). Only where Windows allows it (device region in the EEA), and only when another browser is the default |
| `-ServiceMode Delete` | Services are deleted instead of disabled; a Windows update may register one again |
| `DisableHibernate` | Hibernation and Fast Startup |
| `MpoOff` | Can fix flicker; can break some HDR setups |
| `DeviceWakeOff` | Keyboard and mouse no longer wake the PC |
| `HypervisorFeatures` | WSL 2, Hyper-V, Windows Sandbox |
| `NvidiaReBar` | Resizable BAR forced for every game: helps some, slows others |
| `WriteCacheFlushOff` | A power cut can lose data |
| `NvmeNativeDriver` | Experimental: disk tools and BitLocker may misbehave |

To keep some startup programs, name them (`-StartupReview` lists the names):

    .\FocusedTweaks.ps1 -StartupReview

A profile of your own keeps all choices together. Copy `profiles\desktop-max.json` to `my-pc.json` and edit it, for
example:

    {
      "Enable": ["SvcAggressive", "DisableHibernate"],
      "Skip": ["RemoveOneDrive"],
      "ServiceMode": "Delete",
      "StartupKeep": ["Steam", "Discord"],
      "TaskMode": "Delete",
      "Defender": "Keep",
      "PowerProfile": "High",
      "PowerMode": "Best",
      "PauseDays": 365
    }

`profiles\example.json` shows every setting. Anything on the command line wins over the profile.

## 5. NVIDIA driver (optional, NVIDIA GPUs only)

The script can install a clean, stripped NVIDIA driver in the same run: only the display driver and the installer core,
no NVIDIA App, no telemetry, no HD Audio, unless you ask for them.

| Parameter | Effect |
|---|---|
| `-NvidiaDownload` | Download the newest Game Ready desktop driver from NVIDIA |
| `-NvidiaVersion 576.80` | A specific version instead of the newest |
| `-NvidiaInstaller C:\path\driver.exe` | Use an installer you downloaded yourself |
| `-NvidiaNotebook` | The notebook driver (laptop GPUs) |
| `-NvidiaApp` | Also install the NVIDIA App (or GeForce Experience for drivers before 566.36): recording, overlay, driver update checks |
| `-NvidiaHdAudio` | Also install HD Audio: **needed for sound through HDMI or DisplayPort** (monitor or TV speakers) |
| `-NvidiaNoClean` | Keep your current NVIDIA settings (the default is a clean install, which resets them) |

What happens, in order: winget installs 7-Zip and, on NVIDIA PCs, NVIDIA Profile Inspector (`Packages`); the driver
installer's NVIDIA signature is checked; the chosen components are unpacked and installed silently; telemetry DLLs and
container plugins are removed (`NvidiaTelemetryStrip`, undone only by reinstalling the driver); then the low latency,
maximum performance global profile is imported with Profile Inspector (`NvidiaProfile`; the previous driver settings
are backed up and `-Revert` restores them). DDU is not included: if the old driver is broken, clean it with DDU in
Safe Mode first.

Restart after the driver install before gaming.

## 6. Dry run, then the real run

Look first. A dry run prints every change and changes nothing:

    .\FocusedTweaks.ps1 -ProfilePath .\profiles\desktop-max.json -NvidiaDownload -DryRun

Then run it for real (same parameters without `-DryRun`):

    .\FocusedTweaks.ps1 -ProfilePath .\profiles\desktop-max.json -NvidiaDownload

You will see, in order: the plan (every option on and off, and what each security trade-off weakens), the pre flight
checks with the reason for each warning, one question (type `YES`), the restore point, then each step with
`Completed` or `Failed`. Expect a UAC notice that a restart is needed, and Explorer restarting at the end. The run
ends with the health check and `Finished without errors` or the number of failures.

**Restart Windows** when it is done. Services, policies, mitigations and the power plan only fully apply after that.

Where things are: everything goes to `C:\ProgramData\FocusedTweaks` (administrators only): `run-<time>.log` (what
happened), `journal.jsonl` (every change with its option, value before and after, and OK, MISMATCH or FAILED),
`state.json` (what `-Revert` needs), and the health and benchmark results.

## 7. After the restart

Check that everything stuck:

    .\FocusedTweaks.ps1 -HealthCheck

PASS is fine, INFO is a note, WARN says what differs and why, FAIL means something you asked to keep is broken (undo
that option, see section 9). Add `-HealthCheckLaunch` to also open Settings, Store, Photos, Paint and Xbox once.

Measure again and compare:

    .\tools\Measure-Performance.ps1 -BenchmarkBaseline before
    .\tools\Measure-Performance.ps1 -FrameProcess Cyberpunk2077.exe -FrameLabel 1440p-high

The second run of each prints a before and after table (median and range; "within noise" when the ranges overlap). A
comparison is refused when the hardware, resolution, refresh rate or power source differ, and flagged when Windows was
busy during either run.

## 8. Living with it

**After a Windows update.** Big updates set some values back, register removed tasks and services again and reinstall
apps. `-HealthCheck` says when an update installed after your run. Then:

    .\FocusedTweaks.ps1 -Reapply -DryRun
    .\FocusedTweaks.ps1 -Reapply

The first lists what drifted, the second puts back only that. It never touches startup entries, Start pins, desktop
shortcuts, app permissions or software you installed since, and it waits while an update is still installing. It
does remove again an app, OneDrive or Edge that the first run removed and that is back, because it cannot tell
whether Windows or you reinstalled it: if you did, add `-Skip Debloat` (or `RemoveOneDrive`, `RemoveEdge`).

**A new NVIDIA driver.** Install only the driver and the profile again, nothing else:

    .\FocusedTweaks.ps1 -Only NvidiaProfile,NvidiaTelemetryStrip -NvidiaDownload

**Updates.** With the defaults, updates are paused and automatic checks are off until `-Revert`. Settings, Windows
Update, Check for updates still works when you want to update by hand; Defender definitions keep arriving.

**Something you removed.** Apps come back from the Store or winget (`winget install Microsoft.OneDrive`,
`winget install Microsoft.Edge`). A deleted scheduled task comes back with `-RestoreTask`:

    .\FocusedTweaks.ps1 -RestoreTask '\Microsoft\Windows\Application Experience\*'

**What is running and why.** `tools\Explain-Processes.ps1` (it only reads) groups every process by origin, shows the
services inside each svchost and gives Keep, Manual or Remove advice.

**The mouse.** `tools\Test-Mouse.ps1` (it only reads) says whether Enhance pointer precision is off, the pointer speed
is the 1:1 middle notch and the background polling cap is lifted (`MouseFullRateBackground`), then opens a window:
move the mouse in fast circles in it and it measures the real polling rate and how steady it is from the raw input
games read. Below 1000 Hz or unsteady, it says what to try (mouse software, another USB port, wired). For a second
opinion in the browser, with button and sensor tests, https://control.openmouse.app/ runs a hardware test.

**Temperatures and clocks.** Install HWiNFO from https://www.hwinfo.com/download/ (or `winget install -e --id
REALiX.HWiNFO`, which fails for a while after each HWiNFO release until winget's entry catches up, so it is not in
the default packages). Run it in sensors only mode to watch CPU and GPU temperatures, clocks and throttling while you
game.

## 9. Undoing

| Command | Undoes |
|---|---|
| `.\FocusedTweaks.ps1 -Revert -Only SvcBackground` | Only those options (comma list), from the journal. A value another option also set is kept and named. |
| `.\FocusedTweaks.ps1 -Revert` | Everything the script recorded, back to the state before your first run, then a revert check. |
| `.\FocusedTweaks.ps1 -RestoreTask '<path wildcard>'` | Only those deleted or disabled tasks. |

Restart after a revert. Not undone by `-Revert`: removed apps, Quick Assist, OneDrive and Edge (reinstall them),
installed packages, deleted temp and update cache files, the NVIDIA telemetry strip (reinstall the driver), and System
Protection if the script turned it on. The restore point from the start of the run is the last resort.

## 10. Laptop and privacy setups

Laptop:

    .\FocusedTweaks.ps1 -ProfilePath .\profiles\laptop.json -DryRun
    .\FocusedTweaks.ps1 -ProfilePath .\profiles\laptop.json

It keeps the CPU mitigations, core isolation, UAC, Windows Hello, the power mode and Windows Update, skips the timer
service and the High Performance plan on battery machines, and trims Lenovo and Intel helper services
(`VendorServices`: never thermal, power, Fn key, audio or display services). Add `-NvidiaDownload -NvidiaNotebook` for
a laptop NVIDIA GPU.

Privacy first: `profiles\privacy.json`, same commands.

## 11. When something goes wrong

| Message | What to do |
|---|---|
| `Refused by the pre flight check(s) Managed` | The PC is managed by an organisation. Run it on a PC you manage, or `-AllowManaged` if you accept the conflicts. |
| `A restart is pending` / `servicing is installing` (warning) | Restart, wait for Windows Update, run again. `-Reapply` refuses until then. |
| `Restore point NOT created` | System Protection is off. Turn it on, or answer `YES`, or use `-Enable EnableSystemRestore`. |
| `winget not found` | Update App Installer from the Microsoft Store, open a new elevated window. |
| `OneDrive kept: an account is signed in` | Sign out of OneDrive (Settings, Account, Unlink this PC) and run again, or skip `RemoveOneDrive`. |
| `Edge kept: ...` | Set another browser as default, or Windows does not allow removal outside the EEA. |
| `The saved state ... cannot be read` (exit code 4) | Nothing was changed. The message names the file; `state.json.bak` is tried first automatically. |
| Something broke after the run | `-HealthCheck` names it; `-Revert -Only <Option>` undoes that option; `-Revert` undoes everything. |

Exit codes: 0 ok, 1 failures, 2 cancelled, 3 refused by a pre flight check, 4 state unreadable. For unattended use
add `-Json -Force`: the console then prints one JSON result object.
