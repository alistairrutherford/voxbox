#!/usr/bin/env python3
"""voxbox phase 0 oracle: run the cart under lupa with the canonical shim
and write the deterministic draw/audio trace.

The same shim/driver Lua sources run under the browser runtime (wasmoon);
tools/conform.py diffs the two traces.

Usage:
    python3 tools/trace_run.py [--frames 1500] [--out trace_py.txt]
"""
import argparse
import os
import sys

from lupa import LuaRuntime

VOXBOX = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(VOXBOX)
DEFAULT_CART = os.path.join(ROOT, "iso-defender", "build", "voxel_defender.lua")
FLUSH_EVERY = 100  # frames per trace_flush, bounds Lua-side memory


def read(path):
    with open(path) as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=1500)
    ap.add_argument("--out", default=os.path.join(VOXBOX, "trace_py.txt"))
    ap.add_argument("--cart", default=DEFAULT_CART)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    lua = LuaRuntime(unpack_returned_tuples=True)
    print(f"lua: {lua.lua_implementation}", file=sys.stderr)

    lua.execute(read(os.path.join(VOXBOX, "shim", "picovox.lua")))
    lua.execute(read(args.cart))
    lua.execute(read(os.path.join(VOXBOX, "shim", "driver.lua")))

    lua.execute(f"srand({args.seed}) _init()")

    run = lua.globals().run_frames
    flush = lua.globals().trace_flush
    with open(args.out, "w") as out:
        f = 1
        while f <= args.frames:
            hi = min(f + FLUSH_EVERY - 1, args.frames)
            run(f, hi)
            out.write(flush())
            out.write("\n")
            f = hi + 1

    mode = lua.eval("mode")
    print(f"wrote {args.out}: {args.frames} frames, final mode={mode!r}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
