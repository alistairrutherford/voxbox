-- picovox.lua : canonical Voxatron 0.3.5b / PICO-8 API shim  (voxbox phase 0)
--
-- This file is the single source of truth for API semantics. It is executed
-- unmodified by every host (Python/lupa oracle, wasmoon browser runtime,
-- future Node runner), so any behaviour that could differ between Lua VMs or
-- libm builds is implemented here in pure Lua using only operations IEEE 754
-- guarantees to be exactly rounded (+ - * / sqrt floor): trigonometry is
-- polynomial, the PRNG is a float-safe Park-Miller LCG, and pairs() iterates
-- in sorted key order.  Identical cart + identical input script => bit
-- identical draw/audio traces on every host.
--
-- Verified against lupa (Lua 5.5) and wasmoon (Lua 5.4).

local mfloor, mabs = math.floor, math.abs
local sformat, tconcat = string.format, table.concat
local ssub, sbyte, schar = string.sub, string.byte, string.char
local host_print = print  -- captured before the draw-call print shadows it

-- ---------------------------------------------------------------- math ----
flr  = mfloor
ceil = math.ceil
abs  = mabs
sqrt = math.sqrt          -- correctly rounded per IEEE 754: deterministic

function max(a,b) if a>b then return a end return b end
function min(a,b) if a<b then return a end return b end
function mid(a,b,c)       -- arithmetic median: no table.sort dependency
 return max(min(a,b),min(max(a,b),c))
end
function sgn(x) if (x or 0)<0 then return -1 end return 1 end  -- pico-8: sgn(0)=1

local PI     = 3.14159265358979323846
local TAU    = PI*2
local HALFPI = PI/2

-- sin(2*pi*t) via odd Taylor series on the quarter wave (|err| < 4e-6).
-- Polynomial-only => bit identical on every VM, unlike libm sin.
local function sin_turns(t)
 t=t-mfloor(t)
 local sign=1.0
 if t>=0.5 then sign=-1.0 t=t-0.5 end
 if t>0.25 then t=0.5-t end
 local z=t*TAU
 local z2=z*z
 return sign*(z*(1+z2*(-1/6+z2*(1/120+z2*(-1/5040+z2*(1/362880))))))
end

-- pico-8 conventions: angles in turns, y axis flipped
function cos(x) return sin_turns((x or 0)+0.25) end
function sin(x) return -sin_turns(x or 0) end

-- atan(z) for z in [0,1], radians; minimax polynomial (|err| ~ 1e-6)
local function atan_poly(z)
 local z2=z*z
 return z*(0.99997726+z2*(-0.33262347+z2*(0.19354346
        +z2*(-0.11643287+z2*(0.05265332+z2*(-0.01172120))))))
end

-- pico-8 atan2(dx,dy) -> turns in [0,1), 0=east, 0.25=up (screen y down)
function atan2(dx,dy)
 local x=dx or 0
 local y=-(dy or 0)
 if x==0 and y==0 then return 0 end
 local ax,ay=mabs(x),mabs(y)
 local a
 if ax>=ay then a=atan_poly(ay/ax) else a=HALFPI-atan_poly(ax/ay) end
 if x<0 then a=PI-a end
 if y<0 then a=-a end
 return (a/TAU)%1
end

-- Park-Miller MINSTD via float arithmetic only (16807*2^31 < 2^53, so every
-- intermediate is an exact integer in a double; no bitops, no VM divergence)
local rnd_state=1
function srand(x)
 rnd_state=(mfloor(mabs(x or 0))%2147483646)+1
end
function rnd(x)
 rnd_state=(rnd_state*16807)%2147483647
 return ((rnd_state-1)/2147483646)*(x or 1)
end

-- ------------------------------------------------------- bit operations ---
-- pico-8 bitops act on 16.16 fixed point; this port uses doubles throughout
-- (VOXBOX_ENGINE_PLAN.md §7: document the divergence rather than emulate the
-- fixed-point layout), so these operate on the integer part.  Native Lua 5.3+
-- integer bitwise ops are exactly defined, hence still VM-independent.
local function toint(x) return mfloor(x or 0) end
function band(a,b) return toint(a) & toint(b) end
function bor(a,b)  return toint(a) | toint(b) end
function bxor(a,b) return toint(a) ~ toint(b) end
function bnot(a)   return ~toint(a) end
function shl(a,n)  return toint(a) << toint(n) end
function shr(a,n)  return toint(a) >> toint(n) end   -- arithmetic in pico-8
lshr = shr

-- ------------------------------------------------------------- tables -----
function add(t,v,i)       -- pico-8 3-arg form inserts at index i
 if i then table.insert(t,i,v) else t[#t+1]=v end
 return v
end
function del(t,v)
 for i=1,#t do if t[i]==v then table.remove(t,i) return v end end
end
function deli(t,i)
 if i then return table.remove(t,i) end
 return table.remove(t)
end
function all(t)
 if t==nil then return function() end end   -- pico-8 tolerates all(nil)
 local i=0
 return function() i=i+1 return t[i] end
end
function foreach(t,f)
 if t==nil then return end
 for i=1,#t do f(t[i]) end
end
function count(t,v)
 if t==nil then return 0 end
 if v==nil then return #t end
 local n=0
 for i=1,#t do if t[i]==v then n=n+1 end end
 return n
end

-- ------------------------------------------------------------ strings -----
sub = ssub
function ord(s,i) return sbyte(s,i or 1) end
function chr(n) return schar(toint(n)) end
function tonum(v)
 if type(v)=="number" then return v end
 return tonumber(v) or 0
end
function tostr(v,hex)
 if hex then return sformat("0x%04x",toint(v)) end
 if v==nil then return "[nil]" end
 return tostring(v)
end
function split(s,sep,convert)
 sep = sep or ","
 if convert==nil then convert=true end
 local out,i={},1
 s = tostring(s)
 while true do
  local j = string.find(s,sep,i,true)
  local piece = ssub(s, i, j and j-1 or #s)
  if convert then piece = tonumber(piece) or piece end
  out[#out+1]=piece
  if not j then break end
  i = j + #sep
 end
 return out
end

-- Deterministic pairs(): hash iteration order differs per VM (the cart's
-- wave spawner iterates {lander=6,pod=2}, 05_enemies.lua), so iterate keys
-- in sorted order instead.  Keys of one table are distinct and (num|str)
-- totally ordered => result independent of sort algorithm.
-- Keys are ranked by type first, because `a<b` raises on tables and booleans
-- and `set[obj]=true` is a common Lua idiom in carts other than the reference
-- one.  Numbers and strings sort by value (fully deterministic); anything else
-- falls back to tostring, which for tables is an address — stable within a run,
-- not across runs.  Carts keyed on table identity cannot be trace-conformed,
-- but they no longer crash.
local rawpairs=pairs
local function keyrank(v)
 local t=type(v)
 if t=="number" then return 0 elseif t=="string" then return 1 end
 return 2
end
function pairs(t)
 local keys={}
 for k in rawpairs(t) do keys[#keys+1]=k end
 table.sort(keys,function(a,b)
  local ra,rb=keyrank(a),keyrank(b)
  if ra~=rb then return ra<rb end
  if ra==2 then return tostring(a)<tostring(b) end
  return a<b
 end)
 local i=0
 return function()
  i=i+1
  local k=keys[i]
  if k~=nil then return k,t[k] end
 end
end

-- -------------------------------------------------------------- trace -----
-- Every draw/audio call is recorded as one line: "<op> <arg> <arg> ...".
-- Number formatting: exact integers print as integers (works for both Lua
-- integer and float subtypes), everything else as %.4f.  All game numbers
-- derive from deterministic ops, so the strings are identical across hosts.
local trace,tn={},0

local function fmt(v)
 if type(v)=="number" then
  if v==mfloor(v) and mabs(v)<=9007199254740992 then return sformat("%d",v) end
  return sformat("%.4f",v)
 end
 return tostring(v)
end

function trace_mark(s) tn=tn+1 trace[tn]=s end

-- hosts call periodically to stream the trace out and bound memory
function trace_flush()
 local s=tconcat(trace,"\n")
 trace={} tn=0
 return s
end

local function op(name)
 return function(...)
  local n=select("#",...)
  local parts={name}
  for i=1,n do parts[i+1]=fmt((select(i,...))) end
  tn=tn+1 trace[tn]=tconcat(parts," ")
 end
end

-- ------------------------------------------------- voxatron draw API ------
clv            = op("clv")
vset           = op("vset")
box            = op("box")
boxfill        = op("boxfill")
line3d         = op("line3d")
sphere         = op("sphere")
set_draw_slice = op("slice")
line           = op("line")
circ           = op("circ")
circfill       = op("circfill")
pset           = op("pset")
print          = op("print")     -- draw-call print (shadows lua print)
draw_voxmap    = op("voxmap")
blit_voxmap    = op("blitvox")
-- vget/pget are intentionally left unimplemented: the manifest turns them into
-- recording "value" stubs (returning 0, as before) so a cart that reads the
-- volume back is flagged rather than silently fed zeroes.  The play runtime
-- overrides vget with the real volume lookup.

-- ------------------------------------------------------ audio + input -----
play_sound = op("sfx")
stop_sound = op("sfxstop")
play_music = op("music")
stop_music = op("musicstop")

-- pico-8 spellings.  These resolve play_sound/play_music at call time, so they
-- follow the host's JS overrides rather than binding the trace recorder.
function sfx(n,...) return play_sound(n,...) end
function music(n,...) return play_music(n,...) end

btn_state={[0]=0,0,0,0,0,0}
function button(n) return btn_state[n] or 0 end

-- btnp needs per-frame edge state, which the API alone cannot derive: the host
-- calls _tick() once per _update.  Hold counts also drive time().
local hold,frames={},0
function _tick()
 frames=frames+1
 for i=0,7 do
  if button(i)~=0 then hold[i]=(hold[i] or 0)+1 else hold[i]=0 end
 end
end
function btn(i,p)
 if i==nil then                       -- pico-8 bitfield form
  local m=0
  for k=0,7 do if button(k)~=0 then m=m|(1<<k) end end
  return m
 end
 return button(i)~=0
end
function btnp(i,p)
 if i==nil then                       -- pico-8 bitfield form
  local m=0
  for k=0,7 do if btnp(k) then m=m|(1<<k) end end
  return m
 end
 local h=hold[i] or 0
 return h==1 or (h>15 and (h-16)%4==0)   -- pico-8 autorepeat: 15 then every 4
end

function time() return frames/30 end
t = time

function printh(s) if host_print then host_print(tostr(s)) end end
