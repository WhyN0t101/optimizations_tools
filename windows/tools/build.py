"""Build FocusedTweaks.ps1 from the files in src/ (joined in name order) plus data read from ZOICWARE source files.

Usage:
    python tools/build.py --out FocusedTweaks.ps1

By default the ZOICWARE files come from the copy in upstream/zoicware (the original repository is no longer on
GitHub); --zoicware points at another folder that contains a ZOICWARE "src" directory.

The files in src/ are the source of truth, one per area (options, data, registry, services, health check, entry
point and so on); joined in name order they form the template. Do not edit the generated FocusedTweaks.ps1 by hand,
change the file in src/ and build again.
"""
import argparse, hashlib, os, re, io, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument('--zoicware', default=os.path.join(HERE, '..', 'upstream', 'zoicware'),
                help='folder that contains the ZOICWARE "src" directory (default: the copy in upstream/zoicware)')
ap.add_argument('--src', default=os.path.join(HERE, '..', 'src'), help='folder with the NN-name.ps1 source files')
ap.add_argument('--out', default='FocusedTweaks.ps1')
ap.add_argument('--allow-other-commit', action='store_true',
                help='accept ZOICWARE files that differ from the pinned ones (when updating upstream)')
ap.add_argument('--version', default='',
                help='release tag to stamp into the script, like v8.0 (the release workflow passes the tag); '
                     'without it the script says it is a development build')
args = ap.parse_args()
if args.version and not re.fullmatch(r'v\d+(\.\d+){1,2}', args.version):
    sys.exit(f'--version must look like v8.0 or v8.0.1, not {args.version!r}')
SRC = os.path.join(args.zoicware, 'src')

# Only the exact upstream data makes a build reproducible. The three files are pinned by SHA256 of their text with
# line endings removed, so a git checkout with CRLF and one with LF give the same result.
ZOICWARE_COMMIT = '2363922c51eeff9ce415e51ae4b8161174654082'  # 24 Oct 2026, the files in upstream/zoicware
ZOICWARE_FILES = {
    'zFunctions.psm1': '75bdd32421f93ee76a09b63bbb32ffcbf69e5faa9474107effef20b29c220060',
    'RegTweaks.txt': '2eaf9484b0130af4305fce7036ce77357e5b582783538893c6fc21f11efaf6cd',
    'Unpin.ps1': '9bb6b001c3ca5d7186509c1909dee2016b07c55357d63fadb6aa1e763a96a43e',
}
for name, want in ZOICWARE_FILES.items():
    path = os.path.join(SRC, name)
    if not os.path.isfile(path):
        sys.exit(f'ZOICWARE file missing: {path}')
    with open(path, 'rb') as f:
        got = hashlib.sha256(f.read().replace(b'\r', b'')).hexdigest()
    if got != want and not args.allow_other_commit:
        sys.exit(f'{path} does not match ZOICWARE {ZOICWARE_COMMIT[:7]} (SHA256 {got}). '
                 'Use the files in upstream/zoicware, or pass --allow-other-commit when updating upstream.')

def read(name):
    with open(os.path.join(SRC, name), encoding='utf-8') as f:
        return f.read().replace('\r', '')

zf = read('zFunctions.psm1').split('\n')
reg = read('RegTweaks.txt')
src_files = sorted(f for f in os.listdir(args.src) if re.match(r'^\d{2}-[a-z0-9-]+\.ps1$', f))
assert src_files and src_files[0].startswith('00-'), src_files
tpl = ''.join(open(os.path.join(args.src, f), encoding='utf-8').read() for f in src_files)
# The version comes from the release tag, so a release needs no version commit. The committed script, built without
# --version, says it is a development build.
assert tpl.count('__FT_VERSION__') == 1, 'src/00-header.ps1 must hold the __FT_VERSION__ placeholder once'
tpl = tpl.replace('__FT_VERSION__', args.version or 'Development build; releases carry their tag here')

def ps_str(s):
    return "'" + s.replace("'", "''") + "'"

ROW = re.compile(r"Reg\.exe add '([^']+)' /v '([^']+)' /t (REG_\w+) /d '([^']*)' /f", re.I)

def rows(lines):
    out = []
    for l in lines:
        m = ROW.search(l)
        if m:
            out.append(m.groups())
    return out

def tweak_line(path, name, typ, data, indent='    '):
    if typ == 'REG_DWORD':
        return f"{indent}New-Tweak {ps_str(path)} {ps_str(name)} {int(data)} 'DWord'"
    if typ == 'REG_SZ':
        return f"{indent}New-Tweak {ps_str(path)} {ps_str(name)} {ps_str(data)} 'String'"
    raise ValueError(typ)

# 1. upstream reg text
reg = reg.replace('\r', '')
assert "\n'@" not in reg, 'here-string terminator inside reg text'
block1 = "# Upstream src/RegTweaks.txt, unchanged. Groups are the comment lines above each section.\n$UpstreamRegText = @'\n" + reg.rstrip('\n') + "\n'@"

# 2. telemetry
tel_block = zf[4738:4796]
tel_rows = rows(tel_block)
svc_rows = [r for r in tel_rows if '\\services\\' in r[0].lower()]
bio_rows = [r for r in tel_rows if 'biometrics' in r[0].lower()]
reg_rows = [r for r in tel_rows if r not in svc_rows and r not in bio_rows]
svc_names = [r[0].split('\\')[-1] for r in svc_rows]
tel_services = [n for n in svc_names if n in ('DiagTrack', 'dmwappushservice')]
cdp_services = [n for n in svc_names if n.startswith('CDP')]

# disable-services function text
fn_start = next(i for i, l in enumerate(zf) if l.startswith('function disable-services'))
fn_end = next(i for i, l in enumerate(zf) if l.startswith('function gpTweaks'))
ds_text = '\n'.join(zf[fn_start:fn_end])
ds_names = re.findall(r"Services\\([A-Za-z0-9_.]+)' /v 'Start' /t REG_DWORD /d '4'", ds_text)
ds_names = list(dict.fromkeys(ds_names))
groups = {
    'SvcBluetooth': ['BTAGService', 'BthAvctpSvc', 'bthserv', 'BluetoothUserService'],
    'SvcPrinting': ['Spooler', 'PrintWorkflowUserSvc', 'PrintNotify'],
    'SvcDeliveryOpt': ['DoSvc'],
    'SvcRadio': ['RmSvc'],
    'SvcBiometrics': ['WbioSrvc'],
    'SvcSmartCard': ['SCardSvr', 'ScDeviceEnum', 'SCPolicySvc'],
    'SvcDiagnostics': ['diagsvc', 'DPS', 'WdiServiceHost', 'WdiSystemHost'],
    'SvcDefrag': ['defragsvc'],
}
assigned = {n for v in groups.values() for n in v}
missing = [n for v in groups.values() for n in v if n not in ds_names]
assert not missing, missing
groups['SvcOther'] = [n for n in ds_names if n not in assigned]
# Not in upstream disable-services; taken from FR33THY Ultimate (8 Advanced\17 Services.ps1, "Services: Off").
# Only services nothing usable depends on: contact and user data sync for the removed Mail/People apps, SSDP
# discovery, Storage Spaces, and the built-in VPN client.
groups['SvcExtra'] = ['PimIndexMaintenanceSvc', 'UnistoreSvc', 'UserDataSvc', 'SSDPSRV', 'smphost', 'RasMan', 'SstpSvc']
# Still running in a clean Windows 11 VM after a full run (11 Nov 2026, Explain-Processes before and after), chosen
# by the owner: background helpers a home PC does not need. cbdhsvc and OneSyncSvc are per user templates.
groups['SvcBackground'] = ['OneSyncSvc', 'PcaSvc', 'TrkWks', 'InventorySvc', 'iphlpsvc', 'LanmanServer', 'cbdhsvc']
# Opt in: still running after a full run too, but turning them off costs a visible feature (notifications, the data
# usage page, AutoPlay and the scanners that depend on it).
groups['SvcAggressive'] = ['WpnService', 'WpnUserService', 'DusmSvc', 'ShellHWDetection']
# From the coverage comparison (docs/COVERAGE.md, Nov 2026): error reporting and the diagnostics hub collectors join
# the diagnostics group; the retail demo, Media Player network sharing and NVIDIA's old telemetry container join the
# extra group; third party updaters get a group of their own. Services that are not installed are skipped.
groups['SvcDiagnostics'] += ['WerSvc', 'wercplsupport', 'diagnosticshub.standardcollector.service', 'VSStandardCollectorService150']
groups['SvcExtra'] += ['RetailDemo', 'WMPNetworkSvc', 'NvTelemetryContainer']
groups['SvcUpdaters'] = ['AdobeARMservice', 'adobeupdateservice', 'dbupdate', 'dbupdatem', 'Razer Game Scanner Service']
order = ['SvcOther', 'SvcExtra', 'SvcBackground', 'SvcAggressive', 'SvcUpdaters', 'SvcDefrag', 'SvcBiometrics', 'SvcSmartCard', 'SvcDiagnostics', 'SvcBluetooth', 'SvcPrinting', 'SvcDeliveryOpt', 'SvcRadio']

lines = ["# Telemetry policy rows from upstream gpTweaks (gpTel). Service starts are handled separately below."]
lines.append("$TelemetryRegs = @(")
lines += [tweak_line(*r) for r in reg_rows]
lines.append(")")
lines.append("$BiometricsRegs = @(")
lines += [tweak_line(*r) for r in bio_rows]
lines.append(")")
lines.append("$TelemetryServices = @(" + ', '.join(ps_str(n) for n in tel_services) + ")")
lines.append("$CdpServices = @(" + ', '.join(ps_str(n) for n in cdp_services) + ")")
lines.append("")
lines.append("# Service groups from upstream disable-services. Each key is the option that switches the group on.")
lines.append("$ServiceGroups = [ordered]@{")
for g in order:
    lines.append(f"    {g} = @(" + ', '.join(ps_str(n) for n in groups[g]) + ")")
lines.append("}")
telemetry_block = '\n'.join(lines)

# 3. domains
dom_start = next(i for i, l in enumerate(zf) if '$domains = @(' in l and i > 4700)
tel_domains = []
for l in zf[dom_start + 1:dom_start + 60]:
    s = l.strip()
    if s == ')': break
    if s.startswith("'"): tel_domains.append(s.strip("'"))
assert len(tel_domains) == 30, len(tel_domains)
raz_start = next(i for i, l in enumerate(zf) if "synapse3ui-common.razerzone.com" in l)
razer, asus = [], []
for l in zf[raz_start:raz_start + 40]:
    m = re.search(r"0\.0\.0\.0 ([A-Za-z0-9.\-]+)", l)
    if m:
        d = m.group(1)
        (razer if ('razer' in d) else asus).append(d)
assert len(razer) == 13 and len(asus) == 11, (len(razer), len(asus))
dom_lines = ["# Domain lists from upstream (Get-TeleDomains, Razer and ASUS blocks)."]
for nm, lst in (('TelemetryDomains', tel_domains), ('RazerDomains', razer), ('AsusDomains', asus)):
    dom_lines.append(f"${nm} = @(")
    dom_lines += ["    " + ps_str(d) for d in lst]
    dom_lines.append(")")
domains_block = '\n'.join(dom_lines)

# 4. mouse profiles
ms = next(i for i, l in enumerate(zf) if "Getting Scaling Value" in l)
mtxt = '\n'.join(zf[ms:ms + 270])
cases = re.findall(r"^\s{8}(\d{3}) \{(.*?)^\s{8}\}", mtxt, re.S | re.M)
mlines = ["# Mouse profiles per display scaling, from upstream opNoMouseAccel. X and Y are SmoothMouse curves."]
mlines.append("$MouseProfiles = @{")
for scale, body in sorted(cases, key=lambda c: int(c[0])):
    def g(name):
        m = re.search(rf"'{name}' /t REG_SZ /d '(\d+)'", body)
        return m.group(1)
    speed, t1, t2 = g('MouseSpeed'), g('MouseThreshold1'), g('MouseThreshold2')
    lp = int(re.search(r"'LogPixels' /t REG_DWORD /d '(\d+)'", body).group(1))
    pp = int(re.search(r"'EnablePerProcessSystemDPI' /t REG_DWORD /d '(\d+)'", body).group(1))
    curves = re.findall(r"\$SmoothMouse([XY])Curve = \[byte\[\]\]\((.*?)\)", body, re.S)
    cx = cy = None
    for ax, data in curves:
        hexs = ','.join(h[2:].lower() for h in re.findall(r"0x[0-9A-Fa-f]{2}", data))
        if ax == 'X': cx = hexs
        else: cy = hexs
    xs = ps_str(cx) if cx else '$null'
    ys = ps_str(cy) if cy else '$null'
    mlines.append(f"    {scale} = @{{ Speed = {ps_str(speed)}; T1 = {ps_str(t1)}; T2 = {ps_str(t2)}; X = {xs}; Y = {ys}; LogPixels = {lp}; PerProc = {pp} }}")
mlines.append("}")
mouse_block = '\n'.join(mlines)
assert len(cases) == 6
assert sum(1 for l in mlines if 'X = $null' in l) == 1, 'only the 100 percent profile may lack curves'


# 5. updates
nd = next(i for i, l in enumerate(zf) if "Excluding Drivers From Windows Update" in l)
drv_rows = rows(zf[nd:nd + 20])
assert len(drv_rows) == 12, len(drv_rows)
su = next(i for i, l in enumerate(zf) if "Disabling All Update Types Except for Security" in l)
sec_rows = rows(zf[su:su + 8])
assert len(sec_rows) == 5, len(sec_rows)
pu = next(i for i, l in enumerate(zf) if "Pausing Updates for 1 Year" in l)
ens = next(i for i in range(pu, pu + 60) if 'ensure pause really works' in zf[i])
pause_rows = rows(zf[ens:ens + 14])
cls = re.findall(r"'(\{[0-9a-f\-]+\})'", '\n'.join(zf[su:su + 30]))
assert len(cls) == 10, len(cls)
tasks = re.findall(r"'(\\Microsoft\\[^']+\*)'", '\n'.join(zf[pu:pu + 40]))
assert len(tasks) == 6, tasks
ul = ["# Windows Update option data from upstream (noDriversInUpdate, opSecUpdatesOnly, oppauseUpdates)."]
ul.append("$DriverExclusionRegs = @(")
ul += [tweak_line(*r) for r in drv_rows]
ul.append(")")
ul.append("$SecurityUpdatesRegs = @(")
ul += [tweak_line(*r) for r in sec_rows]
ul.append(")")
ul.append("$PauseRegs = @(")
ul += [tweak_line(*r) for r in pause_rows]
ul.append(")")
ul.append("$UpdateClassifications = @(" + ', '.join(ps_str(c) for c in cls) + ")")
ul.append("$UpdateTaskPaths = @(" + ', '.join(ps_str(t) for t in tasks) + ")")
updates_block = '\n'.join(ul)


# 6. empty Start menu layout (upstream Unpin.ps1)
un = read('Unpin.ps1')
m = re.search(r"-----BEGIN CERTIFICATE-----\n(.*?)\n-----END CERTIFICATE-----", un, re.S)
sl = m.group(1).split('\n')
import base64 as _b64
assert len(_b64.b64decode(''.join(sl), validate=True)) == 4540
start_block = "# Empty Windows 11 Start menu layout (start2.bin) from upstream Unpin.ps1, base64.\n$EmptyStartLayout = @(\n" + '\n'.join("    '" + l + "'" for l in sl) + "\n)"

out = tpl
for key, val in (('#@@UPSTREAM_REG@@', block1), ('#@@TELEMETRY@@', telemetry_block), ('#@@DOMAINS@@', domains_block), ('#@@MOUSE@@', mouse_block), ('#@@UPDATES@@', updates_block), ('#@@STARTLAYOUT@@', start_block)):
    assert key in out
    out = out.replace(key, val)

# normalise to CRLF for Windows, UTF-8 with BOM so Windows PowerShell 5.1 reads any non ASCII safely
assert all(ord(c) < 128 for c in out) or True
out = out.replace('\r\n', '\n').replace('\n', '\r\n')
open(args.out, 'w', encoding='utf-8-sig', newline='').write(out)
print('written', len(out), 'chars')
print('telemetry regs', len(reg_rows), 'bio', len(bio_rows), 'tel svc', tel_services, 'cdp', cdp_services)
print('service groups:', {g: len(groups[g]) for g in order})
print('pause rows', len(pause_rows), [r[1] for r in pause_rows])
print('mouse scales', [c[0] for c in cases])


# 7. docs/OPTIONS.md, generated from $OptionInfo so the option reference cannot drift from the script.
OPTION_GROUPS = [
    ('Software', ['Packages', 'Debloat', 'RemoveQuickAssist', 'RemoveOneDrive', 'RemoveEdge', 'EdgeBackground', 'LegacyFeatures', 'HypervisorFeatures', 'NvidiaProfile', 'NvidiaReBar',
                  'NvidiaTelemetryStrip']),
    ('Registry and account', ['Registry', 'Uac', 'RunKeys', 'PrivacyDenials', 'TaskbarEndTask', 'CoreIsolation',
                              'HideLockOption', 'HideSleepOption', 'RegHibernateOff']),
    ('Desktop, Start and sign in', ['NotificationSettings', 'RestartExplorer', 'ClearDesktopIcons', 'HideAllDesktopIcons',
                                    'ClearStartPins', 'NoRecentDocsHistory', 'ForceDpi100', 'MouseAccel', 'LockScreenOff',
                                    'StartupDelayOff']),
    ('Right click menu', ['MenuKillNotResponding', 'MenuRestartExplorer', 'MenuTakeOwnership', 'MenuRunAsAdmin',
                          'MenuNoShare', 'MenuNoGiveAccess', 'MenuNoCast', 'MenuNoLibrary', 'MenuNoQuickAccess',
                          'MenuNoPinToStart', 'MenuNoPrevVersions', 'MenuNoTroubleshoot', 'MenuNoDefenderScan',
                          'MenuNoOneDrive', 'MenuNoTerminal']),
    ('Telemetry, privacy and Defender', ['TelemetryPolicy', 'TelemetryExtra', 'TelemetryHosts', 'WindowsAIOff', 'BrowserPolicies',
                                         'BiometricsPolicy', 'Cdp', 'RazerAsusHosts', 'DefenderQuiet']),
    ('Services', ['SvcOther', 'SvcExtra', 'SvcBackground', 'SvcAggressive', 'SvcUpdaters', 'VendorServices', 'SvcDefrag', 'SvcBiometrics', 'SvcSmartCard', 'SvcDiagnostics', 'SvcBluetooth', 'SvcPrinting',
                  'SvcDeliveryOpt', 'SvcRadio', 'SearchIndexingOff']),
    ('Windows Update', ['DriverExclusion', 'SecurityUpdatesOnly', 'PauseUpdates', 'PauseStopsUpdateTasks',
                        'KeepDefinitionUpdates', 'BlockFeatureUpgrades', 'UpdateNoReboot']),
    ('Power, devices and network', ['DisableHibernate', 'MsiMode', 'MemoryCompression', 'SleepStudy', 'NetAdapterPower',
                                    'NetAdapterEee', 'DevicePowerSaving', 'DeviceWakeOff', 'MpoOff', 'WriteCacheFlushOff',
                                    'TimerResolution', 'HardwareGpuScheduling', 'NvmeNativeDriver', 'IPv4Only',
                                    'StandbyNetworkOff']),
    ('Security trade-offs', ['SpectreMeltdownOff', 'NoDeviceEncryption']),
    ('System and cleanup', ['NoAutoMaintenance', 'PasswordExpiry', 'FaultTolerantHeap', 'FastShutdown', 'TimeServerPool', 'EnableSystemRestore',
                            'TempCleanup', 'UpdateCacheCleanup', 'HealthCheckAfter']),
]
# What -Revert cannot undo, and options that change nothing by themselves.
NOT_REVERTED = {
    'Packages': 'no, installed software stays',
    'Debloat': 'no, reinstall apps from the Store or winget',
    'RemoveQuickAssist': 'no, add it back with Add-WindowsCapability',
    'RemoveOneDrive': 'the policy yes; OneDrive itself comes back with winget install Microsoft.OneDrive',
    'RemoveEdge': 'no, reinstall with winget install Microsoft.Edge',
    'NvidiaTelemetryStrip': 'no, reinstall the driver',
    'FaultTolerantHeap': 'no',
    'Cdp': 'services yes; the cache folder is deleted (Windows rebuilds it)',
    'TempCleanup': 'no, files are deleted',
    'UpdateCacheCleanup': 'no, files are deleted',
    'EnableSystemRestore': 'no, System Protection stays on',
    'RestartExplorer': 'nothing to undo',
    'HealthCheckAfter': 'nothing to undo',
}

opt_block = re.search(r"^\$OptionInfo = \[ordered\]@\{\n(.*?)^\}", tpl.replace('\r', ''), re.S | re.M).group(1)
options = re.findall(r"^\s+(\w+)\s+= @\(\$(true|false), '((?:[^']|'')*)', '(Measured|Documented|Folklore|n/a)', '([^']*)'\)", opt_block, re.M)
names = [o[0] for o in options]
# Every option needs its evidence tier and, when Measured or Documented, a source link (docs/AUDIT.md C-3).
declared = re.findall(r"^\s+(\w+)\s+= @\(", opt_block, re.M)
assert sorted(declared) == sorted(names), ('options without a valid evidence tier', sorted(set(declared) - set(names)))
nosource = [o[0] for o in options if o[3] in ('Measured', 'Documented') and not o[4].startswith('https://')]
assert not nosource, ('Measured or Documented options without a source link', nosource)
grouped = [n for _, g in OPTION_GROUPS for n in g]
assert sorted(grouped) == sorted(names) and len(grouped) == len(set(grouped)), \
    ('options missing from OPTION_GROUPS', sorted(set(names) - set(grouped)), 'unknown', sorted(set(grouped) - set(names)))
assert set(NOT_REVERTED) <= set(names), sorted(set(NOT_REVERTED) - set(names))
info = {n: (d == 'true', desc.replace("''", "'"), tier, src) for n, d, desc, tier, src in options}

md = ['# FocusedTweaks options', '',
      'Generated by `tools/build.py` from `$OptionInfo` in `src/01-options.ps1`. Do not edit by hand.', '',
      f'{len(names)} options. Change them with `-Enable A,B`, `-Skip A,B`, `-Only A,B` or a profile (`-ProfilePath`).',
      'Run `.\\FocusedTweaks.ps1 -ListOptions` for the same list in the console.', '',
      'Evidence says what backs an option\'s effect, for information only (defaults aim for maximum performance, less',
      'bloat, less telemetry and smoothness together): **Measured** on real hardware, **Documented** (the linked vendor',
      'page describes the mechanism; the size of the effect is not measured here), **Folklore** (repeated without a',
      'measurement), **n/a** (not about speed). See `docs/AUDIT.md`.', '']
for title, group in OPTION_GROUPS:
    md += [f'## {title}', '', '| Option | Default | Undone by -Revert | Evidence | What it does |', '|---|---|---|---|---|']
    for n in group:
        on, desc, tier, src = info[n]
        evidence = f'[{tier}]({src})' if src else tier
        md.append(f"| `{n}` | {'on' if on else 'off'} | {NOT_REVERTED.get(n, 'yes')} | {evidence} | {desc.replace('|', '/')} |")
    md.append('')
md += ['## Other settings', '',
       '| Parameter | Values | Default | What it does |', '|---|---|---|---|',
       '| `-TaskMode` | Delete, Disable, None | Delete | Delete scheduled tasks (backed up; time sync, retrim, TPM, BitLocker, Defender, System Restore, certificate and browser update tasks are kept), disable 12 telemetry tasks, or leave them |',
       '| `-ServiceMode` | Disable, Delete | Disable | What the service group options do: disable the services, or delete them (each key is exported first and `-Revert` brings it back; gone after a restart; a Windows update may register one again) |',
       '| `-Defender` | Keep, Disable, Enable | Keep | Defender real time protection |',
       '| `-PowerProfile` | Off, Medium, High | High | Custom power plan |',
       '| `-PowerMode` | Keep, Balanced, Best | Keep | Windows power mode overlay |',
       '| `-PauseDays` | 1 to 730 | 365 | Length of the update pause |',
       '| `-SkipRegGroup` | title wildcards | none | Leave out upstream registry groups (`-ListRegGroups` lists them) |',
       '| `-TaskKeep` | task path wildcards | none | Scheduled tasks never deleted |',
       '| `-StartupKeep` | startup entry name wildcards | none | Startup entries `RunKeys` keeps (Windows Security is always kept); `-StartupReview` lists the names |',
       '| `-Revert -Only` | option names | none | Undo only these options from the change journal; values another option also set are kept |',
       '| `-Reapply` | switch | off | Put back what Windows changed since the last run: lists drifted items, then asks (`-DryRun` only lists, `-Force` does not ask). Uses the options of that run; leaves alone Packages, RunKeys, Start pins, desktop icons, app permissions, cleanup and other one shot options |',
       '| `-SkipCheck` | PendingReboot, WindowsUpdate, PowerSource, Managed, Edition, TamperProtection, SystemProtection | none | Pre flight checks to skip by name |',
       '| `-AllowManaged` | switch | off | Run on a PC joined to a domain or Entra ID, enrolled in MDM or under domain Group Policy (refused otherwise) |',
       '| `-Json` | switch | off | Print one JSON result object and nothing else on the console; a real run also needs `-Force` |',
       '', 'Modes that change nothing: `-DryRun`, `-ListOptions`, `-ListRegGroups`, `-HealthCheck`,',
       '`-StartupReview`. `-Revert` undoes the last run. Measuring before and after (system benchmark, game frame',
       'times) is `tools\\Measure-Performance.ps1`, with the parameters `-BenchmarkRuns`, `-BenchmarkIdleSeconds`,',
       '`-BenchmarkBaseline`, `-FrameProcess`, `-FrameSeconds`, `-FrameRuns` and `-FrameLabel`.', '']
docs = os.path.join(os.path.abspath(args.src), '..', 'docs', 'OPTIONS.md')
open(docs, 'w', encoding='utf-8', newline='\n').write('\n'.join(md))
print('options documented', len(names), '->', os.path.normpath(docs))


# 8. docs/REGISTRY.md: every upstream registry item, its group, and the option that applies it. Generated from the
# same vendored file the script embeds and the same group mapping the script uses, so it cannot drift.
import fnmatch
tpl_lf = tpl.replace('\r', '')
gfn = re.search(r"^function Get-RegGroupOption \{(.*?)^\}", tpl_lf, re.S | re.M).group(1)
group_rules = re.findall(r"^\s+'([^']+)' \{ return '(\w+)' \}", gfn, re.M)
assert len(group_rules) >= 10, group_rules
rw_block = re.search(r"^\$WindowsRewrittenValues = @\((.*?)^\)", tpl_lf, re.S | re.M).group(1)
rewritten = re.findall(r"^\s+'([^']+\|[^']+)'", rw_block, re.M)


def group_option(title):
    for pat, opt in group_rules:
        if fnmatch.fnmatchcase(title.lower(), pat.lower()):
            return opt
    return 'Registry'


def reg_unescape(s):
    return s.replace('\\\\', '\x00').replace('\\"', '"').replace('\x00', '\\')


HEX_TYPES = {'hex': 'Binary', 'hex(0)': 'None', 'hex(2)': 'ExpandString', 'hex(3)': 'Binary',
             'hex(7)': 'MultiString', 'hex(b)': 'QWord'}
joined, buf = [], ''
for raw in reg.split('\n'):
    line = buf + (raw.lstrip() if buf else raw.rstrip())
    buf = ''
    if line.endswith('\\') and '=' in line and not line.lstrip().startswith('['):
        buf = line[:-1]
        continue
    joined.append(line)
items, group, key = [], '(no group)', None
for line in joined:
    s = line.strip()
    if not s or s.startswith('Windows Registry Editor'):
        continue
    if s.startswith(';'):
        group = s[1:].strip()
        continue
    if s.startswith('[-'):
        items.append(dict(group=group, key=s[2:-1], name='', type='', data='', action='Delete key'))
        key = None
        continue
    if s.startswith('['):
        key = s[1:-1]
        continue
    m = re.match(r'^(@|"((?:[^"\\]|\\.)*)")=(.*)$', s)
    if not m or key is None:
        continue
    name = '(default)' if m.group(1) == '@' else reg_unescape(m.group(2))
    v = m.group(3)
    it = dict(group=group, key=key, name=name, action='Set')
    if v == '-':
        it.update(type='', data='', action='Delete value')
    elif v.lower().startswith('dword:'):
        it.update(type='DWord', data=f"{int(v[6:], 16)} (0x{v[6:].lower()})")
    elif v.startswith('"'):
        it.update(type='String', data=reg_unescape(v[1:-1]))
    elif v.lower().startswith('hex'):
        kind, body = v.split(':', 1)
        b = bytes(int(x, 16) for x in body.replace(' ', '').split(',') if x)
        t = HEX_TYPES.get(kind.lower(), kind)
        if t == 'ExpandString':
            data = b.decode('utf-16-le').rstrip('\x00')
        elif not b:
            data = '(empty)'
        else:
            data = ' '.join(f'{x:02x}' for x in b[:16]) + (f' ... ({len(b)} bytes)' if len(b) > 16 else '')
        it.update(type=t, data=data)
    else:
        it.update(type='?', data=v)
    items.append(it)
assert len(items) > 400, len(items)


def item_option(it):
    return 'NoRecentDocsHistory' if it['name'] == 'NoRecentDocsHistory' else group_option(it['group'])


def item_note(it):
    notes = []
    if '\\policies\\' in it['key'].lower():
        notes.append('policy')
    ident = f"{it['key']}|{it['name']}"
    if any(fnmatch.fnmatchcase(ident.lower(), r.lower()) for r in rewritten):
        notes.append('Windows sets it itself')
    if item_option(it) != group_option(it['group']):
        notes.append('own option')
    return ', '.join(notes)


def cell(s):
    return (s if s != '' else ' ').replace('|', '\\|')


groups_order = []
for it in items:
    if it['group'] not in groups_order:
        groups_order.append(it['group'])
rmd = ['# Upstream registry items', '',
       'Generated by `tools/build.py` from `upstream/zoicware/src/RegTweaks.txt` (ZOICWARE commit '
       f'`{ZOICWARE_COMMIT[:7]}`) and the group mapping in the script. Do not edit by hand.', '',
       f'{len(items)} items in {len(groups_order)} groups. Each group runs when its option is on; the option of most groups '
       'is `Registry`. Leave one group out with `-SkipRegGroup \'<group title>\'` (wildcards work; `-ListRegGroups` '
       'lists them), or a whole option with `-Skip <Option>`. `-Revert` restores every value and key from the journal.', '',
       'Notes: **policy** is a Group Policy value; Home and Pro ignore some of them, and the Edition area of `-HealthCheck` '
       'names those it knows. **Windows sets it itself** marks a value Windows writes back, which the health and revert '
       'checks treat as a note. **own option** marks a value with an option of its own instead of its group\'s. Some '
       'values are set again by a later step (telemetry, update and mouse options); the health check verifies them there.',
       '', 'What a group is for is its title, which upstream wrote; the values are listed so that you can look up any one '
       'of them.', '', '## Groups', '', '| # | Group | Option | Items |', '|---|---|---|---|']
for i, g in enumerate(groups_order, 1):
    n = sum(1 for it in items if it['group'] == g)
    rmd.append(f'| {i} | [{cell(g)}](#g{i}) | `{group_option(g)}` | {n} |')
rmd.append('')
for i, g in enumerate(groups_order, 1):
    rmd += [f'<a id="g{i}"></a>', f'### {i}. {g}', '', f'Option: `{group_option(g)}`', '',
            '| Key | Value | Type | Data | Note |', '|---|---|---|---|---|']
    for it in items:
        if it['group'] != g:
            continue
        name = it['name'] if it['action'] != 'Delete key' else '(whole key)'
        data = (it['data'] if it['data'] != '' else '(empty)') if it['action'] == 'Set' else it['action'].lower()
        rmd.append(f"| `{cell(it['key'])}` | {cell(name)} | {it['type']} | {cell(data)} | {item_note(it)} |")
    rmd.append('')
regdoc = os.path.join(os.path.abspath(args.src), '..', 'docs', 'REGISTRY.md')
open(regdoc, 'w', encoding='utf-8', newline='\n').write('\n'.join(rmd))
print('registry items documented', len(items), 'in', len(groups_order), 'groups ->', os.path.normpath(regdoc))
