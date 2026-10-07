#!/usr/bin/env python3
"""Sahte analiz motoru (yalnız DEBUG testleri için, ATLAS_ENGINE ile seçilir).

graphify'ın komut satırını taklit eder:
  fake-engine.py extract <kök> --code-only --out <çıktı>
  fake-engine.py cluster-only <çıktı> --no-viz
Kökteki .ts/.swift dosyalarından basit bir graf yazar: her dosya bir düğüm,
dosyada `uses <ad>` geçiyorsa o dosyaya bir bağ.
"""
import json, os, re, sys, time

def extract(root, out):
    files = []
    for d, dirs, names in os.walk(root):
        dirs[:] = [x for x in dirs if not x.startswith('.') and x != 'node_modules']
        for n in names:
            if n.endswith(('.ts', '.swift')):
                files.append(os.path.relpath(os.path.join(d, n), root))
    files.sort()
    total = len(files)
    for i in range(total):
        print(f"  AST extraction: {i+1}/{total} uncached files", flush=True)
    nodes, links = [], []
    ids = {}
    for f in files:
        nid = re.sub(r'[^a-z0-9]+', '_', f.lower())
        ids[os.path.splitext(os.path.basename(f))[0]] = nid
        nodes.append({"id": nid, "label": os.path.basename(f), "file_type": "code", "source_file": f, "source_location": "L1", "community": 0})
    for f in files:
        text = open(os.path.join(root, f), encoding='utf-8', errors='ignore').read()
        src = re.sub(r'[^a-z0-9]+', '_', f.lower())
        for m in re.findall(r'uses (\w+)', text):
            if m in ids:
                links.append({"source": src, "target": ids[m], "relation": "imports_from", "confidence": "EXTRACTED"})
    os.makedirs(os.path.join(out, 'graphify-out'), exist_ok=True)
    with open(os.path.join(out, 'graphify-out', 'graph.json'), 'w') as fh:
        json.dump({"directed": True, "graph": {"schema_version": 1, "graphify_version": "fake"}, "nodes": nodes, "links": links}, fh)

if __name__ == '__main__':
    time.sleep(float(os.environ.get('FAKE_ENGINE_DELAY', '0.3')))
    cmd = sys.argv[1]
    if cmd == 'extract':
        extract(sys.argv[2], sys.argv[sys.argv.index('--out') + 1])
    elif cmd == 'cluster-only':
        pass
    else:
        sys.exit(2)
