#!/usr/bin/env python3
"""Import a cart into voxbox/carts/ from an external source tree.

voxbox has no knowledge of where any cart came from — carts/ is served straight
off disk and the engine depends on nothing outside this repo. This is the
explicit step that replaces the old implicit rebuild hook: when a cart is
developed elsewhere, run this to pull the current version in.

A directory is concatenated in filename order, which is the documented load
order for multi-module carts (the 01_… 09_ prefix convention). A single file is
copied as-is.

Usage:
    python3 tools/import_cart.py ../some-game/src            # -> carts/some-game.lua
    python3 tools/import_cart.py ../some-game/src --name foo # -> carts/foo.lua
    python3 tools/import_cart.py ../some-game/build/foo.lua
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CARTS = os.path.join(os.path.dirname(HERE), "carts")


def collect(src):
    """Return (cart source text, default name, list of parts used)."""
    if os.path.isfile(src):
        with open(src) as f:
            return f.read(), os.path.splitext(os.path.basename(src))[0], [src]
    if not os.path.isdir(src):
        sys.exit(f"no such file or directory: {src}")
    parts = sorted(f for f in os.listdir(src) if f.endswith(".lua"))
    if not parts:
        sys.exit(f"no .lua files in {src}")
    text = "".join(open(os.path.join(src, p)).read() for p in parts)
    # a src/ directory is named after its layout, not its game, so fall back to
    # the parent directory for the cart name
    name = os.path.basename(os.path.normpath(src))
    if name in ("src", "build", "lua"):
        name = os.path.basename(os.path.dirname(os.path.normpath(os.path.abspath(src))))
    return text, name, parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="a .lua file, or a directory of .lua modules")
    ap.add_argument("--name", help="cart name (default: derived from the source)")
    args = ap.parse_args()

    text, default_name, parts = collect(args.source)
    name = args.name or default_name
    out = os.path.join(CARTS, f"{name}.lua")

    os.makedirs(CARTS, exist_ok=True)
    existed = os.path.exists(out)
    with open(out, "w") as f:
        f.write(text)

    print(f"{'updated' if existed else 'wrote'} carts/{name}.lua "
          f"({len(text.splitlines())} lines from {len(parts)} file(s))")
    manifest = os.path.join(CARTS, f"{name}.voxbox.json")
    if not os.path.exists(manifest):
        print(f"note: no carts/{name}.voxbox.json — the cart will use engine "
              f"defaults for its name, camera and controls")


if __name__ == "__main__":
    main()
