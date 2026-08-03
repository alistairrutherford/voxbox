#!/usr/bin/env python3
"""Shared boot for the cart test harnesses.

Loads a cart under lupa with the canonical shim -- the same three files the
browser runtime executes -- so a harness can call the cart's own functions
directly and inspect its globals. That is the whole trick these tools rely on:
the cart is plain Lua in a sandbox, so a test can drive `try_move` or read
`node.mons` without any hooks in the cart itself.

Not a renderer. Draw calls go to the shim's trace recorder, which is what makes
`trace_flush()` usable for counting a frame's primitives (see deeper_play.py).

    from cartlab import load_cart
    lua = load_cart()                    # deeper.lua, _init already called
    lua.globals().vb_call("_update")
"""
import os
import sys

from lupa import LuaRuntime

VOXBOX = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(*parts):
    with open(os.path.join(VOXBOX, *parts)) as f:
        return f.read()


def load_cart(cart="deeper.lua", init=True, extra=None):
    """Return a LuaRuntime with the shim and `cart` loaded.

    init   call the cart's _init(), as the host does on load.
    extra  additional Lua source to load into the same sandbox, for the probe
           functions a harness wants to define alongside the cart.
    """
    lua = LuaRuntime(unpack_returned_tuples=True)
    for f in ("picovox.lua", "api.lua", "sandbox.lua"):
        lua.execute(read("shim", f))
    lua.globals().vb_build()

    err = lua.globals().vb_load(read("carts", cart), "cart")
    if err:
        sys.exit(f"{cart}: {err}")
    if init:
        lua.globals().vb_call("_init")
    if extra:
        err = lua.globals().vb_load(extra, "probe")
        if err:
            sys.exit(f"probe: {err}")
    return lua
