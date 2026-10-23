#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Lists interface texts without a Turkish translation.

Literal texts come from the compiler (-emit-localized-strings); texts that components receive
as String (ToolButton, settings tables…) are found by pattern. Usage:
    python3 scripts/check-localization.py            # report missing keys, exit 1 if any
    python3 scripts/check-localization.py --keys     # print every key as JSON lines
"""
import glob, json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "Sources", "SyncSCP")
LITERAL = r'"((?:[^"\\]|\\.)*)"'
RUNTIME = {
    "CommanderView.swift": [r"ToolButton\(title: ", r'ToolButton\(title: [^"]*', r'ToolButton\(title: [^"]*"[^"]*"\s*:\s*',
                            r'IconButton\(icon: "[^"]*", label: ', r"tab\(\.\w+, title: ", r"return L\(", r"format: L\("],
    "ConnectionSheet.swift": [r"labeled\(", r"labeled\(s3 \? ", r"\? " + LITERAL + r" : ", r"\(\.\w+, "],
    "AdvancedSiteSettings.swift": [r"Field\(label: ", r"Check\(title: ", r"Group\(title: ", r"return ", r"title: ", r"label: "],
    "BrowsingTools.swift": [r"\("],
    "QuickOpen.swift": [r"\(", r"detail: "],
}


def compiler_keys():
    with tempfile.TemporaryDirectory() as out:
        for path in glob.glob(os.path.join(APP, "*.swift")):
            os.utime(path)
        subprocess.run([os.path.join(ROOT, "scripts", "swift.sh"), "build", "-Xswiftc", "-emit-localized-strings",
                        "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out], check=True, stdout=subprocess.DEVNULL)
        keys = set()
        for path in glob.glob(os.path.join(APP, "*.swift")):
            data = os.path.join(out, os.path.basename(path).replace(".swift", ".stringsdata"))
            if os.path.exists(data):
                for entries in json.load(open(data)).get("tables", {}).values():
                    keys.update(entry["key"] for entry in entries)
        return keys


def runtime_keys():
    keys = set()
    for name, patterns in RUNTIME.items():
        text = open(os.path.join(APP, name), encoding="utf-8").read()
        for pattern in patterns:
            for match in re.finditer(pattern + LITERAL, text):
                value = match.groups()[-1]
                if "\\(" not in value:
                    keys.add(value)
    for match in re.finditer(r"labels: \(" + LITERAL + ", " + LITERAL + ", " + LITERAL, open(os.path.join(APP, "AdvancedSiteSettings.swift")).read()):
        keys.update(match.groups())
    return keys


# Values the core shows through L(): synchronization directions and actions, job states, the cipher divider.
CORE_TEXTS = ["Local → Remote", "Remote → Local", "Both", "Create remote folder", "Create local folder", "Delete remote",
              "Move local to Trash", "Conflict", "— warn below here —", "Waiting", "Transferring", "Complete", "Failed", "Cancelled",
              "SSH (always encrypted)", "No encryption", "TLS/SSL Explicit encryption", "TLS/SSL Implicit encryption", "Amazon S3"]


def translated():
    path = os.path.join(ROOT, "Resources", "tr.lproj", "Localizable.strings")
    if not os.path.exists(path):
        return {}
    text = open(path, encoding="utf-8").read()
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)
    return {key.encode().decode("unicode_escape").encode("latin-1").decode("utf-8") if "\\" in key else key: value for key, value in pairs}


def interesting(key):
    # Paths, placeholders, host names and identifiers (lower-case single tokens) are not translated;
    # protocol names and acronyms (SFTP, IPv4, UTF-8…) read the same in Turkish.
    if key.startswith(("/", "~", ".")) or not re.search(r"[a-z]{2}", key):
        return False
    if re.fullmatch(r"[\w.:@%…-]+", key) and not key[0].isupper():
        return False
    return key not in SAME_IN_TURKISH


SAME_IN_TURKISH = {"syncSCP", "WebDAV", "IPv4", "IPv6", "SOCKS4", "SOCKS5", "HTTP", "PuTTY", "GSSAPI", "TLS/SSL", "SCP/Shell", "FTP", "SFTP",
                   "SSH", "S3", "LF", "CR/LF", "UTF-8", "AKIA…", "arn:aws:iam::…", "Role ARN", "Terminal", "Proxy", "Amazon S3", "%@ · %@",
                   "%@ → %@:%@", "%@@%@:%lld", "%@  ⇄  %@", "%lld", "Snippets", "ls -la"}


if __name__ == "__main__":
    keys = {k for k in compiler_keys() | runtime_keys() | set(CORE_TEXTS) if k}
    if "--keys" in sys.argv:
        for key in sorted(keys):
            print(json.dumps(key, ensure_ascii=False))
        sys.exit(0)
    have = translated()
    missing = sorted(k for k in keys if interesting(k) and k not in have)
    for key in missing:
        print(json.dumps(key, ensure_ascii=False))
    print(f"{len(missing)} of {len(keys)} keys have no Turkish translation.", file=sys.stderr)
    sys.exit(1 if missing else 0)
