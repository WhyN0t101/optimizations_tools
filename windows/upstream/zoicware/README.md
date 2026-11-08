# ZOICWARE source files used by the build

These are unchanged copies of the three files `tools/build.py` reads from
[ZOICWARE](https://github.com/zoicware/ZOICWARE) by zoicware, MIT licence (see `LICENSE` in this folder), at commit
`2363922c51eeff9ce415e51ae4b8161174654082` (24 Oct 2026):

- `src/zFunctions.psm1`: telemetry values, service and task lists, domain lists, mouse curves, update policy data
- `src/RegTweaks.txt`: the registry tweak list
- `src/Unpin.ps1`: the empty Start menu layout

They are kept here because the ZOICWARE repository stopped being available on GitHub on 8 Nov 2026, and the build
must stay reproducible. `build.py` checks each file against a pinned SHA256 (line endings ignored), so an edit here
fails the build. Do not change these files; to move to a newer ZOICWARE, see "When upstream changes" in `CLAUDE.md`.
