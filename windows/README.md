# FocusedTweaks

A focused, option driven Windows 10/11 tweak script derived from [ZOICWARE](https://github.com/zoicware/ZOICWARE) (MIT),
with ideas from [FR33THYFR33THY/Ultimate](https://github.com/FR33THYFR33THY/Ultimate) (MIT). Windows only.

## Quick start

1. Download `FocusedTweaks.zip` from the repo's Releases page and unzip it. It holds the script, the profiles and
   the licence notices. Check the script against `FocusedTweaks.ps1.sha256` from the same release:
   `(Get-FileHash .\FocusedTweaks.ps1).Hash` must match (case does not matter).
2. Open Windows PowerShell (5.1) in that folder. The script asks for administrator rights itself.

       Set-ExecutionPolicy -Scope Process Bypass

3. Pick a profile, or none for the maximum performance defaults:
   `profiles\desktop-max.json` (desktop, all out), `profiles\laptop.json` (keeps security and battery life),
   `profiles\privacy.json` (privacy first, no security or update trade-offs).
4. See what it would do, then do it, then restart:

       .\FocusedTweaks.ps1 -ProfilePath .\profiles\laptop.json -DryRun
       .\FocusedTweaks.ps1 -ProfilePath .\profiles\laptop.json

5. After the restart, check the result. Undo everything, or only some deleted tasks, at any time:

       .\FocusedTweaks.ps1 -HealthCheck
       .\FocusedTweaks.ps1 -Revert
       .\FocusedTweaks.ps1 -RestoreTask '\Microsoft\Windows\Time Synchronization\*'

App removal, installed software and the temp cleanup cannot be undone; everything else can.

## More

    .\FocusedTweaks.ps1 -ListOptions
    .\FocusedTweaks.ps1 -HealthCheck -HealthCheckLaunch

Lists such as `-Enable A,B` only work from the prompt like this. `powershell -File .\FocusedTweaks.ps1 -Enable A,B`
passes `A,B` as one name and fails with "Unknown option".

Keep a set of choices in a file and pass it with `-ProfilePath`; `profiles\example.json` shows every setting.
Command line parameters win over the profile.

Two modes change nothing: `-Benchmark` measures timer resolution, latency (DPC and ISR), kernel call cost and boot
time and compares with the previous benchmark; `-StartupReview` lists everything that starts with Windows.

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
SSD retrim, time sync, TPM and BitLocker tasks, and display scaling. Use a profile to relax the defaults
per machine; `profiles/laptop.json` keeps the mitigations, core isolation and UAC and skips the timer service
to save battery. On a machine with a battery and no profile, the script suggests the laptop profile.

Every option, with its default and whether `-Revert` undoes it, is in [`docs/OPTIONS.md`](docs/OPTIONS.md).
That file is generated from the script by `tools/build.py`, so it always matches. `-ListOptions` prints the same list.

Third party licence notices are in `NOTICE.md`.

## Testing

Every push builds the script, runs the static tests and runs it for real on a throwaway Windows Server 2025
runner (dry runs, apply, health check, task restore, revert); see `.github/workflows`. For a full Windows 11 check,
`tools\Test-InVm.ps1` automates a VMware Workstation VM, see `docs/VM-TESTING.md`. See `docs/SUMMARY.md` for
what it does and how far it has been tested, and `CLAUDE.md` for how the repo is built.
