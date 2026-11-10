# FocusedTweaks: project summary

## What it is
One Windows-only PowerShell 5.1 script (`FocusedTweaks.ps1`, about 4,500 lines, elevates itself) that applies only the Windows
tweaks you chose from ZOICWARE (MIT, commit 2363922 of 24 Oct 2026, pinned in `tools/build.py`), plus a few ideas from
FR33THYFR33THY/Ultimate (MIT). Every risky item is a named option. Since v7.0 the defaults aim for maximum performance
with Windows still usable, and things are removed or left alone, never half done; profiles relax them per machine.
Releases (GitHub, from v7.0) ship the built script, its SHA256 and a zip with the README, NOTICE and starter profiles.

## Safety model
- `-DryRun` lists every action and changes nothing. A `YES` prompt guards a real run (`-Force` skips it).
- Every change is first written, flushed, to `journal.jsonl` in the state folder (time, step, option, value before,
  value after, then OK, MISMATCH or FAILED), and the state is saved after every step; a run that stops mid step is
  recovered from the journal at the next start. A step that fails is rolled back from its journal lines, or the run
  stops when the step changed something the journal cannot put back.
  `-Revert` restores registry values and deleted keys, the hosts file, scheduled tasks
  (exported to XML first), the power plan, hibernation, memory compression, sleep study logs, password age, the consent
  database, the Start layout and desktop shortcuts, Defender real time protection, DEP, the timer service, the power
  mode, the time server and optional features. Registry keys the run created are removed again when they are empty.
  Values are restored to what they were before the first run (sleep study logs, password age), not to fixed defaults.
  Tasks that only SYSTEM may register or change are handled through the TrustedInstaller helper.
- `-RestoreTask <wildcards>` brings back only the matching deleted or disabled tasks, leaving the rest of the run.
- Never deleted by `TaskMode Delete`, whatever the profile says: time sync, Defrag, TPM, BitLocker, Defender, the
  System Restore schedule, certificate services, the Edge, Google and Firefox updaters, and `SdbinstMergeDbTask`
  (Windows refuses to register it again). SSD retrim, automatic maintenance and display scaling
  are left alone unless `SvcDefrag`, `NoAutoMaintenance` or `ForceDpi100` is switched on.
- Service stops time out after 30 seconds; the update cache cleanup stops UsoSvc first and skips when a service hangs.
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
`-ProfilePath file.json`, `-Revert`, `-RestoreTask`, `-Benchmark`, `-StartupReview`, `-SkipRestorePoint`.
Profiles: `desktop-max.json`, `laptop.json` (keeps UAC, mitigations, core isolation, the power mode and Windows Update, no timer service),
`privacy.json` (keeps UAC, mitigations, core isolation, updates and the Defender and update tasks), `example.json`. A battery without a profile prints a hint.
`tools/Explain-Processes.ps1` (read only) explains running processes, services and optional features, gives
Keep/Manual/Remove advice for common Windows and vendor services, and compares two machines.

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

- v7 (not yet run in the VM): `MenuRunAsAdmin`, eleven right click menu removals, `LockScreenOff`, `IPv4Only` and
  `NvmeNativeDriver`, all off by default; `-Benchmark` and `-StartupReview` modes.
- v7.0 (7 Nov 2026), maximum performance defaults. These replace earlier decisions above where they differ: on by
  default now Spectre and Meltdown mitigations off, core isolation off, the timer service (always held), Delivery
  Optimisation off, Search indexing off, faster shutdown, and `SvcExtra` (contact and user data sync, SSDP, Storage
  Spaces, built-in VPN, from Ultimate). Still kept by default: Bluetooth, printing and radio services, hide Lock, hide
  Sleep, hibernation. Off by default and part of the hard floor: `SvcDefrag`, `NoAutoMaintenance`, `ForceDpi100`.
- v7.1: six upstream registry groups now belong to the option they duplicate (mouse acceleration, notifications, sleep
  study, background apps, fault tolerant heap, Delivery Optimisation), so skipping the option keeps the feature.
  `NoRecentDocsHistory` is its own option, off by default (it broke Quick Access pinning). New health lines for power
  mode, notifications, telemetry and CDP services, password age, MSI mode and time sync.
- v7.2: `LegacyFeatures` (on: SMB 1.0, PowerShell 2.0, Recall, Work Folders, Media Player Legacy) and
  `HypervisorFeatures` (off: Hyper-V, Virtual Machine Platform, Windows Hypervisor Platform, WSL, Sandbox).
- v7.4 (not yet run on an NVIDIA machine): `NvidiaProfile` (on, NVIDIA GPUs only) merges 14 global settings into
  the driver's Base Profile with Profile Inspector (low latency, prefer maximum performance, unlimited shader cache,
  high performance texture filtering, threaded optimization), leaving G-SYNC, V-Sync, the frame rate limiter and
  antialiasing alone. `NvidiaReBar` (off) forces Resizable BAR on. The driver settings database
  (`ProgramData\NVIDIA Corporation\Drs`) is copied before the first import and `-Revert` puts it back. Profile
  Inspector is only installed when an NVIDIA GPU is present. Last access time is set in the current Windows format
  (0x80000001), because Windows resets the legacy value from upstream.

## Test status
- Static checks (`tests/Test-Parse.ps1`) on Windows PowerShell 5.1 and PowerShell 7, on every push in CI, which also
  fails when the committed script or `docs/OPTIONS.md` differ from a fresh build.
- Smoke test on every push (`.github/workflows/windows-smoke.yml`, `tools/Test-Smoke.ps1`): a throwaway Windows Server
  2025 runner runs both dry runs, a real run with the defaults, the health check, `-RestoreTask` and `-Revert`, and
  publishes the results as annotations. Run of 7 Nov 2026 (v7.2): no errors in any stage, health 52 passed, 0 failed
  (warnings are Server only: no Store apps, Defender off on the image), revert check 712 values back, 1 difference (a
  Visual Studio task tied to the runner's own account). It found and fixed: the update cache cleanup crash on an empty
  folder, `reg.exe` and `schtasks` stopping steps under Windows PowerShell 5.1, about 40 protected tasks revert could
  not restore, and update tasks registered again by UsoSvc. Server cannot cover Store apps or a restart, so the VM
  test stays the full Windows 11 check.
- v5 full run on the Windows 11 VM (build 26200, 3 Nov 2026): no errors, health check 42 passed, 2 warnings (Gaming
  services missing from the image, the protected Diagtrack autologger value), 0 failed. Scheduled task deletion takes
  about a second per task.
- First run on a real Windows 11 VM (build 26200): finished with no errors. Health check: 32 passed, 4 warnings, 0 failed.
  The 4 warnings were: Gaming services missing from the image, one protected Diagtrack autologger value not writable,
  Defender signatures 411 days old (stale image, and definition updates are excluded), and Windows Modules Installer
  service events caused by the script's own TrustedInstaller helper. The 7 log warnings also included a wrong USB
  selective suspend GUID, now fixed.
- 7 Nov 2026, the owner's ThinkPad (laptop profile, real hardware): run finished; health check 0 failed. Found then:
  the forced 100% DPI group skewing the mouse profile, deleted time sync, TPM and Defrag tasks (restored by hand, now
  in the keep list), and `NoRecentDocsHistory` breaking Quick Access pins. All fixed in v7.0 and v7.1.
- 8 Nov 2026, Windows 11 VM (build 26200, VMware, 6 GB RAM, no TPM or Secure Boot), v7.3 with
  `desktop-max.json`, full `Test-InVm.ps1` cycle: every stage exit code 0 and no errors. Health after the restart 58
  passed, 0 failed; warnings were Gaming Services missing from the image, Defender signatures 418 days old (stale
  image), last access time reset by Windows (fixed in v7.4) and the Start list view reset by Windows (now a note).
  Functional check, not performance evidence (one sample each, in a VMware guest whose hypervisor sets timers and
  interrupts): the benchmark before and after showed the options took effect, timer 15.6 to 0.5 ms and Sleep(1)
  15.9 to 1.6 ms (timer service), interrupts per second 27,397 to 3,049, kernel call cost 30.5 to 13.2 us and the
  CPU loop 618 to 422 ms. Real speed gains need `-Benchmark` on physical hardware. Revert: 1,277 values checked, 2 differ (one USB root hub
  idle setting the driver rewrote, and `StartOobeAppsScanAfterUpdate`, now in the never-delete list). `RunKeys` also
  removes the VMware Tools autostart entry, so `Test-InVm.ps1` puts that one entry back before restarting.
- Not yet verified: `-HealthCheckLaunch`, the restore point retry, the NVIDIA download and the NVIDIA options (no
  NVIDIA GPU in the test machines), memory compression above 8 GB in the VM. Start pins: check by eye.

## Changed
Fixes from `docs/AUDIT.md` (branch `audit-fixes`, after v7.4). None of these has run in the VM yet.
- A-14: the `-RestoreTask` examples (README, help, `-ListOptions`) now name `\Microsoft\Windows\Application
  Experience\*`. The old examples named time sync and TPM tasks, which are never deleted.
- A-15: `-Enable`, `-Skip` and `-Only` accept `A,B` as one string, so lists also work through `powershell -File`.
  `-SkipRegGroup` is not split, because a group title can contain a comma.
- A-16: on Windows 10 (builds below 22000) a run warns that security updates arrive only through ESU, until
  12 October 2027 (Microsoft's end of support page, checked 9 Nov 2026), and that `PauseUpdates` and
  `SecurityUpdatesOnly` delay them.
- A-09: edition awareness. Every Home edition is recognised (`Core*`, before only `Core`). The plan, the run log and
  a new health area "Edition" name the policy values the edition does not honour: telemetry level 0 (Enterprise,
  Education and Server only) and the update deferral and target version policies (Pro, Enterprise and Education).
  Every other policy value on Home or Pro is counted as "unconfirmed" and not judged. Values are still written.
- A-05: `state.json` is written to a temporary file and swapped in; the version before it stays as
  `state.json.bak`. A state file that cannot be read falls back to the `.bak` with a warning. When neither can be
  read, every mode (including `-Revert`) stops with one clear message and exit code 4 before changing anything.
  `-Revert` removes the `.bak` together with the state it archives.
- A-19: `tests/Test-Parse.ps1` now also covers the journal rules: the first original of a value is kept on a second
  snapshot and after a save and load, state survives a round trip (date-like strings, binary data), `Remove-RegKey`
  on repeat, comma lists (A-15) and the atomic state write (A-05). It uses a scratch key under
  `HKCU\Software\FocusedTweaksTest-<id>` and a temp folder, and removes both.
- A-01, A-11: change journal. Every change is announced in `journal.jsonl` (state folder) with one flushed write
  before it is made: time, step number and name, option, target, value before and value after; a second line gives
  the result. All state records go through it, and the state file stores the last journal line it holds
  (`JournalSeq`, state version 2). At start the lines the state file lacks are replayed, so a run killed mid step
  keeps its originals. `-Revert` archives the journal with the state. Version 1 state files load unchanged.
  The device power and wake steps write one journal flush per registry key instead of two per value.
- A-06: every registry write is read back; the journal records OK or MISMATCH and a mismatch is logged as a warning.
- A-04: a step that fails (an error, or a change in it that failed) is rolled back from its journal lines, newest
  first: registry values, deleted keys, created keys and scheduled tasks. When the step also changed something the
  journal cannot put back (hosts file, power plan, features, files and other state), the run stops there and says so;
  `-Revert` still undoes everything recorded.
- A-02: every deletion of a registry key (the Run keys and four other upstream keys) is exported to its own
  timestamped file, also on a later run. `-Revert` imports all exports newest first, so the original wins where they
  overlap and entries added between runs come back too.
- A-17: `-Defender Disable` and `-Defender Enable` record the three Defender preferences they change (real time,
  behaviour and download scanning) the first time; `-Revert` puts those values back instead of switching all three on.
- A-07: a restore point counts only when System Restore lists one made since the step started. When Windows refuses,
  the log quotes what it said (an error, or the warning it gives when one was made in the last 24 hours, which was
  logged as "Restore point created." before). The run then asks before continuing without one; `-Force` continues
  with a warning.
- C-2, A-08: pre flight checks before every run, each logged with the reason it fired: pending restart, Windows
  servicing at work (TiWorker), battery power, management, edition (replaces the old run log line), Tamper
  Protection and System Protection (System Restore off by policy, or a restore point less than 24 hours old). A PC
  joined to a domain or Entra ID, enrolled in MDM or under domain Group Policy is refused (exit code 3) unless
  `-AllowManaged`; `-SkipCheck <name>` skips any check. A dry run reports a block and goes on.
- C-5: `-Json` prints one result object (exit code and its meaning, reason, mode, failure and warning counts,
  pre flight and health results, log, journal and state paths) and keeps the console otherwise quiet; a real run
  with `-Json` needs `-Force`. Exit codes are documented in the README and the help: 0 ok, 1 failures, 2 cancelled,
  3 pre flight refused, 4 state unreadable. Every exit after start up goes through one function. The smoke test
  passes `-AllowManaged`, since the hosted runner image may be joined to a directory.
- C-3: every option carries an evidence tier and, when Documented, a link to the vendor page, shown by
  `-ListOptions` and in `docs/OPTIONS.md`. The build fails when an option lacks a tier or a Documented one lacks a
  link. Ten options are Documented, 31 Folklore, the rest n/a; none is Measured, since the only measurements so far
  come from a VM. Tiers are information only and decide no default.
- B-01: `-Benchmark` rewritten. Each short measurement runs `-BenchmarkRuns` times (5) and is reported as median
  with minimum and maximum; the idle footprint (CPU use, DPC and interrupt time share with maximum, DPCs and
  interrupts per second, processes, running services, committed memory) is sampled once a second over
  `-BenchmarkIdleSeconds` (60); boot time uses the last restarts, not one. Each result records the machine (CPU,
  logical processors, RAM, power source, VM) and the settings (power plan, power mode, VBS, hypervisor,
  mitigations, MPO, timer service). A comparison is refused when the machine differs, and a change whose ranges
  overlap is marked as within noise. `-BenchmarkBaseline <name>` keeps a named baseline. Results from a VM are
  marked `ValidForPerformance: false`. Benchmark files from v7.4 are not compared (one sample, no context).
- B-06: the VM benchmark figures of 8 Nov 2026 are now described as a functional check (the options took effect),
  not as performance evidence.
- A-03 (revised): `TaskMode Delete` stays the default. The built-in keep list now also holds the Defender tasks,
  `\Microsoft\Windows\SystemRestore\SR`, `\Microsoft\Windows\CertificateServicesClient\*` and the Edge
  (`\MicrosoftEdgeUpdate*`), Google (`\GoogleUpdateTask*`, `\GoogleSystem\GoogleUpdater\*`) and Firefox
  (`\Mozilla\Firefox Background Update*`) update tasks. The Firefox Default Browser Agent and other telemetry
  tasks are still deleted. The `edgeupdate` advice in `Explain-Processes.ps1` now says the tasks are kept.
- A-12 (revised): `laptop.json` now leaves the power mode alone (`PowerMode Keep`, was `Best`, which costs battery)
  and no longer pauses or restricts Windows Update (`PauseUpdates` and `SecurityUpdatesOnly` skipped). `TaskMode`
  stays `Delete`, now that the A-03 keeps protect Defender and the updaters.

## Known gaps and ideas
Not ported from upstream: Store and App Actions settings, calendar expansion, priority notification blob, terminal and
console colours, Task Manager always on top, DDU and Safe Mode cleaning.
Ideas queue: `-NoTrustedInstaller`, wildcard option names, script signing, a keep/disable/delete mode for services
and startup entries modelled on `TaskMode`, partial revert by option, more vendors in `Explain-Processes`.
