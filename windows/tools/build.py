"""Build FocusedTweaks.ps1 from tools/FocusedTweaks.template.ps1 plus data read from a ZOICWARE checkout.

Usage:
    python tools/build.py --zoicware C:\\path\\to\\ZOICWARE-main --out FocusedTweaks.ps1

The template is the source of truth. Do not edit the generated FocusedTweaks.ps1 by hand,
change tools/FocusedTweaks.template.ps1 and build again.
"""
import argparse, os, re, io, sys

ap = argparse.ArgumentParser()
ap.add_argument('--zoicware', required=True, help='folder that contains the ZOICWARE "src" directory (a clone or the unzipped release)')
ap.add_argument('--template', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'FocusedTweaks.template.ps1'))
ap.add_argument('--out', default='FocusedTweaks.ps1')
ap.add_argument('--allow-other-commit', action='store_true', help='build from a ZOICWARE commit other than the pinned one (when updating upstream)')
args = ap.parse_args()
SRC = os.path.join(args.zoicware, 'src')

# The upstream data is checked by list sizes below, but only the exact commit makes a build reproducible.
ZOICWARE_COMMIT = '2363922c51eeff9ce415e51ae4b8161174654082'  # 24 Oct 2026
if os.path.isdir(os.path.join(args.zoicware, '.git')):
    import subprocess
    head = subprocess.run(['git', '-C', args.zoicware, 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
    if head != ZOICWARE_COMMIT and not args.allow_other_commit:
        sys.exit(f'ZOICWARE checkout is at {head}, expected {ZOICWARE_COMMIT}. '
                 'Check out the pinned commit, or pass --allow-other-commit when updating upstream.')
else:
    print(f'warning: {args.zoicware} is not a git checkout, so the pinned commit {ZOICWARE_COMMIT[:7]} cannot be verified')

def read(name):
    with open(os.path.join(SRC, name), encoding='utf-8') as f:
        return f.read().replace('\r', '')

zf = read('zFunctions.psm1').split('\n')
reg = read('RegTweaks.txt')
tpl = open(args.template, encoding='utf-8').read()

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
order = ['SvcOther', 'SvcExtra', 'SvcDefrag', 'SvcBiometrics', 'SvcSmartCard', 'SvcDiagnostics', 'SvcBluetooth', 'SvcPrinting', 'SvcDeliveryOpt', 'SvcRadio']

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
    ('Software', ['Packages', 'Debloat', 'RemoveQuickAssist', 'LegacyFeatures', 'HypervisorFeatures', 'NvidiaTelemetryStrip']),
    ('Registry and account', ['Registry', 'Uac', 'RunKeys', 'PrivacyDenials', 'TaskbarEndTask', 'CoreIsolation',
                              'HideLockOption', 'HideSleepOption', 'RegHibernateOff']),
    ('Desktop, Start and sign in', ['NotificationSettings', 'RestartExplorer', 'ClearDesktopIcons', 'HideAllDesktopIcons',
                                    'ClearStartPins', 'NoRecentDocsHistory', 'ForceDpi100', 'MouseAccel', 'LockScreenOff']),
    ('Right click menu', ['MenuKillNotResponding', 'MenuRestartExplorer', 'MenuTakeOwnership', 'MenuRunAsAdmin',
                          'MenuNoShare', 'MenuNoGiveAccess', 'MenuNoCast', 'MenuNoLibrary', 'MenuNoQuickAccess',
                          'MenuNoPinToStart', 'MenuNoPrevVersions', 'MenuNoTroubleshoot', 'MenuNoDefenderScan',
                          'MenuNoOneDrive', 'MenuNoTerminal']),
    ('Telemetry, privacy and Defender', ['TelemetryPolicy', 'TelemetryHosts', 'BiometricsPolicy', 'Cdp', 'RazerAsusHosts',
                                         'DefenderQuiet']),
    ('Services', ['SvcOther', 'SvcExtra', 'SvcDefrag', 'SvcBiometrics', 'SvcSmartCard', 'SvcDiagnostics', 'SvcBluetooth', 'SvcPrinting',
                  'SvcDeliveryOpt', 'SvcRadio', 'SearchIndexingOff']),
    ('Windows Update', ['DriverExclusion', 'SecurityUpdatesOnly', 'PauseUpdates', 'PauseStopsUpdateTasks',
                        'KeepDefinitionUpdates', 'BlockFeatureUpgrades']),
    ('Power, devices and network', ['DisableHibernate', 'MsiMode', 'MemoryCompression', 'SleepStudy', 'NetAdapterPower',
                                    'NetAdapterEee', 'DevicePowerSaving', 'DeviceWakeOff', 'MpoOff', 'WriteCacheFlushOff',
                                    'TimerResolution', 'NvmeNativeDriver', 'IPv4Only']),
    ('Security trade-offs', ['SpectreMeltdownOff', 'DepOff']),
    ('System and cleanup', ['NoAutoMaintenance', 'PasswordExpiry', 'FaultTolerantHeap', 'FastShutdown', 'TimeServerPool', 'EnableSystemRestore',
                            'TempCleanup', 'UpdateCacheCleanup', 'HealthCheckAfter']),
]
# What -Revert cannot undo, and options that change nothing by themselves.
NOT_REVERTED = {
    'Packages': 'no, installed software stays',
    'Debloat': 'no, reinstall apps from the Store or winget',
    'RemoveQuickAssist': 'no, add it back with Add-WindowsCapability',
    'NvidiaTelemetryStrip': 'no, reinstall the driver',
    'FaultTolerantHeap': 'no',
    'TempCleanup': 'no, files are deleted',
    'UpdateCacheCleanup': 'no, files are deleted',
    'EnableSystemRestore': 'no, System Protection stays on',
    'RestartExplorer': 'nothing to undo',
    'HealthCheckAfter': 'nothing to undo',
}

opt_block = re.search(r"^\$OptionInfo = \[ordered\]@\{\n(.*?)^\}", tpl.replace('\r', ''), re.S | re.M).group(1)
options = re.findall(r"^\s+(\w+)\s+= @\(\$(true|false), '((?:[^']|'')*)'\)", opt_block, re.M)
names = [o[0] for o in options]
grouped = [n for _, g in OPTION_GROUPS for n in g]
assert sorted(grouped) == sorted(names) and len(grouped) == len(set(grouped)), \
    ('options missing from OPTION_GROUPS', sorted(set(names) - set(grouped)), 'unknown', sorted(set(grouped) - set(names)))
assert set(NOT_REVERTED) <= set(names), sorted(set(NOT_REVERTED) - set(names))
info = {n: (d == 'true', desc.replace("''", "'")) for n, d, desc in options}

md = ['# FocusedTweaks options', '',
      'Generated by `tools/build.py` from `$OptionInfo` in the template. Do not edit by hand.', '',
      f'{len(names)} options. Change them with `-Enable A,B`, `-Skip A,B`, `-Only A,B` or a profile (`-ProfilePath`).',
      'Run `.\\FocusedTweaks.ps1 -ListOptions` for the same list in the console.', '']
for title, group in OPTION_GROUPS:
    md += [f'## {title}', '', '| Option | Default | Undone by -Revert | What it does |', '|---|---|---|---|']
    for n in group:
        on, desc = info[n]
        md.append(f"| `{n}` | {'on' if on else 'off'} | {NOT_REVERTED.get(n, 'yes')} | {desc.replace('|', '/')} |")
    md.append('')
md += ['## Other settings', '',
       '| Parameter | Values | Default | What it does |', '|---|---|---|---|',
       '| `-TaskMode` | Delete, Disable, None | Delete | Delete all scheduled tasks (backed up), disable 12 telemetry tasks, or leave them |',
       '| `-Defender` | Keep, Disable, Enable | Keep | Defender real time protection |',
       '| `-PowerProfile` | Off, Medium, High | High | Custom power plan |',
       '| `-PowerMode` | Keep, Balanced, Best | Keep | Windows power mode overlay |',
       '| `-PauseDays` | 1 to 730 | 365 | Length of the update pause |',
       '| `-SkipRegGroup` | title wildcards | none | Leave out upstream registry groups (`-ListRegGroups` lists them) |',
       '| `-TaskKeep` | task path wildcards | none | Scheduled tasks never deleted |',
       '', 'Modes that change nothing: `-DryRun`, `-ListOptions`, `-ListRegGroups`, `-HealthCheck`, `-Benchmark`,',
       '`-StartupReview`. `-Revert` undoes the last run.', '']
docs = os.path.join(os.path.dirname(os.path.abspath(args.template)), '..', 'docs', 'OPTIONS.md')
open(docs, 'w', encoding='utf-8', newline='\n').write('\n'.join(md))
print('options documented', len(names), '->', os.path.normpath(docs))
