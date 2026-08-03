#!/usr/bin/env python3
"""Structural checks on deeper.lua's dungeon generator, run under the same
shim the browser uses. Connectivity and reachability, not looks."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cartlab import load_cart

lua = load_cart(init=False)

probe = r'''
function probe_floor(seed, d)
  srand(seed)
  run_seed = seed
  depth = d
  hero = hero or { tx = 0, ty = 0, px = 0, py = 0, face = 3, anim = 0 }
  torchfuel = 250
  spell_light = 0
  helm_pot = false
  floor_build(d)

  -- reachability over the graph
  local seen, q, qi = { [1] = true }, { 1 }, 1
  while qi <= #q do
    local n = nodes[q[qi]]
    for dir = 1, 4 do
      local x = n.exits[dir]
      if x and not seen[x.to] then seen[x.to] = true add(q, x.to) end
    end
    qi = qi + 1
  end
  local reach = 0
  for i = 1, #nodes do if seen[i] then reach = reach + 1 end end

  -- every exit must be mirrored by the node it points at
  local bad = 0
  for i = 1, #nodes do
    for dir = 1, 4 do
      local x = nodes[i].exits[dir]
      if x then
        local back = nodes[x.to].exits[x.back]
        if not back or back.to ~= i then bad = bad + 1 end
        if not nodes[i].door[dir] then bad = bad + 100 end
      end
    end
  end

  -- geometry: every node inside the grid, doors on walkable rows/cols
  local geo, rooms, corrs, mons, items = 0, 0, 0, 0, 0
  local maxw, maxh = 0, 0
  for i = 1, #nodes do
    local n = nodes[i]
    if n.kind == "corr" then corrs = corrs + 1 else rooms = rooms + 1 end
    mons = mons + #n.mons
    items = items + #n.items
    -- nodes now fill the grid rather than stopping a tile short of it, so the
    -- invariant is the grid itself plus the voxel extent below
    if n.w > GW or n.h > GH then geo = geo + 1 end
    maxw = max(maxw, n.w) maxh = max(maxh, n.h)
    -- voxel extent
    if OX + n.w * TS > 127 or OY + n.h * TS > 127 then geo = geo + 1000 end
    if n.w < 3 or n.h < 3 then geo = geo + 1 end
    for dir = 1, 4 do
      local dd = n.door[dir]
      if dd then
        -- the tile just inside the door must be walkable, or the exit is a trap
        local ix = dd.x + (dir == 2 and -1 or dir == 4 and 1 or 0)
        local iy = dd.y + (dir == 3 and -1 or dir == 1 and 1 or 0)
        if not node_free(n, ix, iy) then geo = geo + 1 end
      end
    end
    if #n.torch == 0 then geo = geo + 10 end
  end
  return #nodes, reach, bad, geo, rooms, corrs, mons, items, maxw, maxh
end
'''
err = lua.globals().vb_load(probe, "probe")
if err:
    sys.exit("probe: " + err)

call = lua.globals().vb_call
bad_total = geo_total = 0
unreach = 0
print(f"{'seed':>6} {'d':>2} {'nodes':>5} {'reach':>5} {'link':>4} {'geo':>4} "
      f"{'rm':>3} {'cor':>3} {'mon':>4} {'itm':>4} {'maxw':>4} {'maxh':>4}")
for i, (seed, d) in enumerate([(s, dd) for s in range(1, 21) for dd in (1, 3, 5, 8)]):
    n, reach, bad, geo, rooms, corrs, mons, items, mw, mh = call("probe_floor", seed * 131, d)
    bad_total += bad
    geo_total += geo
    if reach != n:
        unreach += 1
    if i < 12:
        print(f"{seed*131:>6} {d:>2} {n:>5} {reach:>5} {bad:>4} {geo:>4} "
              f"{rooms:>3} {corrs:>3} {mons:>4} {items:>4} {mw:>4} {mh:>4}")

print()
print(f"80 floors: link errors={bad_total}  geometry errors={geo_total}  "
      f"floors with unreachable nodes={unreach}")
