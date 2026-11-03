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

## Options added in v5 and v6

See `-ListOptions` for every option.

| Option | Default | What it does |
|---|---|---|
| `DefenderQuiet` | on | Defender stays on; cloud reporting, sample submission, infection reports and notifications off (policy) |
| `NetAdapterPower` | on | Power saving off on physical network adapters |
| `NetAdapterEee` | on | Energy Efficient Ethernet off where the driver exposes it |
| `TempCleanup` | on | Empties the user and Windows Temp folders (not reversible; `C:\XboxGames` is never touched) |
| `UpdateCacheCleanup` | on | Empties the Windows Update download cache (not reversible) |
| `TaskbarEndTask` | on | End task in the right click menu of taskbar apps (Windows 11) |
| `DevicePowerSaving` | on | Power saving and selective suspend off for ACPI, HID, PCI and USB devices (skipped on battery) |
| `TimeServerPool` | on | Clock synced from pool.ntp.org |
| `MenuKillNotResponding` | on | "Kill not responding tasks" in the desktop right click menu |
| `MenuRestartExplorer` | on | "Restart Explorer" in the desktop right click menu |
| `SpectreMeltdownOff` | off | Spectre and Meltdown mitigations off. Lowers security |
| `DepOff` | off | Data Execution Prevention off (`bcdedit`). Needs Secure Boot off. Lowers security |
| `TimerResolution` | off | Small service that holds the finest timer resolution |
| `DeviceWakeOff` | off | Devices can no longer wake the PC (keyboard and mouse included) |
| `MpoOff` | off | Multiplane overlay off. Can fix flicker, can break some HDR setups |
| `WriteCacheFlushOff` | off | Write cache buffer flushing off on SATA and NVMe disks. A power cut can lose data |
| `FastShutdown` | off | Shorter shutdown timeouts, hung apps closed without asking |
| `BlockFeatureUpgrades` | off | Stay on the current Windows version; security updates continue until it ends |
| `SearchIndexingOff` | off | Windows Search indexer off (search gets slower) |
| `MenuTakeOwnership` | off | "Take ownership" in the right click menu of files and folders |

Enable the off ones with, for example, `-Enable SpectreMeltdownOff,TimerResolution`. Everything except the two cleanups
is undone by `-Revert`.

Third party licence notices are in `NOTICE.md`.

Test in a virtual machine with a snapshot first. See `docs/SUMMARY.md` for what it does and how far it has been tested,
and `CLAUDE.md` for how the repo is built.
