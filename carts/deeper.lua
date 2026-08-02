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
GW, GH   = 21, 21        -- grid capacity: 126 x 126 voxels of a 128 volume
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
HUD_Y    = 2             -- HUD is painted on the back plane, in that sky band

MOVE_FR  = 5             -- frames a tile step takes
MAX_PART = 80            -- particle cap: each one is a vset

-- Recovery. Rogue regenerated health with time and so does this: without it
-- the run is a one-way ratchet down to zero and no amount of good play buys
-- anything back. Slow enough that you cannot out-heal a fight -- you have to
-- break off, which is the decision the mechanic exists to create.
REGEN    = 16            -- turns per point of natural healing
DIVE_HEAL = 8            -- restored on reaching a new floor
DIVE_MAX  = 2            -- and permanent max health for getting there

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
      w = 15 + irnd(5), h = 14 + irnd(6),
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
      w = horiz and (17 + irnd(3)) or 3,
      h = horiz and 3 or (15 + irnd(5)),
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
  n.w = min(n.w, GW - 2)
  n.h = min(n.h, GH - 2)
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
  if n.kind == "room" and n.w >= 11 and n.h >= 9 then
    if rnd(1) < 0.45 then
      for py = 2, n.h - 3, 3 do
        for px = 2, n.w - 3, 3 do
          if rnd(1) < 0.5 then n.tile[py][px] = T_WALL end
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
  -- faces does not apply to something standing proud of a low wall. With
  -- rooms this size, far-wall-only lighting leaves the near half black.
  n.torch = {}
  local step = n.kind == "corr" and 5 or 4
  for x = 1, n.w - 2, step do
    if n.tile[0][x] == T_WALL and rnd(1) < 0.8 then
      add(n.torch, { x = x, y = 0, ph = rnd(1) })
    end
    if n.h > 3 and n.tile[n.h - 1][x] == T_WALL and rnd(1) < 0.5 then
      add(n.torch, { x = x, y = n.h - 1, ph = rnd(1) })
    end
  end
  for y = 1, n.h - 2, step do
    if n.tile[y][0] == T_WALL and rnd(1) < 0.8 then
      add(n.torch, { x = 0, y = y, ph = rnd(1) })
    end
    if n.w > 3 and n.tile[y][n.w - 1] == T_WALL and rnd(1) < 0.5 then
      add(n.torch, { x = n.w - 1, y = y, ph = rnd(1) })
    end
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
  local count = clamp(flr(area / 55) + irnd(2) + flr(d / 3), 0, 8)
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
end

function light_build()
  local n = node
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
    local trow = tile[tyof[ly]]
    local lrow, wrow = lmap[ly], wmap[ly]
    local cur = {}
    local lx = 0
    while lx < LW do
      local t = trow[txof[lx]]
      if t == T_VOID or t == T_WALL then
        lx = lx + 1
      else
        local l = lrow[lx]
        local c
        if t == T_FLOOR then c = (wrow[lx] and rw or rc)[l + 1]
        elseif t == T_WATER then c = ice[l + 1]
        elseif t == T_DOOR then c = (l > 0) and acc or 1
        else c = (l > 0) and 10 or 4 end

        local x0 = lx
        lx = lx + 1
        while lx < LW do
          local t2 = trow[txof[lx]]
          if t2 == T_VOID or t2 == T_WALL then break end
          local l2 = lrow[lx]
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
  local lx, ly = tx * SUB + 1, ty * SUB + 1
  local l = lmap[ly][lx]
  local r = wmap[ly][lx] and RAMPS[theme.warm] or RAMPS[theme.cold]
  return r[min(l + 1, 4)]
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
  for r in all(wruns) do
    boxfill(vx(r.x0), vy(r.ty), r.near and SILL_Z or WALL_Z,
            vx(r.x1) + TS - 1, vy(r.ty) + TS - 1, FLOOR_Z - 1, r.c)
  end
  for t in all(n.torch) do torch_draw(t) end
  if n.stair then stairs_draw(n.stair) end
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

-- ============================================================== 06_hero ==
-- Parts, not a sprite: each responds to the light map through its own ramp,
-- so a polished breastplate is yellow-white beside a torch and navy away
-- from one.
function hero_init()
  hero = { tx = 0, ty = 0, px = 0, py = 0, face = 3, anim = 0 }
  hp, hpmax, regen = 14, 14, 0
  gold, arm, dmg = 0, 0, 2
  helm, chest, shield, helm_pot = false, false, false, false
  torchfuel = 250
  spells = {}
  spell_light, spell_conf, spell_chicken, spell_swap = 0, 0, 0, 0
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
    say = { "SQUEAK. THAT IS ALL I HAVE." } },
  { n = "goblin intern", plan = "biped", ramp = "moss", hp = 5, dmg = 2, d = 1,
    flee = true, say = { "I AM ONLY HERE FOR THE XP", "IS THIS UNPAID? IT IS." } },
  { n = "sorry slime", plan = "blob", ramp = "moss", hp = 6, dmg = 2, d = 1,
    split = true, say = { "SORRY IN ADVANCE", "NO HARD FEELINGS. SOME." } },
  { n = "skeleton",   plan = "biped", ramp = "bone", hp = 8,  dmg = 3, d = 2,
    say = { "I AM ALL BONE, NO PLAN" } },
  { n = "bat cloud",  plan = "swarm", ramp = "cold", hp = 5,  dmg = 2, d = 2,
    erratic = true, say = { "WE HAVE DISCUSSED THIS" } },
  { n = "minor poet", plan = "ghost", ramp = "ice",  hp = 6,  dmg = 1, d = 2,
    calm = true, say = { "I DIED DOING WHAT I LOVED",
                         "WHICH WAS, SADLY, THIS" } },
  { n = "mimic",      plan = "blob",  ramp = "warm", hp = 10, dmg = 4, d = 3,
    say = { "OPEN ME. I AM A CHEST.", "A NORMAL CHEST. NO TEETH." } },
  { n = "cultist",    plan = "biped", ramp = "blood", hp = 9, dmg = 3, d = 3,
    say = { "THE STARS ARE NEARLY RIGHT", "GIVE IT ANOTHER FORTNIGHT" } },
  { n = "hound",      plan = "quad",  ramp = "blood", hp = 9, dmg = 4, d = 3,
    charge = true, say = { "WHO IS A GOOD BOY. NOT YOU." } },
  { n = "wraith",     plan = "ghost", ramp = "ice",  hp = 12, dmg = 4, d = 4,
    drain = true, say = { "YOUR ARMOUR LOOKS HEAVY", "LET ME TAKE THAT" } },
  { n = "live armour", plan = "biped", ramp = "cold", hp = 14, dmg = 5, d = 4,
    drops = true, say = { "NOBODY IS IN HERE", "STOP ASKING" } },
  { n = "sad ghost",  plan = "ghost", ramp = "cold", hp = 10, dmg = 2, d = 4,
    sigh = true, say = { "I EXPECTED MORE FROM YOU", "SO DID YOUR MOTHER" } },
  { n = "cave troll", plan = "tall",  ramp = "moss", hp = 20, dmg = 6, d = 5,
    smash = true, say = { "TROLL REDECORATING. MIND OUT." } },
  { n = "spider",     plan = "quad",  ramp = "bone", hp = 12, dmg = 4, d = 5,
    web = true, say = { "EIGHT LEGS, ZERO REGRETS" } },
  { n = "lich clerk", plan = "biped", ramp = "ice",  hp = 18, dmg = 5, d = 6,
    say = { "YOUR EXPENSES ARE DENIED", "RECEIPTS OR IT DID NOT HAPPEN" } },
  { n = "ghost landlord", plan = "ghost", ramp = "warm", hp = 14, dmg = 3, d = 6,
    rent = true, say = { "THAT WILL BE 40 GOLD", "THE DUNGEON IS NOT FREE" } },
  { n = "floating eye", plan = "ghost", ramp = "blood", hp = 16, dmg = 5, d = 7,
    say = { "I HAVE SEEN YOUR INVENTORY" } },
  { n = "regret",     plan = "ghost", ramp = "cold", hp = 14, dmg = 4, d = 8,
    follows = true, say = { "REMEMBER THE THING YOU SAID" } },
  { n = "the manager", plan = "tall", ramp = "blood", hp = 40, dmg = 7, d = 9,
    boss = true, say = { "I WILL HAVE TO ESCALATE THIS",
                         "THIS IS A PERFORMANCE ISSUE" } },
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
  local scale = 1 + depth * 0.12
  return {
    bi = bi, x = x, y = y, px = x, py = y, anim = 0,
    hp = flr(b.hp * scale), dmg = flr(b.dmg * scale), said = false, slow = 0,
  }
end

function mon_draw(m)
  local b = BESTIARY[m.bi]
  local x = flr(vx(0) + m.px * TS) + 3
  local y = flr(vy(0) + m.py * TS) + 3
  local l = clamp(cell_light(m.x, m.y), 0, 3)
  local c = RAMPS[b.ramp][l + 1]
  local hi = RAMPS[b.ramp][min(l + 2, 4)]
  local bob = flr(frame / 4 + m.x) % 2

  if b.plan == "biped" then
    boxfill(x - 1, y, 55, x - 1, y, 57, c)
    boxfill(x + 1, y, 55, x + 1, y, 57, c)
    boxfill(x - 1, y - 1, 52, x + 1, y + 1, 54, c)
    boxfill(x - 1, y - 1, 50, x + 1, y + 1, 51, hi)
    vset(x - 1, y + 1, 50, 8)                       -- eyes, on the near face
    vset(x + 1, y + 1, 50, 8)
  elseif b.plan == "quad" then
    boxfill(x - 1, y - 1, 54, x + 1, y + 1, 56, c)
    boxfill(x - 2, y, 56, x + 2, y, 57, c)
    boxfill(x, y + 1, 53, x + 1, y + 2, 55, hi)
    vset(x + 1, y + 2, 53, 8)
  elseif b.plan == "blob" then
    sphere(x, y, 55 + bob, 3, c)
    vset(x - 1, y + 2, 54 + bob, 7)
    vset(x + 1, y + 2, 54 + bob, 7)
  elseif b.plan == "swarm" then
    for i = 0, 4 do
      local a = frame * 0.03 + i / 5 + m.x
      boxfill(flr(x + cos(a) * 3), flr(y - sin(a) * 3), 52 + (i % 3),
              flr(x + cos(a) * 3), flr(y - sin(a) * 3), 53 + (i % 3), c)
    end
  elseif b.plan == "tall" then
    boxfill(x - 2, y - 1, 53, x + 2, y + 1, 57, c)
    boxfill(x - 1, y - 1, 49, x + 1, y + 1, 52, hi)
    vset(x - 1, y + 1, 50, 8)
    vset(x + 1, y + 1, 50, 8)
    boxfill(x - 3, y, 54, x - 3, y, 56, c)
    boxfill(x + 3, y, 54, x + 3, y, 56, c)
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
  { n = "pot helm",     k = "helm", pot = true },
  { n = "steel helm",   k = "helm" },
  { n = "breastplate",  k = "chest" },
  { n = "kite shield",  k = "shield" },
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
  if d >= 2 then add(pool, 4) add(pool, 5) end
  if d >= 3 then add(pool, 6) end
  if d >= 4 then add(pool, 7) end
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
    say("you", "THE BREAD IS FINE. JUST FINE.")
    sfx_safe("potion_powerup")
  elseif d.k == "oil" then
    torchfuel = min(400, torchfuel + d.v)
    say("you", "TORCH TOPPED UP")
    sfx_safe("potion_powerup")
  elseif d.k == "helm" then
    helm = true
    helm_pot = d.pot and true or false
    arm = arm + (d.pot and 1 or 2)
    say("you", d.pot and "IT FITS. YOU CANNOT SEE." or "A PROPER HELM")
    sfx_safe("armour_equip")
  elseif d.k == "chest" then
    chest = true
    arm = arm + 3
    say("you", "BREASTPLATE ON")
    sfx_safe("armour_equip")
  elseif d.k == "shield" then
    shield = true
    arm = arm + 2
    say("you", "SHIELD UP")
    sfx_safe("armour_equip")
  elseif d.k == "spell" then
    add(spells, d.s)
    say("you", "TOOK " .. d.n)
    sfx_safe("scroll_pickup")
  end
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
    say("you", "LET THERE BE SOME LIGHT")
  elseif s == "annoy" then
    sfx_safe("scroll_warp")
    for m in all(node.mons) do m.slow = 4 end
    say("you", "THEY ALL DROPPED THEIR KIT")
  elseif s == "confidence" then
    spell_conf = 40
    sfx_safe("potion_powerup")
    burst(hx, hy, 20, { 14, 8, 10 })
    say("you", "YOU FEEL EXTREMELY READY")
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
      say("you", "YOU BROKE YOUR OWN SWORD")
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
        say("you", "CHICKENS CANNOT HOLD SWORDS")
      else
        mon_hurt(i, roll)
      end
      end_turn()
      return
    end
  end

  if nx < 0 or ny < 0 or nx >= n.w or ny >= n.h then return end
  local t = n.tile[ny][nx]

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
      item_take(it)
      deli(n.items, i)
    end
  end
  end_turn()
end

function end_turn()
  turns = turns + 1
  torchfuel = max(0, torchfuel - 1)
  regen = regen + 1
  if regen >= REGEN then
    regen = 0
    if hp < hpmax then hp = hp + 1 end
  end
  if spell_light > 0 then spell_light = spell_light - 1 end
  if spell_conf > 0 then spell_conf = spell_conf - 1 end
  if spell_chicken > 0 then spell_chicken = spell_chicken - 1 end
  if spell_swap > 0 then spell_swap = spell_swap - 1 end
  if torchfuel == 0 and turns % 40 == 0 then
    say("you", "THE DARK IS GETTING PERSONAL")
  end
  mons_turn()
  light_build()
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
      elseif d <= 8 or b.follows then
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
    say(b.n, "I EXPECTED MORE FROM YOU")
    return
  end
  if b.rent and gold > 0 then
    local take = min(gold, 40)
    gold = gold - take
    say(b.n, "THAT WILL BE " .. take .. " GOLD")
    return
  end
  if b.drain and arm > 0 then
    arm = max(0, arm - 1)
    say(b.n, "LET ME TAKE THAT FOR YOU")
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
    say(b.n, "I AM ESCALATING THIS UPWARD")
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
function hud_draw()
  set_draw_slice(HUD_Y)
  -- Health is drawn, not printed. The host's font is 46 glyphs (font.js) and
  -- has no "|" or ":"; a missing glyph still advances the cursor, so a bar
  -- built out of pipes comes out as an invisible row of spaces.
  -- Pips show max health as well as current: the empty ones are what tells
  -- you a draught is worth drinking and that diving raised the ceiling.
  for i = 1, min(hpmax, 20) do
    local x = 4 + (i - 1) * 3
    local lit = i <= hp
    line(x, 4, x + 1, 4, lit and (hp > 3 and 8 or 14) or 5)
    line(x, 5, x + 1, 5, lit and (hp > 3 and 14 or 8) or 1)
  end
  -- The usable band was measured, not derived: a grid of labelled test rows
  -- drawn on this plane and read off a screenshot. Dropping the room to
  -- FLOOR_Z = 58 opened it right up -- z = 2..38 is clear even with a node
  -- filling the whole footprint, where the old high floor left only z = 11..32.
  -- Rows drift right as z grows, because the plane is seen at 22 degrees; that
  -- is why the right-hand column sits at x = 60 and not further left.
  if #spells > 0 then
    print("z-" .. SPELLINFO[spells[1]].n, 60, 4, SPELLINFO[spells[1]].c)
  end

  print("d" .. depth .. " " .. theme.name .. "  g" .. gold .. " a" .. arm,
        4, 12, theme.acc)

  -- torch fuel, the clock that makes the light map a mechanic
  local fw = flr(torchfuel / 400 * 30)
  line(92, 12, 122, 12, 5)
  if fw > 0 then line(92, 12, 92 + fw, 12, torchfuel > 80 and 9 or 8) end

  if bark_t > 0 then
    print(bark_who, 4, 21, 6)
    print(bark_txt, 4, 28, 7)
  end

  minimap()
end

-- The explored graph, chambers and corridors alike. `rect` is not implemented
-- by the host, so boxes are four `line` calls.
function minimap()
  local bx, bz = 92, 24
  for i = 1, #nodes do
    local n = nodes[i]
    if n.seen then
      local x = bx + flr(n.gx * 9)
      local z = bz + flr(n.gy * 9)
      local w = n.kind == "corr" and 3 or 6
      local c = (i == node_idx) and 10 or (i == stair_node and 11 or 5)
      line(x, z, x + w, z, c)
      line(x, z + 5, x + w, z + 5, c)
      line(x, z, x, z + 5, c)
      line(x + w, z, x + w, z + 5, c)
    end
  end
end

function banner(txt, z, c)
  set_draw_slice(HUD_Y)
  print(txt, 64 - #txt * 2, z, c)
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
    if btnp(4) then
      mode = "play"
      modet = 0
      srand(frame * 7 + 13)
      new_game()
      sfx_safe("menu_select")
    end

  elseif mode == "play" then
    if rept > 0 then rept = rept - 1 end
    if hero.anim == 0 then
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
  banner("you died", 8, 8)
  banner("killed by " .. (killer or "the dark"), 16, 7)
  banner("depth " .. depth .. "  score " .. score, 24, 7)
  if modet > 90 and frame % 40 < 26 then banner("press x", 32, 10) end
end

function title_draw()
  -- A lit floor, kept down at the room's own height so it stays out of the
  -- sky band the text lives in. Drawn with the same ramps as a real floor, so
  -- the title screen is a demonstration of the light model rather than a
  -- picture of one.
  local ramp = RAMPS.cold
  boxfill(6, 6, FLOOR_Z, 121, 121, FLOOR_B, ramp[2])
  for i = 3, 1, -1 do
    local r = 14 + i * 16
    boxfill(64 - r, 64 - r, FLOOR_Z, 64 + r, 64 + r, FLOOR_Z,
            RAMPS.warm[5 - i])
  end
  for i = 0, 5 do
    local a = frame * 0.01 + i / 6
    vset(flr(64 + cos(a) * 40), flr(64 - sin(a) * 40), FLOOR_Z - 1, 9)
  end
  set_draw_slice(HUD_Y)
  banner("deeper", 4, 10)
  banner("a voxbox roguelike", 11, 12)
  banner("arrows move and attack", 24, 7)
  banner("x confirm   z cast", 31, 7)
  banner("best depth " .. best_depth .. "  hi " .. hiscore, 38, 6)
  if frame % 40 < 26 then banner("press x to start", 45, 10) end
end
