#!/usr/bin/env python3
import os
import re
import subprocess
import sys
from pathlib import Path

base = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
since = sys.argv[2] if len(sys.argv) > 2 else "5m"
out = base / "tmp" / "not_in_list_cn.txt"
out.parent.mkdir(parents=True, exist_ok=True)

p = subprocess.run(
    ["docker", "logs", "--since", since, "mosdns"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    errors="ignore",
)

found = set()
for line in p.stdout.splitlines():
    if "not_in_list_cn" not in line:
        continue
    m = re.search(r'"qname"\s*:\s*"([^"]+)"', line)
    if not m:
        m = re.search(r"qname[=:]\s*([^\s,}]+)", line)
    if not m:
        continue
    qname = m.group(1).strip().lower().rstrip(".")
    if qname:
        found.add(qname)

existing = set()
if out.exists():
    existing = {
        x.strip().lower().rstrip(".")
        for x in out.read_text(errors="ignore").splitlines()
        if x.strip()
    }

merged = sorted(existing | found)
tmp = out.with_suffix(".txt.tmp")
tmp.write_text("\n".join(merged) + ("\n" if merged else ""))
os.replace(tmp, out)
