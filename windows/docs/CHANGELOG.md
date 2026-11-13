# FocusedTweaks changelog

Newest first. Add a line under Unreleased with every change; a release moves them under its tag.
Project overview, safety model and decisions: [SUMMARY.md](SUMMARY.md).

## Unreleased

- Journal: only lines that announce a change are forced to disk before it (they hold the value before). Result lines
  (OK, MISMATCH, FAILED) are written normally: a crash that loses one leaves the change counted as interrupted with its
  original still recorded. Half the forced writes for registry values and tasks.
- Timing: start up (Load state), the plan, the pre flight checks and each health check area now log Starting and
  Completed lines to the log file (not the console), so CI's step times show them.

## v8.0 (13 Nov 2026)

- Revert check: the optional features are checked with the same light query, and only features not on are asked by
  name through servicing (EnablePending counts as restored), instead of listing every feature (82 s on ARM).
- Optional feature status: one `Win32_OptionalFeature` query for just the script's feature names (0.6 s here) instead
  of listing every feature through Windows servicing (about a minute on the Windows 11 ARM runner, in every dry run, run
  and -Reapply pass). A feature it calls on is confirmed by name through servicing, which tells DisablePending from on.
  The revert check keeps the full servicing query (it needs EnablePending).
- Step times in CI: every smoke run times each step from its run log and lists every stage with its slowest steps in the
  summary, next to the previous run on the same runner (kept in the Actions cache, saved only by passing runs on main).
  A step at least 50 % and 30 s slower than before is a warning annotation, not a failure. `steps.json` is in the
  smoke results.
- Revert check and protected task restore: one task list query instead of one query per task. In the clean VM run of
  13 Nov 2026 (every stage exit code 0, revert 1415 values, 0 differ) the revert check spent 8 of Revert's 17 minutes
  looking up 220 tasks one at a time.
- Scheduled tasks: deleting and restoring them now talks to Task Scheduler directly (its COM interface, as its own console
  does) instead of through WMI, which took most of the CPU in the VM run of 13 Nov 2026 at 2 s or more per task. The
  exported XML is identical (a test compares both). Each delete now makes one forced journal write before it, not two.
  Protected tasks still go through TrustedInstaller. `Test-InVm.ps1` notices a finished stage within 3 s, not 15.
- Stay awake: every mode asks Windows not to sleep while the script runs (`SetThreadExecutionState`, as installers do;
  no setting changes, Windows drops it when the script ends). In the VM test of 13 Nov 2026 the idle VM went to sleep
  20 minutes after the last input, two minutes into the task step, and VMware suspended it. `Test-InVm.ps1` keeps the
  host awake the same way.
- Development (v7.9 on): `tools\Check.ps1` builds and runs Test-Parse under 5.1 and 7 in one go; the pre-commit hook in
  `.githooks/` runs it and refuses stale generated files. CI cancels runs for older pushes. A release is a tag only:
  the workflow checks that the smoke test passed on the tagged commit and stamps the tag into the script header
  (`build.py --version`); the committed script says it is a development build.
- Coverage: `tools\coverage.py` compares the script with winutil, Win11Debloat, Sophia Script and privacy.sexy at
  pinned commits (`tools\references.json`) and writes `docs\COVERAGE.md`: what the others change that FocusedTweaks does
  not, items several projects agree on first, and what FocusedTweaks keeps on purpose. Reference only; privacy.sexy
  (AGPL-3.0) is a cross-check, never a source. First run: 685 registry values, 51 services and 147 Store apps to review.
- From the coverage comparison (all on by default): `TelemetryExtra` (error reporting, typing, inking and speech data,
  per account advertising ID, feedback, feature trials, tips, Cortana and cloud search, location, NVIDIA, Office and Visual
  Studio telemetry), `BrowserPolicies` (Edge, Chrome, Brave, Firefox ads, telemetry and AI), `StartupDelayOff`,
  `NoDeviceEncryption` (stops automatic BitLocker, decrypts nothing), `UpdateNoReboot`, `StandbyNetworkOff` and the
  `SvcUpdaters` group (Adobe, Dropbox, Razer Game Scanner). `WindowsAIOff` gained the newer Recall policy, Paint AI and
  the Copilot pin screen; SvcDiagnostics gained error reporting and the diagnostics hub, SvcExtra the retail demo, Media
  Player sharing and the old NVIDIA container; the app list gained Camera, Mail and Calendar, Paint 3D, OneNote, Sway,
  Remote Desktop, the Widgets board and its feed, and five more. Items two or more projects change that FocusedTweaks
  does not went from 37 registry values, 2 services and 12 apps to 15, 1 and 0; what is left is interface taste or a
  deliberate security choice.
- Mouse and sensors: `tools\Test-Mouse.ps1` (reads only) checks Enhance pointer precision, pointer speed and the
  background polling cap, then measures the polling rate and its steadiness from raw input in a small window.
  `MouseFullRateBackground` (on) lifts Windows 11's cap of about 125 Hz for windows in the background (idea from FR33THY
  Ultimate). HWiNFO was added to the default packages and dropped again: winget's link breaks after each HWiNFO release
  (404 in the VM run of 13 Nov 2026); the guide links it instead.
- Windows 11 ARM smoke run (13 Nov 2026): TaskMode Delete now keeps a task that names an account which no longer exists, in its principal or its logon trigger (it cannot run,
  and Windows refuses to register it again, so -Revert could not bring it back), and the policy store cache
  `CPSS\Store\AllowTelemetry` joined the values Windows recomputes after a revert.
  The health check fails only for a core service the run disabled; one already disabled before it (that image ships
  StorSvc disabled) is a warning.
- VM run of 13 Nov 2026: revert check 1414 values, 0 differ; health 0 failed. Apply took 25 minutes, 17 of them in
  LegacyFeatures waiting behind Windows servicing (the snapshot was taken while TiWorker was busy; Windows Update
  installed an update mid run). Optional features are now turned off, and back on, in one call (one servicing session;
  one at a time only if that fails), and Test-InVm waits for TiWorker before the Dry, Apply and Reapply stages.
  HWiNFO failed with HTTP 404 from winget's own manifest (0x80190194).

## v7.6 to v7.9

From v7.6 (the VM run of 11 Nov 2026 covered OneDrive, Edge and the process snapshots; SvcBackground and NoAutoUpdate
have not run in the VM yet):

- `RemoveOneDrive` (on): uninstalls OneDrive (per user and per machine installs) and sets the `DisableFileSyncNGSC`
  policy so it does not set itself up again. When an account is signed in it changes nothing and says why: files
  that live only in the cloud would become unreachable. `-Revert` lifts the policy; OneDrive itself comes back with
  `winget install Microsoft.OneDrive`.
- `EdgeBackground` (on): the Edge policies `StartupBoostEnabled 0` and `BackgroundModeEnabled 0`, so Edge no longer
  starts processes at sign in or keeps them after its last window closes. Edge then says it is managed.
- `-ServiceMode Disable|Delete` (default Disable): with Delete, the service group options delete their services
  (and per user copies) instead of disabling them. Each key is exported first and `-Revert` imports it again; the
  services are gone after the next restart. A Windows update may register a deleted service again. Disable stays
  the default because of that, and because the profiles must equal the defaults.
- `SvcBackground` (on): a new service group with what still ran in a clean Windows 11 VM after a full run and that
  a home PC does not need, chosen by the owner: `OneSyncSvc` (Mail and Calendar sync), `PcaSvc` (Program
  Compatibility Assistant), `TrkWks` (link tracking), `InventorySvc` (app inventory), `iphlpsvc` (IP Helper; WSL
  localhost forwarding uses it), `LanmanServer` (file sharing from this PC) and `cbdhsvc` (clipboard history).
- VM test of 11 Nov 2026 on a freshly installed VM (the old snapshot had been retaken after earlier runs): every
  stage exit code 0, health 0 failed, revert 1,278 values with 0 differences. Processes 125 to 99, running services
  87 to 73, committed memory 1,806 to 1,551 MB. With both benchmarks idle, kernel call cost and the CPU loop did not
  change (VM), interrupts per second rose 68 % from the timer service. A clean Windows 11 has System Protection off,
  so the restore point failed.
- `PauseUpdates` also sets the documented policy `NoAutoUpdate 1`: no automatic update checks, downloads or installs
  until `-Revert` (it does not expire like the pause). The Update Orchestrator turns its Schedule Scan and Schedule
  Work tasks back on at every start (seen in the VM on 11 Nov 2026), so disabling them never held; with the policy
  they do nothing, and the health check notes them instead of warning. Check for updates in Settings still works,
  and Defender definitions still arrive.
- `SvcAggressive` (off): push notifications (`WpnService`, `WpnUserService`), data usage (`DusmSvc`) and AutoPlay
  (`ShellHWDetection`; scanners and camera import through WIA depend on it).
- `-Reapply`: puts back what a Windows update undid. The apply steps run again in two passes; every primitive (registry
  values and keys, services, hosts blocks, tasks, apps, features, hibernation, memory compression, Sleep Study,
  password age, time server, timer service) skips what is still as the run left it, so the first pass lists only the
  drift and the second fixes just that, through the journal. It uses the options saved with the run (new options
  stay off and are listed), leaves alone what would undo later choices or runs once (`$ReapplyLeavesAlone`), removes
  only apps and tasks the run removed, keeps the pause dates, and is blocked by a pending restart or servicing at
  work. The run now also records `ServiceMode`. `-HealthCheck` adds a Drift area that points at `-Reapply` when an
  update installed after the run and something warns.
- `-FrameBenchmark`: frame times of a game through Intel PresentMon 2.6.0 (MIT), downloaded into the state folder and
  checked against its pinned SHA256 before every use. Warm-up recording, then `-FrameRuns` recordings; average, 99th
  and 99.9th percentile frame time, spread, stutters per minute (frames over twice the median) and frames not shown,
  from the busiest swap chain with 2 s trimmed at both ends and pauses over 1 s left out. Compared with the last run
  of the same process and `-FrameLabel`, refused when GPU, resolution, refresh rate or the machine differ. Warns on a
  capped frame rate and on frame generation. Not run on real hardware yet.
- `RemoveEdge` (off): runs Edge's own uninstaller (signed by Microsoft, under Program Files). Windows completes it
  only where Edge may be uninstalled (device region in the EEA); elsewhere Edge is kept and the log says why, the
  region is not faked. Refused while Edge is the default browser; warns when Edge opens PDF files. WebView2 and
  Microsoft Edge Update are never touched (WebView2 updates through it, and its tasks stay on the keep list).
  `-Reapply` removes Edge again when an update brought it back. Not tested in the VM yet.
- `RunKeys` now removes the Run key entries one by one through the journal instead of deleting the keys:
  `-StartupKeep` (also in profiles) spares entries by name, Windows Security and the VMware Tools user process are
  always kept, and `-Revert` restores each removed entry with its value.
- `VendorServices` (off; on in `laptop.json`): disables Lenovo Vantage, its installer and the Lenovo, ELAN and Intel
  presence sensing services, and sets Lenovo standby, the camera effects installer and Intel reporting, tuning
  telemetry and graphics panel services to Manual. Thermal, power, Fn key, audio, HDCP and display services are on a
  never list that a test checks.
- `WindowsAIOff` (on): the WindowsAI policy CSP lists `TurnOffWindowsCopilot` as a user policy and
  `DisableAIDataAnalysis` and `DisableClickToDo` for user and device; the upstream group sets them only under HKLM,
  so they are now also set per user. `HubsSidebarEnabled 0` hides the Edge sidebar with Copilot.
- `-Revert -Only A,B`: undoes single options from the change journal (registry values, key exports, tasks, plus the
  hosts blocks, optional features and timer service of those options), keeps values another option also set, and
  names options it cannot undo alone. The run record stops expecting the undone options; a later full `-Revert`
  still restores every original.
- `Test-Smoke.ps1` runs `-Reapply` after the health check.
- Source split (13 Nov 2026): the template became `src/NN-name.ps1`, one file per area; `build.py` joins them and the
  built script stayed byte for byte the same. The benchmarks moved to `tools\Measure-Performance.ps1` (same
  parameters; `-FrameProcess` selects the frame benchmark), with their own small logging and administrators only
  folder handling, so the tweak script lost about 450 lines and two modes. `FocusedTweaks.ps1 -Benchmark` and
  `-FrameBenchmark` now say where they went. The release zip carries `tools\` (Measure-Performance and
  Explain-Processes); `Test-InVm.ps1` runs the benchmark stages with the tool.
- Run context: fifteen script-level flags and counters (dry run, reapply, after-apply, failures, warnings, the current
  step and its journal option, and more), which four files each set up, became one object, `$Ctx`, made once in the
  header. The built script behaves the same; a test fails if a `$script:` copy of one of them comes back.
- Mode dispatch: the `if`/`elseif` chain at the end became a table from mode (`Get-RunMode`) to action, and one pure
  function, `Get-ModeConflict`, refuses every combination that would drop a mode. New: `-HealthCheck`,
  `-StartupReview`, `-RestoreTask`, `-Revert` and `-Reapply` are refused together instead of the first one winning;
  `-Revert -Only` is its own mode (`revertonly` in `-Json`). Tests check the combinations and that every mode has an
  action.
- Behaviour tests: five text checks (about 30 of the 197 checks matched source text) now run the real functions with
  the Windows calls stubbed: Quick Assist and deleted tasks under `-Reapply` (only what the run removed and came back
  is drift), `PauseUpdates` writing `NoAutoUpdate` and scheduling its end (and `-Reapply` only during the pause), the
  end task itself (SYSTEM, `reg.exe` deleting only that value, recorded first), and the strict pre flight check.
- `PauseUpdates`: `NoAutoUpdate` now ends with the pause. A one-off task, `\FocusedTweaks\End update pause`, runs as
  SYSTEM at the pause end (or at the next start when the PC was off) and only deletes that value with `reg.exe`. It is
  on the never-delete list, recorded before it is made, and removed by `-Revert` and `-Revert -Only PauseUpdates`.
  `-Reapply` sets the policy again only while the pause lasts. The health check warns when the task is missing, or
  when the pause ended but the policy is still there.
- `docs/REGISTRY.md`: generated by `build.py` from the vendored ZOICWARE file and the script's group mapping: all
  482 items in 192 groups, with key, value, type, data, the option that applies each, and whether it is a policy,
  one Windows sets itself, or one with an option of its own. CI fails when it is stale; a test checks it has one
  row per item the script's own parser reads.
- Code review of everything since v7.6 (12 Nov 2026), fixed with tests: `-Reapply` reported drift that was not drift
  on every run (Quick Assist logged before checking it was still there, the Connected Devices Platform cache that
  Windows refills, and the Update Orchestrator tasks Windows registers at every start were deleted again), so it never
  said "nothing drifted"; the drift hint in `-HealthCheck` counted daily Defender definitions and Store app updates as
  Windows updates; `-Reapply` silently ignored `-Only` and could be combined with `-FrameBenchmark` or
  `-StartupReview`; a failed `-Benchmark` or `-FrameBenchmark` ended in a stack trace with no `-Json` result; a game
  name with a space did not reach PresentMon as one argument; a startup entry was logged as removed even when the
  removal failed. Known limit, documented: `-Reapply` removes again an app, OneDrive or Edge that the first run
  removed, also when you reinstalled it yourself.
- `Test-InVm.ps1` saves an `Explain-Processes` snapshot at every benchmark (`processes.txt`, `processes.json`) and
  writes `processes-compare.txt`, the first benchmark against the last: what the run removed and what still runs.

## v7.5 (audit fixes)

Fixes from `docs/AUDIT.md` (branch `audit-fixes`, after v7.4), since covered by the VM runs of 11 and 13 Nov 2026.
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
- A-13: `KeepDefinitionUpdates` is on by default (was off). With the default update restriction and pause, Defender
  stayed on with signatures that were never refreshed through Windows Update.
- B-02 (defaults rejected, kept by design): `SpectreMeltdownOff`, `CoreIsolation` and `Uac` stay on by default. The
  plan now logs, as a warning, what each one that is on weakens.
- B-03 (revised): the timer service stays on by default. It is skipped, with the reason in the log, on Windows 10
  (builds below 22000 honour timer requests per process, so the service would only affect itself) and on machines
  with a battery (`-ForcePowerPlanOnLaptop` overrides that). The health check notes the skip instead of warning.
- B-04 (revised): hardware accelerated GPU scheduling (`HwSchMode 2`) is its own option, `HardwareGpuScheduling`,
  on by default as before (it was part of `Registry`). It is skipped, with the reason, when no display driver is
  WDDM 2.7 or later (the first field of the driver version), and the health check then notes it. Skipping it with
  `-Skip HardwareGpuScheduling` now keeps the Windows setting.
- B-05: `MemoryCompression` turns compression off only with 32 GB of RAM or more (was: above 8 GB). With 9 to
  31 GB, compression under load replaces page file reads, so it stays on.
- `DepOff` removed (approved): turning Data Execution Prevention off gains no speed and needed Secure Boot off. A
  profile that names it is refused as an unknown option. `-Revert` still restores DEP from state files of runs that
  used it.
- `desktop-max.json` now equals the no-profile defaults in every option, as the owner decided: the defaults are
  the maximum performance set. It no longer enables `DisableHibernate` (off by default, so hibernation and Fast
  Startup now stay on with this profile) or lists `KeepDefinitionUpdates` (on by default now). It still sets
  `PowerMode Best`, the one setting the defaults leave alone because they also run on laptops. A test fails if the
  profile and the defaults diverge in any other way.
- A-10: the release workflow adds a build provenance attestation (`actions/attest-build-provenance`) for the
  script and the zip; the README and the release notes show `gh attestation verify` and say plainly that the
  SHA256 file only detects a damaged download. Every action in the three workflows is pinned to the commit of its
  release tag, with the tag in a comment. The CI check that fails on a stale generated script is unchanged.
  No Authenticode signing (not approved).
- VM test of 11 Nov 2026: the pre flight check refused the unmanaged Windows 11 VM as MDM enrolled, because
  Windows creates 'Local Authority', 'Cloud Authority' and 'Deploy Authority' enrolments itself. Those providers no
  longer count as MDM.
- Second VM test of 11 Nov 2026 (`desktop-max.json`, every stage exit code 0, health 0 failed): the first benchmark
  ran at 92.5 % median CPU use (startup work in the freshly restored snapshot, servicing restart pending), so its
  comparison with the second was not fair. A benchmark with median CPU use above 20 % in the idle window is now
  flagged, and a comparison with such a run is called unreliable. `Test-InVm.ps1` restarts the VM before the first
  benchmark and waits until the guest is idle before each one. Boot time now counts only when Windows recorded the
  current boot (it repeated the previous restart before; `SvcDiagnostics` stops the recording). The power plan
  name is read correctly when it contains brackets. The revert check now treats three differences as Windows' own:
  `GameDVR_Enabled` (Game Bar sets it), the USB 3 root hub idle value (its driver saves it; also seen on 8 Nov) and
  the Update Orchestrator tasks (UsoSvc disabled `Schedule Work` again four minutes after the revert enabled it).
