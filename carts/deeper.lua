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
DIVE_HEAL = 8            -- restored on reaching a new floor
DIVE_MAX  = 2            -- and permanent max health for getting there
AGGRO     = 6            -- tiles at which a monster notices you

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

-- Per-flagstone mottling of walls and floors (see light_alloc). Off by
-- default while the look is undecided -- and it is a run-count saving as well
-- as a look, since a flat-lit stretch of floor collapses back to one box.
TEXTURES = cfg("textures", false) == true

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
  { n = "the lost sock reliquary", k = "gold",  say = "A COIN. ODDLY WARM." },
  { n = "shrine of second wind",   k = "heal",  say = "THAT IS BETTER" },
})

ARM_KINDS = { "helm", "chest", "shield" }
ARM_MSG = { helm = "A PROPER HELM", chest = "BREASTPLATE ON", shield = "SHIELD UP" }

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
  ice   = { 1, 13, 12,  7 },
  bone  = { 1,  5,  6, 15 },
}

-- Depth bands. Each picks the cold/warm pair the level is painted with, plus
-- an accent used for doors, stairs and trim.
THEMES = {
  { name = "the crypt",   cold = "cold",  warm = "warm",  acc = 12, mon = 1 },
  { name = "the cisterns", cold = "ice",  warm = "warm",  acc =  7, mon = 2 },
  { name = "the warrens", cold = "moss",  warm = "warm",  acc = 11, mon = 3 },
  { name = "the ossuary", cold = "bone",  warm = "warm",  acc = 15, mon = 4 },
  { name = "the red floor", cold = "blood", warm = "warm", acc = 8, mon = 5 },
}

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
  if n.kind == "room" and n.w >= 11 and n.h >= 9 then
    if rnd(1) < 0.45 then
      for py = 2, n.h - 3, 3 do
        for px = 2, n.w - 3, 3 do
          if rnd(1) < 0.5 then
            n.tile[py][px] = T_WALL
            -- roughly one pillar in four is worth reading
            local r = rnd(1)
            if r < 0.16 then
              add(n.props, { x = px, y = py, kind = "shrine",
                             si = irnd(#SHRINES) + 1, used = false })
            elseif r < 0.36 then
              add(n.props, { x = px, y = py, kind = "statue",
                             si = irnd(#STATUES) + 1 })
            end
          end
        end
      end
    end
    if rnd(1) < 0.3 then
      local wx, wy = 2 + irnd(n.w - 6), 2 + irnd(n.h - 5)
      for y = wy, min(wy + 2, n.h - 2) do
        for x = wx, min(wx + 3, n.w - 2) do
          if n.tile[y][x] == T_FLOOR then n.tile[y][x] = T_WATER end
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
    add(n.torch, { x = cand[j].x, y = cand[j].y, ph = rnd(1) })
    deli(cand, j)
  end
  if #n.torch == 0 then
    n.tile[0][flr(n.w / 2)] = T_WALL
    add(n.torch, { x = flr(n.w / 2), y = 0, ph = rnd(1) })
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
  for i = 1, count do
    local x, y = spot(n)
    if x then add(n.mons, mon_new(mon_roll(d), x, y)) end
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
    local cx, cy = t.x * SUB + 1, t.y * SUB + 1
    local r = 5.5 * SUB + sin(t.ph + flicker * 0.11) * 3.0
    local r2, b1, b2 = r * r, (r / 3) * (r / 3), (r * 2 / 3) * (r * 2 / 3)
    local warm2 = (r * 0.62) * (r * 0.62)
    for y = max(0, flr(cy - r)), min(LH - 1, flr(cy + r)) do
      local lr, wr = lmap[y], wmap[y]
      local dy = y - cy
      local dy2 = dy * dy
      for x = max(0, flr(cx - r)), min(LW - 1, flr(cx + r)) do
        local dx = x - cx
        local d2 = dx * dx + dy2
        if d2 <= r2 then
          local l = (d2 <= b1) and 3 or ((d2 <= b2) and 2 or 1)
          if l > lr[x] then lr[x] = l end
          if d2 <= warm2 then wr[x] = true end
        end
      end
    end
  end

  -- the hero's own torch, and the reason the torch clock matters
  local hr = (1 + flr(torchfuel / 70)) * SUB
  if spell_light > 0 then hr = hr + 3 * SUB end
  local hx, hy = hero.tx * SUB + 1, hero.ty * SUB + 1
  local hr2, hb = hr * hr, (hr / 2) * (hr / 2)
  for y = max(0, hy - hr), min(LH - 1, hy + hr) do
    local lr, wr = lmap[y], wmap[y]
    local dy = y - hy
    local dy2 = dy * dy
    for x = max(0, hx - hr), min(LW - 1, hx + hr) do
      local dx = x - hx
      local d2 = dx * dx + dy2
      if d2 <= hr2 then
        local l = (d2 <= hb) and 3 or 2
        if l > lr[x] then lr[x] = l end
        wr[x] = true
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
  if t == T_DOOR then return l > 0 and theme.acc or 1 end
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
  local rw, rc, ice, acc = RAMPS[theme.warm], RAMPS[theme.cold], RAMPS.ice, theme.acc
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
        elseif t == T_DOOR then c = (l > 0) and acc or 1
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
          elseif t2 == T_DOOR then c2 = (l2 > 0) and acc or 1
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
        local c, near = wall_col(tx, ty), is_near_wall(tx, ty)
        local x0 = tx
        tx = tx + 1
        while tx < n.w and n.tile[ty][tx] == T_WALL
              and wall_col(tx, ty) == c and is_near_wall(tx, ty) == near do
          tx = tx + 1
        end
        add(wruns, { x0 = x0, x1 = tx - 1, ty = ty, c = c, near = near })
      end
    end
  end
end

function wall_col(tx, ty)
  local m = mottle[ty][tx]
  if not lightfx then
    return RAMPS[theme.cold][clamp(FLAT_WALL + m, 0, 3) + 1]
  end
  local lx, ly = tx * SUB + 1, ty * SUB + 1
  local l = clamp(lmap[ly][lx] + m, 0, 3)
  local r = wmap[ly][lx] and RAMPS[theme.warm] or RAMPS[theme.cold]
  return r[l + 1]
end

-- ============================================================== 05_render ==
-- A wall on the near edge (max row / max column) is drawn as a low sill.
-- Full height there would stand between the camera and the room.
function is_near_wall(x, y)
  return x == node.w - 1 or y == node.h - 1
end

function room_draw()
  local n = node
  for r in all(runs) do
    boxfill(lx2v(r.x0), ly2v(r.ly0), FLOOR_Z,
            lx2v(r.x1) + LS - 1, ly2v(r.ly1) + LS - 1, FLOOR_B, r.c)
  end
  -- Walls get three bands rather than one flat slab: a capping course on top,
  -- the body, and a skirting at the floor. Each is one extra boxfill per run,
  -- and the renderer's per-face shading does the rest -- it is the cheapest
  -- way to make masonry read as built rather than extruded.
  local capc = RAMPS[theme.cold][4]
  for r in all(wruns) do
    local top = r.near and SILL_Z or WALL_Z
    local x0, x1 = vx(r.x0), vx(r.x1) + TS - 1
    local y0, y1 = vy(r.ty), vy(r.ty) + TS - 1
    boxfill(x0, y0, top, x1, y1, FLOOR_Z - 1, r.c)
    boxfill(x0, y0, top, x1, y1, top, capc)                    -- capping course
    boxfill(x0, y0, FLOOR_Z - 2, x1, y1, FLOOR_Z - 1, theme.acc)  -- skirting
  end
  seams_draw()
  for t in all(n.torch) do torch_draw(t) end
  for p in all(n.props) do prop_draw(p) end
  if n.stair then stairs_draw(n.stair) end
end

-- Drawn standing on the pillar tile it replaced, taller than the wall around
-- it so it reads as a monument rather than masonry.
-- Flagstone seams: one long box per major gridline rather than per tile edge.
-- Every tile edge would be right, and would also multiply the floor's run
-- count several times over; every third is enough to read as large slabs.
function seams_draw()
  local n = node
  local c = RAMPS[theme.cold][2]
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

  if p.kind == "statue" then
    local c = RAMPS.bone[l + 1]
    local hi = RAMPS.bone[min(l + 2, 4)]
    -- stepped plinth with an inscription band, then a figure on top of it
    boxfill(x - 3, y - 3, 55, x + 3, y + 3, 57, stone)
    boxfill(x - 2, y - 2, 52, x + 2, y + 2, 54, dark)
    boxfill(x - 2, y + 2, 53, x + 2, y + 2, 53, theme.acc)     -- brass plaque
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
    boxfill(x - 2, y - 2, 50, x + 2, y + 2, 50, live and theme.acc or 5)
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
  hp, hpmax, regen = 16, 16, 0
  -- Starting armour is 0 on purpose. Damage has a floor of 1 (mon_attack), so
  -- a single point of armour reduces *every* depth-1 monster to that floor and
  -- makes the first floor harmless. The fix for dying on floor 1 was making
  -- armour findable there, not handing it over.
  gold, arm, dmg = 0, 0, 2
  armv = { helm = 0, chest = 0, shield = 0 }
  helm, chest, shield, helm_pot = false, false, false, false
  torchfuel = 250
  spells = {}
  spell_light, spell_conf, spell_chicken, spell_swap = 0, 0, 0, 0
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
  -- weapon, angled toward the camera so it is never lost behind the body
  local wz = hero.anim > 0 and 51 or 53
  boxfill(x + 2, y + 1, wz, x + 2, y + 2, wz + 2, 6)
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
  { n = "bat cloud",  plan = "swarm", ramp = "cold", hp = 5,  dmg = 2, d = 2,
    erratic = true, say = { "WE HAVE DISCUSSED THIS" } },
  { n = "minor poet", plan = "ghost", ramp = "ice",  hp = 6,  dmg = 1, d = 2,
    calm = true, say = { "I DIED DOING WHAT I",
                         "WHICH WAS, SADLY, THIS" } },
  { n = "mimic",      plan = "blob",  ramp = "warm", hp = 10, dmg = 4, d = 3,
    say = { "OPEN ME. I AM A CHEST.", "A NORMAL CHEST" } },
  { n = "cultist",    plan = "biped", ramp = "blood", hp = 9, dmg = 3, d = 3,
    say = { "THE STARS ARE ALMOST", "GIVE IT A FORTNIGHT" } },
  { n = "hound",      plan = "quad",  ramp = "blood", hp = 9, dmg = 4, d = 3,
    charge = true, say = { "WHO IS A GOOD BOY" } },
  { n = "wraith",     plan = "ghost", ramp = "ice",  hp = 12, dmg = 4, d = 4,
    drain = true, say = { "THAT ARMOUR IS HEAVY", "LET ME TAKE THAT" } },
  { n = "live armour", plan = "biped", ramp = "cold", hp = 14, dmg = 5, d = 4,
    drops = true, say = { "NOBODY IS IN HERE", "STOP ASKING" } },
  { n = "sad ghost",  plan = "ghost", ramp = "cold", hp = 10, dmg = 2, d = 4,
    sigh = true, say = { "I EXPECTED MORE", "SO DID YOUR MOTHER" } },
  { n = "cave troll", plan = "tall",  ramp = "moss", hp = 20, dmg = 6, d = 5,
    smash = true, say = { "TROLL REDECORATING" } },
  { n = "spider",     plan = "quad",  ramp = "bone", hp = 12, dmg = 4, d = 5,
    web = true, say = { "EIGHT LEGS, NO REGRETS" } },
  { n = "lich clerk", plan = "biped", ramp = "ice",  hp = 18, dmg = 5, d = 6,
    say = { "EXPENSES ARE DENIED", "NO RECEIPT, NO REFUND" } },
  { n = "ghost landlord", plan = "ghost", ramp = "warm", hp = 14, dmg = 3, d = 6,
    rent = true, say = { "THAT WILL BE 40 GOLD", "THE DUNGEON ISNT FREE" } },
  { n = "floating eye", plan = "ghost", ramp = "blood", hp = 16, dmg = 5, d = 7,
    say = { "I HAVE SEEN YOUR BAG" } },
  { n = "regret",     plan = "ghost", ramp = "cold", hp = 14, dmg = 4, d = 8,
    follows = true, say = { "REMEMBER WHAT YOU SAID" } },
  { n = "the manager", plan = "tall", ramp = "blood", hp = 40, dmg = 7, d = 9,
    boss = true, say = { "I MUST ESCALATE THIS",
                         "A PERFORMANCE ISSUE" } },
}

function mon_roll(d)
  local pool = {}
  for i = 1, #BESTIARY do
    local b = BESTIARY[i]
    if b.d <= d and b.d >= d - 4 and not (b.boss and d < 9) then add(pool, i) end
  end
  if #pool == 0 then return 1 end
  return pick(pool)
end

function mon_new(bi, x, y)
  local b = BESTIARY[bi]
  local scale = 1 + (depth - 1) * 0.14
  return {
    bi = bi, x = x, y = y, px = x, py = y, anim = 0,
    hp = flr(b.hp * scale), dmg = flr(b.dmg * scale), said = false, slow = 0,
  }
end

function mon_draw(m)
  local b = BESTIARY[m.bi]
  local l = clamp(cell_light(m.x, m.y), 0, 3)
  plan_draw(b.plan,
            flr(vx(0) + m.px * TS) + 3, flr(vy(0) + m.py * TS) + 3,
            RAMPS[b.ramp][l + 1], RAMPS[b.ramp][min(l + 2, 4)],
            RAMPS.cold[l + 1], m.x)
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
}

-- Food is deliberately common. Natural regen (REGEN) is slow enough that it
-- only pays for retreating, so bread and draughts are what actually carry you
-- between fights.
function item_roll(d)
  local pool = { 1, 1, 1, 2, 2, 2, 2, 14, 14, 3, 3, 8, 9, 10, 11, 12, 13 }
  -- Every armour piece used to be gated behind d >= 2, which meant the one
  -- floor where you have no armour at all was also the only floor where none
  -- could drop. Helms and breastplates now appear from the start, which puts
  -- floor 1's ceiling at 5 of the maximum 7; shields still wait for floor 2,
  -- so there is somewhere left to go.
  add(pool, 4) add(pool, 5) add(pool, 6)
  if d >= 2 then add(pool, 7) end
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
    if rnd(1) < 0.1 then
      dmg = max(1, dmg - 1)
      say("you", "YOU BROKE YOUR SWORD")
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
  if spell_swap > 0 then dir = OPPOSITE[dir] end
  hero.face = dir
  local d = DIRS[dir]
  local nx, ny = hero.tx + d[1], hero.ty + d[2]
  local n = node

  for i = #n.mons, 1, -1 do
    local m = n.mons[i]
    if m.x == nx and m.y == ny then
      local roll = dmg + irnd(3) + (spell_conf > 0 and 3 or 0)
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
      enter(ex.to, ex.back)
      -- a doorway costs a turn like any other step, or the torch never burns
      -- while you travel and whatever is waiting in the next node gets no move
      end_turn()
    end
    return
  end
  if t == T_STAIR then
    descend()
    return
  end
  if t == T_WALL then return end

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

-- A statue talks. A shrine does one thing, once, and then only talks.
function prop_touch(p)
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
  p.used = true
  -- Four kinds, and an unrecognised one still speaks and is still spent: the
  -- list is authored in the manifest, so a typo there should read as a shrine
  -- that did nothing much rather than stop the game.
  if sh.k == "heal" then
    hp = min(hpmax, hp + 8)
  elseif sh.k == "torch" then
    torchfuel = 400
  elseif sh.k == "gold" then
    gold = gold + 20 + irnd(30)
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
  torchfuel = max(0, torchfuel - 1)
  regen = regen + 1
  if regen >= (hunted() and REGEN or REGEN_CALM) then
    regen = 0
    if hp < hpmax then hp = hp + 1 end
  end
  if spell_light > 0 then spell_light = spell_light - 1 end
  if spell_conf > 0 then spell_conf = spell_conf - 1 end
  if spell_chicken > 0 then spell_chicken = spell_chicken - 1 end
  if spell_swap > 0 then spell_swap = spell_swap - 1 end
  if torchfuel == 0 and turns % 40 == 0 then
    say("you", "THE DARK IS PERSONAL")
  end
  mons_turn()
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
    local m = n.mons[i]
    local b = BESTIARY[m.bi]
    if m.slow > 0 then
      m.slow = m.slow - 1
    else
      local d = chebyshev(m.x, m.y, hero.tx, hero.ty)
      if d <= 1 then
        mon_attack(m, b)
      elseif d <= AGGRO or b.follows then
        if b.calm and not m.angry then
          if not m.said then bark(m, b) end
        else
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
       and not (nx == hero.tx and ny == hero.ty) and not mon_at(nx, ny) then
      m.x, m.y = nx, ny
      m.anim = MOVE_FR
      return
    end
  end
end

function mon_at(x, y)
  for m in all(node.mons) do if m.x == x and m.y == y then return true end end
  return false
end

function mon_attack(m, b)
  m.angry = true
  local hit = max(1, m.dmg - arm)
  if b.sigh then
    dmg = max(1, dmg - 1)
    say(b.n, "I EXPECTED MORE")
    return
  end
  if b.rent and gold > 0 then
    local take = min(gold, 40)
    gold = gold - take
    say(b.n, "THAT WILL BE " .. take .. " GOLD")
    return
  end
  if b.drain and arm > 0 then
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
  m.hp = m.hp - amount
  m.angry = true
  sfx_safe("sword_hit")
  burst(m.x, m.y, 6, { 8, 14, 7 })
  if m.hp <= 0 then
    burst(m.x, m.y, 14, { 8, 9, 7 })
    sfx_safe("enemy_explode")
    kills = kills + 1
    score = score + 10 + depth * 5
    if b.drops then add(n.items, item_new(6, m.x, m.y)) end
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

-- ============================================================== 12_dialogue ==
function say(who, txt)
  bark_who = who
  bark_txt = txt
  bark_t = 70
end

function bark(m, b)
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

function hud_draw()
  -- ---- the near slice, in front of the room: health and armour ----------
  -- Health is drawn, not printed. The host's font has no "|", and a missing
  -- glyph still advances the cursor, so a bar built out of pipes comes out as
  -- an invisible row of spaces.
  -- Pips show max health as well as current: the empty ones are what tells
  -- you a draught is worth drinking and that diving raised the ceiling.
  -- Armour gets its own group beside them, because it is the other half of how
  -- long you live and a number buried in a text line does not read as
  -- something you should go looking for.
  --
  -- They are down here rather than up in the sky band because they are what
  -- you look at most and there is exactly one row of frame below the room to
  -- put them in. It is also the nearest plane anything is drawn on, so they
  -- come out half again as large as the text above.
  set_draw_slice(HUD_BY)
  for i = 1, min(hpmax, 20) do
    local x = HUD_BX + (i - 1) * 3
    local lit = i <= hp
    line(x, HUD_BZ, x + 1, HUD_BZ, lit and (hp > 3 and 8 or 14) or 5)
    line(x, HUD_BZ + 1, x + 1, HUD_BZ + 1, lit and (hp > 3 and 14 or 8) or 1)
  end
  for i = 1, min(arm, 10) do
    local x = HUD_BX + 64 + (i - 1) * 4
    line(x, HUD_BZ, x + 2, HUD_BZ, 6)
    line(x, HUD_BZ + 1, x + 2, HUD_BZ + 1, 13)
  end

  -- ---- the back plane, above the far wall: everything else -------------
  set_draw_slice(HUD_Y)
  print("d" .. depth .. " " .. theme.name .. "  g" .. gold, 0, hrow(0), theme.acc)

  -- torch fuel, the clock that makes the light map a mechanic
  local fw = flr(torchfuel / 400 * 28)
  line(HUD_MAPX, hrow(0) + 2, HUD_MAPX + 28, hrow(0) + 2, 5)
  if fw > 0 then
    line(HUD_MAPX, hrow(0) + 2, HUD_MAPX + fw, hrow(0) + 2,
         torchfuel > 80 and 9 or 8)
  end

  if #spells > 0 then
    print("z-" .. SPELLINFO[spells[1]].n, 0, hrow(1), SPELLINFO[spells[1]].c)
  end

  if pending then
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
      local c = (i == node_idx) and 10 or (i == stair_node and 11 or 5)
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
  lightfx = dget(2) < 1        -- slot defaults to 0, so effects start on
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

  -- flicker: the light map is rebuilt on a step, never per frame
  if frame % 4 == 0 then
    flicker = flicker + 1
    if mode ~= "title" then light_build() end
  end

  parts_update()
  if hero.anim > 0 then hero.anim = hero.anim - 1 end
  for m in all(node.mons) do if m.anim > 0 then m.anim = m.anim - 1 end end
  anim_lerp()

  if mode == "title" then
    if btnp(5) then
      lightfx = not lightfx
      dset(2, lightfx and 0 or 1)
      sfx_safe("menu_select")
    end
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
      if btnp(5) and #spells > 0 then
        local s = spells[1]
        deli(spells, 1)
        cast(s)
        end_turn()
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
           "minor poet", "cave troll" }

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
    "x confirm   z cast",
    "best depth " .. best_depth .. "  hi " .. hiscore,
    "z  torchlight " .. (lightfx and "on" or "off"),
    "press x to start",
  }
  local x = block_x(l)
  banner(l[1], trow(0), 10, x)
  banner(l[2], trow(1), 12, x)
  banner(l[3], trow(2), 7, x)
  banner(l[4], trow(3), 7, x)
  banner(l[5], trow(4), 6, x)
  banner(l[6], trow(5), lightfx and 10 or 6, x)
  if frame % 40 < 26 then banner(l[7], trow(6), 10, x) end
end
