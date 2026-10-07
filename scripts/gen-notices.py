#!/usr/bin/env python3
"""Üçüncü taraf lisans bildirimlerini üretir: App/Resources/ThirdPartyNotices.txt

    python3 scripts/gen-notices.py

Kaynaklar: gömülü motordaki Python paketleri (dist-info), Python'un kendisi,
haritanın npm bağımlılıkları (yalnız üretim), Sparkle. Her paketin lisans metni
kendi dağıtımından okunur; bulunamazsa betik hata verir (eksik bildirimle
yayın yapılmaz).
"""
import glob, json, os, re, sys

ROOT = os.path.join(os.path.dirname(__file__), '..')
OUT = os.path.join(ROOT, 'App/Resources/ThirdPartyNotices.txt')
entries = []
missing = []

def read(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        return f.read().strip()

def add(name, version, license_name, text, url=''):
    entries.append((name.lower(), name, version, license_name, text, url))

# --- Python packages in the embedded engine
sp = glob.glob(os.path.join(ROOT, 'Engine/dist/python/lib/python3.*/site-packages'))
if not sp:
    sys.exit('Gömülü motor yok: önce bash scripts/build-engine.sh')
for info in sorted(glob.glob(os.path.join(sp[0], '*.dist-info'))):
    meta = read(os.path.join(info, 'METADATA'))
    name = re.search(r'^Name: (.+)$', meta, re.M).group(1)
    version = re.search(r'^Version: (.+)$', meta, re.M).group(1)
    lic = (re.search(r'^License-Expression: (.+)$', meta, re.M) or re.search(r'^License: (.{1,80})$', meta, re.M))
    lic = lic.group(1).strip() if lic else ''
    if not lic:
        cls = re.findall(r'^Classifier: License :: (?:OSI Approved :: )?(.+)$', meta, re.M)
        lic = ', '.join(cls)
    url = (re.search(r'^Project-URL: (?:Source|Repository|Homepage|Source Code)[^,]*, (.+)$', meta, re.M | re.I)
           or re.search(r'^Home-page: (.+)$', meta, re.M))
    files = sorted(glob.glob(os.path.join(info, 'licenses', '**', '*'), recursive=True)
                   + glob.glob(os.path.join(info, 'LICEN[CS]E*')) + glob.glob(os.path.join(info, 'COPYING*')))
    files = [f for f in files if os.path.isfile(f)]
    # Some wheels ship without their license file; vendored copy from upstream.
    extra = os.path.join(ROOT, 'scripts/notices-extra', f'{name}.LICENSE')
    if not files and os.path.isfile(extra):
        files = [extra]
    if not files:
        missing.append(name); continue
    text = '\n\n'.join(read(f) for f in files)
    add(name, version, lic or 'see text', text, url.group(1).strip() if url else '')

# --- Python itself
pylic = glob.glob(os.path.join(ROOT, 'Engine/dist/python/lib/python3.*/LICENSE.txt'))
if not pylic:
    missing.append('CPython')
else:
    add('Python', '3.12', 'PSF-2.0', read(pylic[0]), 'https://www.python.org')

# --- Map (npm, production dependencies, transitively)
nm = os.path.join(ROOT, 'Map/node_modules')
pkg = json.load(open(os.path.join(ROOT, 'Map/package.json')))
seen = set()
def walk(name):
    if name in seen: return
    seen.add(name)
    d = os.path.join(nm, name)
    pj = json.load(open(os.path.join(d, 'package.json')))
    files = [f for f in glob.glob(os.path.join(d, '*')) if re.match(r'(?i)licen[cs]e|copying', os.path.basename(f))]
    if files:
        add(name, pj.get('version', ''), str(pj.get('license', '')), read(files[0]),
            (pj.get('repository') or {}).get('url', '') if isinstance(pj.get('repository'), dict) else pj.get('repository', ''))
    else:
        missing.append(name)
    for dep in (pj.get('dependencies') or {}):
        if os.path.isdir(os.path.join(nm, dep)): walk(dep)
for dep in pkg.get('dependencies', {}):
    walk(dep)

# --- Sparkle
sparkle = glob.glob(os.path.join(ROOT, 'build/SourcePackages/checkouts/Sparkle/LICENSE')) \
       or glob.glob(os.path.join(ROOT, 'build/**/SourcePackages/checkouts/Sparkle/LICENSE'), recursive=True)
if sparkle:
    add('Sparkle', '2.10.0', 'MIT', read(sparkle[0]), 'https://sparkle-project.org')
else:
    missing.append('Sparkle')

if missing:
    sys.exit('Lisans metni bulunamadı: ' + ', '.join(missing))

entries.sort()
lines = ['Mapo — Üçüncü taraf yazılımlar / Third-party software', '',
         'Mapo aşağıdaki açık kaynak yazılımları içerir. Teşekkürler.',
         'Mapo includes the following open-source software. Thank you.', '']
lines += [f'  • {n} {v} — {l}' for _, n, v, l, _, _ in entries]
for _, n, v, l, text, url in entries:
    lines += ['', '=' * 72, f'{n} {v}', f'License: {l}'] + ([f'Source: {url}'] if url else []) + ['=' * 72, '', text]
open(OUT, 'w').write('\n'.join(lines) + '\n')
print(f'{len(entries)} bileşen → {OUT}')
