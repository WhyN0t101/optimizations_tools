# FocusedTweaks

A focused, option driven Windows 10/11 tweak script derived from [ZOICWARE](https://github.com/zoicware/ZOICWARE) (MIT),
with ideas from [FR33THYFR33THY/Ultimate](https://github.com/FR33THYFR33THY/Ultimate) (MIT). Windows only.

Run it from a Windows PowerShell (5.1) prompt in this folder. It asks for elevation itself when needed.

    Set-ExecutionPolicy -Scope Process Bypass
    .\FocusedTweaks.ps1 -ListOptions
    .\FocusedTweaks.ps1 -DryRun
    .\FocusedTweaks.ps1
    .\FocusedTweaks.ps1 -HealthCheck -HealthCheckLaunch
    .\FocusedTweaks.ps1 -Revert

Lists such as `-Enable A,B` only work from the prompt like this. `powershell -File .\FocusedTweaks.ps1 -Enable A,B`
passes `A,B` as one name and fails with "Unknown option".

Keep a set of choices in a file and pass it with `-ProfilePath .\profiles\example.json`. Command line parameters win over
the profile.

Two modes change nothing: `-Benchmark` measures timer resolution, latency (DPC and ISR), kernel call cost and boot
time and compares with the previous benchmark; `-StartupReview` lists everything that starts with Windows.

## Options

The defaults aim for maximum performance: Spectre and Meltdown mitigations off, core isolation off, the
timer resolution service on, non-essential services off, apps removed. Things are removed or left alone,
never half done. A few things are always left alone because removing them gains no speed or costs it:
SSD retrim, time sync, TPM and BitLocker tasks, and display scaling. Use a profile to relax the defaults
per machine; `profiles/laptop.json` keeps the mitigations and core isolation and skips the timer service
to save battery.

Every option, with its default and whether `-Revert` undoes it, is in [`docs/OPTIONS.md`](docs/OPTIONS.md).
That file is generated from the script by `tools/build.py`, so it always matches. `-ListOptions` prints the same list.

Third party licence notices are in `NOTICE.md`.

Test in a virtual machine with a snapshot first. `tools\Test-InVm.ps1` automates that with VMware Workstation, see
`docs/VM-TESTING.md`. See `docs/SUMMARY.md` for what it does and how far it has been tested,
and `CLAUDE.md` for how the repo is built.
