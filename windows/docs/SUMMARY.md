# FocusedTweaks: project summary

## What it is
One PowerShell 5.1 script (`FocusedTweaks.ps1`, about 3,600 lines, run as administrator) that applies only the Windows
tweaks you chose from ZOICWARE (MIT, commit of 24 Oct 2026), plus a few ideas from FR33THYFR33THY/Ultimate (MIT).
Every risky item is a named option. Defaults follow upstream except your exclusions.

## Safety model
- `-DryRun` lists every action and changes nothing. A `YES` prompt guards a real run (`-Force` skips it).
- State is saved after every step. `-Revert` restores registry values and deleted keys, the hosts file, scheduled tasks
  (exported to XML first), the power plan, hibernation, memory compression, sleep study logs, password age, the consent
  database, the Start layout and desktop shortcuts, and Defender real time protection.
- Not reversible by `-Revert`: temp and update cache cleanup, app debloat, Quick Assist removal, software installed by winget or NVIDIA, NVIDIA
  telemetry files removed, the fault tolerant heap reset, and System Protection once switched on.
- `-HealthCheck` (automatic after a run, or on its own after a restart) verifies the result against the options you used.

## Commands
`-ListOptions`, `-ListRegGroups`, `-DryRun`, `-Force`, `-Skip A,B`, `-Enable A,B`, `-Only A,B`, `-SkipRegGroup`,
`-TaskMode Delete|Disable|None`, `-Defender Keep|Disable|Enable`, `-PowerProfile Off|Medium|High`,
`-PowerMode Keep|Balanced|Best`, `-PauseDays`, `-NvidiaDownload|-NvidiaInstaller`, `-HealthCheck`, `-HealthCheckLaunch`,
`-Revert`.

## Your decisions on record
- UAC off, startup Run keys cleared once, app privacy denials on, all accepted.
- Update options (driver exclusion, long deferral, one year pause, definition updates excluded) are separate switches.
- Kept by default: Bluetooth, printing, Delivery Optimisation and radio management services.
- Excluded by default: core isolation, hide Lock, hide Sleep, hibernate off.
- Debloat keeps Store, Xbox, Edge, Paint, Photos (plus Calculator, Notepad, Terminal, Snipping Tool, winget, image codecs).
- Packages: Visual C++ 2015+ x64 and x86, DirectX, 7-Zip, Firefox, NVIDIA Profile Inspector, Autoruns.
- Defender stays on by default and is switchable. Taskbar pin changes were dropped.
- Start pins cleared, desktop icons cleared (shortcuts moved, restorable), Quick Assist removed.
- Added after the VM run (not yet run on real Windows): quiet Defender, network adapter power saving and EEE off, temp and
  update cache cleanup (junction safe, `C:\XboxGames` never touched), and three off-by-default options: Spectre and
  Meltdown mitigations off, DEP off, timer resolution service.
- Not offered: SMT off and per app priority. Ultimate implements both as a temporary affinity or priority on one running
  process, which is not a system setting.

## Test status
- Verified by simulation (PowerShell 7 on Linux with a fake registry, hosts file, task list and power plans):
  apply, health check, injected faults, revert with exact restore, partial `-Only` runs, desktop and power changes.
- Run once on a real Windows 11 VM (build 26200): finished with no errors. Health check: 32 passed, 4 warnings, 0 failed.
  The 4 warnings were: Gaming services missing from the image, one protected Diagtrack autologger value not writable,
  Defender signatures 411 days old (stale image, and definition updates are excluded), and Windows Modules Installer
  service events caused by the script's own TrustedInstaller helper. The 7 log warnings also included a wrong USB
  selective suspend GUID, now fixed.
- Not yet verified on real Windows: Start pin reset on build 26200, desktop icon clearing, the richer High power plan,
  Quick Assist removal, `-Revert` on a real system, `-HealthCheckLaunch`, the restore point retry, the NVIDIA download.

## Known gaps and ideas
Not ported from upstream: Store and App Actions settings, calendar expansion, priority notification blob, terminal and
console colours, Task Manager always on top, HDR on battery, DDU and Safe Mode cleaning.
Ideas queue: `-NoTrustedInstaller`, JSON profiles and wildcard options, a Windows runner for CI, script signing.
