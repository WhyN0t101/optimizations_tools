"""Compare FocusedTweaks with other Windows tweak projects and write docs/COVERAGE.md.

Usage (in windows/, after a build):
    python tools/coverage.py            # compare with the pinned commits in tools/references.json
    python tools/coverage.py --update   # move the pins to each repository's newest commit first

The projects are references, not sources: nothing they contain is copied into FocusedTweaks. Their data is
downloaded once per pinned commit into .cache/references/ (not committed). For each registry value, service, Store
app and scheduled task the others change, the report says whether FocusedTweaks changes it too, keeps it on purpose,
or does not touch it, sorted so items several projects agree on come first. Decide per item whether it becomes an
option; privacy.sexy is AGPL-3.0, so its scripts are a cross-check only and are never copied.

Limits: values the script writes through variables rather than literal paths are not seen, so check an item in
src/ before adding it. Tasks are compared with the never-delete list only, since TaskMode Delete removes every other
task. Sophia's functions switch settings both ways, so its rows mean "Sophia has a switch for this".
"""
import argparse, fnmatch, io, json, os, re, sys, tarfile, urllib.request
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
REFS = os.path.join(HERE, 'references.json')
CACHE = os.path.join(ROOT, '.cache', 'references')
SCRIPT = os.path.join(ROOT, 'FocusedTweaks.ps1')
OUT = os.path.join(ROOT, 'docs', 'COVERAGE.md')
UA = {'User-Agent': 'FocusedTweaks-coverage'}


# --- Download --------------------------------------------------------------------------------------------------
def wanted(path, patterns):
    for p in patterns:
        if '*' in p:
            if os.path.dirname(path) == os.path.dirname(p) and fnmatch.fnmatch(os.path.basename(path), os.path.basename(p)):
                return True
        elif path == p:
            return True
    return False


def fetch(ref):
    """Extract the listed files of the pinned commit into the cache; return that folder."""
    folder = os.path.join(CACHE, f"{ref['id']}-{ref['commit'][:12]}")
    if os.path.isfile(os.path.join(folder, '.complete')):
        return folder
    url = f"https://codeload.github.com/{ref['repo']}/tar.gz/{ref['commit']}"
    print(f"download {ref['repo']} {ref['commit'][:7]}")
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r:
        data = r.read()
    count = 0
    # Read from memory: some repositories hold paths that differ only by case, which a Windows checkout breaks on.
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tar:
        for m in tar.getmembers():
            if not m.isfile():
                continue
            rel = m.name.split('/', 1)[1] if '/' in m.name else ''
            if not rel or '..' in rel.split('/') or rel.startswith('/') or not wanted(rel, ref['files']):
                continue
            dest = os.path.join(folder, *rel.split('/'))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, 'wb') as f:
                f.write(tar.extractfile(m).read())
            count += 1
    if count == 0:
        sys.exit(f"none of {ref['files']} found in {ref['repo']} at {ref['commit']}")
    open(os.path.join(folder, '.complete'), 'w').close()
    return folder


def update_pins(cfg):
    for ref in cfg['repos']:
        url = f"https://api.github.com/repos/{ref['repo']}/commits/HEAD"
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
            sha = json.load(r)['sha']
        if sha != ref['commit']:
            print(f"{ref['repo']}: {ref['commit'][:7]} -> {sha[:7]}")
            ref['commit'] = sha
    with open(REFS, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')


# --- Normalising -----------------------------------------------------------------------------------------------
HIVES = [('HKEY_LOCAL_MACHINE', 'HKLM'), ('HKEY_CURRENT_USER', 'HKCU'), ('HKEY_CLASSES_ROOT', 'HKCR'),
         ('HKEY_USERS', 'HKU')]


def reg_path(p):
    p = p.strip().strip('"\'').replace('/', '\\')
    p = re.sub(r'^Registry::', '', p, flags=re.I)
    for long, short in HIVES:
        if p.upper().startswith(long):
            p = short + p[len(long):]
    p = re.sub(r'^(HKLM|HKCU|HKCR|HKU):', r'\1', p, flags=re.I)
    p = re.sub(r'\\+', r'\\', p).rstrip('\\')
    return p


def reg_key(path, name):
    return (reg_path(path).lower() + '|' + name.strip().lower())


class Items:
    """Everything one project changes: kind -> key -> {'show', 'data', 'labels'}."""

    def __init__(self):
        self.by = defaultdict(dict)

    def add(self, kind, key, show, data, label):
        e = self.by[kind].setdefault(key, {'show': show, 'data': set(), 'labels': []})
        if data not in (None, ''):
            e['data'].add(str(data))
        if label and label not in e['labels']:
            e['labels'].append(label)

    def reg(self, path, name, data, label):
        if not path or name is None or '{{' in path or '{{' in name:
            return
        self.add('reg', reg_key(path, name), f"{reg_path(path)} ! {name or '(default)'}", data, label)


# --- Parsers, one per project -----------------------------------------------------------------------------------
def parse_winutil(folder):
    it = Items()
    tweaks = json.load(open(os.path.join(folder, 'config', 'tweaks.json'), encoding='utf-8'), strict=False)
    for t in tweaks.values():
        label = t.get('Content', '')
        for r in t.get('registry', []) or []:
            it.reg(r.get('Path', ''), r.get('Name', ''), r.get('Value'), label)
        for s in t.get('service', []) or []:
            if s.get('StartupType') in ('Disabled', 'Manual') and s.get('StartupType') != s.get('OriginalType'):
                it.add('service', s['Name'].lower(), s['Name'], s['StartupType'], label)
    appx = json.load(open(os.path.join(folder, 'config', 'appx.json'), encoding='utf-8'), strict=False)
    for a in appx.values():
        if a.get('PackageId'):
            it.add('app', a['PackageId'].lower(), a['PackageId'], 'remove', a.get('Content', ''))
    return it


def parse_reg_file(text, label, it):
    path = None
    for line in text.replace('\r', '').split('\n'):
        s = line.strip()
        if s.startswith('['):
            path = s.strip('[]')
            if path.startswith('-'):
                it.add('regkey', reg_path(path[1:]).lower(), reg_path(path[1:]), 'delete key', label)
                path = None
            continue
        m = re.match(r'^("(?:[^"\\]|\\.)*"|@)=(.*)$', s)
        if path and m:
            name = '' if m.group(1) == '@' else m.group(1)[1:-1]
            it.reg(path, name, 'delete' if m.group(2) == '-' else m.group(2), label)


def parse_win11debloat(folder):
    it = Items()
    feats = json.load(open(os.path.join(folder, 'Config', 'Features.json'), encoding='utf-8-sig'))['Features']
    for f in feats:
        name = f.get('RegistryKey')
        path = os.path.join(folder, 'Regfiles', name) if name else None
        if not path or not os.path.isfile(path):
            continue
        raw = open(path, 'rb').read()
        text = raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8-sig')
        parse_reg_file(text, f['FeatureId'], it)
    apps = json.load(open(os.path.join(folder, 'Config', 'Apps.json'), encoding='utf-8-sig'))['Apps']
    for a in apps:
        ids = a['AppId'] if isinstance(a['AppId'], list) else [a['AppId']]   # one entry can name several packages
        for app_id in ids:
            it.add('app', app_id.lower(), app_id, 'remove',
                   'selected by default' if a.get('SelectedByDefault') else 'optional')
    return it


SOPHIA_REG = re.compile(r'(?:New|Set)-ItemProperty\s+-Path\s+("[^"]+"|\S+)\s+-Name\s+("[^"]+"|[^\s,]+)'
                        r'(?:.*?-Value\s+("[^"]*"|\S+))?', re.I)
SOPHIA_SVC = re.compile(r'Get-Service\s+-Name\s+([\w$.-]+(?:\s*,\s*[\w.-]+)*).*?Set-Service\s+-StartupType\s+(\w+)', re.I)


def parse_sophia(folder):
    it = Items()
    path = os.path.join(folder, 'src', 'Sophia_Script_for_Windows_11', 'Module', 'Sophia.psm1')
    fn = ''
    for line in open(path, encoding='utf-8-sig').read().split('\n'):
        m = re.match(r'^function\s+([\w-]+)', line)
        if m:
            fn = m.group(1)
        for m in SOPHIA_REG.finditer(line):
            if '$' in m.group(1) or '$' in m.group(2):
                continue
            it.reg(m.group(1), m.group(2).strip('"'), (m.group(3) or '').strip('"'), fn)
        m = SOPHIA_SVC.search(line)
        if m and m.group(2) in ('Disabled', 'Manual'):
            for n in re.split(r'\s*,\s*', m.group(1)):
                if '$' not in n:
                    it.add('service', n.lower(), n, m.group(2), fn)
    return it


def yaml_value(v):
    out, quote = '', None
    for i, ch in enumerate(v):
        if quote:
            if ch == quote:
                quote = None
        elif ch in '\'"':
            quote = ch
        elif ch == '#' and (i == 0 or v[i - 1] == ' '):
            break
        out += ch
    return out.strip().strip('\'"')


def parse_privacysexy(folder):
    """A line reader for the few fields used; the file is too large and too regular to need a YAML library."""
    it = Items()
    text = open(os.path.join(folder, 'src', 'application', 'collections', 'windows.yaml'), encoding='utf-8').read()
    name, level, fn, params = '', '', None, {}

    def flush():
        if not fn:
            return
        label = name + (f' ({level})' if level else ' (not recommended by default)')
        p = params
        if fn == 'SetRegistryValue':
            it.reg(p.get('keyPath', ''), p.get('valueName', ''), p.get('data'), label)
        elif fn in ('DisableService', 'DisableServiceInRegistry') and p.get('serviceName'):
            it.add('service', p['serviceName'].lower(), p['serviceName'], 'Disabled', label)
        elif fn == 'DisableScheduledTask' and p.get('taskNamePattern'):
            full = p.get('taskPathPattern', '\\') + p['taskNamePattern']
            it.add('task', full.lower(), full, 'disable', label)
        elif fn in ('UninstallStoreApp', 'UninstallNonRemovableStoreAppWithCleanup') and p.get('packageName'):
            it.add('app', p['packageName'].lower(), p['packageName'], 'remove', label)

    for line in text.split('\n'):
        s = line.strip().lstrip('- ').strip()
        if s.startswith('name:'):
            flush(); fn = None
            name, level = yaml_value(s[5:]), ''
        elif s.startswith('recommend:'):
            level = yaml_value(s[10:])
        elif s.startswith('function:'):
            flush()
            fn, params = yaml_value(s[9:]), {}
        elif s == '' or line.strip() == '-':
            continue
        elif fn:
            m = re.match(r'^(\w+):\s*(.*)$', s)
            if m and m.group(1) not in ('parameters', 'call'):
                params[m.group(1)] = yaml_value(m.group(2))
    flush()
    return it


PARSERS = {'winutil': parse_winutil, 'win11debloat': parse_win11debloat, 'sophia': parse_sophia,
           'privacysexy': parse_privacysexy}


# --- What FocusedTweaks does --------------------------------------------------------------------------------------
def ps_array(lines, var):
    """The quoted strings of a top level '$Var = @(' array or '$Var = [ordered]@{' table in the built script."""
    out = []
    for i, line in enumerate(lines):
        if re.match(rf'^\${var} = (@\(|\[ordered\]@\{{|@\{{)', line):
            close = ')' if '@(' in line.split('=', 1)[1] else '}'
            body = [line.split('=', 1)[1]]
            if not line.rstrip().endswith((')', '}')) or line.rstrip().endswith(('@(', '@{', '{')):
                for nxt in lines[i + 1:]:
                    if nxt.strip() == close:
                        break
                    body.append(nxt)
            for b in body:
                b = b.split(' #', 1)[0] if not b.lstrip().startswith('#') else ''
                out += [s.replace("''", "'") for s in re.findall(r"'((?:[^']|'')*)'", b)]
            return out
    raise SystemExit(f'${var} not found in FocusedTweaks.ps1: rebuild, or update tools/coverage.py')


def ours():
    text = open(SCRIPT, encoding='utf-8-sig').read().replace('\r', '')
    lines = text.split('\n')
    reg = set()
    for p, n in re.findall(r"New-Tweak '([^']+)' '([^']*)'", text):
        reg.add(reg_key(p, n))
    for p, n in re.findall(r"-Path '([^']+)' -Name '([^']*)'", text):
        reg.add(reg_key(p, n))
    path = None
    for line in lines:
        s = line.strip()
        m = re.match(r'^\[-?(HKEY_[^\]]+)\]$', s)
        if m:
            path = m.group(1)
            continue
        # The upstream .reg text sits in the script as data: a value line follows its [key] line.
        m = re.match(r'^"((?:[^"\\]|\\.)*)"=', s)
        if path and m:
            reg.add(reg_key(path, m.group(1)))
        elif s and not s.startswith((';', '@=', '"')):
            path = None
    services = set()
    for line in lines[next(i for i, l in enumerate(lines) if l.startswith('$ServiceGroups = ')):]:
        if line.strip() == '}':
            break
        services.update(s.lower() for s in re.findall(r"'([^']+)'", line))
    for var in ('TelemetryServices', 'CdpServices', 'VendorServicesDisable', 'VendorServicesManual'):
        services.update(s.lower() for s in ps_array(lines, var))
    services.update(s.lower() for s in re.findall(r"Set-ServiceStart (?:-Name )?'([\w.-]+)'", text))
    return {'reg': reg, 'service': services, 'remove': ps_array(lines, 'AppsToRemove'),
            'keep': ps_array(lines, 'KeepApps'), 'taskkeep': ps_array(lines, 'TaskKeepBuiltIn')}


def matches(name, patterns):
    return any(fnmatch.fnmatch(name.lower(), p.lower()) for p in patterns)


def status(kind, key, show, mine):
    if kind == 'reg':
        return 'yes' if key in mine['reg'] else 'no'
    if kind == 'service':
        return 'yes' if key in mine['service'] else 'no'
    if kind == 'app':
        if matches(show, mine['keep']):
            return 'kept'
        return 'yes' if matches(show, mine['remove']) else 'no'
    if kind == 'task':
        return 'kept' if matches(show, mine['taskkeep']) else 'yes'
    return 'no'


# --- Report -----------------------------------------------------------------------------------------------------
def cell(s, limit=90):
    s = ' '.join(str(s).split()).replace('|', '\\|')
    return s if len(s) <= limit else s[:limit - 3] + '...'


def report(cfg, results, mine):
    ids = [r['id'] for r in cfg['repos']]
    merged = defaultdict(dict)   # kind -> key -> {'show', 'by': {id: entry}}
    for rid, items in results.items():
        for kind, entries in items.by.items():
            for key, e in entries.items():
                m = merged[kind].setdefault(key, {'show': e['show'], 'by': {}})
                m['by'][rid] = e
    md = ['# Coverage compared with other projects', '',
          'Generated by `python tools/coverage.py` from the pinned commits in `tools/references.json`. Do not edit.',
          'These projects are references, not sources: an item listed here is a lead to check, not something to copy.',
          'privacy.sexy is AGPL-3.0: a cross-check only, never copy its scripts. Values the script writes through',
          'variables are not seen, so check `src/` before adding an item. Sophia rows mean Sophia has a switch for it.',
          '', '| Project | Commit | Licence |', '|---|---|---|']
    for r in cfg['repos']:
        md.append(f"| [{r['repo']}](https://github.com/{r['repo']}/tree/{r['commit']}) | `{r['commit'][:7]}` | {r['license']} |")
    names = {'reg': 'Registry values', 'service': 'Services', 'app': 'Store apps', 'task': 'Scheduled tasks',
             'regkey': 'Registry keys deleted'}
    md += ['', '## Summary', '', 'How many of each project\'s items FocusedTweaks also changes (kept: left alone on purpose).', '',
           '| Project | ' + ' | '.join(names[k] for k in ('reg', 'service', 'app')) + ' |', '|---|---|---|---|']
    for rid in ids:
        row = []
        for kind in ('reg', 'service', 'app'):
            entries = results[rid].by.get(kind, {})
            st = [status(kind, k, e['show'], mine) for k, e in entries.items()]
            row.append(f"{st.count('yes')} of {len(st)}" + (f" ({st.count('kept')} kept)" if st.count('kept') else ''))
        md.append(f'| {rid} | ' + ' | '.join(row) + ' |')
    for kind in ('reg', 'service', 'app'):
        rows = []
        for key, m in merged[kind].items():
            if status(kind, key, m['show'], mine) != 'no':
                continue
            data = sorted({d for e in m['by'].values() for d in e['data']})
            why = '; '.join(f"{rid}: {', '.join(e['labels'][:2])}" for rid, e in m['by'].items())
            rows.append((-len(m['by']), m['show'].lower(), m['show'], ', '.join(r for r in ids if r in m['by']), data, why))
        rows.sort()
        md += ['', f'## {names[kind]} the others change and FocusedTweaks does not ({len(rows)})', '']
        head = ['| Projects | Item | Their value | What for |', '|---|---|---|---|']
        many = [r for r in rows if -r[0] > 1]
        one = [r for r in rows if -r[0] == 1]
        fmt = lambda r: f"| {r[3]} | `{cell(r[2], 120)}` | {cell(', '.join(r[4]), 40)} | {cell(r[5])} |"
        md += [f'Changed by two or more projects ({len(many)}):', ''] + head + [fmt(r) for r in many]
        md += ['', f'<details><summary>Changed by one project ({len(one)})</summary>', ''] + head + [fmt(r) for r in one]
        md += ['', '</details>']
    kept = []
    for kind in ('app', 'task'):
        for key, m in merged[kind].items():
            if status(kind, key, m['show'], mine) == 'kept':
                kept.append((names[kind], m['show'], ', '.join(r for r in ids if r in m['by'])))
    md += ['', '## Kept on purpose by FocusedTweaks, changed by others', '',
           'FocusedTweaks keeps these (`$KeepApps`, `$TaskKeepBuiltIn`); the reasons are in `src/02-data.ps1`.', '',
           '| Kind | Item | Projects |', '|---|---|---|'] + [f'| {k} | `{cell(s, 120)}` | {p} |' for k, s, p in sorted(kept)]
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(md) + '\n')
    print(f'coverage -> {OUT}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--update', action='store_true', help='move the pins to the newest commits first')
    args = ap.parse_args()
    cfg = json.load(open(REFS, encoding='utf-8'))
    if args.update:
        update_pins(cfg)
    if not os.path.isfile(SCRIPT):
        sys.exit('Build first: python tools/build.py --out FocusedTweaks.ps1')
    mine = ours()
    results = {}
    for ref in cfg['repos']:
        results[ref['id']] = PARSERS[ref['id']](fetch(ref))
        counts = {k: len(v) for k, v in results[ref['id']].by.items()}
        print(f"{ref['id']}: {counts}")
    report(cfg, results, mine)


if __name__ == '__main__':
    main()
