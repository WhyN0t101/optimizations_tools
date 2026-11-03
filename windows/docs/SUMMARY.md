# FocusedTweaks: project summary

## What it is
One Windows-only PowerShell 5.1 script (`FocusedTweaks.ps1`, about 4,300 lines, elevates itself) that applies only the Windows
tweaks you chose from ZOICWARE (MIT, commit of 24 Oct 2026), plus a few ideas from FR33THYFR33THY/Ultimate (MIT).
Every risky item is a named option. Defaults follow upstream except your exclusions.

## Safety model
- `-DryRun` lists every action and changes nothing. A `YES` prompt guards a real run (`-Force` skips it).
- State is saved after every step. `-Revert` restores registry values and deleted keys, the hosts file, scheduled tasks
  (exported to XML first), the power plan, hibernation, memory compression, sleep study logs, password age, the consent
  database, the Start layout and desktop shortcuts, Defender real time protection, DEP, the timer service, the power
  mode and the time server. Registry keys the run created are removed again when they are empty.
- The state folder (`C:\ProgramData\FocusedTweaks`) is locked to Administrators and SYSTEM, and refused if anyone else
  owns something in it. A TrustedInstaller service path left behind by an interrupted run is repaired at start.
- The run warns when the elevated account is not the one at the desktop, since per user settings would go to it.
- Not reversible by `-Revert`: temp and update cache cleanup, app debloat, Quick Assist removal, software installed by winget or NVIDIA, NVIDIA
  telemetry files removed, the fault tolerant heap reset, and System Protection once switched on.
- `-HealthCheck` (automatic after a run, or on its own after a restart) verifies the result against the options you used.

## Commands
`-ListOptions`, `-ListRegGroups`, `-DryRun`, `-Force`, `-Skip A,B`, `-Enable A,B`, `-Only A,B`, `-SkipRegGroup`,
`-TaskMode Delete|Disable|None`, `-Defender Keep|Disable|Enable`, `-PowerProfile Off|Medium|High`,
`-PowerMode Keep|Balanced|Best`, `-PauseDays`, `-NvidiaDownload|-NvidiaInstaller`, `-HealthCheck`, `-HealthCheckLaunch`,
`-ProfilePath file.json`, `-Revert`.

## Your decisions on record
- UAC off, startup Run keys cleared once, app privacy denials on, all accepted.
- Update options (driver exclusion, long deferral, one year pause, definition updates excluded) are separate switches.
- Kept by default: Bluetooth, printing, Delivery Optimisation and radio management services.
- Excluded by default: core isolation, hide Lock, hide Sleep, hibernate off.
- Debloat keeps Store, Xbox, Edge, Paint, Photos (plus Calculator, Notepad, Terminal, Snipping Tool, winget, image codecs).
- Packages: Visual C++ 2015+ x64 and x86, DirectX, 7-Zip, Firefox, NVIDIA Profile Inspector, Autoruns.
- Defender stays on by default and is switchable. Taskbar pin changes were dropped.
- Start pins cleared, desktop icons cleared (shortcuts moved, restorable), Quick Assist removed.
- v5: quiet Defender, network adapter power saving and EEE off, temp and update cache cleanup (junction safe,
  `C:\XboxGames` never touched), and off by default: Spectre and Meltdown mitigations off, DEP off, timer service.
- v6 (not yet run in the VM): End task as its own option; on by default: device power saving (skipped on battery),
  pool.ntp.org time server, "Kill not responding tasks" and "Restart Explorer" in the desktop menu; off by default:
  device wake off, MPO off, write cache flushing off, faster shutdown, feature upgrade block, Search indexing off,
  "Take ownership" menu. Game Mode and Game Bar were already covered by the upstream registry set.
- Tamper Protection is never bypassed. When `DefenderQuiet` or `-Defender Disable` is used, the run asks you up front to
  turn it off (and opens the Windows Security page); `-Force` skips the question. Turn it back on afterwards.
- Not offered: SMT off and per app priority. Ultimate implements both as a temporary affinity or priority on one running
  process, which is not a system setting.

## Test status
- Static checks (`tests/Test-Parse.ps1`) on Windows PowerShell 5.1 and PowerShell 7.
- v5 full run on the Windows 11 VM (build 26200, 3 Nov 2026): no errors, health check 42 passed, 2 warnings (Gaming
  services missing from the image, the protected Diagtrack autologger value), 0 failed. Scheduled task deletion takes
  about a second per task.
- First run on a real Windows 11 VM (build 26200): finished with no errors. Health check: 32 passed, 4 warnings, 0 failed.
  The 4 warnings were: Gaming services missing from the image, one protected Diagtrack autologger value not writable,
  Defender signatures 411 days old (stale image, and definition updates are excluded), and Windows Modules Installer
  service events caused by the script's own TrustedInstaller helper. The 7 log warnings also included a wrong USB
  selective suspend GUID, now fixed.
- Not yet verified on real Windows: every v6 option, the power mode revert, removal of created keys, the TrustedInstaller
  repair, the wrong account warning, `-ProfilePath`, `-Revert` on a real system, `-HealthCheckLaunch`, the restore
  point retry, the NVIDIA download. Start pins: the log says cleared, but it has to be checked by eye.

## Known gaps and ideas
Not ported from upstream: Store and App Actions settings, calendar expansion, priority notification blob, terminal and
console colours, Task Manager always on top, HDR on battery, DDU and Safe Mode cleaning.
Ideas queue: `-NoTrustedInstaller`, wildcard option names, a Windows runner for CI, script signing.
