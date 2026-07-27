-- sandbox.lua : builds the cart environment  (generic-cart phase 1)
--
-- Load order is picovox.lua -> api.lua -> [host installs its JS API into _G]
-- -> vb_build() -> vb_load(cart).  Everything the cart can see is assembled
-- into one table (VB_ENV) from the api.lua allowlist, so the cart never sees
-- _G: no io, os, require, package, load, dofile, debug, collectgarbage, and no
-- math.random (Voxatron carts use rnd/srand, and math.random would break trace
-- determinism).
--
-- Manifest names with no implementation become recording stubs rather than nil,
-- so an unknown cart degrades instead of dying on `attempt to call a nil
-- value`.  Names *not* in the manifest stay nil and keep ordinary Lua
-- semantics -- a catch-all __index would make every undefined variable a
-- truthy function and break `if not player then player={} end`.

local env = {}
VB_ENV = env

local calls = {}    -- name -> {n=count, kind="void"|"value"}
local order = {}    -- first-seen order, so the host panel is stable

local function record(name, kind)
 local r = calls[name]
 if r then
  r.n = r.n + 1
 else
  calls[name] = {n=1, kind=kind}
  order[#order+1] = name
 end
end

local function make_stub(name, kind, dflt)
 if kind == "void" then
  return function() record(name, kind) end
 end
 return function() record(name, kind) return dflt end
end

-- Host-registered stub for a name the manifest never listed (see the
-- undeclared-global loop in host.js).  Defaults to "value" with nil, the
-- least-surprising choice for something we know nothing about: it keeps the
-- call from throwing without inventing a plausible-looking number.
function vb_stub(name, kind, dflt)
 kind = kind or "value"
 env[name] = make_stub(name, kind, dflt)
 VB_API[name] = {kind, dflt}
end

-- Returns "<implemented> <stubbed>" so the host can log the coverage it booted
-- with -- a one-glance answer to "how much of this cart's API is real?".
function vb_build()
 local real, stubbed = 0, 0
 for _,n in ipairs(VB_LUA) do env[n] = _G[n] end
 env.unpack = env.unpack or table.unpack     -- global `unpack` is 5.1-only

 -- math minus the nondeterministic entry points
 local m = {}
 for k,v in pairs(math) do
  if k ~= "random" and k ~= "randomseed" then m[k] = v end
 end
 env.math = m

 for name,spec in pairs(VB_API) do
  local impl = _G[name]
  if type(impl) == "function" then
   env[name] = impl
   real = real + 1
  else
   env[name] = make_stub(name, spec[1], spec[2])
   stubbed = stubbed + 1
  end
 end

 -- shared by reference, so driver.lua (which runs inside the sandbox) and
 -- picovox's button() -- which reads _G.btn_state -- mutate the same table
 env.btn_state = btn_state
 env._G = env                                -- _G.foo stays inside the sandbox
 return real, stubbed
end

-- ------------------------------------------------------- cart lifecycle ---

-- Loads a chunk into the cart environment. Returns nil on success, else the
-- error string. Chunks share one env, so a multi-file cart just loads in
-- filename order, as ASSEMBLY.md's 01_..09_ convention requires.
function vb_load(src, name)
 local f, err = load(src, "@"..(name or "cart"), "t", env)
 if not f then return err end
 local ok, e = pcall(f)
 if not ok then return tostring(e) end
 return nil
end

function vb_has(name) return type(env[name]) == "function" end

-- Errors propagate: the host catches them, pauses the loop and shows the
-- traceback rather than spinning at 30 fps of stack traces.
function vb_call(name, ...)
 local f = env[name]
 if type(f) ~= "function" then return end
 return f(...)
end

function vb_get(name) return env[name] end
function vb_set(name, v) env[name] = v end

-- ------------------------------------------------------------ reporting ---
-- One line per stubbed name: "<kind> <count> <name>".  The host colours
-- "value" red -- those stubs return a made-up number the cart consumes, so the
-- game is misbehaving, not merely quiet.
function vb_stubs()
 local out = {}
 for i=1,#order do
  local n = order[i]
  local r = calls[n]
  out[i] = r.kind.." "..r.n.." "..n
 end
 return table.concat(out, "\n")
end
