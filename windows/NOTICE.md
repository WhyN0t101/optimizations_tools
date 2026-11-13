# Third party notices

`FocusedTweaks.ps1` is derived from the following MIT licensed projects. Their copyright notices are kept here as the
licence requires.

## ZOICWARE

https://github.com/zoicware/ZOICWARE

MIT License. Copyright (c) 2024 zoicware.

Used for: the registry tweak list, telemetry and update policy data, domain lists, mouse profiles, the empty Start menu
layout and the option structure. The generated script embeds this data; `tools/build.py` reads it from unchanged copies
of three ZOICWARE files kept in `upstream/zoicware/` together with ZOICWARE's own `LICENSE`, because the original
repository is no longer available on GitHub (commit 2363922 of 24 Oct 2026).

## winutil and Win11Debloat

https://github.com/ChrisTitusTech/winutil (MIT License. Copyright (c) 2022 CT Tech Group LLC.)
https://github.com/Raphire/Win11Debloat (MIT License. Copyright (c) 2020 Raphire.)

Used for: registry values, Store app names and services that `tools/coverage.py` found in these projects and that
were taken over, rewritten, into `TelemetryExtra`, `BrowserPolicies`, `WindowsAIOff`, `StartupDelayOff`,
`NoDeviceEncryption`, `UpdateNoReboot`, `StandbyNetworkOff`, the service groups and the app list (Nov 2026).
Sophia Script (MIT) and privacy.sexy (AGPL-3.0) were only compared against; nothing was copied from them.

## Ultimate

https://github.com/FR33THYFR33THY/Ultimate

MIT License. Copyright (c) FR33THY.

Used for: the ideas and registry values behind network adapter power saving and Energy Efficient Ethernet, Spectre and
Meltdown mitigations, Data Execution Prevention and the timer resolution service (reduced and rewritten here).

## MIT License text

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
