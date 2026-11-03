# FocusedTweaks

A focused, option driven Windows 10/11 tweak script derived from [ZOICWARE](https://github.com/zoicware/ZOICWARE) (MIT),
with ideas from [FR33THYFR33THY/Ultimate](https://github.com/FR33THYFR33THY/Ultimate) (MIT).

Run in an elevated Windows PowerShell (5.1):

    powershell -ExecutionPolicy Bypass -File .\FocusedTweaks.ps1 -ListOptions
    powershell -ExecutionPolicy Bypass -File .\FocusedTweaks.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File .\FocusedTweaks.ps1
    powershell -ExecutionPolicy Bypass -File .\FocusedTweaks.ps1 -HealthCheck -HealthCheckLaunch
    powershell -ExecutionPolicy Bypass -File .\FocusedTweaks.ps1 -Revert

The script asks for elevation itself when started without administrator rights.

Options added in v5 (see `-ListOptions` for every option):

| Option | Default | What it does |
|---|---|---|
| `DefenderQuiet` | on | Defender stays on; cloud reporting, sample submission, infection reports and notifications off (policy) |
| `NetAdapterPower` | on | Power saving off on physical network adapters |
| `NetAdapterEee` | on | Energy Efficient Ethernet off where the driver exposes it |
| `TempCleanup` | on | Empties the user and Windows Temp folders (not reversible; `C:\XboxGames` is never touched) |
| `UpdateCacheCleanup` | on | Empties the Windows Update download cache (not reversible) |
| `SpectreMeltdownOff` | off | Spectre and Meltdown mitigations off. Lowers security |
| `DepOff` | off | Data Execution Prevention off (`bcdedit`). Needs Secure Boot off. Lowers security |
| `TimerResolution` | off | Small service that holds the finest timer resolution |

Enable the off ones with, for example, `-Enable SpectreMeltdownOff,TimerResolution`. All except the two cleanups are undone by `-Revert`.

Third party licence notices are in `NOTICE.md`.

Test in a virtual machine with a snapshot first. See `docs/SUMMARY.md` for what it does and how far it has been tested,
and `CLAUDE.md` for how the repo is built.
