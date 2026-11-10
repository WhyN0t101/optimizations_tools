# FocusedTweaks audit (Phase 1, read only)

Date: 9 November 2026. Auditor: Claude Code. Scope: the `windows/` folder and `.github/workflows`.
This phase wrote this file only. Nothing was applied, reverted or restored on any machine.

## Starting state

| Item | Result |
|---|---|
| Branch and commit | `main` at `48a6b3f` (CHORE: rebuild FocusedTweaks.ps1), working tree clean before and after the audit |
| Script version | v7.4 (template synopsis), 88 options |
| Fresh build vs committed script | Identical. `python tools/build.py` into a scratch folder gave SHA256 `c28e302d3201849a69018f01d238e9f0ffebdf3cae69414b3b99a36c3d4fbeb5` for both |
| Fresh build vs committed `docs/OPTIONS.md` | Identical (SHA256 `8f789ebf...263d99`) |
| `tests/Test-Parse.ps1` | All checks passed under Windows PowerShell 5.1 and PowerShell 7 (exit 0 both) |
| Dry runs | Not run. `CLAUDE.md` hard rule 1 forbids running the script on this machine, even with `-DryRun` |

How to read this file:

- Line numbers refer to `tools/FocusedTweaks.template.ps1` (the source of truth), not the generated script.
- "Verified" means confirmed by reading the code or by the build and static tests above. Nothing was verified by
  running the script, so every statement about live Windows behaviour is marked UNVERIFIED and listed at the end.
- Evidence tiers: **Measured** (a measurement exists in this repository), **Documented mechanism** (a vendor
  document describes the mechanism; the size of the effect is not measured here), **Folklore** (repeated without
  measurement, or a no-op on current Windows), **n/a** (not a performance option).

---

## Approvals (10 November 2026)

Recorded from the owner's amended approvals. They override the "Recommended placement" column of Section B.

**Guiding principle.** Options are judged on four goals together: best performance, less bloat, less telemetry
and overall smoothness. "Folklore" or "no measured gain" is not a reason to remove an option or make it opt in.
Defaults stay maximum performance. Options are removed or kept, never half done. Evidence tiers (C-3) are
informational only. Rows marked "Rejected: kept by design" stay exactly as they were for this reason.

| Item | Decision |
|---|---|
| A-01, A-04, A-05, A-06, A-07, A-08, A-09, A-10 (provenance and SHA pinning only, no Authenticode), A-11, A-14, A-15, A-16, A-17, A-19, B-01, B-06, C-1, C-2, C-3, C-5 | Approved as written |
| A-02 | Approved: a new timestamped export on every run; `-Revert` imports all exports, newest first, so the oldest (the original) wins |
| A-03 | Revised: `TaskMode` stays `Delete` by default. Built-in keeps added for the Defender tasks, `\Microsoft\Windows\SystemRestore\SR`, `\Microsoft\Windows\CertificateServicesClient\*` and the Edge, Google and Firefox background update tasks. Telemetry tasks such as the Firefox Default Browser Agent are still deleted. The `edgeupdate` advice in `Explain-Processes.ps1` is corrected |
| A-12 | Revised: `laptop.json` gets `PowerMode Keep`, `PauseUpdates` off and `SecurityUpdatesOnly` off. `TaskMode` stays `Delete` |
| A-13 | Approved: `KeepDefinitionUpdates` on by default |
| B-02 | Rejected: `SpectreMeltdownOff`, `CoreIsolation` and `Uac` keep their defaults. Only a log line stating what each weakens is added |
| B-03 | Revised: the timer service stays on by default; it is skipped below build 22000 and on machines with a battery, with a log line saying why |
| B-04 | Revised: `HwSchMode` becomes its own option `HardwareGpuScheduling`, default on (behaviour unchanged), skipped when the display driver is below WDDM 2.7 |
| B-05 | Approved: the `MemoryCompression` threshold rises from 8 GB to 32 GB |
| `DepOff` | Removed: no gain, and it needs Secure Boot off |
| `NvidiaTelemetryStrip`, `FaultTolerantHeap`, `IPv4Only`, `Win32PrioritySeparation`, `NetworkThrottlingIndex`, `SystemResponsiveness`, the service groups, `SearchIndexingOff`, `RunKeys`, the Game Bar settings | Rejected: kept by design |
| `desktop-max.json` | Must equal the no-profile defaults in effective options, enforced by a test |
| C-4, C-6, C-8, C-9, C-10, C-11, C-12 | Deferred |
| A-18 | Not in the approvals: left open |

### Defaults after Batch 5, compared with 48a6b3f

Option defaults (no profile), from `$OptionInfo` at `48a6b3f` and now:

| Option | 48a6b3f | Now | Item |
|---|---|---|---|
| `KeepDefinitionUpdates` | off | on | A-13 |
| `HardwareGpuScheduling` | part of `Registry` (on) | own option, on; skipped below WDDM 2.7 | B-04 |
| `DepOff` | off | removed | approved removal |

Parameter defaults (`TaskMode Delete`, `Defender Keep`, `PowerProfile High`, `PowerMode Keep`, `PauseDays 365`) are
unchanged. Behaviour changed without a default changing: the timer service is skipped below build 22000 and on
battery machines (B-03); memory compression is turned off only from 32 GB of RAM (B-05); `TaskMode Delete` keeps the
Defender, System Restore, certificate and browser update tasks (A-03, not in the owner's expected list, so named here);
a managed PC is refused unless `-AllowManaged` (C-2, A-08); a run without a restore point asks first (A-07).

`desktop-max.json` against the no-profile defaults: every option is equal; the only other difference is
`PowerMode Best`. Before, it also enabled `DisableHibernate` and listed `KeepDefinitionUpdates`; both lines are gone.
`tests/Test-Parse.ps1` fails if the two diverge in any other way.

## Section A: correctness and recoverability

### Summary

| ID | Severity | Title | Status |
|---|---|---|---|
| A-01 | High | The journal reaches disk only at the end of a step, not before each change | Fixed in `3bc0a0e` |
| A-02 | High | A second run deletes the Run keys again without a new backup | Fixed in `3bc0a0e` |
| A-03 | High | `TaskMode Delete` removes every task outside six patterns, including updaters and Defender tasks | Fixed (revised) |
| A-04 | Medium | A failed step is logged and skipped; nothing is rolled back | Fixed in `3bc0a0e` |
| A-05 | Medium | `state.json` is rewritten in place, so a crash during the write can block `-Revert` | Fixed in `a0599ff` |
| A-06 | Medium | No read back after a normal registry write; success is not logged per value | Fixed in `3bc0a0e` |
| A-07 | Medium | Restore point failure only warns, and the 24 hour refusal may be logged as success | Fixed in `da3f58f` |
| A-08 | Medium | Domain joined, MDM enrolled and policy managed machines are not detected | Fixed in `6b67d2b` |
| A-09 | Medium | Edition check covers one edition ID and is not per setting | Fixed in `7321371` |
| A-10 | Medium | Integrity: the SHA256 file shares the release with the script; no signing or provenance | Fixed |
| A-11 | Medium | The run log has no option, before value or after value per change | Fixed in `3bc0a0e` |
| A-12 | Medium | `laptop.json` does not match its description (power mode Best, updates paused, tasks deleted) | Fixed (revised) |
| A-13 | Medium | Defaults keep Defender on but exclude its definition updates and delete its tasks | Fixed in `b98a47d` |
| A-14 | Low | The `-RestoreTask` examples name paths that are never deleted | Fixed in `04ca2e3` |
| A-15 | Low | `-Enable`, `-Skip` and `-Only` do not accept a comma list through `powershell -File` | Fixed in `28ddcd6` |
| A-16 | Low | No Windows 10 notice | Fixed in `057dd70` |
| A-17 | Low | Three revert paths use fixed values, not recorded originals | Fixed in `9fff65a` |
| A-18 | Low | The TrustedInstaller helper leaves servicing broken if the process is killed mid call | Open |
| A-19 | Low | No tests for the journal, repeated runs or option parsing | Fixed in `0c309a6` |
| A-20 | Info | Relative paths survive self elevation (no defect) | No defect |

### A-01 (High) Journal persistence

- **Where:** `Invoke-Step` (704-718), `Save-State` (689-702), `Save-RegSnapshot` (869-873), `Set-RegValue`
  (1020-1045), `Set-TweakListBatched` (2525-2553), `Remove-AllScheduledTasks` (1616-1658).
- **Observed:** The original value is recorded once per value: `Save-RegSnapshot` adds to the `$script:RecordedReg`
  set, and `Import-State` (720-739) refills that set from `state.json` at start. A second run therefore keeps the
  first originals. That part works. The record is made in memory before the write, but `state.json` is written only
  in the `finally` block of `Invoke-Step`, once per step. Within a step nothing reaches the disk.
- **Why it matters:** If the process dies inside a step (window closed, power cut, `Stop-Process`), every original
  recorded in that step is lost while the changes stay. The next run then reads the tweaked values and records them
  as originals, so `-Revert` restores the tweaks. The large steps are "Registry tweaks" (about 470 values), "Device
  power saving" (thousands of values) and "Scheduled tasks" (about one second per task; the XML files exist but
  the `Tasks` records that `-Revert` and `-RestoreTask` read do not). The header promises that revert works "even
  after an interrupted run" (line 16-17).
- **Verification:** Code reading. `finally` does not run when a process is killed.
- **Proposed fix:** Append each record to a write ahead journal file (one JSON line, flushed) before the change,
  and rebuild state from `state.json` plus the journal at start. Cheaper interim: call `Save-State` every N records
  and after each task. See C-1.

### A-02 (High) Repeated Run key deletion

- **Where:** `Remove-RegKey` (1080-1111), upstream group "Remove logons" (`RegTweaks.txt` 727-730), option `RunKeys`.
- **Observed:** The key is exported only when no `KeyBackups` record exists (1091-1096). The delete at 1100 runs
  every time. On a second run the HKCU and HKLM `Run` keys hold whatever was installed since the first run; they
  are deleted with no export. `-Revert` imports the first export only.
- **Why it matters:** Startup entries added between runs are lost for good, in an option that is on by default and
  listed as "Undone by -Revert: yes". The option text says "once", but nothing limits it to once. The same applies
  to the four other upstream key deletions (`PerMonitorSettings`, `ContentDeliveryManager\Subscriptions`, two
  `NameSpace` keys).
- **Verification:** Code reading; `grep '^\[-'` on `RegTweaks.txt` lists six key deletions.
- **Proposed fix:** When a backup record exists, either skip the deletion (true "once"), or export to a new
  timestamped file and record it so revert imports all of them in order.

### A-03 (High) Scope of scheduled task deletion

- **Where:** `Remove-AllScheduledTasks` (1616-1658), `$TaskKeepBuiltIn` (387-396), default `-TaskMode Delete`
  (line 83), all three machine profiles.
- **Observed:** Each task is exported with `Export-ScheduledTask` before `Unregister-ScheduledTask`, and a failed
  export throws before the delete, so `-RestoreTask` has what it needs. A second run keeps the first export
  (1639-1644). That part works. The scope is "every task on the machine" minus three upstream names, six built in
  patterns and `-TaskKeep`. Nothing limits it to `\Microsoft\Windows\`.
- **Why it matters:** Tasks outside the keep list include the Edge, Chrome and Firefox update tasks, the Defender
  scan, cache and verification tasks, `\Microsoft\Windows\SystemRestore\SR`, certificate enrolment, .NET NGEN,
  component cleanup and every third party task. Browsers stop updating without telling the user.
  `Explain-Processes.ps1` line 74 advises setting `edgeupdate` to Manual because it "runs from its scheduled task
  anyway", which is false after a default run. Only `privacy.json` keeps the Defender and update tasks. The speed
  gain is Folklore: an idle task costs nothing until it triggers (see B, `-TaskMode Delete`).
- **Verification:** Code reading. Which tasks exist on a given machine is UNVERIFIED (U-03).
- **Proposed fix (needs approval, changes a default):** Make `Disable` the default and `Delete` opt in; or keep
  `Delete` but restrict it to `\Microsoft\Windows\*` and add built in keeps for Defender, System Restore,
  certificate services and browser updaters.

### A-04 (Medium) No rollback

- **Where:** `Invoke-Step` (704-718), `Set-RegValue` catch (1041-1044).
- **Observed:** A failure increments `$script:Failures`, logs an error and the run continues with the next value
  and the next step. The exit code is 1. Nothing already changed is undone.
- **Why it matters:** The README sentence "never half done" describes option design, but a failed step does leave
  that step half applied. The user must run a full `-Revert` to get a consistent state.
- **Verification:** Code reading.
- **Proposed fix:** Tag journal records with a step ID and offer rollback of the failed step (C-1), or state the
  actual behaviour in the README.

### A-05 (Medium) Non atomic state write

- **Where:** `Save-State` line 701, `Import-State` line 722, entry point 3660-3661.
- **Observed:** `Set-Content` truncates and rewrites `state.json`. `Import-State` runs for every mode and
  `ConvertFrom-Json` is not in a `try`.
- **Why it matters:** A crash during the write leaves truncated JSON. Every later start, including `-Revert`,
  stops at `Import-State`, and the originals are gone.
- **Verification:** Code reading.
- **Proposed fix:** Write to `state.json.tmp`, then `[IO.File]::Replace` with a `.bak`; fall back to `.bak` on a
  parse error.

### A-06 (Medium) Read back verification

- **Where:** `Set-RegValue` (1029-1040), `Test-RegValueNow` (1012-1018), health check (2881-3021, 3099-3129).
- **Observed:** The value is read back only after the TrustedInstaller fallback. A normal write is trusted and
  logs nothing. Verification happens later, in the health check, which compares most tables with the registry.
- **Defender specifically:** Handled better than the rest. `-Defender Disable` refuses when `IsTamperProtected`
  is true (2248-2251). `DefenderQuiet` warns up front (2270-2297), and the health check reads the effective
  values (`MAPSReporting`, `SubmitSamplesConsent`, `RealTimeProtectionEnabled`) rather than the policy keys, so a
  silent block by Tamper Protection shows as a warning. Gaps: the four notification policy values are compared at
  registry level only, and `DisableAntiSpyware` (2253) is written although current Defender ignores it on client
  editions (U-06).
- **Why it matters:** A run can end "without errors" while a value did not take; the proof arrives only if the
  health check covers that table.
- **Verification:** Code reading.
- **Proposed fix:** Read back inside `Set-RegValue` and log `OK` or `MISMATCH` per value (feeds A-11).

### A-07 (Medium) Restore point

- **Where:** `New-SafetyRestorePoint` (1298-1317), `Invoke-Apply` line 3494.
- **Observed:** Created before the first change unless `-SkipRestorePoint` or `-DryRun`. On an exception the run
  logs a warning that names both possible causes ("System Protection may be off, or one was made in the last 24
  hours") and continues. So a refusal is reported, not hidden, but it is not distinguished and it does not stop a
  run that turns off mitigations and deletes tasks.
- **Open point:** Microsoft's `Checkpoint-Computer` page calls the 24 hour refusal an error. If Windows PowerShell
  5.1 emits it as a warning, `-ErrorAction Stop` does not catch it and line 1301 logs "Restore point created."
  although none was (U-01). `SUMMARY.md` lists the restore point retry as not yet verified.
- **Proposed fix:** After the call, confirm with `Get-ComputerRestorePoint` that a point newer than the run start
  exists; report the exact cause; ask before continuing without one unless `-Force`.

### A-08 (Medium) Managed devices

- **Where:** Whole script. `grep` for `PartOfDomain`, `MDM`, `Enrollments`, `dsregcmd`: no match.
- **Observed:** No detection of domain join, Entra join, MDM enrolment or existing policy.
- **Why it matters:** Defaults disable `Netlogon` (`SvcOther`), smart card and biometric services, and write about
  60 values under `HKLM\SOFTWARE\Policies`. On a managed machine this breaks sign in or is overwritten at the next
  policy refresh, and the health check then reports drift with no explanation.
- **Verification:** Code reading and grep.
- **Proposed fix:** Pre flight check (C-2): `Win32_ComputerSystem.PartOfDomain`, `dsregcmd /status`,
  `HKLM\SOFTWARE\Microsoft\Enrollments`. Refuse unless `-AllowManaged`.

### A-09 (Medium) Edition awareness

- **Where:** `Invoke-Apply` 3490-3493.
- **Observed:** One warning when `EditionID` equals `Core`. `CoreSingleLanguage`, `CoreN` and
  `CoreCountrySpecific` are missed. Policy values are still written, and the health check reports them as
  matching because it compares registry values.
- **Why it matters:** On Home, telemetry level 0 and the update deferral policies are ignored by Windows, yet the
  result reads PASS (U-07).
- **Proposed fix:** Match `Core*`; mark each policy backed tweak with the editions that honour it; report "not
  applicable on this edition" in the plan, the log and the health check.

### A-10 (Medium) Download integrity

- **Where:** `.github/workflows/windows-release.yml`, `windows-build.yml`, README step 1.
- **Observed:**
  - The release job computes the SHA256 and publishes it in the same release as the script. This detects a
    corrupted download. It does not protect against a compromised release or account, because whoever can replace
    the script can replace the hash.
  - No Authenticode signature and no build provenance attestation (grep for `signtool`,
    `Set-AuthenticodeSignature`, `attest`: no match).
  - Actions are pinned by tag (`actions/checkout@v7`, `upload-artifact@v7`, `download-artifact@v8`), not by
    commit SHA. The release job has `contents: write`.
  - CI does fail when the committed script or `docs/OPTIONS.md` differ from a fresh build
    (`git diff --ignore-cr-at-eol --exit-code`). Verified in the workflow and reproduced locally.
  - The ZOICWARE inputs are pinned by SHA256 in `build.py`; the build is reproducible.
- **Proposed fix (needs approval, changes the hashing and signing process):** Add
  `actions/attest-build-provenance` and document `gh attestation verify`; pin actions by SHA; state in the README
  what the SHA256 does and does not prove. Authenticode signing is optional and costs a certificate.

### A-11 (Medium) Logging

- **Where:** `Write-Log` (671-681), `Set-RegValue`, `Save-ResultJson` (3331-3337).
- **Observed:** A persistent log exists (`run-<time>.log` in the state folder). On a real run a registry write
  logs nothing on success, so the log holds no option name, before value or after value. Before values are in
  `state.json` only, without the option that caused them. The health check does export a machine readable report
  (`health-<time>.json`, and `revert-check-<time>.json`), in a fixed folder.
- **Proposed fix:** A JSON lines change log: time, option, target, before, after, result. The same records can be
  the journal of A-01.

### A-12 (Medium) `laptop.json` versus its description

- **Where:** `profiles/laptop.json`, README line 16 ("keeps security and battery life").
- **Observed:** The profile sets `PowerMode: Best` (the best performance overlay, which costs battery),
  `TaskMode: Delete` (A-03), and leaves `PauseUpdates` (60 days), `SecurityUpdatesOnly`, `DriverExclusion`,
  `SvcOther` and `SearchIndexingOff` on. `PowerProfile: High` is skipped on battery machines by the script, so that
  line has no effect.
- **Proposed fix (needs approval, profile posture):** `PowerMode: Keep` or `Balanced`, `TaskMode: Disable`, skip
  `PauseUpdates` and `SecurityUpdatesOnly`; or change the README wording.

### A-13 (Medium) Defender kept on but starved

- **Where:** `Set-UpdatePolicies` (1772-1804), `$UpdateClassifications`, defaults `SecurityUpdatesOnly` on,
  `KeepDefinitionUpdates` off, `PauseUpdates` 365 days, `TaskMode Delete`.
- **Observed:** With no profile, the definition update classification is excluded, updates are paused for a year
  and the Defender tasks are deleted, while real time protection stays on. The health check warns when signatures
  are older than 7 days (3118-3128). All three profiles enable `KeepDefinitionUpdates`; the bare defaults do not.
- **Why it matters:** Protection with year old signatures is protection in name only. Whether Windows honours the
  `ExcludeUpdateClassifications` value is U-08.
- **Proposed fix (needs approval, changes a default):** Turn `KeepDefinitionUpdates` on by default.

### A-14 (Low) `-RestoreTask` examples

- **Where:** README line 28, template `.EXAMPLE` line 52, `-ListOptions` hint line 294.
- **Observed:** The README and help example use `'\Microsoft\Windows\Time Synchronization\*'`; the hint uses
  `'\Microsoft\Windows\TPM\*'`. Both are in `$TaskKeepBuiltIn`, so they are never deleted or disabled and the
  command prints "No recorded task matches". The README Options section itself says these are always left alone.
- **Proposed fix:** Use `'\Microsoft\Windows\Application Experience\*'`, as `Test-Smoke.ps1` does.

### A-15 (Low) Comma lists through `-File`

- **Where:** `param` block (79-84), `Resolve-Options` (274-279); `Explain-Processes.ps1` line 222.
- **Observed:** `[string[]]` parameters receive `A,B` as one string under `powershell -File`, and
  `Resolve-Options` does not split, so the README workaround is still needed for `FocusedTweaks.ps1`.
  `Explain-Processes.ps1 -Compare` already splits on commas, so it accepts both forms. Self elevation is not
  affected: it rebuilds the list inside an encoded command (112-117).
- **Proposed fix:** Split `Enable`, `Skip` and `Only` on commas in `Resolve-Options`, then drop the README note.
  Do not split `SkipRegGroup`: one upstream group title contains a comma.

### A-16 (Low) Windows 10

- **Where:** `Invoke-Apply` line 3489.
- **Observed:** The only version warning is for builds below 19041. Nothing is said on Windows 10 22H2.
- **Verified externally:** Microsoft's end of support page states that Extended Security Updates keep a Windows 10
  PC receiving security updates until 12 October 2027; the consumer programme was extended from October 2026
  during 2026. Sources at the end.
- **Proposed fix:** On builds below 22000, log that Windows 10 receives security updates only through ESU until
  12 October 2027, and that `PauseUpdates` and `SecurityUpdatesOnly` delay them.

### A-17 (Low) Fixed values in revert

- **Where:** `Invoke-Revert` 3635-3640, `Set-PerformancePowerPlan` 1867-1870, 3618-3627.
- **Observed:** Registry values, tasks, features, hibernation, memory compression, sleep study logs and password
  age are restored from recorded originals. Three paths are fixed: Defender real time protection is always set to
  on (`State.Defender` is a boolean), the power plan falls back to Balanced when the previous plan was a tweaked
  one or is gone, and password age falls back to 42 days for old state files.
- **Proposed fix:** Record the three Defender preferences before changing them and restore those.

### A-18 (Low) TrustedInstaller helper

- **Where:** `Invoke-AsTI` (932-960), `Repair-TrustedInstallerPath` (962-974).
- **Observed:** The helper points the TrustedInstaller service at a command and restores the path in `finally`.
  If the process is killed in between, Windows servicing fails until the script is started again, because the
  repair runs only at script start. Endpoint security products flag this technique (MITRE ATT&CK T1543.003).
- **Proposed fix:** Document it in the README safety notes; offer `-NoTrustedInstaller` (already in the ideas
  queue) that reports protected values as skipped.

### A-19 (Low) Test coverage

- **Where:** `tests/Test-Parse.ps1`.
- **Observed:** The static tests cover parsing, defaults, profiles, quoting and the junction safe cleanup. There
  is no test that a second snapshot keeps the first original, that state survives a save and load, that
  `Remove-RegKey` behaves on a repeat, or that `Resolve-Options` handles lists.
- **Proposed fix:** Add these in the same dependency free style, against a scratch `HKCU\Software\FocusedTweaksTest`
  key or with the registry primitives stubbed.

### A-20 (Info) Relative paths and elevation

- **Where:** Self elevation block (107-126).
- **Observed:** The elevated command starts with `Set-Location -LiteralPath <original directory>` and forwards the
  bound parameters quoted. `-ProfilePath .\profiles\laptop.json` is not rewritten to an absolute path, but it
  resolves to the same file. No defect. One edge: when the elevation prompt is answered with another account,
  mapped drive letters may not exist in the new session.

---

## Section B: Windows performance

### B findings

| ID | Severity | Finding | Status |
|---|---|---|---|
| B-01 | High | The benchmark cannot support the performance claims | Fixed in `c17e102` |
| B-02 | High | Security controls are off by default with no per machine evidence of a gain | Rejected: kept by design; trade-off log line added |
| B-03 | High | The timer service is on by default; on Windows 10 it likely does nothing, on Windows 11 it costs power all the time | Fixed (revised) |
| B-04 | Medium | Hardware accelerated GPU scheduling is forced on inside the `Registry` bundle | Fixed (revised) |
| B-05 | Medium | Three default tweaks are no-ops or harmful on common hardware | Fixed (MemoryCompression threshold; other two rows kept by design) |
| B-06 | Medium | The only before and after numbers in the repository come from a VM | Fixed in `196b937` |

**B-01 (High) Benchmark methodology.** `Invoke-Benchmark` (2722-2768).

- Boot time is one sample: the latest event 100 in `Diagnostics-Performance/Operational` (2727-2728). No
  repetitions. With `SvcDiagnostics` on (the default) the service that writes this log is disabled, so the "after"
  value may be the stale "before" event (U-05).
- DPC and ISR are the mean of ten one second samples of `Win32_PerfFormattedData_PerfOS_Processor` on an idle
  system (2741-2745). This gives percent of CPU time, not latency. There is no maximum or percentile, so it cannot
  show the stutter that latency tweaks target.
- "Kernel call cost" is 20,000 `File.Exists` calls in a PowerShell loop and "CPU loop" is 3 million interpreted
  steps, each run once. Both measure the PowerShell interpreter, CPU frequency state and the Defender file filter
  more than the kernel.
- Every metric is a single run. No median, no spread, no warm up. Results are compared with the latest earlier
  file only, so a third run compares with the second, not the baseline.
- The context block records mitigations, MPO, timer service and power plan name. It does not record power source
  (AC or battery), power mode overlay, CPU model, core isolation state, or whether a hypervisor is present.
- Not measured at all: idle RAM, idle CPU over a fixed window, process and service count, disk or network
  throughput, frame times. The background footprint options (services, tasks, Run keys, debloat) therefore have no
  metric.
- CI: `windows-smoke.yml` does not run `-Benchmark` and makes no performance claim. Correct as it is.
- **Proposed fix:** Benchmark v2: N repetitions (default 5) with median and min to max; idle footprint (process
  count, services running, committed bytes, mean CPU over 60 s); context with power source, overlay, CPU, VBS
  state and `HypervisorPresent`; refuse to compare runs whose context differs; keep a named baseline; mark results
  from a VM as not valid for performance.

**B-02 (High) Security off by default.** `SpectreMeltdownOff`, `CoreIsolation` and `Uac` are on by default
(lines 137, 140, 189). On CPUs with the hardware fixes the mitigation gain is close to zero (rows below), UAC has
no performance effect, and the repository holds no measurement on physical hardware. The cost is certain; the gain
is not. **Proposed (needs approval):** default off, on in `desktop-max.json`, and gate `SpectreMeltdownOff` and
`CoreIsolation` on a benchmark v2 comparison on that machine.

**B-03 (High) Timer service.** `Install-TimerResolutionService` (2483-2507). Since Windows 10 version 2004 a
timer resolution request applies to the calling process only (Microsoft `timeBeginPeriod` documentation, verified).
The script relies on `GlobalTimerResolutionRequests = 1` to make it system wide. That value is not documented by
Microsoft; community research reports it is honoured on Windows 11 and Server 2022 and later, not on Windows 10
(U-02). So on Windows 10 2004 to 22H2 the service raises the resolution for itself and nothing else. On Windows 11
it holds a 0.5 ms tick for the whole system all the time, which keeps the CPU out of deep idle states; Microsoft's
idle energy guidance says a 1 ms resolution already increases battery drain. Games and media players request a
fine timer themselves while they run. The benchmark "measures" this option only by reading back the resolution it
set. **Proposed (needs approval):** off by default, skipped with a note below build 22000, on in `desktop-max.json`.

**B-04 (Medium)** `HwSchMode = 2` sits in the upstream group "Turn on hardware accelerated GPU scheduling" and is
applied by the `Registry` option with 200 other groups. It has real compatibility effects (row below) and should be
its own option with a hardware check.

**B-05 (Medium)** `MemoryCompression` off above 8 GB can increase paging on 12 to 16 GB machines;
`Win32PrioritySeparation = 0x26` equals the client default behaviour; `MsiMode` forces a driver setting that
current GPU drivers already choose. Rows below.

**B-06 (Medium)** `docs/SUMMARY.md` lines 107-108 quote "timer 15.6 to 0.5 ms ... CPU loop 618 to 422 ms" from a
VMware guest with 6 GB RAM. Timer and interrupt behaviour in a guest is set by the hypervisor, and each figure is
one sample. These numbers should be labelled as a functional check, not as performance evidence.

### Required areas, current state in the script

| Area | Current state (verified in code) | Assessment |
|---|---|---|
| Power plan | `-PowerProfile High` (default) duplicates Ultimate Performance, falling back to High Performance, then sets processor minimum 100%, core parking off, ASPM off, USB suspend off, disk idle never, wake timers off. Skipped when a battery exists unless `-ForcePowerPlanOnLaptop`. `-PowerMode` default Keep; all three machine profiles except privacy set Best, including `laptop.json` | Desktop: lower wake latency, higher idle power draw and heat (Documented mechanism). Modern CPUs with hardware P-states already ramp in about a millisecond, so throughput gain is small. Laptop: correct that the plan is skipped; `PowerMode Best` in `laptop.json` contradicts the profile's purpose (A-12) |
| Spectre and Meltdown | `FeatureSettingsOverride = 3`, mask 3. Per Microsoft KB4072698 this turns off the Spectre variant 2 and Meltdown mitigations only | Meltdown is fixed in silicon on Intel from Whiskey Lake, Coffee Lake Refresh (9th gen, stepping dependent) and Cascade Lake onward, and never affected AMD. Spectre v2 is cheap with enhanced IBRS (Intel from the same generations) and on AMD Zen 2 and later. On those CPUs expect 0 to 2%. On Intel 6th to 8th gen and older expect a few percent to double digits in syscall and I/O heavy work (U-04). Benchmark should gate it |
| Core isolation | Group "Disable core isolation (VBS)" sets VBS, HVCI, Credential Guard (`LsaCfgFlags 0`) and kernel shadow stacks off | Wider than "memory integrity": it also drops Credential Guard. HVCI is cheap on CPUs with MBEC or GMET (Intel 7th gen and later, AMD Zen 2 and later) and costly without (U-04). Microsoft's own gaming guidance says turning memory integrity off can help some games. Benchmark should gate it; the current benchmark has no game or frame time metric |
| Timer resolution service | On by default, see B-03 | Effect survives on Windows 11 only (U-02); power cost is constant |
| Game DVR and background recording | `GameDVR_Enabled 0`, `AppCaptureEnabled 0`, `HistoricalCaptureEnabled 0`, policy `AllowGameDVR 0` | Background recording costs encoder time only when the user switched it on; it is off by default in Windows, so the usual gain is zero. Cost: no capture at all |
| Xbox Game Bar | App kept (`Microsoft.Xbox*` in the keep list); hotkeys zeroed, controller button off; Game Mode set on (already the Windows default) | No measurable gain. Harm: Game Bar widgets and capture stop working; some games show an `ms-gamingoverlay` prompt |
| HAGS | Forced on (`HwSchMode 2`) in `Registry` | Helps: needed for DLSS 3 frame generation; can reduce latency on recent GPUs with current drivers. Harms: reported stutter with some capture tools, VR and multi monitor setups, and on GPUs with little VRAM. Ignored without WDDM 2.7 driver support |
| NTFS last access | `NtfsDisableLastAccessUpdate = 0x80000001` (user managed, off) | Since Windows 10 1803 the default is system managed and already off on system volumes larger than 128 GB, so on most machines this is a no-op. Helps HDD with many small reads. NVMe and SATA SSD: negligible |
| SysMain | Not touched (no reference in template or data). Good | Disabling it is forum advice; it helps launch times on HDD and is light on SSD. Leave alone |
| Memory compression | Off when RAM is above 8 GB (`Disable-MMAgent`) | 32 GB and more: rarely active, gain about zero. 9 to 16 GB under load: compression avoids pagefile I/O, so turning it off can make things slower. Raise the threshold or make it opt in |
| Indexing | `SearchIndexingOff` on by default (WSearch disabled) | HDD: real relief during indexing. NVMe and SATA SSD: the indexer backs off under user activity, gain negligible. Cost: Start, Explorer and Outlook search degrade |
| Background footprint | Services (10 groups), tasks (A-03), Run keys (A-02), debloat. OneDrive and Edge are not removed; their autostart entries go with `RunKeys`; Edge startup boost and background mode are not set | Not measured at all (B-01). Most listed services are manual or trigger start and do not run, so disabling them changes nothing at idle |
| Network | `NetworkThrottlingIndex = 0xffffffff`, `SystemResponsiveness = 10`, adapter power saving off, EEE off, optional `IPv4Only`. No TCP, Nagle, autotuning or RSS tweaks (verified by grep). Good | Rows below. `NetworkThrottlingIndex` and `IPv4Only` are Folklore |
| Benchmark | See B-01 | Not fit to support claims yet |
| CI performance tests | None | Correct. Keep it that way |

### Option table

Columns: mechanism; tier; expected effect on desktop (D) and laptop (L); measurable by the current `-Benchmark`
(Yes, Partly, No); cost; reversibility (from `docs/OPTIONS.md`); recommended placement. "Default" means the default
profile, "Opt in" means off by default and on in a named profile.

#### Software

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `Packages` | Installs runtimes and tools with winget | n/a | None | No | Installs software the user did not pick (Firefox) | No | Opt in |
| `Debloat` | Removes consumer Appx packages | Documented mechanism | Fewer background processes (Phone Link, Teams, widgets helpers); small RAM gain | No | Apps gone | No | Default |
| `RemoveQuickAssist` | Removes a remote assistance tool | n/a | None (security hardening) | No | Remote help harder | No | Default |
| `LegacyFeatures` | Turns off SMB1, PowerShell 2, Recall, Work Folders, WMP Legacy | n/a | None (security hardening) | No | Old NAS shares on SMB1 fail | Yes | Default |
| `HypervisorFeatures` | Removes the Windows hypervisor | Documented mechanism | Removes virtualization overhead; only matters if it was on | Partly | No WSL 2, Hyper-V, Sandbox | Yes | Opt in (as now) |
| `NvidiaProfile` | 14 global driver settings (low latency Ultra, max performance power mode, texture filtering) | Documented mechanism | GPU bound games: lower input latency; frame rate about equal. Higher idle GPU power | No | Global override for every app; image quality slightly lower; untested on NVIDIA hardware per SUMMARY | Yes | Opt in |
| `NvidiaReBar` | Forces Resizable BAR for all games | Documented mechanism | Game dependent, plus or minus | No | Regressions in some games | Yes | Opt in (as now) |
| `NvidiaTelemetryStrip` | Deletes driver DLLs and plugins | Folklore | None measurable | No | Modifies the driver store; not reversible | No | Rejected: kept by design |

#### Registry and account

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `Registry` | About 200 upstream groups, mostly UI and privacy; a few performance values (rows in "Registry sub groups") | Folklore as a bundle | Mostly cosmetic | No | Many UI changes at once; hard to attribute | Yes | Default, after splitting out HAGS (B-04) |
| `Uac` | `EnableLUA 0` | Folklore | None | No | Every process of an admin runs elevated; large security loss | Yes | Rejected: kept by design |
| `RunKeys` | Deletes the Run keys | Documented mechanism | Fewer startup processes; faster sign in | Partly (boot time) | Removes wanted entries too, including the Windows Security tray icon; see A-02 | Yes (first run only) | Rejected: kept by design |
| `PrivacyDenials` | Denies app capabilities, background apps off, resets consent database | n/a | Small: fewer background UWP wakeups | No | Camera, microphone and location denied until re-allowed | Yes | Default |
| `TaskbarEndTask` | Adds a menu item | n/a | None | No | None | Yes | Default |
| `CoreIsolation` | VBS, HVCI, Credential Guard, shadow stacks off | Documented mechanism | 0 to 10% in games, hardware dependent (see areas table) | No (no game metric) | Kernel and credential protection lost | Yes | Rejected: kept by design |
| `HideLockOption` | UI | n/a | None | No | Feature hidden | Yes | Opt in (as now) |
| `HideSleepOption` | UI | n/a | None | No | Feature hidden | Yes | Opt in (as now) |
| `RegHibernateOff` | `HibernateEnabled 0` | n/a | None | No | No hibernate | Yes | Opt in (as now) |

#### Desktop, Start and sign in

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `NotificationSettings` | Per app toasts off | n/a | None | No | Missed notifications | Yes | Opt in |
| `RestartExplorer` | Applies settings | n/a | None | No | None | n/a | Default |
| `ClearDesktopIcons` | Moves shortcuts, hides system icons | n/a | None | No | Workflow change | Yes | Opt in |
| `HideAllDesktopIcons` | UI | n/a | None | No | Workflow change | Yes | Opt in (as now) |
| `ClearStartPins` | Replaces `start2.bin` | n/a | None | No | Pins lost until revert | Yes | Opt in |
| `NoRecentDocsHistory` | Policy | n/a | None | No | Breaks Quick Access pinning | Yes | Opt in (as now) |
| `ForceDpi100` | Forces 100% scaling | Folklore | None | No | Unreadable on high DPI panels | Yes | Opt in (as now) |
| `MouseAccel` | Pointer curve per scaling | n/a | Input feel, not speed | No | Changes pointer behaviour | Yes | Opt in |
| `LockScreenOff` | Policy | n/a | None | No | None | Yes | Opt in (as now) |

#### Right click menu

All fifteen are UI only: tier n/a, no performance effect, not measurable, reversible, and correctly placed as they
are (two additions on by default, thirteen off).

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `MenuKillNotResponding` | Adds a verb | n/a | None | No | None | Yes | Default |
| `MenuRestartExplorer` | Adds a verb | n/a | None | No | None | Yes | Default |
| `MenuTakeOwnership` | Adds a verb | n/a | None | No | Easy to misuse on system files | Yes | Opt in |
| `MenuRunAsAdmin` | Adds a verb | n/a | None | No | Sets process execution policy to Bypass for the script | Yes | Opt in |
| `MenuNoShare` | Blocks a shell extension | n/a | None | No | Entry hidden | Yes | Opt in |
| `MenuNoGiveAccess` | Blocks a shell extension | n/a | None | No | Entry hidden | Yes | Opt in |
| `MenuNoCast` | Blocks a shell extension | n/a | None | No | Entry hidden | Yes | Opt in |
| `MenuNoLibrary` | Blocks a shell extension | n/a | None | No | Entry hidden | Yes | Opt in |
| `MenuNoQuickAccess` | Hides verbs | n/a | None | No | Entry hidden | Yes | Opt in |
| `MenuNoPinToStart` | Blocks a shell extension | n/a | None | No | Entry hidden | Yes | Opt in |
| `MenuNoPrevVersions` | Blocks a shell extension | n/a | None | No | Entry hidden | Yes | Opt in |
| `MenuNoTroubleshoot` | Blocks a shell extension | n/a | None | No | Entry hidden | Yes | Opt in |
| `MenuNoDefenderScan` | Blocks a shell extension | n/a | None | No | Manual scan entry hidden | Yes | Opt in |
| `MenuNoOneDrive` | Blocks a shell extension | n/a | None | No | Entry hidden | Yes | Opt in |
| `MenuNoTerminal` | Blocks a shell extension | n/a | None | No | Entry hidden | Yes | Opt in |

#### Telemetry, privacy and Defender

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `TelemetryPolicy` | Policy values, DiagTrack services off | Folklore (for speed) | DiagTrack idle cost is small; privacy is the real reason | No | Some policies ignored on Home (A-09) | Yes | Default (as privacy) |
| `TelemetryHosts` | 30 hosts entries | Folklore | None | No | Defender may flag or undo hosts entries for Microsoft domains (U-09) | Yes | Opt in |
| `BiometricsPolicy` | Policy | n/a | None | No | Windows Hello face and fingerprint off | Yes | Opt in |
| `Cdp` | CDP services off, cache deleted | Folklore | None measurable | No | Nearby sharing, cross device features | Partly | Opt in |
| `RazerAsusHosts` | Hosts entries | n/a | None | No | Vendor installers fail | Yes | Opt in |
| `DefenderQuiet` | Cloud reporting and sample submission off | n/a | None | No | Cloud delivered protection reduced | Yes | Opt in (privacy profile) |

#### Services

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `SvcOther` | 15 services disabled | Folklore | Near zero: most are manual or trigger start | No | `Netlogon` breaks domain sign in (A-08); location off | Yes | Rejected: kept by design |
| `SvcExtra` | 7 services disabled | Folklore | Near zero | No | Built in VPN, UPnP discovery, Storage Spaces | Yes | Rejected: kept by design |
| `SvcDefrag` | Optimize Drives off | Folklore | Negative over time | No | No retrim | Yes | Rejected: kept by design |
| `SvcBiometrics` | Service off | Folklore | None | No | Windows Hello | Yes | Rejected: kept by design |
| `SvcSmartCard` | Services off | Folklore | None | No | Smart cards, some security keys | Yes | Rejected: kept by design |
| `SvcDiagnostics` | DPS and WDI off | Folklore | None | No | Troubleshooters, network diagnostics; may stop the boot time event the benchmark reads (U-05) | Yes | Rejected: kept by design |
| `SvcBluetooth` | Services off | Folklore | None | No | Bluetooth | Yes | Rejected: kept by design |
| `SvcPrinting` | Spooler off | Folklore | None (security hardening on machines that never print) | No | Printing, some PDF export | Yes | Rejected: kept by design |
| `SvcDeliveryOpt` | DoSvc off | Documented mechanism | Removes background upload and disk use during updates | No | Slower Store and update downloads | Yes | Rejected: kept by design |
| `SvcRadio` | Service off | Folklore | None | No | Airplane mode toggle | Yes | Rejected: kept by design |
| `SearchIndexingOff` | WSearch off | Documented mechanism (HDD only) | HDD: less disk load. SSD: negligible | No | Search quality | Yes | Rejected: kept by design |

#### Windows Update

None of these change steady state speed; they trade security for fewer background update runs.

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `DriverExclusion` | Policy | n/a | None | No | No driver fixes through Windows Update | Yes | Opt in |
| `SecurityUpdatesOnly` | 730 day deferral policies, excluded classifications | n/a | None | No | Security updates delayed; Defender definitions excluded (A-13) | Yes | Opt in |
| `PauseUpdates` | Pause dates, update services to Manual | n/a | None at steady state | No | No patches for up to 365 days | Yes | Opt in, short default |
| `PauseStopsUpdateTasks` | Disables update tasks | n/a | None | No | As above | Yes | Opt in |
| `KeepDefinitionUpdates` | Keeps Defender definitions | n/a | None | No | None | Yes | Default on |
| `BlockFeatureUpgrades` | `TargetReleaseVersion` | n/a | None | No | Stuck on a version until removed | Yes | Opt in (as now) |

#### Power, devices and network

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `DisableHibernate` | `powercfg /hibernate off` | n/a | Frees disk space; cold boot gets slower because Fast Startup goes | Partly (boot time) | No hibernate | Yes | Opt in (as now) |
| `MsiMode` | `MSISupported 1` on display adapters | Folklore | None on current GPU drivers, which already use MSI | Partly (interrupts) | A device that does not support MSI may fail to start | Yes | Opt in |
| `MemoryCompression` | `Disable-MMAgent` above 8 GB | Folklore | 32 GB and more: none. 9 to 16 GB under load: can be slower | No | More paging | Yes | Default, threshold 32 GB (B-05 approved) |
| `SleepStudy` | Three diagnostic logs off | Folklore | None measurable | No | No sleep diagnostics | Yes | Opt in |
| `NetAdapterPower` | Adapter power keywords off, `PnPCapabilities 24` | Documented mechanism | D: avoids link drops after idle. L: more drain | No | Wake on LAN off | Yes | Default on desktop |
| `NetAdapterEee` | EEE off | Documented mechanism | Removes link wake latency (microseconds); fixes flaky links on some NICs | No | About 1 W more per port | Yes | Default on desktop |
| `DevicePowerSaving` | Selective suspend and idle off for all ACPI, HID, PCI, USB devices | Documented mechanism | D: steadier USB input polling. L: skipped | Partly (DPC) | Higher idle power; thousands of values written | Yes | Opt in |
| `DeviceWakeOff` | `WaitWakeEnabled 0` | n/a | None | No | Keyboard cannot wake the PC | Yes | Opt in (as now) |
| `MpoOff` | `OverlayTestMode 5` | Folklore (undocumented workaround) | Fixes flicker on some setups | No | Can break HDR, raises compositor load | Yes | Opt in (as now) |
| `WriteCacheFlushOff` | `CacheIsPowerProtected 1` | Documented mechanism | Faster small synchronous writes | No (no disk metric) | Data loss on power cut | Yes | Opt in (as now) |
| `TimerResolution` | Service holds 0.5 ms, global flag | Measured (the setting only, in a VM); benefit Folklore | Windows 11: Sleep(1) finer for apps that never ask. Windows 10: none (U-02) | Yes, but circular | Constant power cost | Yes | Default, skipped below build 22000 and on battery (B-03 revised) |
| `NvmeNativeDriver` | Feature overrides for the new NVMe stack | Documented mechanism (server; unsupported on client, U-10) | Higher IOPS on fast NVMe | No | Experimental; BitLocker and disk tools | Yes | Opt in (as now) |
| `IPv4Only` | Unbinds IPv6 | Folklore | None | No | Breaks IPv6 only networks; Microsoft advises against disabling IPv6 | Yes | Rejected: kept by design |

#### Security trade-offs

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `SpectreMeltdownOff` | Mitigations for two CVEs off | Documented mechanism | Old Intel: several percent in syscall heavy work. Intel 9th gen and later, AMD Zen 2 and later: 0 to 2% (U-04) | Partly (kernel call cost) | Cross process and kernel memory disclosure | Yes | Rejected: kept by design |
| `DepOff` | `nx AlwaysOff` | Folklore | None; NX has no measurable cost | No | Removes a core exploit mitigation; needs Secure Boot off | Yes | Removed (approved) |

#### System and cleanup

| Option | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `NoAutoMaintenance` | Maintenance off | Folklore | Negative over time | No | No retrim, no scheduled scans | Yes | Remove |
| `PasswordExpiry` | `maxpwage unlimited` | n/a | None | No | None for home use | Yes | Default |
| `FaultTolerantHeap` | FTH off and reset | Folklore | None; FTH only acts on apps that crashed | No | Crashing apps lose a mitigation | No | Rejected: kept by design |
| `FastShutdown` | Short kill timeouts | n/a | Faster shutdown | No | Unsaved work lost | Yes | Opt in |
| `TimeServerPool` | NTP pool | n/a | None | No | None | Yes | Opt in |
| `EnableSystemRestore` | Turns System Protection on for the retry | n/a | None | No | Disk space | No | Default on (safety) |
| `TempCleanup` | Deletes temp files | Folklore | Disk space only | No | Running installers may lose files | No | Opt in |
| `UpdateCacheCleanup` | Deletes update downloads | Folklore | Disk space only | No | Updates download again | No | Opt in |
| `HealthCheckAfter` | Verification | n/a | None | No | None | n/a | Default |

#### Other settings and registry sub groups

| Item | Mechanism | Tier | Expected effect | Bench | Cost | Revert | Placement |
|---|---|---|---|---|---|---|---|
| `-TaskMode Delete` | Deletes all tasks | Folklore | None at idle | No | A-03 | Yes | Rejected: kept by design (A-03 revised: Delete stays the default, with more built-in keeps) |
| `-TaskMode Disable` | Disables 12 telemetry tasks | Documented mechanism | Removes periodic Compatibility Appraiser CPU and disk bursts | No | None notable | Yes | Default |
| `-PowerProfile High` | Ultimate or High Performance clone | Documented mechanism | D: lower wake latency, higher idle power. L: skipped | Partly | Power, heat, fan | Yes | Default on desktop |
| `-PowerProfile Medium` | Balanced clone, minimum 50% | Documented mechanism | Small | Partly | Some power | Yes | Opt in |
| `-PowerMode Best` | Performance overlay | Documented mechanism | Faster frequency ramp on Balanced based plans | Partly | Battery life on laptops | Yes | Opt in; not in `laptop.json` |
| `-Defender Disable` | Real time protection off | Documented mechanism | Faster file heavy work (builds, installs) | Partly (kernel call cost) | No antivirus | Yes | Opt in (as now) |
| HAGS (`HwSchMode 2`) | GPU scheduler in the GPU | Documented mechanism | See areas table | No | Compatibility | Yes | Own option, default on, skipped below WDDM 2.7 (B-04 revised) |
| Game DVR and capture off | No background encoder | Documented mechanism | Zero unless background recording was on | No | No capture | Yes | Default |
| Game Bar hotkeys and `AllowGameDVR 0` | Policy and hotkeys | Folklore | None | No | Game Bar unusable | Yes | Rejected: kept by design |
| Game Mode on | Already the Windows default | Documented mechanism | No change | No | None | Yes | Default |
| `NetworkThrottlingIndex 0xffffffff` | Lifts the MMCSS packet limit during media playback | Folklore | None for games; relevant only with multimedia playback on fast links | No | None known | Yes | Rejected: kept by design |
| `SystemResponsiveness 10` | Less CPU reserved for background work under MMCSS | Folklore | Negligible | No | None known | Yes | Rejected: kept by design |
| `Win32PrioritySeparation 0x26` | Short variable quanta, foreground boost | Folklore (equals the client default) | None | No | None | Yes | Rejected: kept by design |
| Last access off | No atime writes | Documented mechanism | HDD: fewer writes. SSD: negligible; often already off | No | Tools that use last access dates | Yes | Default |
| Visual effects and animations off | Less compositor work | Documented mechanism | Perceived snappiness; no throughput change | No | Looks | Yes | Default |
| Storage Sense off | Policy | Folklore | None | No | No automatic cleanup | Yes | Opt in |
| WPBT execution off | Blocks firmware injected binaries | n/a | None (security gain) | No | Vendor firmware tools | Yes | Default |

#### README and SUMMARY performance claims

| Claim | Where | Tier | Assessment |
|---|---|---|---|
| "The defaults aim for maximum performance" | README line 56, template line 8 | Folklore | No measurement on physical hardware exists in the repository |
| SSD retrim, time sync, TPM, BitLocker and display scaling are left alone because removing them gains no speed | README line 58-59 | Documented mechanism | Correct, and enforced by the hard floor tests in `Test-Parse.ps1` |
| `-Benchmark` measures timer resolution, latency (DPC and ISR), kernel call cost and boot time | README line 43-44 | See B-01 | It reports DPC and ISR time share, not latency; the other three are single samples |
| "timer 15.6 to 0.5 ms, Sleep(1) 15.9 to 1.6 ms, interrupts per second 27,397 to 3,049, kernel call cost 30.5 to 13.2 us, CPU loop 618 to 422 ms" | SUMMARY line 107-108 | Measured (VM, one sample each) | Not valid as performance evidence (B-06) |

---

## Section C: features and extensions

Ranked by benefit to the user, security value and maintenance cost (3 high, 1 low for benefit and security; cost
is the reverse, 3 means cheap).

| Rank | Feature | Benefit | Security | Low cost | Fixes |
|---|---|---|---|---|---|
| 1 | Transaction journal with rollback | 3 | 3 | 2 | A-01, A-04, A-05, A-11 |
| 2 | Pre flight checks | 3 | 3 | 3 | A-07, A-08, A-09, A-16 |
| 3 | Evidence tier per option | 3 | 2 | 3 | B-02, the option table above |
| 4 | Per option revert | 3 | 2 | 2 | needs rank 1 |
| 5 | Unattended mode, JSON output, exit codes | 2 | 2 | 3 | A-11 |
| 6 | Hardware aware filtering | 2 | 2 | 2 | B-03, B-04, B-05 |
| 7 | Before and after report with benchmark v2 | 3 | 1 | 2 | B-01, B-06 |
| 8 | Drift detection | 2 | 2 | 2 | |
| 9 | Signer based triage with ATT&CK mapping | 2 | 3 | 2 | |
| 10 | Advice rules as versioned data | 1 | 1 | 3 | |
| 11 | Baseline profile from the current machine | 2 | 1 | 2 | |
| 12 | Optional GUI | 1 | 0 | 1 | defer |

**C-1 Transaction journal with rollback.** *What:* every change appends one flushed JSON line (step ID, option,
target, before, after, result) before it is made; `state.json` is written atomically; a failed step can be rolled
back from its own records. *Why:* closes the two ways originals are lost today and gives the log its missing
detail. *Needs:* a journal writer used by `Set-RegValue`, `Remove-RegKey`, task and service changes; replay at
start; tests. *Risk:* slower runs on the device steps (thousands of appends; batch the flush per key); migration
of existing state files.

**C-2 Pre flight checks.** *What:* before the plan, check and report pending reboot, Windows Update activity,
power source, domain, Entra or MDM management, edition, Tamper Protection, System Protection state, and whether the
elevated account is the desktop account (exists). Block on managed devices unless overridden. *Why:* most
"it did not stick" outcomes come from these states. *Needs:* one function and a JSON result. *Risk:* false blocks;
keep each check overridable by name.

**C-3 Evidence tier per option.** *Status: done in Batch 4; the tiers in `$OptionInfo` are authoritative. Where no
vendor page could be confirmed on 10 Nov 2026 the tier is Folklore, which differs from the Section B table for
`Debloat`, `HypervisorFeatures`, `NvidiaProfile`, `NvidiaReBar` and `WriteCacheFlushOff`; `TimerResolution` is
Documented, not Measured, because the only measurement is from a VM (B-06).* *What:* a third field in `$OptionInfo` (tier) and a fourth (cost), shown by
`-ListOptions` and written to `docs/OPTIONS.md` by `build.py`, with a source link for Measured and Documented
entries. *Why:* users can choose on evidence; removes the gap between "maximum performance" and what is known.
*Needs:* template data, `build.py` regex and table, a `Test-Parse` check that every option has a tier. *Risk:*
low; tiers need upkeep.

**C-4 Per option revert.** *What:* `-Revert -Only A,B` restores only the records tagged with those options.
*Why:* today one bad option forces a full revert. *Needs:* option tags on journal records (C-1); rules for values
shared by two options. *Risk:* shared values (several update options write `SetAllowOptionalContent`) need a
"last owner" rule.

**C-5 Unattended mode.** *What:* `-Json` writes one result object; documented exit codes (0 ok, 1 failures,
2 cancelled, 3 pre flight refused, 4 state unreadable). *Why:* fleet use and the test harnesses stop parsing log
text. *Needs:* small. *Risk:* exit codes become an interface to keep stable.

**C-6 Hardware aware filtering.** *What:* skip GPU options without a discrete GPU, handle hybrid graphics, skip
the timer service below build 22000 and on battery machines, key storage options on drive type and RAM. *Why:*
removes no-ops and harm. *Needs:* a hardware probe function shared with the benchmark context. *Risk:* wrong
detection on unusual hardware; always log the reason and allow an override.

**C-7 Before and after report.** *What:* benchmark v2 (B-01) plus an HTML or JSON report from the baseline and
latest snapshots, including the `Explain-Processes` snapshot. *Why:* this is what makes "measurable" true.
*Needs:* benchmark rewrite, a static HTML template with no external resources. *Risk:* misleading numbers if
context control is weak; refuse mismatched comparisons.

**C-8 Drift detection.** *What:* an optional scheduled, read only `-HealthCheck -Json` that reports settings
reverted by a feature update. *Why:* updates do undo tweaks. *Needs:* a task (which `TaskMode Delete` must keep),
a place to show the result. *Risk:* a persistent elevated task that runs a script from a user chosen folder is a
privilege escalation path unless the script is copied to an administrator only location and its hash is checked.

**C-9 Signer based triage.** *What:* in `Explain-Processes` and `-StartupReview`, take vendor identity from the
Authenticode signer, not from `FileVersionInfo.CompanyName` (used at `Explain-Processes.ps1` line 114 and template
line 2698, and trivially spoofed), and tag persistence locations with ATT&CK IDs (Run keys and Startup folder
T1547.001, services T1543.003, tasks T1053.005). *Why:* an unsigned file claiming "Microsoft" is currently hidden
from the service list (line 2699). *Needs:* `Get-AuthenticodeSignature` with a cache. *Risk:* slower on first
run; catalog signed files need the catalog lookup.

**C-10 Advice rules as data.** *What:* move `$Advice` to a versioned JSON file with a source per rule. It is
already keyed on service name, not display name (verified, lines 33-83, 175). *Why:* reviewable rules. *Needs:*
small. *Risk:* low. The `edgeupdate` rule must change if A-03 stays as it is.

**C-11 Baseline profile.** *What:* generate a profile JSON from the current machine state. *Why:* reproduce a
setup elsewhere. *Needs:* a state reader per option, which C-8 also needs. *Risk:* options that are not readable
back (app removal, NVIDIA profile) make the baseline partial.

**C-12 Optional GUI.** Defer. The audience uses a CLI, the core has open High findings, and a GUI adds a second
surface to test under 5.1 and 7 plus an elevated window that parses user input. Reassess after C-1 to C-5.

---

## Unverified items

| ID | Statement | How to verify |
|---|---|---|
| U-01 | Whether the 24 hour restore point refusal is an error or a warning in Windows PowerShell 5.1 (A-07) | VM: run twice within a day, read the log |
| U-02 | `GlobalTimerResolutionRequests` is honoured on Windows 11 and Server 2022 and later, not on Windows 10 (B-03). Not in Microsoft documentation | `-Benchmark` from a second process on a Windows 10 22H2 VM and on physical Windows 11 |
| U-03 | The exact tasks deleted on a given machine, including browser updaters and Defender tasks (A-03) | Read the task list in an existing VM dry run log |
| U-04 | CPU generations with hardware fixes and the size of the mitigation and HVCI cost | Intel and AMD advisories; benchmark v2 on the owner's hardware |
| U-05 | With `SvcDiagnostics` on, boot event 100 is no longer written, so the benchmark shows a stale boot time (B-01) | Compare event timestamps before and after a run in the VM |
| U-06 | `DisableAntiSpyware` is ignored by current Defender on client editions (A-06) | Microsoft Defender documentation; VM |
| U-07 | Which policy values Windows Home ignores (A-09) | Microsoft policy CSP documentation per value |
| U-08 | Whether Windows Update honours `ExcludeUpdateClassifications` (A-13). Not found in Microsoft documentation | VM with a stale image: check whether definitions update |
| U-09 | Defender flags or reverts hosts entries for Microsoft telemetry domains (`TelemetryHosts`) | VM health check after a restart |
| U-10 | Native NVMe feature overrides are supported on client Windows 11 24H2 | Microsoft storage documentation |
| U-11 | All statements about live behaviour of options, since no dry run or apply was executed in this audit | `tools/Test-InVm.ps1` |

## Sources checked online

- Microsoft, end of support for Windows 10: https://www.microsoft.com/en-us/windows/end-of-support (ESU until
  12 October 2027).
- BleepingComputer, consumer ESU extension to October 2027:
  https://www.bleepingcomputer.com/news/microsoft/microsoft-quietly-extends-free-windows-10-esu-support-to-october-2027/
- Microsoft Learn, `timeBeginPeriod` (per process since Windows 10 version 2004):
  https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod
- Microsoft Learn, idle energy efficiency assessment (timer resolution and battery drain):
  https://learn.microsoft.com/en-us/windows-hardware/test/assessments/results-for-the-idle-energy-efficiency-assessment
- Microsoft Learn, `Checkpoint-Computer` (one restore point per 24 hours):
  https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/checkpoint-computer?view=powershell-5.1

---

## Reporting

**Findings by section and severity**

| Section | High | Medium | Low | Info |
|---|---|---|---|---|
| A: correctness and recoverability | 3 (A-01, A-02, A-03) | 10 (A-04 to A-13) | 6 (A-14 to A-19) | 1 (A-20) |
| B: performance | 3 (B-01, B-02, B-03) | 3 (B-04, B-05, B-06) | 0 | 0 |

**Performance rows by evidence tier** (108 rows: 88 options, 17 other settings and registry sub groups, 3 tiered
claims; the benchmark claim is covered by B-01)

| Tier | Options | Other rows | Total |
|---|---|---|---|
| Measured | 1 (`TimerResolution`, the setting only, in a VM) | 1 (SUMMARY VM figures) | 2 |
| Documented mechanism | 14 | 11 | 25 |
| Folklore | 26 | 7 | 33 |
| n/a (not a performance option) | 47 | 1 | 48 |

**Unverified items:** U-01 to U-11 above.

**Items that need explicit approval before Prompt 2 touches them:** A-03, A-12, A-13, B-02, B-03 (default or
profile posture) and A-10 (hashing and signing process).

**Next:** Prompt 2 will implement only the findings and features approved in this file, completing each approved
item with tests before moving on.
