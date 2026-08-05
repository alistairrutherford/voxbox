#!/usr/bin/env python3
"""Scripted play of deeper.lua. The bundled driver only holds one direction,
which for a turn-based game proves nothing past 'it did not crash'. This walks
the dungeon, fights, casts every spell and draws every monster plan."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cartlab import load_cart

lua = load_cart(init=True)

probe = r'''
-- Play with intent: go for the nearest monster, else the stairs, else a door.
-- Counters accumulate across lives, because new_game() resets the cart's own.
function probe_play(seed, steps)
  srand(seed)
  mode = "play"
  new_game()
  local moved, atk, doors, killed, got = 0, 0, 0, 0, 0
  local descends, deaths, casts, maxdepth = 0, 0, 0, 1
  local prev = 0

  local function goal()
    local best, bd = nil, 999
    for m in all(node.mons) do
      local d = chebyshev(m.x, m.y, hero.tx, hero.ty)
      if d < bd then best, bd = m, d end
    end
    if best then return best.x, best.y end
    if node.stair then return node.stair.x, node.stair.y end
    -- prefer a door that is not the one we just came through, or the walk
    -- ping-pongs on every leaf node and never explores
    for dir = 1, 4 do
      local e = node.door[dir]
      if e and node.exits[dir] and node.exits[dir].to ~= prev then
        return e.x, e.y
      end
    end
    for dir = 1, 4 do
      if node.door[dir] then return node.door[dir].x, node.door[dir].y end
    end
    return nil
  end

  for i = 1, steps do
    frame = frame + 1
    if mode == "over" then
      deaths = deaths + 1
      mode = "play"
      new_game()
    end
    local dir = irnd(4) + 1
    local gx, gy = goal()
    if gx and rnd(1) < 0.85 then
      local dx, dy = isgn(gx - hero.tx), isgn(gy - hero.ty)
      if dx ~= 0 and (dy == 0 or rnd(1) < 0.5) then dir = (dx > 0) and 2 or 4
      elseif dy ~= 0 then dir = (dy > 0) and 3 or 1 end
    end

    local hx, hy = hero.tx, hero.ty
    local ni, mc, gd, dp = node_idx, #node.mons, gold, depth
    hero.anim = 0
    try_move(dir)
    if hero.tx ~= hx or hero.ty ~= hy then moved = moved + 1 end
    if node_idx ~= ni then doors = doors + 1 prev = ni end
    if depth > dp then descends = descends + 1 end
    if node_idx == ni and #node.mons < mc then killed = killed + mc - #node.mons end
    if node_idx == ni and #node.mons == mc and hero.tx == hx and hero.ty == hy then
      atk = atk + 1
    end
    if gold > gd then got = got + gold - gd end

    if #spells > 0 and rnd(1) < 0.06 and mode == "play" then
      local s = spells[1] deli(spells, 1) cast(s) end_turn()
      casts = casts + 1
    end
    if depth > maxdepth then maxdepth = depth end
    _draw()
  end
  return maxdepth, killed, descends, deaths, casts, got, moved, doors, atk
end

-- one of every monster and every item on screen at once: exercises all six
-- body plans, every ramp and the whole item table through the draw path
function probe_draw_all()
  mode = "play"
  new_game()
  local n = node
  n.mons, n.items = {}, {}
  for i = 1, #BESTIARY do
    add(n.mons, mon_new(i, 1 + (i % (n.w - 2)), 1 + (i % (n.h - 2))))
  end
  for i = 1, #ITEMS do
    add(n.items, item_new(i, 1 + (i % (n.w - 2)), 1 + ((i + 3) % (n.h - 2))))
  end
  for f = 1, 12 do frame = frame + 1 _draw() end
  return #BESTIARY, #ITEMS
end

-- every spell, cast back to back
function probe_spells()
  mode = "play"
  new_game()
  local names = { "fireball", "light", "annoy", "confidence", "percussion", "chicken" }
  for i = 1, #names do
    cast(names[i])
    end_turn()
    frame = frame + 1
    _draw()
  end
  -- and every armour piece
  for i = 1, #ITEMS do item_take({ ii = i, x = 1, y = 1 }) frame = frame + 1 _draw() end
  return #parts, arm, #spells
end

-- Combat in isolation: stand next to one of every monster and hit it until it
-- dies, checking the hero takes damage on the way.
function probe_combat()
  mode = "play"
  new_game()
  local unkillable, hits_total, hurt = 0, 0, 0
  for bi = 1, #BESTIARY do
    node.mons = {}
    hp, hpmax, arm = 200, 200, 0
    hero.tx, hero.ty = 2, 2
    local m = mon_new(bi, 3, 2)
    add(node.mons, m)
    local hp0, hits = hp, 0
    while #node.mons > 0 and hits < 400 do
      hero.anim = 0
      try_move(2)
      hero.tx, hero.ty = 2, 2      -- stay put; we only want the bump
      hits = hits + 1
    end
    if #node.mons > 0 then unkillable = unkillable + 1 badname = BESTIARY[bi].n end
    hits_total = hits_total + hits
    if hp < hp0 then hurt = hurt + 1 end
  end
  return unkillable, hits_total, hurt, badname or "-", #BESTIARY
end

-- Descend deliberately: teleport to the stair node, step onto the stairs, and
-- do it again. Tests the descent path and that deep floors (boss tables, the
-- last theme) generate at all -- the wandering walk never gets there.
function probe_descend(levels)
  mode = "play"
  new_game()
  local ok = 0
  for i = 1, levels do
    enter(stair_node, nil)
    if not node.stair then break end
    local before = depth
    for d = 1, 4 do
      local dd = DIRS[d]
      local sx, sy = node.stair.x - dd[1], node.stair.y - dd[2]
      if node_free(node, sx, sy) then
        hero.tx, hero.ty = sx, sy
        hero.anim = 0
        try_move(d)
        break
      end
    end
    if depth > before then ok = ok + 1 end
    frame = frame + 1
    _draw()
  end
  return depth, theme.name, #nodes, ok
end

-- How survivable is floor 1 actually? Walk a fresh run with no cleverness --
-- fight what is in front of you, never retreat -- and see how far it gets.
-- This is the floor of player skill, not the ceiling.
--
-- The bot does detour for armour it can actually use, because otherwise the
-- probe is blind to the whole drop table: making better armour *available*
-- is worth nothing to something that never goes and gets it, so changes to
-- what a floor offers showed up as no change at all. It still does not
-- retreat, heal, or pick its fights -- those stay out so the number keeps
-- meaning "worst case".
function probe_survival(seed, runs, eatfood)
  local turns_total, floor1_deaths, reached2, best = 0, 0, 0, 0
  local armEnd, detours = 0, 0

  -- the best thing worth walking to in this node: an armour upgrade, or a
  -- meal if we are hurt and the caller allows it
  local function armour_goal()
    local bit, bgain = nil, 0
    for it in all(node.items) do
      local d = ITEMS[it.ii]
      if d.k == "helm" or d.k == "chest" or d.k == "shield" then
        local gain = d.v - armv[d.k]
        if gain > bgain then bit, bgain = it, gain end
      end
    end
    if bit then return bit end
    if eatfood > 0 and hp < hpmax - 4 then
      for it in all(node.items) do
        if ITEMS[it.ii].k == "heal" then return it end
      end
    end
    return nil
  end

  local nodesSeen, firstDeath = 0, ""
  for r = 1, runs do
    srand(seed + r * 31)
    mode = "play"
    new_game()
    local t, seen = 0, {}
    while mode == "play" and t < 1200 do
      t = t + 1
      seen[node_idx] = true
      local gx, gy, bd = nil, nil, 999
      for m in all(node.mons) do
        local d = chebyshev(m.x, m.y, hero.tx, hero.ty)
        if d < bd then gx, gy, bd = m.x, m.y, d end
      end
      -- anything adjacent gets hit; otherwise grab an upgrade first
      if bd > 1 then
        local it = armour_goal()
        if it then
          gx, gy = it.x, it.y
          detours = detours + 1
        end
      end
      if not gx then
        if node.stair then gx, gy = node.stair.x, node.stair.y
        else
          for dir = 1, 4 do
            if node.door[dir] then gx, gy = node.door[dir].x, node.door[dir].y break end
          end
        end
      end
      local dir = irnd(4) + 1
      if gx then
        local dx, dy = isgn(gx - hero.tx), isgn(gy - hero.ty)
        if dx ~= 0 and (dy == 0 or rnd(1) < 0.5) then dir = (dx > 0) and 2 or 4
        elseif dy ~= 0 then dir = (dy > 0) and 3 or 1 end
      end
      hero.anim = 0
      try_move(dir)
    end
    local ns = 0
    for k, v in pairs(seen) do ns = ns + 1 end
    nodesSeen = nodesSeen + ns
    if mode == "over" then firstDeath = firstDeath .. t .. " " end
    turns_total = turns_total + t
    armEnd = armEnd + arm
    if depth > best then best = depth end
    if depth >= 2 then reached2 = reached2 + 1 end
    if mode == "over" and depth == 1 then floor1_deaths = floor1_deaths + 1 end
  end
  return flr(turns_total / runs), floor1_deaths, reached2, best,
         armEnd / runs, detours, nodesSeen / runs, firstDeath
end

-- worst case for the draw budget: deepest theme, biggest node, full of things
function probe_worst()
  mode = "play"
  new_game()
  depth = 9
  floor_build(9)
  local big, bi = nil, 1
  for i = 1, #nodes do
    if big == nil or nodes[i].w * nodes[i].h > big.w * big.h then big, bi = nodes[i], i end
  end
  enter(bi, nil)
  node.mons = {}
  for i = 1, 8 do
    add(node.mons, mon_new(mon_roll(9), 1 + (i % (node.w - 2)), 1 + (i % (node.h - 2))))
  end
  for i = 1, 6 do add(node.items, item_new(item_roll(9), 1 + i, 2)) end
  burst(hero.tx, hero.ty, 80, { 8, 9, 10, 7 })
  -- The worst case is a *settled* room. enter() starts the dissolve, and a
  -- frame drawn mid-dissolve withholds most of the room -- which quietly
  -- reported 251 calls for a frame that actually costs 700, i.e. the budget
  -- check measuring a transition and calling it the ceiling.
  dissolve = 0
  trace_flush()
  frame = frame + 1
  _draw()
  local s = trace_flush()
  local n = 0
  for _ in string.gmatch(s, "\n") do n = n + 1 end
  return n + 1, node.w, node.h, #node.mons, #parts
end
'''
if lua.globals().vb_load(probe, "probe"):
    sys.exit("probe load failed")

call = lua.globals().vb_call

md, kills, desc, deaths, casts, gold, moved, doors, atk = call("probe_play", 4242, 6000)
print(f"6000 turns: max depth {md}, {kills} kills, {desc} descents, "
      f"{deaths} deaths, {casts} casts, {gold} gold")
print(f"            {moved} steps taken, {doors} door transits, {atk} bumps/blocked")

t, f1d, r2, best, armAvg, detours, ns, deathTurns = call("probe_survival", 909, 40, 0)
print("survival, 40 runs (fights everything, detours for armour, never retreats):")
print(f"  {t} turns avg, {f1d}/40 died on floor 1, {r2}/40 reached floor 2+, "
      f"deepest {best}")
print(f"  armour {armAvg:.1f}/7 worn at end, {detours} detours, "
      f"{ns:.1f} nodes visited per run")
# When deaths do happen they have consistently landed in the first ~90 turns,
# i.e. in the second room, before any armour has been found -- which is why
# drop-table changes move this number so little. Print the turns so that stays
# checkable rather than remembered.
print(f"  deaths land at turn: {deathTurns.strip() or 'none'}")

unk, hits, hurt, badname, nmon = call("probe_combat")
print(f"combat: {unk} unkillable ({badname}), {hits} bumps for all {int(nmon)}, "
      f"{int(hurt)}/{int(nmon)} fought back")

nm, ni = call("probe_draw_all")
print(f"drew all {nm} monsters and {ni} items for 12 frames: ok")

p, arm, sp = call("probe_spells")
print(f"cast all spells + took every item: armour={arm}, particles={p}")

dep, th, nn, ok = call("probe_descend", 12)
print(f"descent: reached depth {dep} ({th}) in {ok}/12 attempts, "
      f"last floor has {nn} nodes")

calls, w, h, mons, parts = call("probe_worst")
print(f"worst-case frame: {calls} draw calls, node {w}x{h}, "
      f"{mons} monsters, {parts} particles")
