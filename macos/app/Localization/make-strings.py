#!/usr/bin/env python3
# Writes en.lproj/Localizable.strings from en.py, and an empty
# de.lproj/Localizable.strings: German is the language of the source.
#
# usage: make-strings.py OUT_RESOURCES_DIR
import os, runpy, sys

here = os.path.dirname(os.path.abspath(__file__))
T = runpy.run_path(os.path.join(here, "en.py"))["T"]
out = sys.argv[1]


def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


os.makedirs(os.path.join(out, "en.lproj"), exist_ok=True)
os.makedirs(os.path.join(out, "de.lproj"), exist_ok=True)
with open(os.path.join(out, "en.lproj", "Localizable.strings"), "w", encoding="utf-8") as f:
    for key in sorted(T):
        f.write(f"{quote(key)} = {quote(T[key])};\n")
with open(os.path.join(out, "de.lproj", "Localizable.strings"), "w", encoding="utf-8") as f:
    f.write("/* German is the language of the source; keys are the German texts. */\n")
