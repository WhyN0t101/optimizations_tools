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
5. Restart once, wait for the desktop, and take a snapshot of the running VM named `ft-base`.

Use a password for this VM only: `vmrun` receives it on its command line.

## Running

```powershell
.\tools\Test-InVm.ps1 -ProfilePath .\profiles\desktop-max.json
```

It asks for the guest password (or reads `FT_VM_PASSWORD`), then:

| Stage | What runs in the VM |
|---|---|
| Dry | `-DryRun -Force` |
| Benchmark | `-Benchmark` (runs before and after by default, the second one compares) |
| Apply | `-Force` (real run, no prompts), then a restart |
| Health | `-HealthCheck` |
| Revert | `-Revert` with its revert check, then a restart |

The default order is Dry, Benchmark, Apply, Health, Benchmark, Revert; `StartupReview` is also available. Pick stages
with `-Stages Dry,Apply`, add script parameters with `-ScriptArgs '-Only MpoOff'`, and point at another VM
with `-Vmx` and `-Snapshot`. Results land in `test-results\<time>\<number>-<stage>` (ignored by git): `console.txt`, the
`run-*.log`, `health-*.json`, `revert-check-*.json` and `state.json`. `summary.txt` lists errors, health warnings and
values the revert did not bring back. The exit code is 1 when a stage failed or the health check reported a failure.

The VM is left running in the state of the last stage, so you can look around. The next test reverts it anyway.
