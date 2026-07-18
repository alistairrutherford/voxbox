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

-- ------------------------------------------------------------- tables -----
function add(t,v) t[#t+1]=v return v end
function del(t,v)
 for i=1,#t do if t[i]==v then table.remove(t,i) return v end end
end
function all(t)
 local i=0
 return function() i=i+1 return t[i] end
end
tostr=tostring

-- Deterministic pairs(): hash iteration order differs per VM (the cart's
-- wave spawner iterates {lander=6,pod=2}, 05_enemies.lua), so iterate keys
-- in sorted order instead.  Keys of one table are distinct and (num|str)
-- totally ordered => result independent of sort algorithm.
local rawpairs=pairs
function pairs(t)
 local keys={}
 for k in rawpairs(t) do keys[#keys+1]=k end
 table.sort(keys,function(a,b)
  local ta,tb=type(a),type(b)
  if ta~=tb then return ta=="number" end
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
function vget() return 0 end
function pget() return 0 end

-- ------------------------------------------------------ audio + input -----
play_sound = op("sfx")
stop_sound = op("sfxstop")
play_music = op("music")
stop_music = op("musicstop")

btn_state={[0]=0,0,0,0,0,0}
function button(n) return btn_state[n] or 0 end
