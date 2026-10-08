#!/usr/bin/env python3
"""Localizable.xcstrings'e İngilizce çeviri ekler.

    python3 scripts/add-strings.py 'Türkçe=English' ['%lld dosya=%lld file|%lld files' …]

`a|b` biçimi tekil/çoğul ("one"/"other") verir.
"""
import json, os, sys

path = os.path.join(os.path.dirname(__file__), "../App/Resources/Localizable.xcstrings")
cat = json.load(open(path))
for arg in sys.argv[1:]:
    tr, en = arg.split("=", 1)
    if "|" in en:
        one, other = en.split("|", 1)
        loc = {"variations": {"plural": {"one": {"stringUnit": {"state": "translated", "value": one}},
                                          "other": {"stringUnit": {"state": "translated", "value": other}}}}}
    else:
        loc = {"stringUnit": {"state": "translated", "value": en}}
    cat["strings"][tr] = {"localizations": {"en": loc}}
json.dump(cat, open(path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
