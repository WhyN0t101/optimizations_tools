# optimizations_tools

Personal Windows tuning tools.

| Folder | What it is |
|---|---|
| [`windows/`](windows/README.md) | `FocusedTweaks.ps1`: option driven Windows 10/11 tweak script (PowerShell 5.1), built from `windows/src/`. Every change can be previewed (`-DryRun`), undone (`-Revert`) and checked (`-HealthCheck`). |
| [`gpu/`](gpu/gpu_tuner.py) | `gpu_tuner.py`: automated NVIDIA GPU overclock and undervolt search for Windows, with tests in `test_gpu_tuner.py`. |

FocusedTweaks documentation, in `windows/docs/`:

| Document | For |
|---|---|
| [GUIDE.md](windows/docs/GUIDE.md) | A full walkthrough, from download to a maximum performance setup, NVIDIA driver included |
| [OPTIONS.md](windows/docs/OPTIONS.md) | Every option with its default and evidence (generated) |
| [REGISTRY.md](windows/docs/REGISTRY.md) | Every upstream registry value and the option that applies it (generated) |
| [COVERAGE.md](windows/docs/COVERAGE.md) | What winutil, Win11Debloat, Sophia Script and privacy.sexy change that FocusedTweaks does not (generated) |
| [CHANGELOG.md](windows/docs/CHANGELOG.md) | What changed in each version |
| [SUMMARY.md](windows/docs/SUMMARY.md) | Safety model, decisions on record and test status |
| [VM-TESTING.md](windows/docs/VM-TESTING.md) | Testing in a VMware VM |

The tweak script is derived from MIT licensed work. See [`windows/NOTICE.md`](windows/NOTICE.md).
The repository itself is under the Apache License 2.0 (`LICENSE`).
