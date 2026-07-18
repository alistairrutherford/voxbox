#!/usr/bin/env python3
"""voxbox conformance differ: compare two engine traces line by line.

Traces are the output of shim/picovox.lua's recorder ("F <n>" frame markers,
then one "<op> <args...>" line per draw/audio call).  Reports the first
divergence with its enclosing frame and surrounding context, plus per-op
call counts.  Exit 0 iff the traces are identical.

Usage:
    python3 tools/conform.py trace_py.txt trace_js.txt [--context 4]
"""
import argparse
import sys
from collections import Counter


def load(path):
    with open(path) as f:
        return [ln for ln in f.read().splitlines() if ln]


def op_stats(lines):
    c = Counter()
    for ln in lines:
        c[ln.split(" ", 1)[0]] += 1
    return c


def enclosing_frame(lines, i):
    for j in range(i, -1, -1):
        if lines[j].startswith("F "):
            return lines[j][2:]
    return "?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace_a")
    ap.add_argument("trace_b")
    ap.add_argument("--context", type=int, default=4)
    args = ap.parse_args()

    a = load(args.trace_a)
    b = load(args.trace_b)

    n = min(len(a), len(b))
    div = next((i for i in range(n) if a[i] != b[i]), None)
    if div is None and len(a) != len(b):
        div = n

    print(f"{args.trace_a}: {len(a)} lines   {args.trace_b}: {len(b)} lines")

    if div is None:
        frames = sum(1 for ln in a if ln.startswith("F "))
        print(f"IDENTICAL  ({frames} frames)")
        top = op_stats(a).most_common(8)
        print("top ops:", ", ".join(f"{op}={c}" for op, c in top))
        return 0

    print(f"DIVERGED at line {div + 1}, frame {enclosing_frame(a, min(div, len(a) - 1))}")
    lo = max(0, div - args.context)
    hi = div + args.context + 1
    for i in range(lo, hi):
        la = a[i] if i < len(a) else "<eof>"
        lb = b[i] if i < len(b) else "<eof>"
        tag = "  " if la == lb else "->"
        print(f"{tag} {i + 1:>8}  A| {la}")
        if la != lb:
            print(f"{tag} {'':>8}  B| {lb}")

    ca, cb = op_stats(a), op_stats(b)
    drift = {op: (ca[op], cb[op]) for op in ca.keys() | cb.keys()
             if ca[op] != cb[op]}
    if drift:
        print("op count drift (A vs B):")
        for op, (x, y) in sorted(drift.items()):
            print(f"  {op}: {x} vs {y}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
