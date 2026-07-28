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
# the bundled cart, which is also exactly what the browser runner is served, so
# the two hosts cannot diverge on cart bytes
DEFAULT_CART = os.path.join(VOXBOX, "carts", "voxel_defender.lua")
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

    def shim(name):
        return read(os.path.join(VOXBOX, "shim", name))

    # no host API here: the shim's own trace recorders are the implementation
    for f in ("picovox.lua", "api.lua", "sandbox.lua"):
        lua.execute(shim(f))
    real, stubbed = lua.globals().vb_build()
    print(f"api coverage: {real}/{real + stubbed} implemented", file=sys.stderr)

    # cart and driver share one sandbox env, so the driver can drive the cart
    load = lua.globals().vb_load
    for src, name in ((read(args.cart), "cart"), (shim("driver.lua"), "driver")):
        err = load(src, name)
        if err:
            sys.exit(f"{name}: {err}")

    lua.execute(f'srand({args.seed}) vb_call("_init")')

    call = lua.globals().vb_call
    flush = lua.globals().trace_flush

    def run(a, b):
        call("run_frames", a, b)
    with open(args.out, "w") as out:
        f = 1
        while f <= args.frames:
            hi = min(f + FLUSH_EVERY - 1, args.frames)
            run(f, hi)
            out.write(flush())
            out.write("\n")
            f = hi + 1

    mode = lua.eval('vb_get("mode")')
    print(f"wrote {args.out}: {args.frames} frames, final mode={mode!r}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
