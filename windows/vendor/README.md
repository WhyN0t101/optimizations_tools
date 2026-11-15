# Vendored source data used by the build

These are unchanged copies of the three files `tools/build.py` reads, at commit
`2363922c51eeff9ce415e51ae4b8161174654082` (24 Oct 2026). `LICENSE` in this folder is the licence of the project they
come from (MIT); the credit is in `../NOTICE.md`.

- `src/zFunctions.psm1`: telemetry values, service and task lists, domain lists, mouse curves, update policy data
- `src/RegTweaks.txt`: the registry tweak list
- `src/Unpin.ps1`: the empty Start menu layout

They are kept here because the original repository stopped being available on GitHub on 8 Nov 2026, and the build
must stay reproducible. `build.py` checks each file against a pinned SHA256 (line endings ignored), so an edit here
fails the build. Do not change these files; to move to newer data, see "When the vendored data changes" in `CLAUDE.md`.

## Where the data and ideas come from

| Project | Repository | Licence | Used for |
|---|---|---|---|
| ZOICWARE | https://github.com/zoicware/ZOICWARE | MIT | The three files above: the registry tweak list, telemetry and update policy data, domain lists, mouse profiles, the empty Start menu layout and the option structure. |
| Ultimate | https://github.com/FR33THYFR33THY/Ultimate | MIT | Ideas and values only, reduced and rewritten here; no files are kept in this folder. See `../NOTICE.md`. |

The comparison projects (winutil, Win11Debloat, Sophia Script, privacy.sexy) are pinned in `../tools/references.json`.
