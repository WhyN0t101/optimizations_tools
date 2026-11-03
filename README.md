# optimizations_tools

Personal Windows tuning tools.

| Folder | What it is |
|---|---|
| [`windows/`](windows/README.md) | `FocusedTweaks.ps1`: option driven Windows 10/11 tweak script (PowerShell 5.1), built from a template. Has `-DryRun`, `-Revert` and a health check. |
| [`gpu/`](gpu/gpu_tuner.py) | `gpu_tuner.py`: automated NVIDIA GPU overclock and undervolt search for Windows, with tests in `test_gpu_tuner.py`. |

The tweak script is derived from MIT licensed work. See [`windows/NOTICE.md`](windows/NOTICE.md).
The repository itself is under the Apache License 2.0 (`LICENSE`).
