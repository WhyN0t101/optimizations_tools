# Testing in the VM

`tools\Test-InVm.ps1` runs FocusedTweaks in the VMware Workstation test VM and brings the results back. It drives the VM
with `vmrun`; nothing runs on the host.

## One-time VM setup

1. Revert the VM to a clean snapshot, from before any FocusedTweaks run.
2. VMware Tools must be running in the VM (`Get-Service VMTools`). If missing: VM menu, Install VMware Tools, restart.
3. Enable the built-in Administrator with a password: `net user Administrator *`, then `net user Administrator /active:yes`.
   That account runs elevated without a UAC prompt, as long as `FilterAdministratorToken` under
   `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` is missing or 0.
4. Make it sign in on its own after a restart with Sysinternals Autologon (it stores the password encrypted).
   Username `Administrator`, Domain = the VM's `hostname`, then Enable.
5. Install every pending Windows update and restart until Settings shows nothing pending, so Windows Update has
   almost nothing to do after each revert. Then restart once more, wait for the desktop, and wait until Task Manager
   shows no TiWorker (Windows Modules Installer Worker): a snapshot taken while it works keeps it working in every test
   (the run of 13 Nov 2026 spent 17 minutes waiting on it and -Reapply refused to start). Pause updates in Settings,
   turn off Tamper Protection (otherwise Defender may ignore the Defender options) and turn on System Protection for C:
   (otherwise the restore point step is never tested). Then take a snapshot of the running VM named `ft-base`. Repeat
   this every month or two; an old snapshot means downloads, installs and maybe a restart request in the middle of a
   test. The harness also waits, up to 30 minutes, for TiWorker to finish before the Dry, Apply and Reapply stages.

Use a password for this VM only: `vmrun` receives it on its command line.

## Running

```powershell
.\tools\Test-InVm.ps1 -ProfilePath .\profiles\desktop-max.json
```

It asks for the guest password (or reads `FT_VM_PASSWORD`), then:

| Stage | What runs in the VM |
|---|---|
| Dry | `-DryRun -Force` |
| Benchmark | `tools\Measure-Performance.ps1` (runs before and after by default, the second one compares) |
| Apply | `-Force` (real run, no prompts), then a restart |
| Health | `-HealthCheck` |
| Reapply | `-Reapply -Force` (puts back what Windows changed after the restart) |
| Revert | `-Revert` with its revert check, then a restart |

The default order is Dry, Benchmark, Apply, Health, Reapply, Benchmark, Revert; `StartupReview` is also available. Pick stages
with `-Stages Dry,Apply`, add script parameters with `-ScriptArgs '-Only MpoOff'`, and point at another VM
with `-Vmx` and `-Snapshot`. Results land in `test-results\<time>\<number>-<stage>` (ignored by git): `console.txt`, the
`run-*.log`, `health-*.json`, `revert-check-*.json` and `state.json`. `summary.txt` lists errors, health warnings and
values the revert did not bring back. The exit code is 1 when a stage failed or the health check reported a failure.

Each stage folder also holds `guest-diag.txt`: Windows Update events, restarts, crashed services and the VMware Tools
state during that stage. `summary.txt` mentions it when anything happened. Before the first benchmark the VM is restarted, so both
benchmarks start from a fresh boot (the one after Apply follows a restart too), and before every benchmark the test
waits until the VM's CPU use stays below 15 % for 30 seconds (at most 10 minutes). Benchmark stages run with the VM's
virtual network cable unplugged (nothing changes inside Windows), so update and cloud traffic add no noise; the other
stages keep the network, because `Packages` needs it.

Each benchmark folder also holds `processes.txt` and `processes.json`, a snapshot by `tools\Explain-Processes.ps1`
(it only reads), and `processes-compare.txt` in the result folder compares the first benchmark with the last: the
services and process counts the run removed, and what still runs.

Stages are started without waiting and the host polls for a done marker. If VMware Tools stops answering (busy or
restarting guest), the test waits up to `-BootTimeoutSeconds` for it to return; a stage that runs longer than
`-StageTimeoutMinutes` (120) fails. When a stage fails, whatever the guest has (console output so far, logs,
diagnostics) is still copied back before the error.

The VM is left running in the state of the last stage, so you can look around. After a failure, look before you
revert: `C:\FT\out\<stage>` and the System event log. The next test reverts it anyway.
