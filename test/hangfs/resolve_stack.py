#!/usr/bin/env python3
"""Turn the stacks hangtrace -b wrote (address, mapped file, offset) into function names, with nm."""
import bisect, subprocess, sys
tables = {}
def symbols(path):
    if path not in tables:
        syms = []
        for flags in (["-D"], []):
            try:
                out = subprocess.run(["nm", "-n", "--defined-only", *flags, path], capture_output=True, text=True, timeout=120).stdout
            except Exception:
                out = ""
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 3:
                    try: syms.append((int(parts[0], 16), parts[2]))
                    except ValueError: pass
        syms.sort(); tables[path] = syms
    return tables[path]
for line in open(sys.argv[1]):
    parts = line.rstrip("\n").split("\t")
    if line.startswith("    0x") and len(parts) == 3 and parts[1].startswith("/"):
        syms = symbols(parts[1]); off = int(parts[2], 16)
        i = bisect.bisect_right([a for a, _ in syms], off) - 1
        name = syms[i][1] if i >= 0 else "?"
        print(f"    {name:<60} {parts[1].rsplit('/', 1)[-1]}")
    else:
        print(line.rstrip("\n"))
