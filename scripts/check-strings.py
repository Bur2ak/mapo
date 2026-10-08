#!/usr/bin/env python3
"""Arayüz dizgilerinin İngilizce çevirisi eksik mi? (Derlemeden sonra çalıştır.)

    xcodebuild … build && python3 scripts/check-strings.py [build]

Derleyicinin çıkardığı .stringsdata dosyalarındaki her anahtarın
App/Resources/Localizable.xcstrings içinde `en` karşılığı olmalı. Eksikleri
listeler, varsa 1 ile çıkar.
"""
import glob, json, os, sys

root = os.path.join(os.path.dirname(__file__), "..")
build = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "build/Build")
catalog = json.load(open(os.path.join(root, "App/Resources/Localizable.xcstrings")))["strings"]
keys = {}
for f in glob.glob(os.path.join(build, "**/*.stringsdata"), recursive=True):
    d = json.load(open(f))
    for items in d["tables"].values():
        for it in items:
            keys.setdefault(it["key"], os.path.basename(d["source"]))
missing = sorted(k for k in keys if k and k not in catalog)
for k in missing:
    print(f"çevirisi yok: {k!r}  ({keys[k]})")
print(f"{len(keys)} anahtar, {len(missing)} eksik")
sys.exit(1 if missing else 0)
