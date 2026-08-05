-- deeper.lua : a rogue-style dungeon crawl for Voxatron  (pure Lua, no assets)
--
-- Turn-based, isometric, one dungeon node per volume.  See
-- docs/VOXBOX_ROGUE_PLAN.md for the design; the three things that shape every
-- line of this file are:
--
--   1. There is no lighting in the renderer.  Torchlight here is a light map
--      on its own grid -- finer than the tiles, three cells to a tile -- and
--      every floor and wall voxel picks its palette index from a four-step
--      ramp indexed by that light level.  Warm ramps near torches, cold stone
--      away from them.  It flickers because the map is recomputed with a
--      wobbling radius.  Two RLE passes, across and then down, mean the cost
--      tracks the number of light-level changes rather than the resolution.
--   2. The cart cannot move the camera and is never told where it is, so the
--      view is fixed isometric, nothing is projected world-to-screen, and the
--      HUD is a fixed banner rather than bubbles over speakers' heads.
--   3. Anything on an object's far face is hidden by the object itself.  The
--      two near walls are therefore drawn as a low sill rather than at full
--      height, and torches only ever go on the far walls -- a torch on a near
--      wall would have its flame hidden by its own bracket.
--
-- Volume is 128(x) x 128(y, 0 = back) x 64(z, 0 = TOP): larger z is *lower*,
-- larger y is *nearer the camera*.
--
-- Corridors are nodes in their own right -- same grid, same drawing code, same
-- light map.  The only thing that makes one a corridor is being three tiles
-- wide.

-- =============================================================== 01_config ==
TS       = 6             -- tile size in voxels
-- Wide, not square. A square footprint at this camera projects to something
-- nearly square, but the screen is 4:3 -- so filling the width overflowed the
-- height and left no room for a HUD. 21 x 15 projects to roughly the frame's
-- own shape: 97% of the width used, with a quarter of the height left clear
-- above the room for the HUD to live in.
GW, GH   = 21, 15
OX, OY   = 1, 1          -- voxel origin of tile (0,0)

-- Light is computed on its own grid, *per voxel*, not per tile. Tile size is
-- set by how wide a creature has to be to read at this camera; light wants to
-- be as fine as the volume allows, and there is no reason the two have to
-- agree. The two RLE passes below mean the cost of the finer grid is bounded
-- by the number of light-level changes, not by the resolution -- which is what
-- makes per-voxel light affordable at all.
LS       = 1             -- light cell size in voxels
SUB      = 6             -- light cells per tile (TS / LS)

-- The room sits low in the volume so that z = 0..45 is empty sky above it.
-- That band is the only place a HUD can go once the floor plan fills the
-- footprint, and it has to be paid for in floor height.
FLOOR_Z  = 58            -- top surface of the floor slab
FLOOR_B  = 62            -- bottom of the slab
WALL_Z   = 46            -- top of a full-height wall
SILL_Z   = 54            -- top of a near-edge sill wall
-- The HUD is painted on two planes, and the reason there are two is worth
-- stating, because the obvious single-plane answer was tried and was wrong.
--
-- The back plane at y = 2 is seen at 12 degrees of azimuth, so a row of
-- constant z is not a row of constant screen height: the right-hand end sits
-- nearer the camera and rides up the frame, and a full-width line comes out
-- tilted by about ten voxels. Levelling it -- picking a z per character so the
-- row is horizontal -- works, and looks worse: `print` puts a whole string
-- down at one z, so levelling has to step *inside* the string and every word
-- comes out as a staircase. A cleanly set line at the plane's own angle reads
-- better than a level line made of ragged letters, so the tilt stays and the
-- fix is to stop asking one band to hold everything.
--
-- Which leaves the question of where the rest goes. The band above the far
-- wall is z = 12 .. 40 once rows are honest about their tilt: four rows, and
-- the fifth was what pushed health off the top of the frame.
--
-- So health and armour move *in front of* the room, onto a near slice at
-- y = 104. Anything at y > 90 is nearer the camera than the largest node can
-- reach, so it cannot be occluded, and the wedge of frame below the room's
-- near edge is exactly one row tall: z = 46..49 clears both the room and the
-- bottom of the frame, and z = 45 or 50 does not. One row, up to 26 columns,
-- and the font is half again as big there for being that much nearer.
--
-- Every number here is a property of the camera in deeper.voxbox.json. Change
-- that and they have to be re-derived by projecting the plane; nothing in the
-- cart can detect it, because the cart is never told where the camera is.
HUD_Y    = 2             -- back plane, above the far wall
HUD_TOP  = 12            -- first row; above this the left end leaves the frame
HUD_ROW  = 7             -- 5 for the glyph, 2 of leading
HUD_COLS = 24            -- characters per row before the minimap column
HUD_MAPX = 98            -- minimap column, clear of a full-width line of text
HUD_BY   = 104           -- near slice, in front of the room
HUD_BZ   = 47            -- the one row that fits below it (46..49 clear)
HUD_BX   = 8             -- and its left margin, in from the frame edge

MOVE_FR  = 5             -- frames a tile step takes
MAX_PART = 80            -- particle cap: each one is a vset

-- Recovery. Rogue regenerated health with time and so does this: without it
-- the run is a one-way ratchet down to zero and no amount of good play buys
-- anything back. Two rates, because one rate cannot do both jobs: in a fight
-- it must be too slow to out-heal the damage, but walking somewhere quiet to
-- tick back up at that rate is just tedium. Leaving the fight switches rate.
REGEN     = 14           -- turns per point while anything is hunting you
REGEN_CALM = 3           -- turns per point once nothing in the node is awake
HP_START  = 16           -- and what you start a run with
DIVE_HEAL = 8            -- restored on reaching a new floor
DIVE_MAX  = 2            -- and permanent max health for getting there
-- How far a monster notices you depends on how lit *you* are, which is the
-- only place the light map touches the rules rather than the picture. It was a
-- flat six tiles whatever the light, so the cart's one genuinely unique system
-- was decoration: torchlight decided how the room looked and nothing else.
--
-- Carrying a lit torch through a dark room now advertises you from eight tiles
-- away; douse it and nothing sees you past three. That turns the torch clock
-- from a countdown into a dial, gives the wall sconces a tactical meaning
-- beyond being pretty, and makes the dark a tool as well as a threat.
AGGRO_DARK = 3           -- tiles at which something notices you unlit
AGGRO_LIT  = 8           -- ...and standing in a torch pool
AGGRO      = AGGRO_LIT   -- the range `hunted()` uses to pick a regen rate
AMBUSH     = 2           -- extra damage from something you never saw coming

-- Retreating through a door used to be a total escape: nothing followed, so
-- any fight could be ended by stepping through a doorway, which quietly
-- undid the two-rate regen built to make breaking off a *decision*.
FOLLOW_ODDS = 0.45       -- chance an adjacent, angry monster comes after you
FOLLOW_MAX  = 2          -- but never a whole mob at once

BARK_HOLD  = 45          -- a fresh bark is not shouted over (§5.4)
STONE_DMG  = 2           -- a thrown stone is utility, not a damage source

-- CONFIG arrives from carts/deeper.voxbox.json, installed by the host before
-- this chunk loads (host.js, luaLiteral) and by tools/cartlab.py for the
-- harnesses. It is an override and never a dependency: dropped on the page on
-- its own, with no manifest beside it, the cart sees CONFIG = nil and every
-- default below still applies.
function cfg(key, dflt)
  if CONFIG == nil then return dflt end
  local v = CONFIG[key]
  if v == nil then return dflt end
  return v
end

-- Every visual flourish is a named flag under `config.fx`, so a look can be
-- tried, judged and dropped without a code edit -- which is how `textures`
-- came to be off. Read once into locals-in-name-only rather than through fx()
-- per call: several of these are tested inside the light map's inner loop,
-- which runs ~10k times a rebuild, and a table lookup plus a nil test there is
-- not free.
--
-- Defaults are what the cart does with no manifest beside it at all. All of
-- them are on except the mottling, because each one fixes something that was
-- measurably wrong; `textures` is the one still on trial.
FX = cfg("fx", {})
function fx(key, dflt)
  local v = FX[key]
  if v == nil then return dflt end
  return v == true
end

FX_TEXTURES  = fx("textures", false)      -- per-flagstone mottling (§2.1b)
FX_WALLFLOOR = fx("wall_floor", true)     -- walls never go fully dark
FX_JITTER    = fx("jitter", true)         -- ragged light-pool edges
FX_CREST     = fx("hero_crest", true)     -- the hero is never lost in a crowd
FX_ARCHES    = fx("arches", true)         -- doorways read as doorways
FX_LIQUID    = fx("liquid", true)         -- water moves
FX_DECALS    = fx("decals", true)         -- rooms remember their dead
FX_DISSOLVE  = fx("dissolve", true)       -- rooms build up on entry
FX_DMGNUM    = fx("damage_numbers", true) -- damage prints over the target
FX_THEMETORCH = fx("theme_torches", true) -- each depth lights differently

-- Torchlight itself, and it is a flag like the rest now rather than a line on
-- the title screen. It was toggled with z and remembered in cartdata slot 2 --
-- a setting on the menu of a game whose menu is six rows of a 3x5 font, and
-- the one row there that was neither a control nor a score. Flat mode is a
-- legibility and performance escape hatch (§2.0), which is a thing you decide
-- once about a machine, not something to offer between runs.
lightfx = fx("torchlight", true)

TEXTURES = FX_TEXTURES

-- Some pillars are not pillars. A monument occupies a wall tile like any
-- other pillar -- it blocks, it casts, it is drawn where the pillar was -- but
-- bumping it says something, and a shrine does something once.
--
-- Both lists are content, not code, so they live in the manifest and these are
-- only the fallback. Statues are text alone and the list can grow for nothing;
-- a shrine also names a kind, and only the four prop_touch implements do
-- anything. Names and lines are written to fit HUD_COLS.
STATUES = cfg("statues", {
  { n = "a forgotten king",  say = "HE LOOKS DISAPPOINTED" },
  { n = "a very large rat",  say = "COMMISSIONED BY THE RAT" },
  { n = "bust of the architect", say = "HE PLANNED THE CORRIDORS" },
  { n = "an earlier hero",   say = "NOT YOU. AN EARLIER ONE." },
  { n = "a weeping angel",   say = "DON'T BLINK. ONLY JOKING" },
  { n = "a slime, in marble", say = "SURPRISINGLY LIFELIKE" },
  { n = "the dungeon manager", say = "PLAQUE: EMPLOYEE OF 1347" },
  { n = "two goblins arguing", say = "TITLED: THE STAND UP" },
})
SHRINES = cfg("shrines", {
  { n = "shrine of small mercies", k = "heal",  say = "YOU FEEL A BIT BETTER" },
  { n = "font of stale water",     k = "torch", say = "YOUR TORCH DRINKS DEEP" },
  { n = "altar of tidy kit",       k = "arm",   say = "YOUR KIT LOOKS TIDIER" },
  { n = "the whetstone",           k = "whet",  say = "IT TAKES AN EDGE" },
  { n = "the lost sock reliquary", k = "gold",  say = "A COIN. ODDLY WARM." },
  { n = "shrine of second wind",   k = "heal",  say = "THAT IS BETTER" },
})

ARM_KINDS = { "helm", "chest", "shield" }
ARM_MSG = { helm = "A PROPER HELM", chest = "BREASTPLATE ON", shield = "SHIELD UP" }
ARM_MAX = 7              -- 2 + 3 + 2, the number the damage curve is tuned to

-- A weapon is a fourth rated slot, run exactly like the three armour ones.
--
-- Damage used to be the constant 2 the hero started with, and the only things
-- that ever touched it took it *away* -- permanently, with nothing in the game
-- able to give it back. Monsters meanwhile scale 1 + (depth-1) * 0.14, so by
-- depth 13 they carried 2.7x the health against the same 2..4 a bump did on
-- floor 1, and deep floors turned into arithmetic rather than difficulty.
-- Armour progressed 0..7 and offence progressed not at all.
DMG_BASE = 2             -- bare hands
WPN_MAX  = 4
SIGH_T   = 12            -- turns a sad ghost's sigh keeps your damage down
CREW_REVIVE = 3          -- turns before a downed committee member gets up

-- Flat-light mode: every cell forced to one level, so the room is evenly lit
-- and the torch pools vanish. Toggled on the title screen and remembered in
-- cartdata. Also much cheaper, since the light map collapses to one run a row.
FLAT_FLOOR, FLAT_WALL = 2, 3

-- Materials are not colours, they are four-step ramps indexed by light level.
RAMPS = {
  cold  = { 1,  5,  6,  7 },   -- stone in the dark
  warm  = { 1,  4,  9, 10 },   -- stone under a torch
  moss  = { 1,  3, 11, 10 },
  blood = { 1,  2,  8, 14 },
  gold  = { 1,  4, 10,  7 },   -- a cold, pale torch
  ember = { 1,  2,  8,  9 },   -- a low, red one
  ice   = { 1, 13, 12,  7 },
  bone  = { 1,  5,  6, 15 },
}

-- Depth bands. Each picks the cold/warm pair the level is painted with, plus
-- an accent for doors, trim and the HUD.
--
-- The accent is a *ramp* (`accr`) as well as a bare index, because trim obeys
-- the light like everything else: the skirting course and a statue's plaque
-- take `RAMPS[accr][light]`, and `acc` is only the nominal colour, the one the
-- trim shows at the level you mostly see it and the one the HUD prints in.
-- §2.2's rule is that a material is a ramp indexed by light, and trim is a
-- material.
--
-- Each accent ramp is deliberately *not* the theme's own stone: green trim on
-- green warren stone is not trim, it is a slightly different green.
-- `warm` is the ramp *inside* a torch pool and `cold` the stone away from one.
-- All five themes used to name "warm" for the pool, so every floor's
-- torchlight was the same orange whatever the stone around it -- half the
-- variety the two-ramp scheme was built for, switched off by one repeated
-- field. Each depth now lights differently: pale gold in the cisterns, a low
-- red ember in the warrens. `theme_torches` off restores the single orange.
THEMES = {
  { name = "the crypt",   cold = "cold",  warm = "warm",
    acc = 12, accr = "ice",   mon = 1 },       -- blue on grey
  { name = "the cisterns", cold = "ice",  warm = "gold",
    acc =  7, accr = "cold",  mon = 2 },       -- white on blue
  { name = "the warrens", cold = "moss",  warm = "ember",
    acc = 15, accr = "bone",  mon = 3 },       -- peach on green
  { name = "the ossuary", cold = "bone",  warm = "warm",
    acc =  8, accr = "blood", mon = 4 },       -- red on bone
  { name = "the red floor", cold = "blood", warm = "gold",
    acc =  7, accr = "cold",  mon = 5 },       -- white on red
}
if not FX_THEMETORCH then
  for i = 1, #THEMES do THEMES[i].warm = "warm" end
end

-- tile codes
T_VOID, T_FLOOR, T_WALL, T_DOOR, T_STAIR, T_WATER = 0, 1, 2, 3, 4, 5

DIRS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }   -- n e s w
DIRNAME = { "n", "e", "s", "w" }
OPPOSITE = { 3, 4, 1, 2 }

-- ================================================================= 02_util ==
function sfx_safe(n) pcall(play_sound, n) end
function music_safe(n, f) pcall(play_music, n, f) end
function clamp(v, lo, hi) return mid(lo, v, hi) end
function pick(t) return t[flr(rnd(#t)) + 1] end
function lerp(a, b, t) return a + (b - a) * t end
function chebyshev(ax, ay, bx, by) return max(abs(ax - bx), abs(ay - by)) end

-- pico-8's sgn(0) is 1, not 0 (shim/picovox.lua:30). Chasing code needs a
-- real three-way sign or monsters drift diagonally whenever they line up.
function isgn(v)
  if v > 0 then return 1 end
  if v < 0 then return -1 end
  return 0
end

function vx(tx) return OX + tx * TS end          -- tile -> voxel, low corner
function vy(ty) return OY + ty * TS end

-- Deterministic integer in [0,n)
function irnd(n) return flr(rnd(n)) end

function grid(w, h, v)
  local g = {}
  for y = 0, h - 1 do
    g[y] = {}
    for x = 0, w - 1 do g[y][x] = v end
  end
  return g
end

-- ============================================================ 03_dungeon ==
-- A floor is a graph of nodes. Chambers sit on a 4x3 lattice; every edge of
-- the spanning tree becomes a corridor node, so a corridor is a first-class
-- place with its own torches, monsters and light -- not a line on a map.

LAT_W, LAT_H = 4, 3

function floor_build(d)
  srand(run_seed + d * 977)
  theme = THEMES[min(d, #THEMES)]

  -- 1. grow a connected blob of lattice cells
  local want = min(4 + flr(d / 2) + irnd(3), LAT_W * LAT_H)
  local cells, taken = {}, grid(LAT_W, LAT_H, false)
  local cx, cy = irnd(LAT_W), irnd(LAT_H)
  taken[cy][cx] = true
  add(cells, { x = cx, y = cy })
  while #cells < want do
    local c = pick(cells)
    local dd = DIRS[irnd(4) + 1]
    local nx, ny = c.x + dd[1], c.y + dd[2]
    if nx >= 0 and nx < LAT_W and ny >= 0 and ny < LAT_H and not taken[ny][nx] then
      taken[ny][nx] = true
      add(cells, { x = nx, y = ny })
    end
  end

  -- 2. a chamber node per cell
  nodes = {}
  for i = 1, #cells do
    local c = cells[i]
    local n = {
      kind = "room", gx = c.x, gy = c.y, exits = {}, seen = false,
      w = 18 + irnd(4), h = 12 + irnd(4),
    }
    c.node = i
    add(nodes, n)
  end

  -- 3. spanning tree over the cells, plus a loop or two; each edge is a
  --    corridor node placed between its two chambers
  local reached = { [1] = true }
  local edges = {}
  local function adjacent(a, b)
    return abs(a.x - b.x) + abs(a.y - b.y) == 1
  end
  while true do
    local best = nil
    for i = 1, #cells do
      if reached[i] then
        for j = 1, #cells do
          if not reached[j] and adjacent(cells[i], cells[j]) then
            best = { i, j }
            break
          end
        end
      end
      if best then break end
    end
    if not best then break end
    reached[best[2]] = true
    add(edges, best)
  end
  for i = 1, #cells do
    for j = i + 1, #cells do
      if adjacent(cells[i], cells[j]) and rnd(1) < 0.18 then
        local dup = false
        for e in all(edges) do
          if (e[1] == i and e[2] == j) or (e[1] == j and e[2] == i) then dup = true end
        end
        if not dup then add(edges, { i, j }) end
      end
    end
  end

  for e in all(edges) do
    local a, b = cells[e[1]], cells[e[2]]
    local horiz = a.y == b.y
    local n = {
      kind = "corr", exits = {}, seen = false,
      gx = (a.x + b.x) / 2, gy = (a.y + b.y) / 2,
      w = horiz and (19 + irnd(3)) or 3,
      h = horiz and 3 or (11 + irnd(5)),
    }
    add(nodes, n)
    local ci = #nodes
    -- which way each end faces: from a toward b
    local d1 = (b.x > a.x) and 2 or (b.x < a.x) and 4 or (b.y > a.y) and 3 or 1
    link(e[1], ci, d1)
    link(ci, e[2], d1)
  end

  -- 4. build every node's tile grid, then populate
  for i = 1, #nodes do node_build(nodes[i], d) end

  -- 5. entrance and stairs: furthest node from the start by hops
  local dist = { [1] = 0 }
  local q, qi = { 1 }, 1
  while qi <= #q do
    local n = nodes[q[qi]]
    for _, x in pairs(n.exits) do
      if dist[x.to] == nil then
        dist[x.to] = dist[q[qi]] + 1
        add(q, x.to)
      end
    end
    qi = qi + 1
  end
  local far, fd = 1, -1
  for i = 1, #nodes do
    if nodes[i].kind == "room" and (dist[i] or -1) > fd then far, fd = i, dist[i] end
  end
  stair_node = far
  local n = nodes[far]
  n.stair = { x = flr(n.w / 2), y = flr(n.h / 2) }
  n.tile[n.stair.y][n.stair.x] = T_STAIR

  for i = 1, #nodes do node_populate(nodes[i], d, i) end
  boss_place(d)
  return 1
end

-- Record an exit on both nodes. `dir` is the direction leaving `a`.
function link(a, b, dir)
  nodes[a].exits[dir] = { to = b, back = OPPOSITE[dir] }
  nodes[b].exits[OPPOSITE[dir]] = { to = a, back = dir }
end

-- One node's tile grid. Corridors and chambers go through here identically.
function node_build(n, d)
  -- clamped to the grid itself, not one tile inside it: the camera is framed
  -- on the full grid, so a node that stops short of it wastes screen
  n.w = min(n.w, GW)
  n.h = min(n.h, GH)
  n.ox = flr((GW - n.w) / 2)          -- centre the node in the grid
  n.oy = flr((GH - n.h) / 2)
  n.tile = grid(n.w, n.h, T_FLOOR)
  for y = 0, n.h - 1 do
    for x = 0, n.w - 1 do
      if x == 0 or y == 0 or x == n.w - 1 or y == n.h - 1 then
        n.tile[y][x] = T_WALL
      end
    end
  end

  -- doors, one per exit, centred on the matching wall
  n.door = {}
  for dir = 1, 4 do
    if n.exits[dir] then
      local x, y
      if dir == 1 then x, y = flr(n.w / 2), 0
      elseif dir == 2 then x, y = n.w - 1, flr(n.h / 2)
      elseif dir == 3 then x, y = flr(n.w / 2), n.h - 1
      else x, y = 0, flr(n.h / 2) end
      n.tile[y][x] = T_DOOR
      n.door[dir] = { x = x, y = y }
    end
  end

  -- pillars and puddles, chambers only: a corridor three tiles wide has no
  -- room for either and would just become impassable
  n.props = {}
  n.water = {}
  n.decals = {}
  if n.kind == "room" and n.w >= 11 and n.h >= 9 then
    -- Pillars are placed by *count*, drawn from the lattice, not by rolling
    -- every lattice cell. Rolling each cell at even odds put twelve pillars in
    -- a full-size chamber, which read as a field of crates rather than
    -- architecture -- and because a fixed share of pillars became monuments,
    -- it also meant four statues and shrines standing about in one room.
    -- Counting is also the only way to bound the number: the lattice grows
    -- with the room, so a per-cell probability silently scales with area, the
    -- same trap that took monster density from 2 to 5 (§14).
    if rnd(1) < 0.45 then
      local cand = {}
      for py = 2, n.h - 3, 3 do
        for px = 2, n.w - 3, 3 do add(cand, { x = px, y = py }) end
      end
      local want = min(1 + irnd(4), #cand)
      for i = 1, want do
        local j = irnd(#cand) + 1
        local c = cand[j]
        deli(cand, j)
        n.tile[c.y][c.x] = T_WALL
        -- A monument is meant to be a find. At a fifth of a much larger pillar
        -- count they were furniture; bumping one should be an event.
        local r = rnd(1)
        if r < 0.08 then
          add(n.props, { x = c.x, y = c.y, kind = "shrine",
                         si = irnd(#SHRINES) + 1, used = false })
        elseif r < 0.20 then
          add(n.props, { x = c.x, y = c.y, kind = "statue",
                         si = irnd(#STATUES) + 1 })
        end
      end
    end
    -- A chest or two, on the floor rather than replacing a pillar: you bump
    -- it to open it, and what is inside is rolled from the floor's own loot
    -- table. It exists mostly so the mimic's joke has something to land on.
    for c = 1, irnd(3) do
      local cx, cy = spot(n)
      if cx then
        add(n.props, { x = cx, y = cy, kind = "chest",
                       ii = item_roll(d), used = false })
      end
    end
    if rnd(1) < 0.3 then
      local wx, wy = 2 + irnd(n.w - 6), 2 + irnd(n.h - 5)
      for y = wy, min(wy + 2, n.h - 2) do
        for x = wx, min(wx + 3, n.w - 2) do
          if n.tile[y][x] == T_FLOOR then
            n.tile[y][x] = T_WATER
            -- kept as a list as well as a tile code, so water_draw does not
            -- rescan the whole grid every frame to find a dozen tiles
            add(n.water, { x = x, y = y })
          end
        end
      end
    end
  end

  -- torches on the far walls only (low y, low x): a torch on a near wall
  -- would have its flame hidden by its own bracket
  -- Torches go on all four walls, not just the two far ones. The near walls
  -- are drawn as a 4-voxel sill, so a flame mounted above sill height clears
  -- it and is visible -- the occlusion problem that keeps *detail* off near
  -- faces does not apply to something standing proud of a low wall.
  --
  -- Count is 1..4, picked from the eligible wall tiles at random, not one
  -- every N tiles along every wall. Spacing them evenly lit the whole
  -- perimeter and the room read as flat: a few pools with dark between them
  -- is what makes torchlight look like torchlight.
  n.torch = {}
  local cand = {}
  for x = 1, n.w - 2 do
    if n.tile[0][x] == T_WALL then add(cand, { x = x, y = 0 }) end
    if n.h > 3 and n.tile[n.h - 1][x] == T_WALL then
      add(cand, { x = x, y = n.h - 1 })
    end
  end
  for y = 1, n.h - 2 do
    if n.tile[y][0] == T_WALL then add(cand, { x = 0, y = y }) end
    if n.w > 3 and n.tile[y][n.w - 1] == T_WALL then
      add(cand, { x = n.w - 1, y = y })
    end
  end
  local want = min(n.kind == "corr" and (1 + irnd(2)) or (1 + irnd(4)), #cand)
  for i = 1, want do
    local j = irnd(#cand) + 1
    add(n.torch, { x = cand[j].x, y = cand[j].y, ph = rnd(1), lit = true })
    deli(cand, j)
  end
  if #n.torch == 0 then
    n.tile[0][flr(n.w / 2)] = T_WALL
    add(n.torch, { x = flr(n.w / 2), y = 0, ph = rnd(1), lit = true })
  end
end

function node_free(n, x, y)
  if x < 0 or y < 0 or x >= n.w or y >= n.h then return false end
  local t = n.tile[y][x]
  return t == T_FLOOR or t == T_WATER
end

function node_populate(n, d, idx)
  n.mons, n.items = {}, {}
  if idx == 1 then return end                    -- the entrance is a breather
  local area = n.w * n.h
  -- Density is per *depth*, not per area. When rooms grew from 12x10 to 18x17
  -- the old area/55 quietly went from 2 monsters to 5, all of them inside the
  -- aggro radius of the same room -- which is what made floor 1 lethal.
  local count = clamp(flr(area / 130) + flr(d / 2) + irnd(2), 1, 8)
  if n.kind == "corr" then count = min(count, 2) end
  local crew_id = 0
  for i = 1, count do
    local x, y = spot(n)
    if x then
      local bi = mon_roll(d)
      local b = BESTIARY[bi]
      if b.crew then
        -- they arrive together or not at all: one committee member alone
        -- would be unkillable, since there is nobody left to fail to revive it
        crew_id = crew_id + 1
        for k = 1, b.crew do
          local cx, cy = (k == 1) and x or nil, (k == 1) and y or nil
          if k > 1 then cx, cy = spot(n) end
          if cx then
            local c = mon_new(bi, cx, cy)
            c.crew = crew_id
            add(n.mons, c)
          end
        end
      else
        add(n.mons, mon_new(bi, x, y))
      end
    end
  end
  local loot = 1 + irnd(3)
  for i = 1, loot do
    local x, y = spot(n)
    if x then add(n.items, item_new(item_roll(d), x, y)) end
  end
end

function spot(n)
  for try = 1, 30 do
    local x, y = 1 + irnd(n.w - 2), 1 + irnd(n.h - 2)
    if node_free(n, x, y) and not occupied(n, x, y) then return x, y end
  end
  return nil
end

function occupied(n, x, y)
  for m in all(n.mons or {}) do if m.x == x and m.y == y then return true end end
  for it in all(n.items or {}) do if it.x == x and it.y == y then return true end end
  if prop_at(n, x, y) then return true end
  return false
end

-- ================================================================ 04_light ==
-- The light map is the whole lighting model, and it runs on a finer grid than
-- the tiles: SUB cells to a tile, LS voxels to a cell. Recomputed on a flicker
-- step, not per frame, and read by the run-length painter below.

function lx2v(lx) return OX + lx * LS end        -- light cell -> voxel
function ly2v(ly) return OY + ly * LS end

-- Allocated once per node rather than per flicker step: at three cells to a
-- tile this is 54x54 numbers for a big room, and rebuilding the tables seven
-- times a second is pointless garbage.
function light_alloc()
  LW, LH = node.w * SUB, node.h * SUB
  lmap = grid(LW, LH, 0)
  wmap = grid(LW, LH, false)
  -- light cell -> tile index, precomputed. The RLE pass touches every cell, so
  -- a table lookup here saves a divide and a flr per cell per rebuild, and the
  -- mapping does not depend on the row.
  txof, tyof = {}, {}
  for lx = 0, LW - 1 do txof[lx] = flr(lx / SUB) end
  for ly = 0, LH - 1 do tyof[ly] = flr(ly / SUB) end

  -- Stone texture, as a per-flagstone nudge to the *light level* rather than a
  -- paint colour. Perturbing the light means the mottling reads correctly in
  -- every ramp and at every brightness for free -- a fixed speckle colour
  -- would fight the torchlight and look wrong in half the themes. Derived from
  -- an arithmetic hash, not rnd(), so it does not disturb the PRNG stream that
  -- the dungeon seed depends on.
  --
  -- Switched off in the manifest it stays allocated and all zero, so the RLE
  -- and wall passes read it unconditionally and cost nothing extra -- and with
  -- every tile at its true light level, neighbouring runs merge again.
  mottle = grid(node.w, node.h, 0)
  if TEXTURES then
    for ty = 0, node.h - 1 do
      local mrow = mottle[ty]
      for tx = 0, node.w - 1 do
        local h = (tx * 73 + ty * 151 + node_idx * 37) % 19
        mrow[tx] = (h < 4) and -1 or ((h > 14) and 1 or 0)
      end
    end
  end
end

-- Ragged pool edges, without touching the number of light levels.
--
-- The bands are compass-drawn arcs and it is the most obvious artefact left in
-- the room. Dithering the boundary is the textbook answer and it is the wrong
-- one here: a checkerboard has no runs, so it would wreck the two RLE passes
-- that make the whole light map affordable. Perturbing the *squared distance*
-- per cell instead moves where the band falls rather than what colour a cell
-- takes, so the edge goes organic while the interiors stay solid and the run
-- count only grows along the boundary itself.
--
-- The offsets are scaled by the pool's own radius each time it is walked,
-- because d2 is quadratic: a fixed nudge that shifts a big pool's edge by half
-- a voxel would move a guttering torch's by three. Scaling holds the *outer*
-- edge to about a voxel at any radius. The inner bands move further for the
-- same offset, since the same slope is being read closer to the centre -- so
-- the bright core is the raggedest part of the pool, which is the right way
-- round: it reads as the flame guttering rather than the pool's reach moving.
JIT_N = 32
JIT, JITR = {}, {}
for i = 0, JIT_N - 1 do JIT[i] = (i * 37) % 9 - 4 end
for i = 0, JIT_N - 1 do JITR[i] = 0 end

function jit_scale(r)
  if not FX_JITTER then return end
  local s = r * 0.5
  for i = 0, JIT_N - 1 do JITR[i] = JIT[i] * s end
end

function light_build()
  local n = node
  if not lightfx then
    -- flat mode: one level everywhere, no pools, no flicker
    for y = 0, LH - 1 do
      local lr, wr = lmap[y], wmap[y]
      for x = 0, LW - 1 do lr[x] = FLAT_FLOOR wr[x] = false end
    end
    light_runs()
    return
  end
  for y = 0, LH - 1 do
    local lr, wr = lmap[y], wmap[y]
    for x = 0, LW - 1 do lr[x] = 0 wr[x] = false end
  end

  -- Falloff is Euclidean, so the pools are round. Chebyshev distance is one
  -- subtraction cheaper and gives square pools, which at this resolution look
  -- like a bug rather than a torch. No sqrt is needed: the three band edges
  -- are compared as squared distances.
  for t in all(n.torch) do
    if t.lit then                    -- a snuffed sconce lights nothing
      local cx, cy = t.x * SUB + 1, t.y * SUB + 1
      local r = 5.5 * SUB + sin(t.ph + flicker * 0.11) * 3.0
      local r2, b1, b2 = r * r, (r / 3) * (r / 3), (r * 2 / 3) * (r * 2 / 3)
      local warm2 = (r * 0.62) * (r * 0.62)
      jit_scale(r)
      for y = max(0, flr(cy - r)), min(LH - 1, flr(cy + r)) do
        local lr, wr = lmap[y], wmap[y]
        local dy = y - cy
        local dy2 = dy * dy
        local jrow = (y * 23) % JIT_N
        for x = max(0, flr(cx - r)), min(LW - 1, flr(cx + r)) do
          local dx = x - cx
          local d2 = dx * dx + dy2 + JITR[(x * 9 + jrow) % JIT_N]
          if d2 <= r2 then
            local l = (d2 <= b1) and 3 or ((d2 <= b2) and 2 or 1)
            if l > lr[x] then lr[x] = l end
            if d2 <= warm2 then wr[x] = true end
          end
        end
      end
    end
  end

  -- The hero's own torch, and the reason the torch clock matters. Doused, it
  -- contributes nothing at all -- you keep only what the wall sconces give
  -- you, which is the price of not being seen.
  -- A radius of zero is not "no light": the loop still runs once, over the
  -- hero's own cell, and d2 = 0 <= 0 lights it to full. Doused, the hero was
  -- therefore still standing in a level-3 pool of one cell -- so aggro never
  -- dropped, nothing adjacent was ever in the dark, and the whole mechanic did
  -- nothing while looking as though it worked. The skip has to be explicit.
  local hr = torchlit and (1 + flr(torchfuel / 70)) * SUB or 0
  if spell_light > 0 then hr = hr + 3 * SUB end
  if hr > 0 then
    local hx, hy = hero.tx * SUB + 1, hero.ty * SUB + 1
    local hr2, hb = hr * hr, (hr / 2) * (hr / 2)
    jit_scale(hr)
    for y = max(0, hy - hr), min(LH - 1, hy + hr) do
      local lr, wr = lmap[y], wmap[y]
      local dy = y - hy
      local dy2 = dy * dy
      local jrow = (y * 23) % JIT_N
      for x = max(0, hx - hr), min(LW - 1, hx + hr) do
        local dx = x - hx
        local d2 = dx * dx + dy2 + JITR[(x * 9 + jrow) % JIT_N]
        if d2 <= hr2 then
          local l = (d2 <= hb) and 3 or 2
          if l > lr[x] then lr[x] = l end
          wr[x] = true
        end
      end
    end
  end

  if helm_pot then                                -- +1 armour, -2 vision
    for y = 0, LH - 1 do
      local lr = lmap[y]
      for x = 0, LW - 1 do lr[x] = max(0, lr[x] - 2) end
    end
  end
  light_runs()
end

function cell_tile(lx, ly) return node.tile[flr(ly / SUB)][flr(lx / SUB)] end

function cell_col(lx, ly)
  local t = cell_tile(lx, ly)
  local l = lmap[ly][lx]
  if t == T_WATER then return RAMPS.ice[l + 1] end
  if t == T_DOOR then return RAMPS[theme.accr][l + 1] end
  if t == T_STAIR then return l > 0 and 10 or 4 end
  local r = wmap[ly][lx] and RAMPS[theme.warm] or RAMPS[theme.cold]
  return r[l + 1]
end

-- Run-length encode the floor, then merge identical runs down the rows.
--
-- Painting every light cell would be over two thousand draw calls. The two
-- passes together mean the cost tracks the number of light-level *changes*
-- rather than the resolution: a big unlit stretch of floor collapses back to
-- one box however finely it was sampled, which is what makes a three-times
-- finer light map affordable at all.
function light_runs()
  runs = {}
  local prev = {}
  -- Everything the inner loop needs, hoisted: this runs once per light cell,
  -- which at per-voxel resolution is ~10k times per rebuild. Colour is inlined
  -- rather than called, the tile index comes from a lookup instead of a
  -- divide, and the merge key is an integer rather than a built string.
  local tile = node.tile
  local rw, rc, ice = RAMPS[theme.warm], RAMPS[theme.cold], RAMPS.ice
  local accr = RAMPS[theme.accr]
  for ly = 0, LH - 1 do
    local ty = tyof[ly]
    local trow, mrow = tile[ty], mottle[ty]
    local lrow, wrow = lmap[ly], wmap[ly]
    local cur = {}
    local lx = 0
    while lx < LW do
      local tx = txof[lx]
      local t = trow[tx]
      if t == T_VOID or t == T_WALL then
        lx = lx + 1
      else
        local l = lrow[lx] + mrow[tx]
        if l < 0 then l = 0 elseif l > 3 then l = 3 end
        local c
        if t == T_FLOOR then c = (wrow[lx] and rw or rc)[l + 1]
        elseif t == T_WATER then c = ice[l + 1]
        elseif t == T_DOOR then c = accr[l + 1]
        else c = (l > 0) and 10 or 4 end

        local x0 = lx
        lx = lx + 1
        while lx < LW do
          local tx2 = txof[lx]
          local t2 = trow[tx2]
          if t2 == T_VOID or t2 == T_WALL then break end
          local l2 = lrow[lx] + mrow[tx2]
          if l2 < 0 then l2 = 0 elseif l2 > 3 then l2 = 3 end
          local c2
          if t2 == T_FLOOR then c2 = (wrow[lx] and rw or rc)[l2 + 1]
          elseif t2 == T_WATER then c2 = ice[l2 + 1]
          elseif t2 == T_DOOR then c2 = accr[l2 + 1]
          else c2 = (l2 > 0) and 10 or 4 end
          if c2 ~= c then break end
          lx = lx + 1
        end

        local key = (x0 * 256 + (lx - 1)) * 16 + c
        local p = prev[key]
        if p and p.ly1 == ly - 1 then
          p.ly1 = ly                       -- extend the box downward
          cur[key] = p
        else
          local r = { x0 = x0, x1 = lx - 1, ly0 = ly, ly1 = ly, c = c }
          add(runs, r)
          cur[key] = r
        end
      end
    end
    prev = cur
  end
  wall_runs()
end

-- Walls stay at tile resolution. They are vertical faces read edge-on at this
-- camera, so the extra light detail would not show, and keeping them coarse
-- keeps the pass cheap.
function wall_runs()
  local n = node
  wruns = {}
  for ty = 0, n.h - 1 do
    local tx = 0
    while tx < n.w do
      if n.tile[ty][tx] ~= T_WALL then
        tx = tx + 1
      else
        local l, warm = wall_shade(tx, ty)
        local near = is_near_wall(tx, ty)
        local x0 = tx
        tx = tx + 1
        while tx < n.w and n.tile[ty][tx] == T_WALL
              and is_near_wall(tx, ty) == near do
          local l2, w2 = wall_shade(tx, ty)
          if l2 ~= l or w2 ~= warm then break end
          tx = tx + 1
        end
        add(wruns, { x0 = x0, x1 = tx - 1, ty = ty, l = l, warm = warm,
                     near = near })
      end
    end
  end
end

-- A run carries its light *level*, not a finished colour, because the wall is
-- drawn in three courses and each one wants a different entry of the same
-- ramp. Returning the level is also cheaper than returning a colour: the merge
-- test below compares two integers instead of indexing two ramp tables.
-- Walls bottom out one step above the floor, and that is legibility rather
-- than decoration: index 1 of every ramp is the same navy, so an unlit wall
-- and the unlit floor in front of it were literally the same colour and the
-- room had no shape at all outside the torch pools -- only the capping course
-- gave the edge away, one voxel of it. A floor of level 1 keeps walls reading
-- as boundaries in the dark without lighting what is standing against them.
function wall_shade(tx, ty)
  local m = mottle[ty][tx]
  local lo = FX_WALLFLOOR and 1 or 0
  if not lightfx then return clamp(FLAT_WALL + m, lo, 3), false end
  local lx, ly = tx * SUB + 1, ty * SUB + 1
  return clamp(lmap[ly][lx] + m, lo, 3), wmap[ly][lx]
end

-- ============================================================== 05_render ==
-- A wall on the near edge (max row / max column) is drawn as a low sill.
-- Full height there would stand between the camera and the room.
function is_near_wall(x, y)
  return x == node.w - 1 or y == node.h - 1
end

-- Rooms build up rather than cutting in (§7). The camera cannot move and the
-- cart cannot fade the frame, so a hard cut between nodes is all the engine
-- offers -- but the cart draws every voxel itself, so it can simply withhold
-- most of them for a few frames and let the room assemble. The order is an
-- arithmetic hash of the run index, not rnd(), so it costs nothing and does
-- not touch the PRNG stream the dungeon seed depends on.
DISSOLVE_T = 8

function shown(i)
  if dissolve <= 0 then return true end
  return (i * 37) % DISSOLVE_T < DISSOLVE_T - dissolve
end

function room_draw()
  local n = node
  for i = 1, #runs do
    local r = runs[i]
    if shown(i) then
      boxfill(lx2v(r.x0), ly2v(r.ly0), FLOOR_Z,
              lx2v(r.x1) + LS - 1, ly2v(r.ly1) + LS - 1, FLOOR_B, r.c)
    end
  end
  -- Walls get three courses rather than one flat slab: a capping course on
  -- top, the body, and a skirting at the floor. Each is one extra boxfill per
  -- run, and the renderer's per-face shading does the rest -- it is the
  -- cheapest way to make masonry read as built rather than extruded.
  --
  -- All three take their colour from the run's own light level. They used to
  -- be constants -- the cap the top of the stone ramp, the skirting the bare
  -- accent index -- which meant every wall in the room was capped in the
  -- brightest white it had and skirted in full accent whether it stood under a
  -- torch or in the pitch dark. That drew a bright wireframe over the whole
  -- room and fought the torchlight everywhere: exactly the mistake §2.1b
  -- avoids for the flagstone mottling, made at far greater visual weight. The
  -- cap is a step up the same ramp, so it still reads as a separate course,
  -- and the renderer shades it as a top face anyway.
  local accr = RAMPS[theme.accr]
  for i = 1, #wruns do
    local r = wruns[i]
    if shown(i + 3) then      -- offset so walls and floor do not arrive together
      local ramp = r.warm and RAMPS[theme.warm] or RAMPS[theme.cold]
      local top = r.near and SILL_Z or WALL_Z
      local x0, x1 = vx(r.x0), vx(r.x1) + TS - 1
      local y0, y1 = vy(r.ty), vy(r.ty) + TS - 1
      boxfill(x0, y0, top, x1, y1, FLOOR_Z - 1, ramp[r.l + 1])
      boxfill(x0, y0, top, x1, y1, top, ramp[min(r.l + 2, 4)])      -- capping course
      boxfill(x0, y0, FLOOR_Z - 2, x1, y1, FLOOR_Z - 1, accr[r.l + 1])  -- skirting
    end
  end
  seams_draw()
  water_draw()
  decals_draw()
  arches_draw()
  for t in all(n.torch) do torch_draw(t) end
  for p in all(n.props) do prop_draw(p) end
  if n.stair then stairs_draw(n.stair) end
end

-- A doorway is a gap in the wall, and from across a dark room a gap looks like
-- nothing at all -- which made a node's exits invisible until you were on top
-- of them. A lintel over the opening turns it into a shape you can read from
-- the far side and navigate toward.
--
-- Far walls only. A near wall is a four-voxel sill (§1.2) with nothing above
-- it to arch, and anything built up there would stand between the camera and
-- the room, which is the whole reason the sill is a sill.
function arches_draw()
  if not FX_ARCHES then return end
  local n = node
  for dir = 1, 4 do
    local d = n.door[dir]
    if d and not is_near_wall(d.x, d.y) then
      local l, warm = wall_shade(d.x, d.y)
      local ramp = warm and RAMPS[theme.warm] or RAMPS[theme.cold]
      local x0, x1 = vx(d.x), vx(d.x) + TS - 1
      local y0, y1 = vy(d.y), vy(d.y) + TS - 1
      boxfill(x0, y0, WALL_Z + 1, x1, y1, WALL_Z + 3, ramp[l + 1])
      boxfill(x0, y0, WALL_Z, x1, y1, WALL_Z, ramp[min(l + 2, 4)])
      boxfill(x0, y0, WALL_Z + 4, x1, y1, WALL_Z + 4, RAMPS[theme.accr][l + 1])
    end
  end
end

-- Water cycles its ramp along a travelling sine, so the surface visibly moves
-- (§7). It is drawn over the top of the floor's RLE rather than inside it: the
-- runs are cached and only rebuilt when a light level changes, and animating
-- them per frame would throw away exactly the saving that makes the light map
-- affordable. A puddle is a dozen tiles, so overdrawing it costs a dozen
-- boxfills and leaves the cache alone.
function water_draw()
  if not FX_LIQUID then return end
  local n = node
  for w in all(n.water) do
    local l = clamp(cell_light(w.x, w.y), 0, 3)
    local s = sin(frame * 0.006 + (w.x * 2 + w.y) * 0.09)
    local c = RAMPS.ice[clamp(l + (s > 0.35 and 1 or (s < -0.35 and -1 or 0)),
                              0, 3) + 1]
    boxfill(vx(w.x), vy(w.y), FLOOR_Z, vx(w.x) + TS - 1, vy(w.y) + TS - 1,
            FLOOR_Z, c)
  end
end

-- Blood and scorch stay where they were made, for as long as the floor lasts
-- (§7). Rooms you have fought in look different from rooms you have not, which
-- is the cheapest possible form of memory in a game that cuts hard between
-- them and has a minimap too small to say much.
--
-- They light like everything else, so a stain in an unlit corner is navy and
-- invisible -- the same rule the capping course had to learn. The list is
-- capped because it is drawn every frame and a long fight should not quietly
-- become a draw-call bill.
DECAL_MAX = 20

function decal(tx, ty, ramp)
  if not FX_DECALS then return end
  local n = node
  if not n.decals then n.decals = {} end
  if #n.decals >= DECAL_MAX then deli(n.decals, 1) end
  add(n.decals, { x = tx, y = ty, r = ramp, o = irnd(3) - 1 })
end

function decals_draw()
  if not FX_DECALS then return end
  for d in all(node.decals or {}) do
    local l = clamp(cell_light(d.x, d.y), 0, 3)
    local x, y = vx(d.x) + 2 + d.o, vy(d.y) + 2
    boxfill(x, y, FLOOR_Z, x + 1, y + 1, FLOOR_Z, RAMPS[d.r][l + 1])
  end
end

-- Drawn standing on the pillar tile it replaced, taller than the wall around
-- it so it reads as a monument rather than masonry.
-- Flagstone seams: one long box per major gridline rather than per tile edge.
-- Every tile edge would be right, and would also multiply the floor's run
-- count several times over; every third is enough to read as large slabs.
--
-- A seam is a groove, so it takes the *bottom* of the ramp rather than a mid
-- entry. That is the one colour that is right at every light level without
-- splitting these long boxes per tile: under a torch it reads as a dark line
-- between flagstones, and in an unlit stretch it is the same index as the
-- floor and disappears, which is what an unlit groove should do. At index 2 it
-- was brighter than the floor it crossed wherever the room was dark.
function seams_draw()
  local n = node
  local c = RAMPS[theme.cold][1]
  local x0, x1 = vx(1), vx(n.w - 1) - 1
  local y0, y1 = vy(1), vy(n.h - 1) - 1
  for ty = 3, n.h - 2, 3 do
    boxfill(x0, vy(ty), FLOOR_Z, x1, vy(ty), FLOOR_Z, c)
  end
  for tx = 3, n.w - 2, 3 do
    boxfill(vx(tx), y0, FLOOR_Z, vx(tx), y1, FLOOR_Z, c)
  end
end

function stairs_draw(s)
  local x, y = vx(s.x) + 3, vy(s.y) + 3
  for i = 0, 4 do
    local a = frame * 0.008 + i * 0.2
    local rr = 6 - i
    vset(flr(x + cos(a) * rr), flr(y - sin(a) * rr), FLOOR_Z - i, 10)
    vset(flr(x - cos(a) * rr), flr(y + sin(a) * rr), FLOOR_Z - i, 9)
  end
end

-- A bracket on the wall face that looks at the camera, and a flame that
-- animates through the warm ramp.
function torch_draw(t)
  local x, y = vx(t.x) + 3, vy(t.y) + 3
  -- the bracket always juts into the room, whichever wall it is bolted to
  local ox, oy = 0, 0
  if t.y == 0 then oy = 3
  elseif t.y == node.h - 1 then oy = -3
  elseif t.x == 0 then ox = 3
  else ox = -3 end
  local bx, by = x + ox, y + oy
  boxfill(bx, by, 51, bx, by, 53, 5)
  if not t.lit then
    boxfill(bx - 1, by - 1, 49, bx + 1, by + 1, 50, 5)   -- cold, empty bracket
    return
  end
  local f = flr(frame / 3 + t.ph * 8) % 4
  local cols = { 9, 10, 9, 8 }
  boxfill(bx - 1, by - 1, 49, bx + 1, by + 1, 50, 8)
  boxfill(bx, by, 47 - (f % 2), bx, by, 49, cols[f + 1])
  vset(bx, by, 46 - (f % 2), 10)
end

function prop_draw(p)
  local x, y = vx(p.x) + 3, vy(p.y) + 3
  local l = clamp(cell_light(p.x, p.y), 0, 3)
  local stone = RAMPS.cold[l + 1]
  local dark = RAMPS.cold[max(l, 1)]
  local acc = RAMPS[theme.accr][l + 1]   -- trim obeys the light, like the walls

  if p.kind == "statue" then
    local c = RAMPS.bone[l + 1]
    local hi = RAMPS.bone[min(l + 2, 4)]
    -- stepped plinth with an inscription band, then a figure on top of it
    boxfill(x - 3, y - 3, 55, x + 3, y + 3, 57, stone)
    boxfill(x - 2, y - 2, 52, x + 2, y + 2, 54, dark)
    boxfill(x - 2, y + 2, 53, x + 2, y + 2, 53, acc)           -- brass plaque
    boxfill(x - 2, y - 2, 46, x + 2, y + 2, 51, c)             -- robed body
    boxfill(x - 3, y - 1, 47, x - 3, y + 1, 50, c)             -- arms folded
    boxfill(x + 3, y - 1, 47, x + 3, y + 1, 50, c)
    boxfill(x - 1, y - 1, 41, x + 1, y + 1, 45, hi)            -- head and neck
    boxfill(x - 2, y - 2, 40, x + 2, y + 2, 41, hi)            -- a crown or brow
    vset(x - 1, y + 2, 43, 0)                                  -- carved eyes
    vset(x + 1, y + 2, 43, 0)
  else
    local c = RAMPS[theme.warm][l + 1]
    local live = not p.used
    boxfill(x - 3, y - 3, 55, x + 3, y + 3, 57, stone)          -- base
    boxfill(x - 2, y - 2, 51, x + 2, y + 2, 54, dark)           -- column
    boxfill(x - 3, y - 3, 49, x + 3, y + 3, 50, stone)          -- bowl rim
    boxfill(x - 2, y - 2, 50, x + 2, y + 2, 50,
            live and acc or RAMPS.cold[max(l, 1)])
    if live then
      -- a flame in the bowl, and two motes going round it
      local f = flr(frame / 4) % 3
      boxfill(x - 1, y - 1, 46 - f, x + 1, y + 1, 49, 9)
      boxfill(x, y, 44 - f, x, y, 46, 10)
      local a2 = frame * 0.012
      vset(flr(x + cos(a2) * 4), flr(y - sin(a2) * 4), 47, 10)
      vset(flr(x - cos(a2) * 4), flr(y + sin(a2) * 4), 47, 7)
    else
      boxfill(x - 1, y - 1, 48, x + 1, y + 1, 49, 5)            -- cold ashes
    end
  end
end

-- ============================================================== 06_hero ==
-- Parts, not a sprite: each responds to the light map through its own ramp,
-- so a polished breastplate is yellow-white beside a torch and navy away
-- from one.
function hero_init()
  hero = { tx = 0, ty = 0, px = 0, py = 0, face = 3, anim = 0 }
  hp, hpmax, regen = HP_START, HP_START, 0
  -- Starting armour is 0 on purpose. Damage has a floor of 1 (mon_attack), so
  -- a single point of armour reduces *every* depth-1 monster to that floor and
  -- makes the first floor harmless. The fix for dying on floor 1 was making
  -- armour findable there, not handing it over.
  -- You start bare-handed for the same reason you start unarmoured: floor 1 is
  -- tuned against DMG_BASE, and a weapon is something to find.
  gold, arm = 0, 0
  armv = { helm = 0, chest = 0, shield = 0 }
  helm, chest, shield, helm_pot = false, false, false, false
  wpnv, sigh_t = 0, 0
  wpn_sync()
  torchfuel = 250
  torchlit = true
  stones = 0
  ring, ring_sel = false, 1
  spells = {}
  spell_light, spell_conf, spell_chicken, spell_swap = 0, 0, 0, 0
end

-- The light level the *hero* is standing in, which is what everything else in
-- the node is deciding by.
function aggro_range()
  local l = clamp(hero_light(), 0, 3)
  return flr(AGGRO_DARK + (AGGRO_LIT - AGGRO_DARK) * l / 3 + 0.5)
end

-- arm is derived, never assigned directly: it was a bare counter that every
-- pickup added to, so duplicate helms stacked without limit and armour reached
-- 56 by floor 6 -- past that, every monster in the game does the minimum 1
-- damage and the difficulty is simply off.
function arm_sync()
  arm = armv.helm + armv.chest + armv.shield
  helm = armv.helm > 0
  chest = armv.chest > 0
  shield = armv.shield > 0
  if not helm then helm_pot = false end
end

-- dmg is derived from the weapon slot for the same reason arm is derived from
-- the armour slots: the moment a number is both assigned to directly and
-- meant to represent equipment, the two drift and nothing says so.
function wpn_sync() dmg = DMG_BASE + wpnv end

function hero_place(dir)
  local n = node
  if dir and n.door[dir] then
    local d = n.door[dir]
    hero.tx = clamp(d.x, 1, n.w - 2)
    hero.ty = clamp(d.y, 1, n.h - 2)
  else
    local x, y = spot(n)
    hero.tx, hero.ty = x or flr(n.w / 2), y or flr(n.h / 2)
  end
  hero.px, hero.py = hero.tx, hero.ty
  hero.anim = 0
end

-- Creatures read the light map at their own centre cell, so they light with
-- the floor they stand on.
function cell_light(tx, ty)
  local ly, lx = ty * SUB + 1, tx * SUB + 1
  return (lmap[ly] and lmap[ly][lx]) or 0
end

function hero_light() return cell_light(hero.tx, hero.ty) end

function shade(ramp, boost)
  local l = clamp(hero_light() + (boost or 0), 0, 3)
  return RAMPS[ramp][l + 1]
end

function hero_draw()
  if spell_chicken > 0 then return chicken_draw() end
  local x = flr(vx(0) + hero.px * TS) + 3
  local y = flr(vy(0) + hero.py * TS) + 3
  local sway = (hero.anim > 0 or spell_conf > 0) and (flr(frame / 3) % 2) or 0
  local skin = shade("warm", 1)
  local cloth = shade("blood")

  -- legs, torso, head; detail goes on the +y face, which is the one turned
  -- toward the camera
  boxfill(x - 1, y, 55, x - 1, y, 57, cloth)
  boxfill(x + 1, y, 55, x + 1, y, 57, cloth)
  boxfill(x - 1, y - 1, 52, x + 1, y + 1, 54, chest and shade("cold", 1) or cloth)
  if chest then
    boxfill(x - 1, y + 1, 52, x + 1, y + 1, 53, shade("cold", 2))
  end
  boxfill(x - 1, y - 1, 49 + sway, x + 1, y + 1, 51 + sway, skin)
  if helm then
    boxfill(x - 1, y - 1, 48 + sway, x + 1, y + 1, 49 + sway, helm_pot and 5 or 6)
    vset(x, y + 1, 50 + sway, 0)                -- visor slot
  end
  if shield then
    boxfill(x - 2, y - 1, 52, x - 2, y + 1, 55, shade("cold", 1))
  end
  -- Weapon, angled toward the camera so it is never lost behind the body, and
  -- growing with its rating: armour changes the drawn silhouette (§4) and the
  -- weapon slot should read the same way. Bare-handed draws nothing, which is
  -- the clearest possible statement that you have not found one yet.
  if wpnv > 0 then
    local wz = hero.anim > 0 and 51 or 53
    local blade = wpnv >= 3 and shade("ice", 2) or 6
    boxfill(x + 2, y + 1, wz - wpnv, x + 2, y + 2, wz + 1, blade)
    boxfill(x + 2, y + 1, wz + 1, x + 2, y + 2, wz + 2, 4)      -- grip
  end

  -- A crest, in a fixed colour that ignores the light map entirely -- the only
  -- thing on the hero that does. Everything else here is drawn from `cold`,
  -- `warm` and `blood`, and so is a statue, so an armoured hero standing by a
  -- monument read as a second statue; in an unlit corner he vanished outright.
  -- Two voxels of pink is the whole fix, and it is the trick the monsters'
  -- eyes already use.
  if FX_CREST then
    local hz = (helm and 48 or 49) + sway - 1
    vset(x, y, hz, 14)
    vset(x, y + 1, hz, 14)
  end
  aura_draw(x, y)
end

function chicken_draw()
  local x = flr(vx(0) + hero.px * TS) + 3
  local y = flr(vy(0) + hero.py * TS) + 3
  boxfill(x - 1, y - 1, 54, x + 1, y + 1, 56, 7)
  boxfill(x, y + 1, 52, x, y + 1, 53, 7)
  vset(x, y + 2, 52, 9)
  vset(x - 1, y, 57, 9)
  vset(x + 1, y, 57, 9)
end

function aura_draw(x, y)
  if spell_light <= 0 and spell_conf <= 0 and spell_chicken <= 0 then return end
  local c = spell_light > 0 and 10 or (spell_conf > 0 and 14 or 11)
  for i = 0, 7 do
    local a = frame * 0.02 + i / 8
    vset(flr(x + cos(a) * 5), flr(y - sin(a) * 5), 54 + (i % 2), c)
  end
end

-- ============================================================ 07_monsters ==
-- A monster is data: body plan, ramp, stats, and things to say. Six plans
-- cover the whole menagerie.
BESTIARY = {
  { n = "sewer rat",  plan = "quad",  ramp = "cold",  hp = 3,  dmg = 1, d = 1,
    say = { "SQUEAK. THAT IS ALL" } },
  { n = "goblin intern", plan = "biped", ramp = "moss", hp = 5, dmg = 2, d = 1,
    flee = true, say = { "ONLY HERE FOR THE XP", "IS THIS UNPAID? IT IS." } },
  { n = "sorry slime", plan = "blob", ramp = "moss", hp = 6, dmg = 2, d = 1,
    split = true, say = { "SORRY IN ADVANCE", "NO HARD FEELINGS" } },
  { n = "skeleton",   plan = "biped", ramp = "bone", hp = 8,  dmg = 3, d = 2,
    say = { "I AM ALL BONE, NO PLAN" } },
  -- Armour of its own, four floors before the first boss wears any. It cannot
  -- kill you, so it is where you learn that a bump can be refused.
  { n = "tomb beetle", plan = "quad", ramp = "bone", hp = 7, dmg = 2, d = 2,
    arm = 2, say = { "TAP. TAP. TAP." } },
  { n = "bat cloud",  plan = "swarm", ramp = "cold", hp = 5,  dmg = 2, d = 2,
    erratic = true, say = { "WE HAVE DISCUSSED THIS" } },
  { n = "minor poet", plan = "ghost", ramp = "ice",  hp = 6,  dmg = 1, d = 2,
    calm = true, say = { "I DIED DOING WHAT I",
                         "WHICH WAS, SADLY, THIS" } },
  { n = "mimic",      plan = "blob",  ramp = "warm", hp = 10, dmg = 4, d = 3,
    mimic = true, say = { "OPEN ME. I AM A CHEST.", "A NORMAL CHEST" } },
  { n = "cultist",    plan = "biped", ramp = "blood", hp = 9, dmg = 3, d = 3,
    say = { "THE STARS ARE ALMOST", "GIVE IT A FORTNIGHT" } },
  { n = "hound",      plan = "quad",  ramp = "blood", hp = 9, dmg = 4, d = 3,
    charge = true, say = { "WHO IS A GOOD BOY" } },
  { n = "chandelier rat", plan = "quad", ramp = "warm", hp = 6, dmg = 1, d = 3,
    erratic = true, steal = true,
    say = { "MINE NOW", "I HAVE EXPENSES TOO" } },
  { n = "wraith",     plan = "ghost", ramp = "ice",  hp = 12, dmg = 4, d = 4,
    drain = true, say = { "THAT ARMOUR IS HEAVY", "LET ME TAKE THAT" } },
  { n = "live armour", plan = "biped", ramp = "cold", hp = 14, dmg = 5, d = 4,
    drops = true, say = { "NOBODY IS IN HERE", "STOP ASKING" } },
  { n = "sad ghost",  plan = "ghost", ramp = "cold", hp = 10, dmg = 2, d = 4,
    sigh = true, say = { "I EXPECTED MORE", "SO DID YOUR MOTHER" } },
  -- The only monster that attacks the light map instead of you (2.4)
  { n = "sconce wraith", plan = "ghost", ramp = "gold", hp = 11, dmg = 3, d = 4,
    snuff = true, say = { "LET US TALK IN THE DARK" } },
  { n = "cave troll", plan = "tall",  ramp = "moss", hp = 20, dmg = 6, d = 5,
    smash = true, say = { "TROLL REDECORATING" } },
  { n = "spider",     plan = "quad",  ramp = "bone", hp = 12, dmg = 4, d = 5,
    web = true, say = { "EIGHT LEGS, NO REGRETS" } },
  { n = "the understudy", plan = "biped", ramp = "blood", hp = 13, dmg = 4, d = 5,
    dropw = true, say = { "I KNOW ALL THE LINES", "LET ME HOLD THAT" } },
  { n = "centipede",  plan = "serpent", ramp = "moss", hp = 16, dmg = 4, d = 5,
    train = 2, say = { "ALL OF ME IS THE FRONT" } },
  { n = "lich clerk", plan = "biped", ramp = "ice",  hp = 18, dmg = 5, d = 6,
    say = { "EXPENSES ARE DENIED", "NO RECEIPT, NO REFUND" } },
  { n = "ghost landlord", plan = "ghost", ramp = "warm", hp = 14, dmg = 3, d = 6,
    rent = true, say = { "THAT WILL BE 40 GOLD", "THE DUNGEON ISNT FREE" } },
  { n = "floating eye", plan = "eye", ramp = "blood", hp = 16, dmg = 5, d = 7,
    confuse = true, say = { "I HAVE SEEN YOUR BAG", "YOUR LEFT IS MY RIGHT" } },
  { n = "regret",     plan = "ghost", ramp = "cold", hp = 14, dmg = 4, d = 8,
    follows = true, say = { "REMEMBER WHAT YOU SAID" } },
  -- Follows you anywhere, like Regret, and is slower than you are. You can
  -- outrun it; you cannot lose it.
  { n = "grief",      plan = "ghost", ramp = "ice",  hp = 18, dmg = 4, d = 6,
    follows = true, plod = true, say = { "TAKE YOUR TIME" } },
  { n = "the echo",   plan = "eye",   ramp = "cold", hp = 15, dmg = 3, d = 7,
    echo = true, say = { "SAY THAT AGAIN" } },
  { n = "the auditor", plan = "biped", ramp = "ice", hp = 20, dmg = 4, d = 8,
    audit = true, say = { "THIS IS NOT DEPRECIATED", "SHOW ME THE RECEIPT" } },
  { n = "the committee", plan = "biped", ramp = "bone", hp = 9, dmg = 3, d = 9,
    crew = 3, say = { "WE MOVE TO RECONVENE", "SIX HEADS, ONE BUDGET" } },
  { n = "the manager", plan = "tall", ramp = "blood", hp = 40, dmg = 7, d = 9,
    boss = true, say = { "I MUST ESCALATE THIS",
                         "A PERFORMANCE ISSUE" } },
}

-- Puts out the sconce nearest the wraith, not the one nearest you: it is
-- snuffing the room it is standing in, and the difference shows when it comes
-- at you down a lit corridor.
--
-- A snuffed sconce is not gone. Bumping the wall it hangs on relights it for a
-- turn's cost (try_move), which keeps the light map something you can fight
-- over rather than only lose.
function snuff_torch(m)
  local best, bd = nil, 99
  for t in all(node.torch) do
    if t.lit then
      local d = chebyshev(t.x, t.y, m.x, m.y)
      if d < bd then best, bd = t, d end
    end
  end
  if not best then return false end
  best.lit = false
  sfx_safe("torch_douse")
  burst(best.x, best.y, 10, { 5, 6, 1 })
  light_build()
  return true
end

function torch_at(n, x, y)
  for t in all(n.torch) do if t.x == x and t.y == y then return t end end
  return nil
end

-- ============================================================== 07b_boss ==
-- Every tenth floor is held by a boss, and the stairs do not work until it is
-- dead. That gives a run a shape it did not have -- the only way one used to
-- end was dying -- and it puts a wall across the depth curve at a place the
-- numbers can be tuned for, rather than letting descent run to depth 30 where
-- nothing was ever balanced.
--
-- The fight is built out of the pieces that already exist, not new systems:
--
--   armour   the boss wears its own, subtracting from your damage roll the way
--            yours subtracts from its. Bare-handed you do the floored minimum
--            of 1 and the fight is hopeless arithmetic; the weapon slot is
--            what makes it winnable, so progression is the mechanic.
--   health   its damage is heavy enough to matter against your armour, but it
--            only lands every other turn -- it telegraphs. The wind-up turn is
--            a real turn you may spend: step out of reach, drink, cast, or
--            trade a hit for a hit. That halves incoming damage without
--            halving the threat, and it is legible because the bark says so.
--   drain    every landed strike takes a point off your best armour piece, so
--            the fight erodes the thing keeping you alive and gets worse the
--            longer it runs. Spare pieces and the tidy-kit shrine are the
--            counter-play, which is the armour slots doing their job (§4.2).
--   escalate at each third of its health it calls two monsters from the
--            floor's own roster and its damage goes up. It never introduces a
--            monster you have not already met on the way down.
--
-- Nothing here needs a new verb. You bump it, exactly as you bump everything.
-- Its numbers are not multipliers on a bestiary row, because a multiplier on
-- top of the depth curve compounds into nonsense -- the first attempt gave the
-- depth-10 boss 198 health and 26 damage, a fight needing forty turns that
-- killed a full-health hero in two. They are stated instead as what the fight
-- should *be*: this many landed hits long, costing this share of a full health
-- bar, against the kit the dungeon can actually produce by that depth. The
-- stats fall out of those two numbers and the game's own constants, so they
-- stay correct if the weapon cap or the armour cap ever moves.
BOSS_EVERY = 10          -- a boss floor every tenth depth
BOSS_ARM   = 2           -- subtracted from every hit you land on it, +1 a tier
BOSS_TURNS = 15          -- how many landed hits the fight should take

function boss_index()
  for i = 1, #BESTIARY do if BESTIARY[i].boss then return i end end
  return nil
end

function is_boss_floor(d) return d % BOSS_EVERY == 0 end

-- Placed in the stair node, so the boss is between you and the way down by
-- construction rather than by a rule that has to be enforced somewhere else.
function boss_place(d)
  boss_alive = false
  if not is_boss_floor(d) then return end
  local bi = boss_index()
  if not bi then return end
  local n = nodes[stair_node]
  local x, y = spot(n)
  if not x then return end
  local m = mon_new(bi, x, y)
  m.boss = true
  m.arm = BOSS_ARM + flr(d / BOSS_EVERY) - 1
  -- the kit the dungeon can produce by here: a full weapon slot rolls this on
  -- average, a full set of armour is ARM_MAX, and max health is what diving
  -- this far has bought
  local roll = DMG_BASE + WPN_MAX + 1
  local bar = HP_START + DIVE_MAX * (d - 1)
  m.hp = BOSS_TURNS * max(1, roll - m.arm)
  m.hp0 = m.hp
  -- Damage: exactly cancels a full set of armour at the first boss floor, and
  -- gains a point for every ten the hero's health bar has grown since. Its own
  -- drain does the rest -- by the seventh landed strike there is no armour left
  -- to subtract, which is why a flat number works against this monster and
  -- would not against one that cannot strip it. Swept against the simulation
  -- in tools/deeper_items.py rather than reasoned: escalation and the drain
  -- interact, and the closed form was wrong twice.
  local first = HP_START + DIVE_MAX * (BOSS_EVERY - 1)
  m.dmg = ARM_MAX + flr(max(0, bar - first) / 10)
  m.phase = 0
  m.wind = 0
  add(n.mons, m)
  boss_alive = true
end

-- The boss gets worse as you win. Thirds rather than a smooth curve, so each
-- step is a moment with a line attached to it.
function boss_escalate(m, b)
  local phase = (m.hp <= m.hp0 / 3) and 2 or ((m.hp <= m.hp0 * 2 / 3) and 1 or 0)
  if phase <= m.phase then return end
  m.phase = phase
  m.dmg = m.dmg + 2
  say(b.n, phase == 1 and "I MUST ESCALATE THIS" or "A PERFORMANCE ISSUE")
  sfx_safe("boss_warn")
  local made = 0
  for _, d in pairs(DIRS) do
    if made < 2 then
      local nx, ny = m.x + d[1], m.y + d[2]
      if node_free(node, nx, ny) and not mon_at(nx, ny)
         and not (nx == hero.tx and ny == hero.ty) then
        add(node.mons, mon_new(mon_roll(depth), nx, ny))
        made = made + 1
      end
    end
  end
end

function boss_down(m, b)
  boss_alive = false
  score = score + 500 * depth
  sfx_safe("level_clear")
  burst(m.x, m.y, 40, { 10, 7, 14, 8 })
  -- the reward is a rated piece, so it goes through the same slot rules as
  -- anything else and is refused if you already carry better
  local drop = boss_prize(depth)
  if drop then add(node.items, item_new(drop, m.x, m.y)) end
  say("the way down", "THE STAIRS ARE OPEN")
end

-- The best weapon the dungeon has, or a draught if that slot is already full.
function boss_prize(d)
  local best, bv = nil, wpnv
  for i = 1, #ITEMS do
    local it = ITEMS[i]
    if it.k == "wpn" and it.v > bv then best, bv = i, it.v end
  end
  if best then return best end
  for i = 1, #ITEMS do
    if ITEMS[i].k == "heal" and ITEMS[i].v > 10 then return i end
  end
  return nil
end

-- The deepest thing the book has, worked out rather than written down twice.
MON_DMAX = 0
for i = 1, #BESTIARY do MON_DMAX = max(MON_DMAX, BESTIARY[i].d) end

-- The roster is a sliding five-deep window, so early monsters retire as you
-- descend -- but the window has to stop sliding once its bottom passes the
-- deepest entry in the book. It did not: at depth 14 the range was 10..14, the
-- bestiary tops out at 9, the pool came out empty and the `#pool == 0` guard
-- quietly returned monster 1. Every monster on floors 14 and down was a sewer
-- rat with scaled health, and nothing said so. Same shape as the armour-56
-- bug: the difficulty switched itself off silently.
--
-- Anchoring the window to min(d, MON_DMAX) keeps the last roster in place for
-- however deep the run goes. The boss gate still reads the real depth.
function mon_roll(d)
  local top = min(d, MON_DMAX)
  local pool = {}
  for i = 1, #BESTIARY do
    local b = BESTIARY[i]
    -- bosses are never rolled: they are placed, on their own floor, by
    -- boss_place. One wandering into an ordinary room as a random encounter
    -- was the old behaviour and it is not a boss fight, it is an ambush by
    -- something with forty health.
    if b.d <= top and b.d >= top - 4 and not b.boss then add(pool, i) end
  end
  if #pool == 0 then return 1 end
  return pick(pool)
end

-- Health and damage scale apart, and the split is the whole difficulty curve.
--
-- They used to share one factor, so both grew 2.7x by depth 13 while the hero
-- capped at 7 damage and 7 armour. Armour is a *flat* subtraction, so as
-- monster damage grew it removed a smaller and smaller share of it -- at depth
-- 1 it cancelled a rat outright, at depth 13 it took 39% off the manager. The
-- two curves crossed at depth 9, past which the game was unwinnable in a
-- straight fight even in the best kit the dungeon can produce.
--
-- Health keeps growing; damage stops at DMG_CAP_D. Deep floors are therefore
-- long rather than lethal, which is the honest version of what "deeper" is
-- supposed to feel like -- and because max health keeps rising with depth
-- while incoming damage does not, the hits you can survive now grow faster
-- than the hits you need to land, so the curve converges instead of diverging.
DMG_CAP_D = 8

function mon_new(bi, x, y)
  local b = BESTIARY[bi]
  local hscale = 1 + (depth - 1) * 0.14
  local dscale = 1 + (min(depth, DMG_CAP_D) - 1) * 0.14
  local hp0 = flr(b.hp * hscale)
  local m = {
    bi = bi, x = x, y = y, px = x, py = y, anim = 0,
    hp = hp0, hp0 = hp0, dmg = flr(b.dmg * dscale), said = false, slow = 0,
    arm = b.arm,
  }
  if b.train then
    m.seg = {}
    for i = 1, b.train do add(m.seg, { x = x, y = y }) end
  end
  return m
end

function mon_draw(m)
  local b = BESTIARY[m.bi]
  local l = clamp(cell_light(m.x, m.y), 0, 3)
  local x, y = flr(vx(0) + m.px * TS) + 3, flr(vy(0) + m.py * TS) + 3

  -- A mimic is a chest until it is not. Drawn as the real thing, from the same
  -- function the real thing uses, so there is no tell to spot -- which is the
  -- entire joke and the reason the chest had to exist before the mimic could.
  if b.mimic and not m.angry then
    chest_draw(x, y, l, false)
    return
  end
  if m.down then                       -- a committee member, face down
    boxfill(x - 2, y - 1, 56, x + 2, y + 1, 57, RAMPS[b.ramp][max(l, 1)])
    return
  end

  -- the body first, so the head overlaps it rather than the other way round
  if m.seg then
    local c = RAMPS[b.ramp][l + 1]
    local hi = RAMPS[b.ramp][min(l + 2, 4)]
    for i = #m.seg, 1, -1 do
      local sx = flr(vx(0) + m.seg[i].x * TS) + 3
      local sy = flr(vy(0) + m.seg[i].y * TS) + 3
      boxfill(sx - 2, sy - 2, 53, sx + 2, sy + 2, 56, c)
      boxfill(sx - 2, sy + 2, 54, sx + 2, sy + 2, 55, hi)
      boxfill(sx - 3, sy, 55, sx - 3, sy, 57, c)            -- legs
      boxfill(sx + 3, sy, 55, sx + 3, sy, 57, c)
    end
  end

  plan_draw(b.plan, x, y,
            RAMPS[b.ramp][l + 1], RAMPS[b.ramp][min(l + 2, 4)],
            RAMPS.cold[l + 1], m.x)
  if m.boss then boss_dress(m, x, y, l) end
end

-- A chest, used by the real ones and by the thing pretending to be one.
function chest_draw(x, y, l, open)
  local wood = RAMPS.warm[max(l, 1) + 1]
  local iron = RAMPS.cold[min(l + 1, 3) + 1]
  boxfill(x - 3, y - 2, 53, x + 3, y + 2, 57, wood)          -- the box
  boxfill(x - 3, y - 2, 54, x + 3, y + 2, 54, iron)          -- a band
  boxfill(x - 1, y + 2, 55, x + 1, y + 2, 56, iron)          -- the lock
  if open then
    -- the lid, swung back and up off the far edge
    boxfill(x - 3, y - 3, 49, x + 3, y - 2, 50, wood)
  else
    boxfill(x - 3, y - 2, 51, x + 3, y + 2, 52, wood)        -- lid, shut
    boxfill(x - 3, y - 2, 51, x + 3, y + 2, 51, iron)
  end
end

-- A boss occupies one tile like anything else -- the grid is the grid -- but
-- it is built out past it, because height and overhang are free at this camera
-- and a boss that reads as one more biped is not a boss. A mantle wider than
-- any plan draws, a crown in fixed gold that the light map never touches, and
-- a ring of embers on the floor it stands on so you can see it from the door.
function boss_dress(m, x, y, l)
  local c = RAMPS.blood[max(l, 1) + 1]
  boxfill(x - 5, y - 2, 45, x + 5, y + 2, 47, c)             -- mantle
  boxfill(x - 5, y + 2, 45, x + 5, y + 2, 45, RAMPS.blood[3])
  boxfill(x - 2, y - 1, 37, x + 2, y + 1, 38, 10)            -- crown
  vset(x - 3, y, 36, 10)
  vset(x + 3, y, 36, 10)
  vset(x, y, 35, 10)
  -- embers, and they beat faster once it starts escalating
  local sp = 0.01 + m.phase * 0.006
  for i = 0, 5 do
    local a = frame * sp + i / 6
    vset(flr(x + cos(a) * 7), flr(y - sin(a) * 5), FLOOR_Z - 1,
         m.wind == 1 and 8 or 9)
  end
end

-- Body plans are built from parts rather than a box and a lid: silhouette
-- first (legs, torso, shoulders, head), then the bits that give a species
-- away (horns, snouts, tails), then eyes on the +y face where the camera can
-- see them. Height is free -- z is not constrained by the tile grid the way
-- width is -- so detail goes upward.
--
-- Position and colour come in rather than being looked up from a monster,
-- because the title screen draws the same plans on the demo slab (§13) where
-- there is no tile grid, no node and no light map to look anything up in.
-- `ph` is whatever the caller wants the bob and the swarm's orbit keyed to, so
-- that two monsters standing side by side do not breathe in unison.
function plan_draw(plan, x, y, c, hi, trim, ph)
  local bob = flr(frame / 4 + ph) % 2
  if plan == "biped" then
    boxfill(x - 2, y - 1, 55, x - 1, y + 1, 57, c)          -- legs
    boxfill(x + 1, y - 1, 55, x + 2, y + 1, 57, c)
    boxfill(x - 2, y - 2, 51, x + 2, y + 2, 54, c)          -- torso
    boxfill(x - 3, y - 1, 51, x + 3, y + 1, 52, hi)         -- shoulders
    boxfill(x - 3, y, 53, x - 3, y, 55, c)                  -- arms
    boxfill(x + 3, y, 53, x + 3, y, 55, c)
    boxfill(x - 2, y - 2, 47, x + 2, y + 2, 50, hi)         -- head
    boxfill(x - 2, y - 1, 45, x - 2, y + 1, 46, c)          -- horns
    boxfill(x + 2, y - 1, 45, x + 2, y + 1, 46, c)
    boxfill(x - 2, y + 2, 53, x + 2, y + 2, 53, trim)                     -- belt
    vset(x - 1, y + 2, 48, 8)                               -- eyes, near face
    vset(x + 1, y + 2, 48, 8)
  elseif plan == "quad" then
    boxfill(x - 2, y - 2, 52, x + 2, y + 1, 55, c)          -- barrel
    boxfill(x - 2, y - 2, 56, x - 2, y - 1, 57, c)          -- legs
    boxfill(x + 2, y - 2, 56, x + 2, y - 1, 57, c)
    boxfill(x - 2, y + 1, 56, x - 2, y + 1, 57, c)
    boxfill(x + 2, y + 1, 56, x + 2, y + 1, 57, c)
    boxfill(x - 1, y + 2, 50, x + 1, y + 3, 53, hi)         -- head, thrust out
    boxfill(x - 1, y + 3, 52, x + 1, y + 4, 53, c)          -- snout
    boxfill(x - 1, y + 2, 48, x - 1, y + 2, 49, hi)         -- ears
    boxfill(x + 1, y + 2, 48, x + 1, y + 2, 49, hi)
    boxfill(x - 1, y - 3, 51, x + 1, y - 2, 52, c)          -- tail
    vset(x - 1, y + 4, 51, 8)
    vset(x + 1, y + 4, 51, 8)
  elseif plan == "blob" then
    sphere(x, y, 54 + bob, 4, c)
    sphere(x, y - 1, 53 + bob, 2, hi)                       -- a lighter core
    boxfill(x - 3, y - 1, 57, x + 3, y + 1, 57, c)          -- it spreads
    vset(x - 2, y + 3, 52 + bob, 7)
    vset(x + 2, y + 3, 52 + bob, 7)
    vset(x - 2, y + 3, 53 + bob, 0)
    vset(x + 2, y + 3, 53 + bob, 0)
  elseif plan == "swarm" then
    for i = 0, 5 do
      local a2 = frame * 0.03 + i / 6 + ph
      local sx = flr(x + cos(a2) * 4)
      local sy = flr(y - sin(a2) * 3)
      local sz = 49 + (i % 4) * 2
      boxfill(sx - 1, sy, sz, sx + 1, sy, sz + 1, c)        -- body
      vset(sx - 1, sy + 1, sz, hi)                          -- wings
      vset(sx + 1, sy + 1, sz, hi)
    end
  elseif plan == "tall" then
    boxfill(x - 2, y - 1, 53, x - 1, y + 1, 57, c)          -- legs
    boxfill(x + 1, y - 1, 53, x + 2, y + 1, 57, c)
    boxfill(x - 3, y - 2, 47, x + 3, y + 2, 52, c)          -- slab of a torso
    boxfill(x - 3, y + 2, 48, x + 3, y + 2, 51, hi)         -- chest plate
    boxfill(x - 4, y - 1, 48, x - 4, y + 1, 54, c)          -- long arms
    boxfill(x + 4, y - 1, 48, x + 4, y + 1, 54, c)
    boxfill(x - 2, y - 2, 43, x + 2, y + 2, 46, hi)         -- head
    boxfill(x - 3, y - 1, 41, x - 3, y + 1, 43, c)          -- horns
    boxfill(x + 3, y - 1, 41, x + 3, y + 1, 43, c)
    vset(x - 1, y + 2, 44, 8)
    vset(x + 1, y + 2, 44, 8)
  elseif plan == "serpent" then
    -- Only the head. The body segments are separate tiles and mon_draw walks
    -- them, because a plan draws one tile and a centipede is three.
    boxfill(x - 2, y - 2, 52, x + 2, y + 2, 56, c)          -- head
    boxfill(x - 2, y + 2, 53, x + 2, y + 2, 55, hi)         -- face plate
    boxfill(x - 3, y + 1, 50, x - 2, y + 1, 51, hi)         -- antennae
    boxfill(x + 2, y + 1, 50, x + 3, y + 1, 51, hi)
    boxfill(x - 3, y - 1, 55, x - 3, y + 1, 57, c)          -- legs
    boxfill(x + 3, y - 1, 55, x + 3, y + 1, 57, c)
    vset(x - 1, y + 3, 54, 8)                               -- eyes
    vset(x + 1, y + 3, 54, 8)
  elseif plan == "eye" then
    -- One floating eyeball, hanging clear of the floor. It was drawn with the
    -- `ghost` plan before -- dithered bands, which reads as a wraith -- so the
    -- one monster in the book whose entire name is a description had the least
    -- descriptive body in it.
    --
    -- The white, the iris and the pupil all go on the +y face, the one turned
    -- toward the camera; on any other face they would be hidden by the ball
    -- itself, which is the trap §0 keeps restating. The pupil is colour 0, so
    -- it is a hole bored into the sclera rather than a black voxel -- the same
    -- trick the statues use for carved eyes, and the only way to get true
    -- black out of a 15-colour palette whose index 0 means empty.
    local z = 49 + bob
    sphere(x, y, z, 3, c)                                   -- the ball
    -- The white is built on the two frontmost layers so it wraps the curve
    -- rather than sitting on it as a decal, and the iris is a vertical bar
    -- through the middle of it. The pupil is bored at y + 3, the sphere's own
    -- front face: the first attempt bored at y + 4, which is outside a radius
    -- of 3, so it carved empty air and the eye had no pupil at all.
    boxfill(x - 1, y + 2, z - 1, x + 1, y + 2, z + 1, 7)
    boxfill(x - 1, y + 3, z - 1, x + 1, y + 3, z + 1, 7)
    -- The iris is a ring, not a bar. A vertical bar down the middle left white
    -- standing either side of it and the whole face read as a mouth with
    -- teeth; a ring round the pupil reads as an eye at a glance, which is the
    -- only test that matters for something ten voxels tall.
    boxfill(x - 1, y + 3, z - 1, x + 1, y + 3, z - 1, hi)
    boxfill(x - 1, y + 3, z + 1, x + 1, y + 3, z + 1, hi)
    vset(x - 1, y + 3, z, hi)
    vset(x + 1, y + 3, z, hi)
    vset(x, y + 3, z, 0)                                    -- pupil
      -- three trailing nerves, the middle one longer, so it reads as hanging
    for i = -1, 1 do
      boxfill(x + i * 2, y - 1, z + 3, x + i * 2, y, z + 5 + (i == 0 and 2 or 0),
              hi)
    end
  else
    ghost_draw(x, y, c, hi, bob)
  end
end

-- Voxels are opaque and there is no alpha, so a ghost is drawn as horizontal
-- bands with gaps, the phase alternating. In a raymarcher that reads as
-- translucent and shimmering -- and it is five draw calls, not two hundred
-- vsets, which per-voxel dithering would have cost.
function ghost_draw(x, y, c, hi, bob)
  local ph = flr(frame / 4) % 2
  for i = 0, 4 do
    local z = 49 + i * 2 + bob
    if (i + ph) % 2 == 0 then
      local w = (i < 2) and 1 or 2
      boxfill(x - w, y - 1, z, x + w, y + 1, z, c)
    end
  end
  vset(x - 1, y + 1, 51 + bob, 7)
  vset(x + 1, y + 1, 51 + bob, 7)
end

-- ============================================================== 08_items ==
ITEMS = {
  { n = "gold",         k = "gold" },
  { n = "bread",        k = "heal", v = 6 },
  { n = "torch oil",    k = "oil",  v = 120 },
  -- v is the slot rating, not a bonus: armour is three slots, and a piece
  -- replaces what is in its slot only if it is better. Best possible loadout
  -- is 2 + 3 + 2 = 7, which is the number the whole damage curve is tuned to.
  { n = "pot helm",     k = "helm",   v = 1, pot = true },
  { n = "steel helm",   k = "helm",   v = 2 },
  { n = "breastplate",  k = "chest",  v = 3 },
  { n = "kite shield",  k = "shield", v = 2 },
  { n = "scroll of fireball",  k = "spell", s = "fireball" },
  { n = "scroll of light",     k = "spell", s = "light" },
  { n = "mild inconvenience", k = "spell", s = "annoy" },
  { n = "confidence potion", k = "spell", s = "confidence" },
  { n = "percussion scroll", k = "spell", s = "percussion" },
  { n = "chicken potion",   k = "spell", s = "chicken" },
  -- appended, not inserted: item_roll's pool and the live-armour drop refer
  -- to these by index, and renumbering the table would silently reassign them
  { n = "healing draught",  k = "heal", v = 14 },
  -- Weapons, one rated slot: v is the rating, not a bonus, and a worse one is
  -- refused and left on the floor exactly as a worse helm is. Best is 4, so
  -- the best bump in the game does DMG_BASE + 4 + irnd(3) = 6..8 against
  -- monsters carrying at most 2.7x their floor-1 health.
  { n = "sharp stick",      k = "wpn",  v = 1 },
  { n = "short sword",      k = "wpn",  v = 2 },
  { n = "war hammer",       k = "wpn",  v = 3 },
  { n = "rune blade",       k = "wpn",  v = 4 },
  -- Appended, again, and for the reason the note above gives: slotting stones
  -- in beside the weapons where they read best moved every weapon index by
  -- one, so item_roll's ladder quietly handed out stones where it meant a
  -- sharp stick and never rolled the rune blade at all. Grouping in this table
  -- is cosmetic; position is load-bearing.
  { n = "throwing stones",  k = "stone", v = 3 },
}

-- Food is deliberately common. Natural regen (REGEN) is slow enough that it
-- only pays for retreating, so bread and draughts are what actually carry you
-- between fights.
function item_roll(d)
  local pool = { 1, 1, 1, 2, 2, 2, 2, 14, 14, 3, 3, 19, 19, 8, 9, 10, 11, 12, 13 }
  -- Every armour piece used to be gated behind d >= 2, which meant the one
  -- floor where you have no armour at all was also the only floor where none
  -- could drop. Helms and breastplates now appear from the start, which puts
  -- floor 1's ceiling at 5 of the maximum 7; shields still wait for floor 2,
  -- so there is somewhere left to go.
  add(pool, 4) add(pool, 5) add(pool, 6)
  if d >= 2 then add(pool, 7) end
  -- Weapons ladder the same way armour does: something to find on floor 1, and
  -- somewhere left to go for five floors after it. One entry each, so the slot
  -- fills slower than armour's three do.
  add(pool, 15)
  if d >= 2 then add(pool, 16) end
  if d >= 4 then add(pool, 17) end
  if d >= 6 then add(pool, 18) end
  return pick(pool)
end

function item_new(ii, x, y) return { ii = ii, x = x, y = y } end

function item_draw(it)
  local d = ITEMS[it.ii]
  local x = flr(vx(0) + it.x * TS) + 3
  local y = flr(vy(0) + it.y * TS) + 3
  local bob = flr(frame / 6) % 2
  local z = 55 + bob
  if d.k == "gold" then
    boxfill(x - 1, y - 1, z, x + 1, y + 1, z + 1, 10)
  elseif d.k == "spell" then
    boxfill(x - 1, y, z - 1, x + 1, y, z + 1, 7)
    vset(x, y + 1, z, 14)
  elseif d.k == "heal" then
    boxfill(x - 1, y - 1, z, x + 1, y, z + 1, 4)
  elseif d.k == "oil" then
    boxfill(x, y, z - 1, x, y, z + 1, 9)
    vset(x, y + 1, z - 1, 10)
  elseif d.k == "wpn" then
    -- lying point-up, and the better it is the taller it stands
    boxfill(x, y, z - 1 - d.v, x, y, z, d.v >= 3 and 12 or 6)
    boxfill(x - 1, y, z, x + 1, y, z, 4)                    -- crossguard
  else
    boxfill(x - 1, y - 1, z, x + 1, y + 1, z + 1, d.pot and 5 or 6)
    vset(x, y + 1, z, 7)
  end
end

function item_take(it)
  local d = ITEMS[it.ii]
  if d.k == "gold" then
    local g = 5 + irnd(10 + depth * 4)
    gold = gold + g
    say("you", "PICKED UP " .. g .. " GOLD")
    sfx_safe("coin_pickup")
  elseif d.k == "heal" then
    hp = min(hpmax, hp + d.v)
    say("you", "THE BREAD IS FINE")
    sfx_safe("potion_powerup")
  elseif d.k == "oil" then
    torchfuel = min(400, torchfuel + d.v)
    say("you", "TORCH TOPPED UP")
    sfx_safe("potion_powerup")
  elseif d.k == "stone" then
    stones = stones + d.v
    say("you", "STONES x" .. d.v)
    sfx_safe("coin_pickup")
  elseif d.k == "wpn" then
    if d.v <= wpnv then
      say("you", "YOURS IS BETTER")
      return false                       -- leave it on the floor, unclaimed
    end
    wpnv = d.v
    wpn_sync()
    say("you", "YOU SWING IT ONCE")
    sfx_safe("armour_equip")
  elseif d.k == "helm" or d.k == "chest" or d.k == "shield" then
    if d.v <= armv[d.k] then
      say("you", "ALREADY WEARING BETTER")
      return false                       -- leave it on the floor, unclaimed
    end
    armv[d.k] = d.v
    if d.k == "helm" then helm_pot = d.pot and true or false end
    arm_sync()
    say("you", d.pot and "IT FITS. YOU CANT SEE" or ARM_MSG[d.k])
    sfx_safe("armour_equip")
  elseif d.k == "spell" then
    add(spells, d.s)
    say("you", "TOOK " .. d.n)
    sfx_safe("scroll_pickup")
  end
  return true
end

-- ============================================================== 09_spells ==
SPELLINFO = {
  fireball   = { c = 8,  n = "fireball" },
  light      = { c = 10, n = "light" },
  annoy      = { c = 12, n = "mild inconvenience" },
  confidence = { c = 14, n = "confidence" },
  percussion = { c = 6,  n = "percussion" },
  chicken    = { c = 7,  n = "chicken" },
}

function cast(s)
  local hx, hy = hero.tx, hero.ty
  last_spell = s
  if s == "fireball" then
    sfx_safe("fireball_blast")
    burst(hx, hy, 40, { 8, 9, 10, 7 })
    for i = #node.mons, 1, -1 do
      local m = node.mons[i]
      if chebyshev(m.x, m.y, hx, hy) <= 3 then mon_hurt(i, 8 + depth) end
    end
    say("you", "WHOOMPH")
  elseif s == "light" then
    spell_light = 60
    sfx_safe("light_powerup")
    burst(hx, hy, 24, { 10, 7, 9 })
    say("you", "LET THERE BE LIGHT")
  elseif s == "annoy" then
    sfx_safe("scroll_warp")
    for m in all(node.mons) do m.slow = 4 end
    say("you", "THEY DROPPED THEIR KIT")
  elseif s == "confidence" then
    spell_conf = 40
    sfx_safe("potion_powerup")
    burst(hx, hy, 20, { 14, 8, 10 })
    say("you", "YOU FEEL VERY READY")
  elseif s == "percussion" then
    sfx_safe("percussion_smash")
    shake = 8
    for m in all(node.mons) do
      local dx, dy = isgn(m.x - hx), isgn(m.y - hy)
      if node_free(node, m.x + dx * 2, m.y + dy * 2) then
        m.x, m.y = m.x + dx * 2, m.y + dy * 2
        m.px, m.py = m.x, m.y
      end
      m.slow = 2
    end
    -- Breaking your weapon costs a point of the *slot*, so the repair path is
    -- the acquisition path -- find a better one, or a whetstone shrine. With
    -- nothing in hand there is nothing to break.
    if rnd(1) < 0.1 and wpnv > 0 then
      wpnv = wpnv - 1
      wpn_sync()
      say("you", "YOU CHIPPED YOUR BLADE")
    else
      say("you", "PERCUSSIVE MAINTENANCE")
    end
  elseif s == "chicken" then
    spell_chicken = 50
    sfx_safe("chicken_morph")
    burst(hx, hy, 20, { 7, 10, 9 })
    say("you", "THIS WAS NOT THE PLAN")
  end
end

-- ================================================================= 09b_ring ==
-- Hold z, arrows select, release to use. Six buttons is the whole input
-- surface (§9), so everything that is not a step or a bump has to share one --
-- and a list you scroll needs no cursor and no menu screen.
--
-- z used to cast `spells[1]` and nothing else: no choice at all, and a
-- fireball you were saving went off because it happened to be first. The ring
-- also gives the two new verbs somewhere to live without spending a button
-- each, which is the reason a torch and a handful of stones sit in the same
-- list as a scroll. They are the same kind of thing: what you can do this turn
-- that is not walking into something.
function ring_items()
  local r = {}
  add(r, { k = "torch", n = torchlit and "douse torch" or "light torch",
           c = torchlit and 9 or 5 })
  if stones > 0 then
    add(r, { k = "stone", n = "stones x" .. stones, c = 6 })
  end
  for i = 1, #spells do
    add(r, { k = "spell", s = spells[i], i = i,
             n = SPELLINFO[spells[i]].n, c = SPELLINFO[spells[i]].c })
  end
  return r
end

function ring_use(sel)
  local r = ring_items()
  local e = r[sel]
  if not e then return end
  if e.k == "torch" then
    torchlit = not torchlit
    say("you", torchlit and "THE TORCH CATCHES" or "YOU PINCH IT OUT")
    sfx_safe(torchlit and "torch_light" or "torch_douse")
  elseif e.k == "stone" then
    -- a throw that finds nothing costs no turn: it never happened
    if not throw_stone() then return end
  else
    deli(spells, e.i)
    cast(e.s)
  end
  end_turn()
end

-- Stones aim themselves at the nearest monster sharing a row or column with
-- clear ground between. Automatic, because the arrows are busy selecting while
-- the ring is open and a second aiming mode would need a button there is not
-- one of -- and because lining yourself up with something is already a real
-- decision on a grid, so making that *be* the aim rewards positioning.
function throw_stone()
  local bi, bd = nil, 99
  for i = 1, #node.mons do
    local m = node.mons[i]
    if m.x == hero.tx or m.y == hero.ty then
      local d = chebyshev(m.x, m.y, hero.tx, hero.ty)
      if d > 1 and d < bd and clear_line(m.x, m.y) then bi, bd = i, d end
    end
  end
  if not bi then
    say("you", "NOTHING LINES UP")
    sfx_safe("deny_error")
    return false
  end
  local m = node.mons[bi]
  stones = stones - 1
  sfx_safe("stone_throw")
  -- the stone's flight, as particles along the line it took
  local sx, sy = vx(hero.tx) + 3, vy(hero.ty) + 3
  local ex, ey = vx(m.x) + 3, vy(m.y) + 3
  for i = 1, 6 do
    local t = i / 7
    add(parts, { x = lerp(sx, ex, t), y = lerp(sy, ey, t), z = 52,
                 vx = 0, vy = 0, vz = 0, life = 4 + i, cols = { 6, 7 } })
  end
  mon_hurt(bi, STONE_DMG + irnd(3))
  return true
end

-- Unobstructed along a row or column: no wall, and nothing else standing in
-- the way. Only ever walks one axis, so it is a loop and not a Bresenham.
function clear_line(tx, ty)
  local dx, dy = isgn(tx - hero.tx), isgn(ty - hero.ty)
  local x, y = hero.tx + dx, hero.ty + dy
  while x ~= tx or y ~= ty do
    if not node_free(node, x, y) then return false end
    if mon_at(x, y) then return false end
    x, y = x + dx, y + dy
  end
  return true
end

-- The echo repeats your own last spell, aimed at you. Half the table is a
-- gift when it lands -- an echo is not clever, it is only loud -- and the two
-- that hurt are the two you were pleased with when you cast them.
function echo_cast(b, s)
  say(b.n, "SAY THAT AGAIN")
  sfx_safe("scroll_warp")
  if s == "fireball" then
    hp = hp - max(1, 6 + depth - arm)
    burst(hero.tx, hero.ty, 24, { 8, 9, 10 })
    shake = 6
    if hp <= 0 then die(b.n) end
  elseif s == "chicken" then
    spell_chicken = 30
    burst(hero.tx, hero.ty, 12, { 7, 10 })
  elseif s == "percussion" then
    shake = 8
    sigh_t = SIGH_T
  elseif s == "annoy" then
    spell_swap = 5
  elseif s == "light" then
    spell_light = 30                      -- thank you
  else
    spell_conf = 20                       -- also thank you
  end
end

-- =================================================================== 10_fx ==
function burst(tx, ty, n, cols)
  local x = vx(0) + tx * TS + 3
  local y = vy(0) + ty * TS + 3
  for i = 1, n do
    if #parts >= MAX_PART then return end
    add(parts, {
      x = x, y = y, z = 54,
      vx = (rnd(2) - 1) * 1.4, vy = (rnd(2) - 1) * 1.4, vz = (rnd(2) - 1) * 1.1,
      life = 10 + rnd(14), cols = cols,
    })
  end
end

-- Damage prints in the world, over the thing that took it, and it is exact
-- rather than guessed. The cart is never told where the camera is, so a number
-- placed "near the monster on screen" would be arithmetic on a projection it
-- cannot do -- the reason §5.4 put barks in a fixed banner. But `print` draws
-- on a y-slice, so setting the slice to the target's own y and printing at its
-- x puts the glyphs in the world at exactly the right place, for free, with no
-- projection at all. It rises by drifting up the z axis as its life runs out.
DMGNUM_T = 15

function dmgnum(tx, ty, amount)
  if not FX_DMGNUM then return end
  add(dmgnums, {
    x = vx(tx) + 3 - (amount > 9 and 4 or 2), y = vy(ty) + 3,
    n = amount, life = DMGNUM_T,
  })
end

function dmgnums_update()
  for i = #dmgnums, 1, -1 do
    local d = dmgnums[i]
    d.life = d.life - 1
    if d.life <= 0 then deli(dmgnums, i) end
  end
end

function dmgnums_draw()
  for d in all(dmgnums) do
    set_draw_slice(d.y)
    -- warm while it is fresh, fading through the ramp as it climbs
    local c = d.life > 10 and 7 or (d.life > 5 and 10 or 9)
    print(d.n, d.x, 42 - flr((DMGNUM_T - d.life) / 3), c)
  end
end

function parts_update()
  for i = #parts, 1, -1 do
    local p = parts[i]
    p.x = p.x + p.vx
    p.y = p.y + p.vy
    p.z = p.z + p.vz
    p.vz = p.vz + 0.06
    p.life = p.life - 1
    if p.life <= 0 or p.x < 1 or p.x > 126 or p.y < 1 or p.y > 126
       or p.z < 1 or p.z > 62 then
      deli(parts, i)
    end
  end
end

-- Particles colour themselves by life remaining, so every effect fades
-- through its ramp without any extra bookkeeping.
function parts_draw()
  for p in all(parts) do
    local t = clamp(flr(p.life / 6), 0, #p.cols - 1)
    vset(flr(p.x), flr(p.y), flr(p.z), p.cols[t + 1])
  end
end

-- ================================================================= 11_turn ==
function try_move(dir)
  hero.face = dir
  local n = node

  -- Confusion scrambles where you *walk*, not where you swing: a bump at
  -- something already beside you always lands, so the attack is resolved
  -- against the direction you actually pressed.
  --
  -- Inverting attacks too made the floating eye unkillable, and not in the way
  -- it looked: the inverted step walked the hero off, the eye chased into the
  -- square they had left, and the bump after that swung at empty floor. The
  -- combat probe found it in one run -- 484 bumps against a 16-health monster
  -- that never died. "You cannot fight it" is a lockout, not a joke.
  local ad = DIRS[dir]
  local ax, ay = hero.tx + ad[1], hero.ty + ad[2]

  for i = #n.mons, 1, -1 do
    local m = n.mons[i]
    if mon_covers(m, ax, ay) then
      local roll = max(1, dmg + irnd(3) + (spell_conf > 0 and 3 or 0)
                          - (sigh_t > 0 and 2 or 0))
      if spell_conf > 0 and rnd(1) < 0.35 then
        say("you", "A CONFIDENT MISS")
      elseif spell_chicken > 0 then
        say("you", "CHICKENS HAVE NO HANDS")
      else
        mon_hurt(i, roll)
      end
      end_turn()
      return
    end
  end

  -- nothing there to hit: now the confusion gets to decide where you go
  if spell_swap > 0 then dir = OPPOSITE[dir] end
  local d = DIRS[dir]
  local nx, ny = hero.tx + d[1], hero.ty + d[2]

  if nx < 0 or ny < 0 or nx >= n.w or ny >= n.h then return end
  local t = n.tile[ny][nx]

  for p in all(n.props) do
    if p.x == nx and p.y == ny then
      prop_touch(p)
      end_turn()
      return
    end
  end

  if t == T_DOOR then
    local ex = n.exits[dir]
    if ex then
      local chasers = door_chasers(n)
      enter(ex.to, ex.back)
      door_arrive(chasers)
      -- a doorway costs a turn like any other step, or the torch never burns
      -- while you travel and whatever is waiting in the next node gets no move
      end_turn()
    end
    return
  end
  if t == T_STAIR then
    -- On a boss floor the stairs are the reward for the fight, not a way past
    -- it. Refusing costs a turn like any other bump, so standing on them
    -- hoping is not free while something is walking toward you.
    if boss_alive then
      say("the way down", "SOMETHING STILL OWNS THIS")
      sfx_safe("deny_error")
      end_turn()
    else
      descend()
    end
    return
  end
  if t == T_WALL then
    -- a dead sconce is worth a turn to bring back
    local tt = torch_at(n, nx, ny)
    if tt and not tt.lit and torchlit then
      tt.lit = true
      say("you", "THE SCONCE CATCHES")
      sfx_safe("torch_light")
      light_build()
      end_turn()
    end
    return
  end

  hero.tx, hero.ty = nx, ny
  hero.anim = MOVE_FR
  for i = #n.items, 1, -1 do
    local it = n.items[i]
    if it.x == nx and it.y == ny then
      -- Scrolls and potions ask first. Everything else is unambiguously good
      -- and taking it silently is the right call; a chicken potion is not.
      if ITEMS[it.ii].k == "spell" and not it.declined then
        pending = it
      elseif item_take(it) then
        deli(n.items, i)
      end
    end
  end
  -- walking off a refused scroll lets it ask again next time
  for it in all(n.items) do
    if it.x ~= hero.tx or it.y ~= hero.ty then it.declined = false end
  end
  end_turn()
end

-- Anything angry and within reach when you step through a doorway may come
-- with you. Retreat was a total escape before -- nothing followed, so any
-- fight could be ended by walking through a door, and the two-rate regen built
-- to make breaking off a decision (§4.1) was deciding nothing. It keeps its
-- health and its temper, so retreating buys you distance, not a fresh fight.
--
-- Capped, because a doorway that teleports six monsters onto you is not a
-- decision either.
function door_chasers(n)
  local out = {}
  for i = #n.mons, 1, -1 do
    local m = n.mons[i]
    if #out < FOLLOW_MAX and m.angry and not m.boss
       and chebyshev(m.x, m.y, hero.tx, hero.ty) <= 1
       and rnd(1) < FOLLOW_ODDS then
      add(out, m)
      deli(n.mons, i)
    end
  end
  return out
end

function door_arrive(chasers)
  local n = node
  local came = 0
  for m in all(chasers) do
    for _, d in pairs(DIRS) do
      local nx, ny = hero.tx + d[1], hero.ty + d[2]
      if node_free(n, nx, ny) and not mon_at(nx, ny) then
        m.x, m.y, m.px, m.py, m.anim = nx, ny, nx, ny, 0
        add(n.mons, m)
        came = came + 1
        break
      end
    end
  end
  if came > 0 then
    say("you", came > 1 and "THEY CAME TOO" or "IT CAME TOO")
    sfx_safe("ghost_warn")
  end
end

-- A statue talks. A shrine does one thing, once, and then only talks.
function prop_touch(p)
  if p.kind == "chest" then
    if p.used then
      say("the chest", "EMPTY. YOU EMPTIED IT.")
      return
    end
    p.used = true
    sfx_safe("chest_open")
    burst(p.x, p.y, 14, { 10, 9, 7 })
    -- the contents land beside it rather than under it, since you cannot
    -- stand where the chest is
    for _, d in pairs(DIRS) do
      local nx, ny = p.x + d[1], p.y + d[2]
      if node_free(node, nx, ny) and not occupied(node, nx, ny) then
        add(node.items, item_new(p.ii, nx, ny))
        break
      end
    end
    say("the chest", "IT WAS A REAL CHEST")
    return
  end
  if p.kind == "statue" then
    local st = STATUES[p.si]
    say(st.n, st.say)
    sfx_safe("ui_click")
    return
  end
  local sh = SHRINES[p.si]
  if p.used then
    say(sh.n, "SPENT. IT WAS NICE ONCE")
    sfx_safe("deny_error")
    return
  end
  -- The wish well is the one shrine that asks for something, and it is the
  -- only sink gold has ever had: it accumulated all run, fed the score, and
  -- the ghost landlord took some of it away, which is a tax rather than a
  -- choice. Priced against depth so a late purse still buys about one favour.
  -- Checked before the shrine is marked spent -- being unable to afford it is
  -- not the same as having used it, and it should still be there when you can.
  if sh.k == "wish" then
    local cost = 30 + depth * 10
    if gold < cost then
      say(sh.n, "IT WANTS " .. cost .. " GOLD")
      sfx_safe("deny_error")
      return
    end
    gold = gold - cost
    hp = min(hpmax, hp + 12)
    torchfuel = min(400, torchfuel + 140)
  end

  p.used = true
  -- Six kinds, and an unrecognised one still speaks and is still spent: the
  -- list is authored in the manifest, so a typo there should read as a shrine
  -- that did nothing much rather than stop the game.
  if sh.k == "heal" then
    hp = min(hpmax, hp + 8)
  elseif sh.k == "torch" then
    torchfuel = 400
  elseif sh.k == "gold" then
    gold = gold + 20 + irnd(30)
  elseif sh.k == "whet" then
    -- the weapon slot's answer to the tidy-kit altar: one point back, capped,
    -- and nothing at all if you are still swinging your fists
    if wpnv > 0 and wpnv < WPN_MAX then wpnv = wpnv + 1 wpn_sync() end
  elseif sh.k == "arm" then
    -- repairs the most damaged piece you are actually wearing, which ties the
    -- shrine to the armour slots rather than inventing a second currency
    local wk, wv = nil, 99
    for i = 1, #ARM_KINDS do
      local k = ARM_KINDS[i]
      if armv[k] > 0 and armv[k] < wv then wk, wv = k, armv[k] end
    end
    if wk then armv[wk] = wv + 1 arm_sync() end
  end
  say(sh.n, sh.say)
  sfx_safe("shrine_powerup")
  burst(p.x, p.y, 16, { 10, 7, 12 })
end

function end_turn()
  turns = turns + 1
  -- Fuel only burns while it is lit, so dousing conserves it as well as hiding
  -- you. That is deliberate: it makes the stealth dial and the clock the same
  -- dial, rather than two systems asking for the player's attention separately.
  if torchlit then torchfuel = max(0, torchfuel - 1) end
  regen = regen + 1
  if regen >= (hunted() and REGEN or REGEN_CALM) then
    regen = 0
    if hp < hpmax then hp = hp + 1 end
  end
  if sigh_t > 0 then sigh_t = sigh_t - 1 end
  if spell_light > 0 then spell_light = spell_light - 1 end
  if spell_conf > 0 then spell_conf = spell_conf - 1 end
  if spell_chicken > 0 then spell_chicken = spell_chicken - 1 end
  if spell_swap > 0 then spell_swap = spell_swap - 1 end
  if torchfuel == 0 and turns % 40 == 0 then
    say("you", "THE DARK IS PERSONAL")
  end
  mons_turn()
  crew_turn()
  light_build()
end

-- Is anything in this node actually after us? Drives the regen rate, so that
-- retreating pays off quickly instead of being a long walk.
function hunted()
  for m in all(node.mons) do
    if m.angry or chebyshev(m.x, m.y, hero.tx, hero.ty) <= AGGRO then
      return true
    end
  end
  return false
end

function mons_turn()
  local n = node
  for i = #n.mons, 1, -1 do
    -- Stop the moment the hero is down. Without this the loop ran on and every
    -- remaining monster attacked the corpse: die() fired once per attacker,
    -- each one resetting the death screen's own timer, replaying the death
    -- sound and the music, spawning another burst, and overwriting `killer` --
    -- so the screen named whoever hit last rather than whoever killed you.
    if mode ~= "play" then return end
    local m = n.mons[i]
    local b = BESTIARY[m.bi]
    if m.slow > 0 then
      m.slow = m.slow - 1
    elseif b.plod and turns % 2 == 1 then
      -- Slower than you are, and that is the whole threat: `follows` means it
      -- never loses you, `plod` means you can always walk away from it. The
      -- pair is what makes it dread rather than danger.
    else
      local d = chebyshev(m.x, m.y, hero.tx, hero.ty)
      if m.fleeing then
        -- took what it came for
        mon_step(m, isgn(m.x - hero.tx), isgn(m.y - hero.ty))
      elseif d <= 1 then
        mon_attack(m, b)
      elseif d <= aggro_range() or b.follows then
        if b.calm and not m.angry then
          if not m.said then bark(m, b) end
        else
          -- A sconce wraith puts out the room before it comes for you. It is
          -- the only monster that attacks the light map rather than the hero,
          -- and it does it once, on the turn it notices you (2.4).
          if b.snuff and not m.snuffed then
            m.snuffed = true
            if snuff_torch(m) then say(b.n, "LET US TALK IN THE DARK") end
          end
          local dx = isgn(hero.tx - m.x)
          local dy = isgn(hero.ty - m.y)
          if b.erratic and rnd(1) < 0.4 then
            dx, dy = irnd(3) - 1, irnd(3) - 1
          end
          mon_step(m, dx, dy)
          if not m.said and d <= 5 then bark(m, b) end
        end
      elseif rnd(1) < 0.4 then
        mon_step(m, irnd(3) - 1, irnd(3) - 1)
      end
    end
  end
end

function mon_step(m, dx, dy)
  local n = node
  local try = { { dx, dy }, { dx, 0 }, { 0, dy } }
  for t in all(try) do
    local nx, ny = m.x + t[1], m.y + t[2]
    if (t[1] ~= 0 or t[2] ~= 0) and node_free(n, nx, ny)
       and not (nx == hero.tx and ny == hero.ty) and not mon_at(nx, ny)
       and not prop_at(n, nx, ny) then
      -- A train drags its segments through the squares the head just left, so
      -- the body is always a legal path by construction -- no segment can end
      -- up inside a wall, because the head has already stood there.
      if m.seg then
        for k = #m.seg, 2, -1 do
          m.seg[k].x, m.seg[k].y = m.seg[k - 1].x, m.seg[k - 1].y
        end
        m.seg[1].x, m.seg[1].y = m.x, m.y
      end
      m.x, m.y = nx, ny
      m.anim = MOVE_FR
      return
    end
  end
end

-- Anything a monster occupies, head or body. A centipede is one entity across
-- three tiles, so every occupancy test in the game has to ask the monster
-- rather than compare its x and y -- otherwise things walk through its middle.
function mon_at(x, y)
  for m in all(node.mons) do
    if mon_covers(m, x, y) then return true end
  end
  return false
end

function mon_covers(m, x, y)
  if m.x == x and m.y == y then return true end
  if m.seg then
    for s in all(m.seg) do if s.x == x and s.y == y then return true end end
  end
  return false
end

function prop_at(n, x, y)
  for p in all(n.props or {}) do
    if p.x == x and p.y == y then return true end
  end
  return false
end

function mon_attack(m, b)
  m.angry = true
  -- The boss telegraphs. It winds up on one turn and lands on the next, which
  -- gives back a turn you may actually spend -- retreat, drink, cast, or trade
  -- -- and halves the incoming damage without making it less frightening. The
  -- tell is a bark, so it uses a channel the player is already reading.
  if m.boss then
    m.wind = 1 - m.wind
    if m.wind == 1 then
      say(b.n, "IT RAISES BOTH ARMS")
      sfx_safe("boss_warn")
      return
    end
  end
  -- Something that struck out of an unlit tile before it had ever been angry
  -- never gave you a chance to react: it gets the first hit, and it costs. The
  -- flat AMBUSH rather than a multiplier so a rat in the dark is a shock and
  -- not a death sentence.
  local ambush = 0
  if not m.seen and cell_light(m.x, m.y) == 0 then
    ambush = AMBUSH
    say(b.n, "SOMETHING IN THE DARK")
  end
  m.seen = true
  local hit = max(1, m.dmg + ambush - arm)
  -- The sigh is a timed debuff, not a tax. It used to take a permanent point
  -- of damage every turn it stood next to you, and since base damage is 2 with
  -- a floor of 1, the *first* sigh took everything it could and no shrine,
  -- item or floor in the game gave it back -- from a monster that deals no
  -- damage at all, so there was no risk attached to the worst thing it did.
  if b.sigh then
    sigh_t = SIGH_T
    say(b.n, "I EXPECTED MORE")
    return
  end
  if b.rent and gold > 0 then
    local take = min(gold, 40)
    gold = gold - take
    say(b.n, "THAT WILL BE " .. take .. " GOLD")
    return
  end
  -- Takes a little and runs, rather than taking a lot and staying. The
  -- landlord is a tax; this is a pickpocket, and the difference is that you
  -- can chase it -- which is the point, because chasing it is a bad idea.
  if b.steal and gold > 0 then
    local take = min(gold, 15 + irnd(15))
    gold = gold - take
    m.fleeing = true
    say(b.n, "MINE NOW. " .. take .. " GOLD")
    sfx_safe("coin_pickup")
    return
  end
  -- The auditor writes down a *rating*, not durability, and it reads the
  -- weapon slot as well as the three armour ones -- the only thing in the game
  -- that can take your blade back off you. The whetstone and the tidy-kit
  -- altar are the appeal process.
  if b.audit then
    local bk, bv = nil, 0
    for i = 1, #ARM_KINDS do
      local k = ARM_KINDS[i]
      if armv[k] > bv then bk, bv = k, armv[k] end
    end
    if wpnv > bv then bk, bv = "wpn", wpnv end
    if bk == "wpn" then
      wpnv = wpnv - 1 wpn_sync()
      say(b.n, "THAT BLADE IS UNBUDGETED")
      return
    elseif bk then
      armv[bk] = bv - 1 arm_sync()
      say(b.n, "DEPRECIATED. SIGN HERE.")
      return
    end
  end
  -- Says your own last spell back at you. Half the table helps you when it
  -- lands, which is the joke: the echo is not smart, it is just loud.
  if b.echo and last_spell and rnd(1) < 0.5 then
    echo_cast(b, last_spell)
    return
  end
  if (b.drain or m.boss) and arm > 0 then
    -- damages the best piece by a point rather than shaving a counter, so the
    -- repair path is the same as the acquisition path: find another of that
    -- kind and it replaces the damaged one
    local bk, bv = nil, 0
    for i = 1, #ARM_KINDS do
      local k = ARM_KINDS[i]
      if armv[k] > bv then bk, bv = k, armv[k] end
    end
    if bk then
      armv[bk] = bv - 1
      arm_sync()
      say(b.n, "LET ME TAKE THAT")
    end
  end
  -- `spell_swap` inverts your direction keys and was read in try_move from the
  -- first version of this cart, but nothing ever set it: the Boots of Slightly
  -- Wrong Trousers (§4) were never built, so the code was unreachable and had
  -- been for the life of the project. The floating eye's own gimmick -- "casts
  -- a random spell each turn" -- was equally missing. One is the other's
  -- source, so wiring them together closes both.
  -- It cannot stack its own confusion, and that guard is the whole difference
  -- between a gimmick and a lockout. Re-rolling every attack at 40% for eight
  -- turns meant the effect never lapsed while the eye was adjacent -- so every
  -- bump aimed at it walked away instead, and the combat probe reported the
  -- floating eye as flatly unkillable. Five turns, then a window.
  if b.confuse and spell_swap <= 0 and rnd(1) < 0.35 then
    spell_swap = 5
    say(b.n, "YOUR LEFT IS MY RIGHT")
  end
  hp = hp - hit
  sfx_safe("player_hurt")
  shake = 4
  burst(hero.tx, hero.ty, 8, { 8, 14, 7 })
  if hp <= 0 then die(b.n) end
end

function mon_hurt(i, amount)
  local n = node
  local m = n.mons[i]
  local b = BESTIARY[m.bi]
  -- A boss wears armour of its own, and it subtracts from your roll exactly as
  -- yours subtracts from its -- the same one-line rule, pointed the other way.
  if m.arm then amount = max(1, amount - m.arm) end
  m.hp = m.hp - amount
  m.angry = true
  dmgnum(m.x, m.y, amount)
  sfx_safe("sword_hit")
  burst(m.x, m.y, 6, { 8, 14, 7 })
  if m.hp > 0 and m.boss then boss_escalate(m, b) end
  -- A committee member does not die, it is *carried*. As long as one of them
  -- is still standing it brings the others back, so the fight is not won by
  -- attrition -- it is won by putting all three down inside the same few
  -- turns, which is what the fireball scroll has been waiting for.
  if m.hp <= 0 and m.crew and not m.down then
    m.down = true
    m.hp = 0
    m.revive = CREW_REVIVE
    burst(m.x, m.y, 8, { 5, 6, 7 })
    sfx_safe("enemy_hurt")
    if crew_alive(m.crew) == 0 then
      say(b.n, "THE MOTION CARRIES")
    else
      say(b.n, "WE WILL RECONVENE")
    end
    return
  end
  if m.hp <= 0 then
    burst(m.x, m.y, 14, { 8, 9, 7 })
    sfx_safe("enemy_explode")
    decal(m.x, m.y, b.ramp)
    kills = kills + 1
    score = score + 10 + depth * 5
    if m.boss then boss_down(m, b) end
    if b.drops then add(n.items, item_new(6, m.x, m.y)) end
    -- the only monster that hands back a weapon, so the slot has a source
    -- besides the floor's loot table and the boss
    if b.dropw then
      local w = weapon_for(depth)
      if w then add(n.items, item_new(w, m.x, m.y)) end
    end
    -- Children are flagged with their own field, not by scribbling on px:
    -- px is animation state and anim_lerp overwrites it on the next frame,
    -- which would let every child split again, for ever.
    if b.split and not m.spawn then
      local made = 0
      for s = -1, 1, 2 do
        local nx = m.x + s
        if node_free(n, nx, m.y) and not mon_at(nx, m.y)
           and not (nx == hero.tx and m.y == hero.ty) then
          local c = mon_new(m.bi, nx, m.y)
          c.hp = max(2, flr(b.hp / 3))
          c.spawn = true
          add(n.mons, c)
          made = made + 1
        end
      end
      if made > 0 then say(b.n, "NOW THERE ARE " .. made .. " OF ME") end
    end
    deli(n.mons, i)
  elseif b.flee and m.hp <= 2 then
    say(b.n, "I AM ESCALATING THIS")
    m.slow = 3
  end
end

-- How many of a crew are still on their feet.
function crew_alive(id)
  local n = 0
  for m in all(node.mons) do
    if m.crew == id and not m.down then n = n + 1 end
  end
  return n
end

-- Called once a turn: a crew with nobody left standing is finished and leaves,
-- otherwise its fallen get up again on a timer. This is the only monster in
-- the book that cannot be beaten by trading hits, and the fireball scroll has
-- been sitting in the loot table waiting for a reason.
function crew_turn()
  local seen = {}
  for m in all(node.mons) do
    if m.crew and not seen[m.crew] then
      seen[m.crew] = true
      local up = crew_alive(m.crew)
      for i = #node.mons, 1, -1 do
        local c = node.mons[i]
        if c.crew == m.crew and c.down then
          if up == 0 then
            burst(c.x, c.y, 12, { 8, 9, 7 })
            decal(c.x, c.y, BESTIARY[c.bi].ramp)
            kills = kills + 1
            score = score + 10 + depth * 5
            deli(node.mons, i)
          else
            c.revive = c.revive - 1
            if c.revive <= 0 then
              c.down = false
              c.hp = max(2, flr(c.hp0 / 2))
              burst(c.x, c.y, 10, { 7, 6, 12 })
              say(BESTIARY[c.bi].n, "SECONDED. I AM BACK.")
            end
          end
        end
      end
    end
  end
end

-- The best weapon this depth has any business handing out.
function weapon_for(d)
  local best = nil
  for i = 1, #ITEMS do
    local it = ITEMS[i]
    if it.k == "wpn" and it.v <= 1 + flr(d / 2) then best = i end
  end
  return best
end

-- ============================================================== 12_dialogue ==
function say(who, txt)
  bark_who = who
  bark_txt = txt
  bark_t = 70
end

function bark(m, b)
  -- Walk into a room holding eight monsters and eight of them barked on the
  -- same turn, of which you saw the last. §5.4 claimed these were throttled;
  -- `m.said` only ever limited each monster to one line in its life, which is
  -- a different thing. A bark still up and fresh is left alone, and the
  -- monster keeps its line for a turn when the screen is quiet.
  if bark_t > BARK_HOLD then return end
  m.said = true
  if b.say and #b.say > 0 then
    say(b.n, b.say[irnd(#b.say) + 1])
    sfx_safe("ghost_warn")
  end
end

-- ============================================================== 13_travel ==
function enter(i, from_dir)
  node = nodes[i]
  node_idx = i
  node.seen = true
  hero_place(from_dir)
  parts = {}
  dmgnums = {}
  dissolve = FX_DISSOLVE and DISSOLVE_T or 0
  pending = nil
  light_alloc()
  light_build()
  sfx_safe("door_open")
end

function descend()
  depth = depth + 1
  score = score + 100
  -- getting down a floor is the main thing that buys health back, so the
  -- stairs are worth pushing for rather than something you fall down at 2 hp
  hpmax = hpmax + DIVE_MAX
  hp = min(hpmax, hp + DIVE_HEAL)
  regen = 0
  if depth > best_depth then best_depth = depth dset(1, best_depth) end
  sfx_safe("stairs_warp")
  floor_build(depth)
  enter(1, nil)
  say("you", "DOWN TO " .. theme.name)
  fade = 12
end

function die(by)
  mode = "over"
  modet = 0
  sfx_safe("player_die")
  burst(hero.tx, hero.ty, 40, { 8, 14, 7, 10 })
  killer = by
  bark_t = 0
  if score > hiscore then hiscore = score dset(0, hiscore) end
  music_safe("game_over_theme")
end

-- ================================================================== 14_hud ==
-- Nothing here is levelled: every line is one `print` at one z, so it is set
-- cleanly and sits at the angle its plane is seen at. See the note beside
-- HUD_Y for why the alternative was rejected, and for the two planes.
function hrow(i) return HUD_TOP + i * HUD_ROW end

-- The boss in the node you are standing in, if any. `boss_alive` is a
-- floor-wide fact; this is the one on screen.
function boss_mon()
  for m in all(node.mons) do if m.boss then return m end end
  return nil
end

function hud_draw()
  -- ---- the near slice, in front of the room: health and armour ----------
  -- Health is drawn, not printed. The host's font has no "|", and a missing
  -- glyph still advances the cursor, so a bar built out of pipes comes out as
  -- an invisible row of spaces.
  -- Three groups, in the order they keep you alive: health, armour, weapon.
  -- Every group draws its *empty* slots too, in the dim pair. That is the
  -- whole point of pips over a number -- an empty slot is what tells you a
  -- draught is worth drinking, that diving raised the ceiling, and that there
  -- is a better blade somewhere on this floor. Armour drew only what you had,
  -- which quietly hid six sevenths of the thing it was meant to advertise.
  --
  -- They are down here rather than up in the sky band because they are what
  -- you look at most and there is exactly one row of frame below the room to
  -- put them in. It is also the nearest plane anything is drawn on, so they
  -- come out half again as large as the text above.
  set_draw_slice(HUD_BY)
  local function pips(x0, n, count, lo, hi, dim)
    for i = 1, n do
      local x = HUD_BX + x0 + (i - 1) * 3
      local on = i <= count
      line(x, HUD_BZ, x + 1, HUD_BZ, on and lo or dim)
      line(x, HUD_BZ + 1, x + 1, HUD_BZ + 1, on and hi or 1)
    end
  end
  pips(0,  min(hpmax, 20), hp,   hp > 3 and 8 or 14, hp > 3 and 14 or 8, 5)
  pips(64, ARM_MAX,        arm,  6,  13, 5)
  pips(88, WPN_MAX,        wpnv, 10,  9, 5)

  -- ---- the back plane, above the far wall: everything else -------------
  set_draw_slice(HUD_Y)
  print("d" .. depth .. " " .. theme.name .. "  g" .. gold, 0, hrow(0), theme.acc)

  -- Torch fuel, the clock that makes the light map a mechanic -- and now also
  -- the stealth dial, so a doused torch has to read as *deliberately* out
  -- rather than as empty. Grey says you chose this; red says you did not.
  local fw = flr(torchfuel / 400 * 28)
  line(HUD_MAPX, hrow(0) + 2, HUD_MAPX + 28, hrow(0) + 2, 5)
  if fw > 0 then
    line(HUD_MAPX, hrow(0) + 2, HUD_MAPX + fw, hrow(0) + 2,
         not torchlit and 13 or (torchfuel > 80 and 9 or 8))
  end

  -- A boss gets a bar of its own on the row the spell line normally has to
  -- itself, and the spell moves right to share it. You need both during the
  -- one fight in the game where knowing what you can cast decides it.
  local bm = boss_mon()
  if bm then
    local w = flr(bm.hp / bm.hp0 * 60)
    line(0, hrow(1) + 2, 60, hrow(1) + 2, 5)
    if w > 0 then
      line(0, hrow(1) + 2, w, hrow(1) + 2, bm.phase >= 2 and 8 or 14)
    end
  end
  -- What z would open. Not the first spell's name any more, because z no
  -- longer casts it -- the count is what tells you whether the ring is worth
  -- opening, and the name is one button away.
  if not ring then
    local n = #ring_items()
    print("z-" .. n .. (n == 1 and " thing" or " things"),
          bm and 68 or 0, hrow(1), n > 1 and 12 or 5)
  end

  -- While the ring is open it owns the lower rows: it is modal, the world is
  -- not moving, and a bark from a turn ago is not what you are looking at.
  -- Three entries at a time around the selection, so a long list still fits
  -- two rows and the thing you are on is always the middle one.
  if ring then
    local r = ring_items()
    local e = r[ring_sel]
    print("- " .. sub(e.n, 1, HUD_COLS - 2), 0, hrow(2), e.c)
    local tail = ""
    for i = 1, #r do tail = tail .. (i == ring_sel and "+" or ".") end
    print(tail .. "  arrows pick, let go", 0, hrow(3), 6)
  elseif pending then
    print("pick up?  x yes  z no", 0, hrow(2), 10)
    print(sub(ITEMS[pending.ii].n, 1, HUD_COLS), 0, hrow(3),
          SPELLINFO[ITEMS[pending.ii].s].c)
  elseif bark_t > 0 then
    print(sub(bark_who, 1, HUD_COLS), 0, hrow(2), 6)
    print(sub(bark_txt, 1, HUD_COLS), 0, hrow(3), 7)
  end

  minimap()
end

-- The explored graph, chambers and corridors alike. `rect` is not implemented
-- by the host, so boxes are four `line` calls.
--
-- It sits in its own column to the right of HUD_COLS so it never has to fight
-- a full-width bark for the same voxels, and below the torch bar. The pitch is
-- what fits a 4 x 3 lattice into what is left: 8 across, 6 down.
function minimap()
  local bx, bz = HUD_MAPX, hrow(1)
  for i = 1, #nodes do
    local n = nodes[i]
    if n.seen then
      local x = bx + flr(n.gx * 8)
      local z = bz + flr(n.gy * 6)
      local w = n.kind == "corr" and 2 or 5
      local c = (i == node_idx) and 10
                or (i == stair_node and (boss_alive and 8 or 11) or 5)
      line(x, z, x + w, z, c)
      line(x, z + 4, x + w, z + 4, c)
      line(x, z, x, z + 4, c)
      line(x + w, z, x + w, z + 4, c)
    end
  end
end

-- A block of centred rows is centred *as a block*, every row starting at the
-- same x, rather than each row centred on its own length. On a plane seen at
-- an angle that is not a style choice: a row drawn at one z descends to the
-- right, so the right-hand end of a long line lands at the same height as the
-- left-hand end of the shorter line below it, and the two collide however
-- generous the pitch. Sharing a left edge makes the gap between two rows the
-- same at every x, so it cannot close.
function block_x(lines)
  local w = 0
  for i = 1, #lines do w = max(w, #lines[i]) end
  return max(0, min(64 - w * 2, 128 - w * 4))
end

function banner(txt, row, c, x)
  set_draw_slice(HUD_Y)
  print(txt, x or 0, row, c)
end

-- ================================================================= 15_game ==
function new_game()
  run_seed = 1 + flr(rnd(30000))
  depth = 1
  score = 0
  turns = 0
  kills = 0
  shake = 0
  fade = 0
  rept = 0
  parts = {}
  dmgnums = {}
  dissolve = 0
  boss_alive = false
  bark_t = 0
  killer = nil
  pending = nil
  hero_init()
  floor_build(depth)
  enter(1, nil)
  say("you", "DOWN WE GO")
  music_safe("dungeon_theme", 1)
end

function _init()
  cartdata("voxbox_deeper")
  hiscore = dget(0)
  best_depth = max(1, dget(1))
  frame = 0
  flicker = 0
  modet = 0
  mode = "title"
  srand(7)
  new_game()
  mode = "title"
  music_safe("title_theme")
end

function _update()
  frame = frame + 1
  modet = modet + 1
  if shake > 0 then shake = shake - 1 end
  if fade > 0 then fade = fade - 1 end
  if bark_t > 0 then bark_t = bark_t - 1 end
  if dissolve > 0 then dissolve = dissolve - 1 end

  -- flicker: the light map is rebuilt on a step, never per frame
  if frame % 4 == 0 then
    flicker = flicker + 1
    if mode ~= "title" then light_build() end
  end

  parts_update()
  dmgnums_update()
  if hero.anim > 0 then hero.anim = hero.anim - 1 end
  for m in all(node.mons) do if m.anim > 0 then m.anim = m.anim - 1 end end
  anim_lerp()

  if mode == "title" then
    if btnp(4) then
      mode = "play"
      modet = 0
      srand(frame * 7 + 13)
      new_game()
      sfx_safe("menu_select")
    end

  elseif mode == "play" then
    if rept > 0 then rept = rept - 1 end
    if pending then
      -- modal: movement is ignored until the prompt is answered
      if btnp(4) then
        for i = #node.items, 1, -1 do
          if node.items[i] == pending then
            if item_take(pending) then deli(node.items, i) end
            break
          end
        end
        pending = nil
      elseif btnp(5) then
        pending.declined = true
        pending = nil
        sfx_safe("ui_click")
      end
    elseif btn(5) then
      -- the ring is open: arrows select rather than move, and nothing happens
      -- in the world until it is released
      local r = ring_items()
      if not ring then ring, ring_sel = true, 1 end
      ring_sel = clamp(ring_sel, 1, #r)
      if btnp(0) then
        ring_sel = ring_sel - 1
        if ring_sel < 1 then ring_sel = #r end
        sfx_safe("ui_click")
      elseif btnp(1) then
        ring_sel = ring_sel + 1
        if ring_sel > #r then ring_sel = 1 end
        sfx_safe("ui_click")
      end
      rept = 0
    elseif ring then
      ring = false
      ring_use(ring_sel)
    elseif hero.anim == 0 then
      -- held direction repeats: a roguelike where you have to tap for every
      -- step of a long corridor is a roguelike nobody finishes
      local mv = 0
      if btn(0) then mv = 4 elseif btn(1) then mv = 2
      elseif btn(2) then mv = 1 elseif btn(3) then mv = 3 end
      if mv == 0 then
        rept = 0
      elseif rept <= 0 then
        try_move(mv)
        rept = 6
      end
    end

  elseif mode == "over" then
    if modet > 90 and btnp(4) then
      mode = "title"
      modet = 0
      music_safe("title_theme")
    end
  end
end

-- Positions lerp toward their tile so the turn-based grid still moves
-- smoothly.
function anim_lerp()
  local t = hero.anim / MOVE_FR
  hero.px = lerp(hero.tx, hero.px, t > 0 and 0.6 or 0)
  hero.py = lerp(hero.ty, hero.py, t > 0 and 0.6 or 0)
  for m in all(node.mons) do
    m.px = lerp(m.x, m.px, m.anim > 0 and 0.6 or 0)
    m.py = lerp(m.y, m.py, m.anim > 0 and 0.6 or 0)
  end
end

function _draw()
  clv()
  -- The camera is fixed and the cart cannot move it, so impact is sold by a
  -- flash on the near sill rather than a shake. Offsetting every drawn voxel
  -- would be a true shake and is the obvious next step; this is the cheap one.
  local sx = shake > 0 and (flr(frame / 2) % 2) or 0

  if mode == "title" then
    title_draw()
    return
  end

  room_draw()
  for it in all(node.items) do item_draw(it) end
  for m in all(node.mons) do mon_draw(m) end
  if mode ~= "over" then hero_draw() end
  parts_draw()
  dmgnums_draw()

  if sx > 0 then
    -- a cheap flash on the near sill sells the impact without a camera
    boxfill(OX, vy(node.h - 1), SILL_Z - 1, OX + node.w * TS, vy(node.h - 1), SILL_Z - 1, 8)
  end

  -- The death screen replaces the HUD rather than drawing over it. Both used
  -- the same rows on the back plane, and the two texts were interleaving into
  -- an unreadable mess.
  if mode == "over" then
    death_draw()
  else
    hud_draw()
  end
end

function death_draw()
  set_draw_slice(HUD_Y)
  -- the same rows the HUD uses, and for the same reason: below them the far
  -- wall is in the way
  local l = {
    "you died",
    sub("killed by " .. (killer or "the dark"), 1, HUD_COLS),
    "depth " .. depth .. "  score " .. score,
    "press x",
  }
  local x = block_x(l)
  banner(l[1], hrow(0), 8, x)
  banner(l[2], hrow(1), 7, x)
  banner(l[3], hrow(2), 7, x)
  if modet > 90 and frame % 40 < 26 then banner(l[4], hrow(3), 10, x) end
end

-- The parade: real monsters walking the demo slab, one of every body plan, in
-- place of the six orbiting dots that were there before. They are drawn by the
-- same plan_draw the dungeon uses, so this is the bestiary rather than a
-- picture of it, and they cast the engine's drop shadows onto the slab for
-- nothing.
--
-- Cast by name rather than by index, so reordering BESTIARY cannot silently
-- swap the line-up; unknown names are dropped rather than crashing the title
-- screen. Chosen for one of each plan and for ramps that read against a warm
-- slab -- a `warm` monster on the orange rings would be invisible.
PARADE = { "lich clerk", "hound", "sorry slime", "bat cloud",
           "minor poet", "cave troll", "floating eye" }

-- The ring is a flat ellipse across the *front* of the slab, and where it sits
-- is measured rather than chosen. The tallest plan stands 17 voxels, and any
-- further back than y = 45 the cave troll's horns rise into the last line of
-- the title text -- which it would occlude, being the nearer of the two. A lap
-- was walked frame by frame against the projected text band to find that:
-- y = 45..87 keeps every plan clear of it by 19 px and on the slab, and being
-- near the camera is also what makes them big enough to recognise.
PARADE_CY, PARADE_RY = 66, 21
PARADE_CX, PARADE_RX = 64, 48

function parade_draw()
  for i = 1, #PARADE do
    local bi = nil
    for j = 1, #BESTIARY do if BESTIARY[j].n == PARADE[i] then bi = j end end
    if bi then
      local b = BESTIARY[bi]
      local a = frame * 0.0015 + (i - 1) / #PARADE
      -- Lit as if a torch stood in the middle of the slab: a step brighter at
      -- the front of the ring than at the back, so they are not flat cut-outs.
      -- Levels 2 and 1 rather than 3 and 2, because level 3 is the top of
      -- every ramp and four of the six then come out the same white.
      local l = sin(a) < 0 and 2 or 1
      plan_draw(b.plan,
                flr(PARADE_CX + cos(a) * PARADE_RX),
                flr(PARADE_CY - sin(a) * PARADE_RY),
                RAMPS[b.ramp][l + 1], RAMPS[b.ramp][min(l + 2, 4)],
                RAMPS.cold[l + 1], i * 7)
    end
  end
end

function title_draw()
  -- The demo floor matches the play area's footprint, not a square: at this
  -- camera a square slab runs off the bottom of the frame and swallows the
  -- text. Same ramps as a real floor, so the title screen is a demonstration
  -- of the light model rather than a picture of one.
  local ramp = RAMPS.cold
  local xmax, ymax = OX + GW * TS, OY + GH * TS
  boxfill(OX, OY, FLOOR_Z, xmax, ymax, FLOOR_B, ramp[2])
  for i = 3, 1, -1 do
    local rx, ry = 12 + i * 16, 8 + i * 11
    boxfill(max(OX, 64 - rx), max(OY, 46 - ry), FLOOR_Z,
            min(xmax, 64 + rx), min(ymax, 46 + ry), FLOOR_Z, RAMPS.warm[5 - i])
  end
  parade_draw()
  set_draw_slice(HUD_Y)
  -- Seven rows rather than the HUD's four, at a tighter pitch and starting a
  -- voxel higher: there is no wall here, only the demo slab, so the band runs
  -- on to z = 57 before the slab starts eating the low end of a line.
  local function trow(i) return HUD_TOP - 1 + i * 7 end
  local l = {
    "deeper",
    "a voxbox roguelike",
    "arrows move and attack",
    "x confirm   hold z for kit",
    "best depth " .. best_depth .. "  hi " .. hiscore,
    "press x to start",
  }
  local x = block_x(l)
  banner(l[1], trow(0), 10, x)
  banner(l[2], trow(1), 12, x)
  banner(l[3], trow(2), 7, x)
  banner(l[4], trow(3), 7, x)
  banner(l[5], trow(4), 6, x)
  if frame % 40 < 26 then banner(l[6], trow(5), 10, x) end
end
