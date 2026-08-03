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
import json
import os
import sys

from lupa import LuaRuntime

VOXBOX = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(*parts):
    with open(os.path.join(VOXBOX, *parts)) as f:
        return f.read()


def lua_literal(v):
    """JSON value -> Lua source, mirroring luaLiteral() in runtime/js/host.js.

    Kept in step with the browser deliberately: if the two disagree, a harness
    is testing a cart the host never runs.
    """
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        out = ['"']
        for b in v.encode("utf-8"):
            ch = chr(b)
            out.append(ch if 32 <= b < 127 and ch not in '"\\' else f"\\{b:03d}")
        return "".join(out) + '"'
    if isinstance(v, list):
        return "{" + ",".join(lua_literal(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join(f"[{lua_literal(str(k))}]={lua_literal(x)}"
                              for k, x in v.items()) + "}"
    return "nil"


def load_cart(cart="deeper.lua", init=True, extra=None):
    """Return a LuaRuntime with the shim and `cart` loaded.

    init   call the cart's _init(), as the host does on load.
    extra  additional Lua source to load into the same sandbox, for the probe
           functions a harness wants to define alongside the cart.

    The cart's <cart>.voxbox.json "config" block is installed as the CONFIG
    global before the chunk loads, exactly as the host does it, so a harness
    exercises the same statue text and the same look flags the game ships with.
    """
    lua = LuaRuntime(unpack_returned_tuples=True)
    for f in ("picovox.lua", "api.lua", "sandbox.lua"):
        lua.execute(read("shim", f))
    lua.globals().vb_build()

    man_path = os.path.join(VOXBOX, "carts", cart.replace(".lua", ".voxbox.json"))
    if os.path.exists(man_path):
        with open(man_path) as f:
            cfg = json.load(f).get("config")
        if isinstance(cfg, dict):
            lua.execute(f'vb_set("CONFIG", {lua_literal(cfg)})')

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
