#!/usr/bin/env python3
# Runs the gateway mutation list in mutations.md against copies of gateway.py.
# Standard library only. Exit 0 only when every entry is CAUGHT.

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "..", "docker", "gateway", "gateway.py")
LIST = os.path.join(HERE, "mutations.md")


def entries():
    out = []
    cur = None
    with open(LIST) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("## "):
                cur = {"name": line[3:].strip(), "rows": [], "before": [], "after": []}
                out.append(cur)
            elif cur is None:
                continue
            elif line.startswith("Rows: "):
                cur["rows"] = [r.strip() for r in line[6:].split("|")]
            else:
                m = re.match(r"^(Before|After): `(.*)`$", line)
                if m:
                    cur[m.group(1).lower()].append(m.group(2))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", default="")
    args = ap.parse_args()
    src = open(SOURCE).read()
    bad = 0
    for e in entries():
        if args.k not in e["name"]:
            continue
        before, after = "\n".join(e["before"]), "\n".join(e["after"])
        if not before or not e["rows"] or src.count(before) != 1:
            print("NO MATCH  %s (Before found %d times)" % (e["name"], src.count(before)))
            bad += 1
            continue
        td = tempfile.mkdtemp(prefix="gwmut", dir="/tmp")
        try:
            path = os.path.join(td, "gateway.py")
            with open(path, "w") as f:
                f.write(src.replace(before, after))
            env = dict(os.environ, CLEAT_GW_SOURCE=path, CLEAT_GW_FUZZ_COUNT="200")
            argv = [sys.executable, os.path.join(HERE, "corpus.py")]
            for r in e["rows"]:
                argv += ["-k", r]
            try:
                p = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=300)
            except subprocess.TimeoutExpired:
                print("HUNG      %s (a row never finished, which is a finding in the row)" % e["name"], flush=True)
                bad += 1
                continue
            ran = re.search(r"gateway corpus: (\d+) rows", p.stdout)
            if not ran or ran.group(1) == "0":
                print("NO ROWS   %s (filters %s)" % (e["name"], e["rows"]))
                bad += 1
            elif p.returncode != 0:
                print("CAUGHT    %s" % e["name"], flush=True)
            else:
                print("MISSED    %s" % e["name"], flush=True)
                bad += 1
        finally:
            shutil.rmtree(td, ignore_errors=True)
    print("gateway mutations: %s" % ("all caught" if not bad else "%d not caught" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
