#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Moves every version reference from OLD to NEW: python3 scripts/bump-version.py 0.21.0 0.22.0"""
import sys

old, new = sys.argv[1], sys.argv[2]
build_old, build_new = old.split(".")[1], new.split(".")[1]
files = {
    "Resources/Info.plist": [(f"<string>{old}</string>", f"<string>{new}</string>"),
                             (f"<key>CFBundleVersion</key><string>{build_old}</string>", f"<key>CFBundleVersion</key><string>{build_new}</string>")],
    "Sources/SyncSCP/CommanderView.swift": [(f'let appVersion = "{old}"', f'let appVersion = "{new}"')],
    "README.md": [(f"version-{old}-blue", f"version-{new}-blue"), (f'alt="Version {old}"', f'alt="Version {new}"'),
                  (f"**Status: {old} development preview.**", f"**Status: {new} development preview.**")],
    "README.tr.md": [(f"version-{old}-blue", f"version-{new}-blue"), (f'alt="Sürüm {old}"', f'alt="Sürüm {new}"'),
                     (f"**Durum: {old} geliştirme önizlemesi.**", f"**Durum: {new} geliştirme önizlemesi.**")],
    "docs/HANDOFF.md": [(f"Mevcut uygulama **{old} geliştirme önizlemesi**.", f"Mevcut uygulama **{new} geliştirme önizlemesi**.")],
}
for path, pairs in files.items():
    text = open(path, encoding="utf-8").read()
    for before, after in pairs:
        if before not in text:
            sys.exit(f"{path}: '{before}' not found")
        text = text.replace(before, after)
    open(path, "w", encoding="utf-8").write(text)
print(f"Version {old} -> {new}")
