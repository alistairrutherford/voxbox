-- api.lua : the voxbox API manifest  (generic-cart phase 1)
--
-- The manifest is the contract between the engine and *any* cart, replacing
-- "whatever iso-defender happened to call".  Two jobs:
--
--   1. It is the allowlist for the cart sandbox (sandbox.lua).  A name not
--      listed here is not visible to the cart at all.
--   2. Names with no implementation get a recording stub, so an unknown cart
--      degrades instead of dying on `attempt to call a nil value`.
--
-- Per-name policy, because stubbing is not uniformly safe:
--
--   "void"   side-effecting, return value unused.  A stub draws/plays nothing;
--            the cart's logic is unaffected.  Honest degradation.
--   "value"  the cart consumes the return.  A stub necessarily LIES, and the
--            cart misbehaves in ways that look like game bugs.  These are
--            flagged red in the host panel: implement, don't ship.
--
-- Entries are {policy, default}; `default` is what a "value" stub returns.
--
-- Provenance, stated plainly: the PICO-8 stdlib names below are certain.  The
-- Voxatron-specific names beyond those the reference cart uses (see
-- iso-defender/ASSEMBLY.md) are best-effort and should be corrected against the
-- real 0.3.5b API notes.  The manifest is expected to start incomplete — the
-- host's undeclared-global reporting exists to close the gap from observed
-- behaviour rather than from guesswork.

-- Lua globals the cart may see.  Everything else is withheld: io, os, require,
-- package, load/loadstring, dofile/loadfile, debug, collectgarbage.  `math` is
-- exposed minus random/randomseed (Voxatron carts use rnd/srand, and
-- math.random would break trace determinism).
VB_LUA = {
 "type", "tostring", "tonumber", "pairs", "ipairs", "next", "select",
 "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "rawlen",
 "pcall", "xpcall", "error", "assert", "unpack",
 "string", "table", "coroutine", "_VERSION",
}

VB_API = {
 -- ---- voxel drawing ------------------------------------------------------
 clv            = {"void"},
 vset           = {"void"},
 vget           = {"value", 0},
 box            = {"void"},
 boxfill        = {"void"},
 sphere         = {"void"},
 line3d         = {"void"},
 draw_voxmap    = {"void"},   -- unimplemented: needs .vx.png voxel models
 blit_voxmap    = {"void"},   -- unimplemented: ditto

 -- ---- slice / 2D drawing -------------------------------------------------
 set_draw_slice = {"void"},
 pset           = {"void"},
 pget           = {"value", 0},
 line           = {"void"},
 circ           = {"void"},
 circfill       = {"void"},
 rect           = {"void"},
 rectfill       = {"void"},
 print          = {"void"},
 cursor         = {"void"},
 color          = {"void"},
 cls            = {"void"},
 pal            = {"void"},
 palt           = {"void"},
 camera         = {"void"},
 clip           = {"void"},
 fillp          = {"void"},

 -- ---- sprites / map (no resource tree in a .lua cart; stubbed) -----------
 spr            = {"void"},
 sspr           = {"void"},
 sget           = {"value", 0},
 sset           = {"void"},
 fget           = {"value", 0},
 fset           = {"void"},
 map            = {"void"},
 mget           = {"value", 0},
 mset           = {"void"},

 -- ---- audio --------------------------------------------------------------
 play_sound     = {"void"},
 stop_sound     = {"void"},
 play_music     = {"void"},
 stop_music     = {"void"},
 sfx            = {"void"},   -- PICO-8 spelling; aliased to play_sound
 music          = {"void"},   -- PICO-8 spelling; aliased to play_music

 -- ---- input --------------------------------------------------------------
 button         = {"value", 0},
 btn            = {"value", false},
 btnp           = {"value", false},
 _tick          = {"void"},   -- host-driven: advances btnp edge state + time()

 -- ---- math ---------------------------------------------------------------
 flr            = {"value", 0},
 ceil           = {"value", 0},
 abs            = {"value", 0},
 sgn            = {"value", 1},
 sqrt           = {"value", 0},
 max            = {"value", 0},
 min            = {"value", 0},
 mid            = {"value", 0},
 sin            = {"value", 0},
 cos            = {"value", 1},
 atan2          = {"value", 0},
 rnd            = {"value", 0},
 srand          = {"void"},

 -- ---- bit ops ------------------------------------------------------------
 band           = {"value", 0},
 bor            = {"value", 0},
 bxor           = {"value", 0},
 bnot           = {"value", 0},
 shl            = {"value", 0},
 shr            = {"value", 0},
 lshr           = {"value", 0},
 rotl           = {"value", 0},
 rotr           = {"value", 0},

 -- ---- tables / strings ---------------------------------------------------
 add            = {"value"},
 del            = {"value"},
 deli           = {"value"},
 all            = {"value"},
 foreach        = {"void"},
 count          = {"value", 0},
 sub            = {"value", ""},
 split          = {"value"},
 tostr          = {"value", ""},
 tonum          = {"value", 0},
 ord            = {"value", 0},
 chr            = {"value", ""},

 -- ---- system -------------------------------------------------------------
 time           = {"value", 0},
 t              = {"value", 0},
 stat           = {"value", 0},
 printh         = {"void"},
 flip           = {"void"},
 menuitem       = {"void"},
 extcmd         = {"void"},
 peek           = {"value", 0},
 poke           = {"void"},
 memcpy         = {"void"},
 memset         = {"void"},
 reload         = {"void"},
 cstore         = {"void"},

 -- ---- persistence (host-backed; see generic plan phase 3) ----------------
 cartdata       = {"value", false},
 dget           = {"value", 0},
 dset           = {"void"},

 -- ---- trace recorder (conformance harness; harmless to expose) ----------
 trace_mark     = {"void"},
 trace_flush    = {"value", ""},
}
