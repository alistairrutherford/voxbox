#!/usr/bin/env python3
"""Item, armour and prop checks for deeper.lua.

Armour slots and the drain/repair loop, what floor 1 actually offers,
torch counts, monument placement and effects, and the scroll prompt.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cartlab import load_cart, read

lua = load_cart(init=True)

# ---- from armour.py -------------------------------------------------
lua.globals().vb_load(r'''
function probe_armour(seed, floors)
  srand(seed)
  mode = "play"
  new_game()
  local total, out = 0, ""
  for d = 1, floors do
    depth = d
    floor_build(d)
    local pieces = 0
    for i = 1, #nodes do
      for it in all(nodes[i].items) do
        local k = ITEMS[it.ii].k
        if k == "helm" or k == "chest" or k == "shield" then
          pieces = pieces + 1
          item_take(it)
        end
      end
    end
    total = total + pieces
    out = out .. "d" .. d .. ": +" .. pieces .. " pieces, arm=" .. arm .. "  "
  end
  return out, arm, total
end''', "p")
out, arm, total = lua.globals().vb_call("probe_armour", 4242, 6)
print(out)
print(f"after 6 floors, taking every piece found: arm = {arm} from {total} pickups")

# drain and repair: a wraith damages the best piece, a fresh piece of that kind
# puts it back. Also check a worse duplicate is refused rather than swallowed.
lua.globals().vb_load(r'''
function probe_drain()
  mode = "play"
  new_game()
  armv = { helm = 0, chest = 0, shield = 0 }
  arm_sync()
  local log = ""
  item_take({ ii = 5, x = 1, y = 1 })     -- steel helm, 2
  item_take({ ii = 6, x = 1, y = 1 })     -- breastplate, 3
  log = log .. "equipped: " .. arm .. " (h" .. armv.helm .. " c" .. armv.chest .. ")  "
  local took = item_take({ ii = 4, x = 1, y = 1 })   -- pot helm, 1: worse
  log = log .. "pot helm taken=" .. tostr(took) .. " arm=" .. arm .. "  "
  -- a wraith lands three hits
  hp, hpmax = 99, 99
  local w = nil
  for i = 1, #BESTIARY do if BESTIARY[i].drain then w = i end end
  local m = mon_new(w, 2, 2)
  for i = 1, 3 do mon_attack(m, BESTIARY[w]) end
  log = log .. "after 3 drains: " .. arm .. " (h" .. armv.helm .. " c" .. armv.chest .. ")  "
  item_take({ ii = 6, x = 1, y = 1 })     -- fresh breastplate repairs the slot
  log = log .. "after repair: " .. arm .. " (h" .. armv.helm .. " c" .. armv.chest .. ")"
  return log
end''', "d")
print(lua.globals().vb_call("probe_drain"))

# The weapon slot is the offence half of the same idea, and the thing it exists
# to fix is a curve, not a number: monster health scales with depth, so what
# matters is whether a bump still lands in a sane number of hits deep down.
lua.globals().vb_load(r'''
function probe_weapon(seed, floors)
  srand(seed)
  mode = "play"
  new_game()
  local out = ""
  for d = 1, floors do
    depth = d
    floor_build(d)
    for i = 1, #nodes do
      for it in all(nodes[i].items) do
        if ITEMS[it.ii].k == "wpn" then item_take(it) end
      end
    end
    out = out .. "d" .. d .. ": wpn=" .. wpnv .. " dmg=" .. dmg .. "  "
  end
  return out, wpnv, dmg
end

-- Hits to kill the sturdiest monster available at a depth, bare-handed against
-- fully armed. Bare-handed is the old curve: it is the column that shows why
-- the slot had to exist.
function probe_curve(depths)
  local out = ""
  for di = 1, #depths do
    local d = depths[di]
    depth = d
    local worst = 0
    for i = 1, #BESTIARY do
      local b = BESTIARY[i]
      -- must match mon_roll: bosses are placed, never rolled, so including
      -- one here would report a curve against a monster you cannot meet
      local top = min(d, MON_DMAX)
      if b.d <= top and b.d >= top - 4 and not b.boss then
        worst = max(worst, flr(b.hp * (1 + (d - 1) * 0.14)))
      end
    end
    -- mean bump is dmg + 1 (irnd(3) averages 1)
    local bare = ceil(worst / (DMG_BASE + 1))
    local armed = ceil(worst / (DMG_BASE + WPN_MAX + 1))
    out = out .. "d" .. d .. ": " .. worst .. "hp = " .. bare .. " bare / "
        .. armed .. " armed   "
  end
  return out
end''', "w")
out, wpnv, dmgv = lua.globals().vb_call("probe_weapon", 4242, 8)
print(out)
print(f"after 8 floors, taking every weapon found: wpn = {int(wpnv)}/"
      f"{int(lua.globals().vb_get('WPN_MAX'))}, dmg = {int(dmgv)}")
depths = lua.table_from([1, 3, 5, 7, 9, 11, 13])
print("hits to kill the toughest monster on a floor:")
print("  " + lua.globals().vb_call("probe_curve", depths))



# The new menagerie. Every one of these is a rule rather than a stat line, and
# a rule that silently does nothing looks exactly like a rule that works.
lua.globals().vb_load(r"""
function mob_find(nm)
  for i = 1, #BESTIARY do if BESTIARY[i].n == nm then return i end end
  return 0
end
function mob_solo(nm, dx, dy)
  mode = "play" new_game()
  node.mons = {} node.items = {}
  hp, hpmax, arm = 200, 200, 0
  local bi = mob_find(nm)
  local m = mon_new(bi, hero.tx + (dx or 1), hero.ty + (dy or 0))
  add(node.mons, m)
  return m, BESTIARY[bi]
end

function probe_mobs()
  local out = ""

  -- tomb beetle: its own armour, so the weapon slot is what beats it
  local m = mob_solo("tomb beetle")
  wpnv = 0 wpn_sync()
  local h = m.hp mon_hurt(1, dmg + 1) local bare = h - m.hp
  wpnv = 4 wpn_sync()
  h = m.hp mon_hurt(1, dmg + 1)
  out = out .. "beetle arm " .. m.arm .. ": fists " .. bare ..
        ", blade " .. (h - m.hp) .. (bare < h - m.hp and "" or "  BROKEN") .. "\n"

  -- chandelier rat: takes gold, deals nothing, runs
  local b
  m, b = mob_solo("chandelier rat")
  gold = 100 mon_attack(m, b)
  out = out .. "rat: gold 100->" .. gold .. " hp intact " .. tostr(hp == 200) ..
        " fleeing " .. tostr(m.fleeing == true) .. "\n"

  -- auditor: takes the best rating it can see, weapon included
  m, b = mob_solo("the auditor")
  armv = { helm = 2, chest = 3, shield = 2 } arm_sync()
  wpnv = 4 wpn_sync()
  mon_attack(m, b) mon_attack(m, b)
  out = out .. "auditor: wpn 4 arm 7 -> wpn " .. wpnv .. " arm " .. arm .. "\n"

  -- echo: repeats your last spell back at you
  m, b = mob_solo("the echo")
  last_spell = "fireball"
  h = hp
  for i = 1, 12 do mon_attack(m, b) end
  out = out .. "echo: 12 attacks cost " .. (h - hp) .. " hp\n"

  -- grief: follows anywhere, moves every other turn
  m, b = mob_solo("grief", 6, 0)
  local moves = 0
  for t = 1, 10 do
    local x0 = m.x turns = t mons_turn()
    if m.x ~= x0 then moves = moves + 1 end
  end
  out = out .. "grief: moved on " .. moves .. "/10 turns, follows " ..
        tostr(b.follows == true) .. "\n"

  -- understudy: the only weapon drop that is not the boss or the loot table
  m, b = mob_solo("the understudy")
  depth = 6 mon_hurt(1, 999)
  local got = "nothing"
  for it in all(node.items) do got = ITEMS[it.ii].n end
  out = out .. "understudy dropped: " .. got .. "\n"

  -- centipede: a train, and a bump on the tail hurts the whole animal
  m, b = mob_solo("centipede", 5, 0)
  for t = 1, 4 do mons_turn() end
  local spread = "head " .. m.x
  for s in all(m.seg) do spread = spread .. "," .. s.x end
  local tail = m.seg[#m.seg]
  hero.tx, hero.ty = tail.x - 1, tail.y
  h = m.hp hero.face = 2 try_move(2)
  out = out .. "centipede x: " .. spread .. "  tail bump took " ..
        (h - m.hp) .. ((h - m.hp) > 0 and "" or "  BROKEN") .. "\n"

  -- mimic: a chest until bumped
  m, b = mob_solo("mimic")
  local hidden = not m.angry
  hero.face = 2 hero.tx, hero.ty = m.x - 1, m.y
  try_move(2)
  out = out .. "mimic: disguised " .. tostr(hidden) .. " -> angry " ..
        tostr(m.angry == true) .. "\n"
  return out
end

function probe_crew()
  mode = "play" new_game()
  node.mons = {} node.items = {}
  hp, hpmax, arm = 400, 400, 0
  local bi = mob_find("the committee")
  for k = 1, 3 do
    local c = mon_new(bi, 2 + k, 5) c.crew = 1 add(node.mons, c)
  end
  mon_hurt(1, 999)
  local a = "one down -> " .. crew_alive(1) .. " up"
  for t = 1, CREW_REVIVE + 1 do crew_turn() end
  a = a .. ", revived to " .. crew_alive(1)
  for i = #node.mons, 1, -1 do mon_hurt(i, 999) end
  a = a .. "; all three in one round -> " .. crew_alive(1) .. " up"
  crew_turn()
  return a .. ", " .. #node.mons .. " left"
end

function probe_sconce()
  mode = "play" new_game()
  node.mons = {}
  hp, hpmax, arm = 200, 200, 0
  local bi = 0
  for i = 1, #BESTIARY do if BESTIARY[i].snuff then bi = i end end
  local lit0 = 0
  for t in all(node.torch) do if t.lit then lit0 = lit0 + 1 end end
  local t1 = node.torch[1]
  local m = mon_new(bi, hero.tx + 2, hero.ty)
  add(node.mons, m)
  m.x, m.y = t1.x, t1.y
  if not node_free(node, m.x, m.y) then
    for _, d in pairs(DIRS) do
      if node_free(node, t1.x + d[1], t1.y + d[2]) then
        m.x, m.y = t1.x + d[1], t1.y + d[2]
      end
    end
  end
  mons_turn()
  local lit1 = 0
  for t in all(node.torch) do if t.lit then lit1 = lit1 + 1 end end
  local dead = nil
  for t in all(node.torch) do if not t.lit then dead = t end end
  if not dead then return "sconces " .. lit0 .. " -> " .. lit1 .. "  NOTHING SNUFFED" end
  local dir = nil
  for k = 1, 4 do
    local fx, fy = dead.x - DIRS[k][1], dead.y - DIRS[k][2]
    if node_free(node, fx, fy) then
      hero.tx, hero.ty, hero.px, hero.py = fx, fy, fx, fy
      dir = k
    end
  end
  node.mons = {}
  if dir then try_move(dir) end
  return "sconces " .. lit0 .. " -> " .. lit1 ..
         ", relit by bumping the wall " .. tostr(dead.lit)
end

function probe_chests()
  local n = 0
  for d = 1, 6 do
    floor_build(d)
    for i = 1, #nodes do
      for p in all(nodes[i].props) do if p.kind == "chest" then n = n + 1 end end
    end
  end
  return n .. " chests over 6 floors"
end""")
print(str(lua.globals().vb_call("probe_mobs")).rstrip().replace("\n", "\n         ").rjust(0))
print("crew     " + str(lua.globals().vb_call("probe_crew")))
print("sconce   " + str(lua.globals().vb_call("probe_sconce")))
print("chests   " + str(lua.globals().vb_call("probe_chests")))


# The light-driven AI, the douse and the retreat rules. All four were silent
# failures waiting to happen: a radius of zero still lights one cell, so the
# douse did nothing while looking as though it worked, and none of it is
# visible from a screenshot.
lua.globals().vb_load(r'''
function goto_dark()
  local bx, by, bd = hero.tx, hero.ty, -1
  for y = 1, node.h - 2 do
    for x = 1, node.w - 2 do
      if node_free(node, x, y) then
        local near = 99
        for t in all(node.torch) do near = min(near, chebyshev(t.x, t.y, x, y)) end
        if near > bd then bx, by, bd = x, y, near end
      end
    end
  end
  hero.tx, hero.ty, hero.px, hero.py = bx, by, bx, by
  return bd
end

function probe_stealth()
  mode = "play" new_game()
  goto_dark()
  torchlit = true light_build()
  local a, b = hero_light(), aggro_range()
  torchlit = false light_build()
  local c, d = hero_light(), aggro_range()
  -- an unseen thing in an unlit tile gets the first hit
  node.mons = {}
  hp, hpmax, arm = 60, 60, 0
  local m = mon_new(4, hero.tx + 1, hero.ty)
  add(node.mons, m)
  local h = hp mon_attack(m, BESTIARY[m.bi]) local first = h - hp
  h = hp mon_attack(m, BESTIARY[m.bi]) local second = h - hp
  return "lit: light " .. a .. " noticed at " .. b ..
         "   doused: light " .. c .. " noticed at " .. d ..
         "   ambush " .. first .. " then " .. second ..
         ((d < b and first > second) and "  ok" or "  BROKEN")
end

function probe_fuel()
  mode = "play" new_game()
  torchfuel = 100 torchlit = false end_turn()
  local doused = torchfuel
  torchlit = true end_turn()
  return "fuel over one turn: doused " .. (100 - doused) ..
         ", lit " .. (doused - torchfuel)
end

function probe_follow(runs)
  local followed, tries = 0, 0
  for t = 1, runs do
    new_game()
    local dir, dd = nil, nil
    for k = 1, 4 do if node.exits[k] then dir, dd = k, node.door[k] end end
    if dir then
      hero.tx, hero.ty = dd.x - DIRS[dir][1], dd.y - DIRS[dir][2]
      node.mons = {}
      local m = mon_new(1, hero.tx, hero.ty + 1)
      if not node_free(node, m.x, m.y) then m.y = hero.ty - 1 end
      m.angry = true
      add(node.mons, m)
      tries = tries + 1
      local was = node_idx
      try_move(dir)
      if node_idx ~= was then
        for mm in all(node.mons) do if mm == m then followed = followed + 1 end end
      end
    end
  end
  return followed .. "/" .. tries .. " retreats followed (odds " ..
         FOLLOW_ODDS .. ")"
end

function probe_ring()
  mode = "play" new_game()
  stones = 4
  spells = { "fireball", "light" }
  local r = ring_items()
  local names = ""
  for i = 1, #r do names = names .. r[i].n .. ", " end
  -- a throw that lines up, and one that does not
  node.mons = {}
  add(node.mons, mon_new(1, hero.tx + 3, hero.ty))
  local hit = throw_stone()
  node.mons = {}
  add(node.mons, mon_new(1, hero.tx + 3, hero.ty + 2))
  local miss = throw_stone()
  return "ring: " .. sub(names, 1, #names - 2) ..
         "   throw in line " .. tostr(hit) .. ", off line " .. tostr(miss) ..
         ", stones left " .. stones
end

function probe_wish()
  mode = "play" new_game()
  local si = 0
  for i = 1, #SHRINES do if SHRINES[i].k == "wish" then si = i end end
  if si == 0 then return "no wish shrine authored" end
  local p = { x = 1, y = 1, kind = "shrine", si = si, used = false }
  gold, hp, hpmax = 10, 5, 40
  prop_touch(p)
  local poor = "broke: gold " .. gold .. " hp " .. hp .. " spent " .. tostr(p.used)
  gold = 500
  prop_touch(p)
  return poor .. "   |  rich: gold " .. gold .. " hp " .. hp ..
         " spent " .. tostr(p.used)
end''', "mech")
print("stealth   " + str(lua.globals().vb_call("probe_stealth")))
print("torch     " + str(lua.globals().vb_call("probe_fuel")))
print("retreat   " + str(lua.globals().vb_call("probe_follow", 60)))
print("ring      " + str(lua.globals().vb_call("probe_ring")))
print("wish well " + str(lua.globals().vb_call("probe_wish")))


# The boss fight, simulated with the real combat code -- real telegraph, real
# escalation, real armour drain -- because the closed form got it wrong twice.
# Escalation and the drain interact: by the seventh landed strike there is no
# armour left to subtract, which no static estimate caught. It is a gear check,
# so it is checked at four levels of kit and must stay winnable at the top and
# lethal at the bottom.
lua.globals().vb_load(r'''
function probe_bossfight(d, wpn, drink)
  srand(d * 7717)
  depth = d mode = "play"
  floor_build(d)
  enter(stair_node, nil)
  wpnv = wpn wpn_sync()
  armv = { helm = 2, chest = 3, shield = 2 } arm_sync()
  hpmax = HP_START + DIVE_MAX * (d - 1)
  hp = hpmax
  local bm = boss_mon()
  if not bm then return "NO BOSS ON A BOSS FLOOR" end
  local hp0, arm0, dmg0 = bm.hp, bm.arm, bm.dmg
  local turns, heals = 0, 0
  while bm.hp > 0 and hp > 0 and turns < 400 do
    turns = turns + 1
    local idx = 0
    for i = 1, #node.mons do if node.mons[i] == bm then idx = i end end
    if idx > 0 then mon_hurt(idx, dmg + 1) end
    if bm.hp <= 0 then break end
    mon_attack(bm, BESTIARY[bm.bi])
    if drink > 0 and hp <= hpmax * 0.3 and heals < drink then
      hp = min(hpmax, hp + 14) heals = heals + 1
    end
  end
  return "d" .. d .. " wpn" .. wpn .. "/" .. drink .. "draught: boss " .. hp0 ..
         "hp arm" .. arm0 .. " dmg" .. dmg0 .. " -> " .. turns .. " turns, " ..
         max(0, hp) .. "/" .. hpmax .. " left" ..
         (hp > 0 and "  WIN" or "  dead")
end

function probe_bossfloors(upto)
  local out = ""
  for d = 1, upto do
    floor_build(d)
    local n, locked = 0, false
    for i = 1, #nodes do
      for m in all(nodes[i].mons) do if m.boss then n = n + 1 end end
    end
    if is_boss_floor(d) ~= (n > 0) then out = out .. " d" .. d .. " MISMATCH" end
    if n > 1 then out = out .. " d" .. d .. " HAS " .. n end
  end
  return out == "" and "every 10th floor has exactly one boss, no other floor has any"
         or out
end''', "boss")
print("boss floors: " + str(lua.globals().vb_call("probe_bossfloors", 30)))
for d in (10, 20, 30):
    for wpn, drink in ((4, 1), (4, 0), (0, 1)):
        print("  " + str(lua.globals().vb_call("probe_bossfight", d, wpn, drink)))


# Two failures that were silent in play, so they get printed every run: a
# roster that empties out past the deepest monster in the book and falls back
# to sewer rats, and a death that fires once per adjacent attacker.
lua.globals().vb_load(r'''
function probe_roster(dd)
  local out = ""
  for i = 1, #dd do
    local d, seen, n = dd[i], {}, 0
    for t = 1, 400 do
      local bi = mon_roll(d)
      if not seen[bi] then seen[bi] = true n = n + 1 end
    end
    local rat = seen[1] and (n == 1) and " RAT-ONLY FALLBACK" or ""
    out = out .. "d" .. d .. ":" .. n .. rat .. "  "
  end
  return out
end

DEATHS = 0
local real_die = die
function die(by) DEATHS = DEATHS + 1 real_die(by) end

function probe_onedeath()
  mode = "play" new_game()
  node.mons = {} node.items = {}
  add(node.mons, mon_new(1, hero.tx + 1, hero.ty))
  add(node.mons, mon_new(4, hero.tx - 1, hero.ty))
  add(node.mons, mon_new(4, hero.tx, hero.ty + 1))
  hp = 1
  DEATHS = 0
  mons_turn()
  return DEATHS, tostr(killer)
end''', "r")
depths = lua.table_from([1, 5, 9, 13, 14, 20, 30])
print("monsters in the roll pool by depth: "
      + lua.globals().vb_call("probe_roster", depths))
n, killer = lua.globals().vb_call("probe_onedeath")
print(f"killed with three attackers adjacent: die() fired {int(n)}x "
      f"(want 1), killer = {killer}")


# ---- from snag.py ---------------------------------------------------
lua.globals().vb_load(r'''
function probe_torches(floors)
  local lo, hi, tot, n = 99, 0, 0, 0
  local statues, shrines, roomsWithProps = 0, 0, 0
  for d = 1, floors do
    depth = d
    run_seed = 1000 + d * 7
    floor_build(d)
    for i = 1, #nodes do
      local nd = nodes[i]
      local c = #nd.torch
      lo = min(lo, c) hi = max(hi, c) tot = tot + c n = n + 1
      local sc, hc = 0, 0
      for p in all(nd.props) do
        if p.kind == "statue" then sc = sc + 1 else hc = hc + 1 end
        -- a monument must sit on a blocking tile, or you would walk through it
        if nd.tile[p.y][p.x] ~= T_WALL then BADTILE = (BADTILE or 0) + 1 end
      end
      statues = statues + sc shrines = shrines + hc
      if sc + hc > 0 then roomsWithProps = roomsWithProps + 1 end
    end
  end
  return lo, hi, tot / n, n, statues, shrines, roomsWithProps, BADTILE or 0
end

function probe_shrines()
  mode = "play" new_game()
  local log = ""
  -- one of each shrine kind, fired twice to prove the once-only rule
  for si = 1, #SHRINES do
    local sh = SHRINES[si]
    hp, hpmax, torchfuel, gold = 5, 20, 30, 0
    armv = { helm = 2, chest = 1, shield = 0 } arm_sync()
    -- a chipped weapon, so the whetstone kind has something to act on
    wpnv = 2 wpn_sync()
    local p = { x = 1, y = 1, kind = "shrine", si = si, used = false }
    local function state()
      return hp .. "/" .. torchfuel .. "/" .. gold .. "/" .. arm .. "/w" .. wpnv
    end
    local before = state()
    prop_touch(p)
    local after = state()
    local hp2, w2 = hp, wpnv
    prop_touch(p)                       -- second touch must do nothing
    log = log .. sh.k .. ": " .. before .. " -> " .. after ..
          ((hp == hp2 and wpnv == w2) and " (reuse ok)" or " (REUSE BUG)") .. "  "
  end
  return log
end

function probe_prompt()
  mode = "play" new_game()
  node.items = {}
  node.mons = {}
  spells = {}
  -- drop a chicken potion next to the hero and step onto it
  local sx, sy = hero.tx + 1, hero.ty
  if not node_free(node, sx, sy) then sx, sy = hero.tx - 1, hero.ty end
  local ii = 0
  for i = 1, #ITEMS do if ITEMS[i].s == "chicken" then ii = i end end
  add(node.items, item_new(ii, sx, sy))
  hero.anim = 0
  try_move(sx > hero.tx and 2 or 4)
  local a = "stepped on: pending=" .. tostr(pending ~= nil) ..
            " spells=" .. #spells .. " items=" .. #node.items
  -- decline
  pending.declined = true
  pending = nil
  local b = " after no: spells=" .. #spells .. " items=" .. #node.items
  -- accept
  local it = node.items[1]
  local took = item_take(it)
  if took then deli(node.items, 1) end
  local c = " after yes: spells=" .. #spells .. " items=" .. #node.items
  return a .. b .. c
end''', "p")
c = lua.globals().vb_call
lo, hi, avg, n, st, sh, rooms, bad = c("probe_torches", 8)
print(f"torches over {int(n)} nodes on 8 floors: min {int(lo)}, max {int(hi)}, mean {avg:.1f}")
print(f"monuments: {int(st)} statues, {int(sh)} shrines across {int(rooms)} nodes; "
      f"{int(bad)} on non-blocking tiles")
print(c("probe_shrines"))
print(c("probe_prompt"))


# ---- from floor1.py -------------------------------------------------
lua.globals().vb_load(r'''
function probe_floor1(runs)
  local anyArm, anyChest, ceilTot, none = 0, 0, 0, 0
  for r = 1, runs do
    srand(r * 977)
    mode = "play"
    new_game()          -- builds floor 1
    armv = { helm = 0, chest = 0, shield = 0 } arm_sync()
    local sawChest = false
    for i = 1, #nodes do
      for it in all(nodes[i].items) do
        local k = ITEMS[it.ii].k
        if k == "helm" or k == "chest" or k == "shield" then
          if k == "chest" then sawChest = true end
          item_take(it)
        end
      end
    end
    if arm > 0 then anyArm = anyArm + 1 else none = none + 1 end
    if sawChest then anyChest = anyChest + 1 end
    ceilTot = ceilTot + arm
  end
  return anyArm, anyChest, ceilTot / runs, none
end''', "p")
a, c, avg, none = lua.globals().vb_call("probe_floor1", 200)
print(f"floor 1, 200 seeds: {int(a)}/200 offer some armour, {int(c)}/200 offer a "
      f"breastplate, {int(none)}/200 offer none")
print(f"mean armour available on floor 1 if you collect it all: {avg:.2f} (cap is 7)")


# ---- monument text --------------------------------------------------
# The statue and shrine lists are authored in deeper.voxbox.json, which means
# they can be edited by someone who never opens the cart. These are the three
# ways that goes wrong silently: a line too long for the HUD row is truncated
# mid-word, a character the font has no glyph for still advances the cursor and
# leaves a hole, and a shrine kind prop_touch does not implement fires and does
# nothing. The font is read out of runtime/js/font.js rather than restated
# here, so extending the font relaxes this check by itself.
GLYPHS = set(re.findall(r"""^  (?:'(.)'|"(.)"):""",
                        read("runtime", "js", "font.js"), re.M))
GLYPHS = {a or b for a, b in GLYPHS}      # the apostrophe key is double-quoted
# The kinds are read out of prop_touch rather than restated here, for the same
# reason the glyphs are read out of font.js: a list kept in two places is a list
# that drifts, and the failure mode -- an authored shrine that fires and does
# nothing -- is silent in the game.
KINDS = set(re.findall(r'sh\.k == "(\w+)"', read("carts", "deeper.lua")))
g = lua.globals()
cols = int(g.vb_get("HUD_COLS"))
bad = []
for name in ("STATUES", "SHRINES"):
    t = g.vb_get(name)
    for i in range(1, len(t) + 1):
        e = t[i]
        for field in ("n", "say"):
            s = e[field]
            if len(s) > cols:
                bad.append(f"{name}[{i}].{field}: {len(s)} > {cols} chars: {s!r}")
            missing = sorted(set(s.upper()) - GLYPHS)
            if missing:
                bad.append(f"{name}[{i}].{field}: no glyph for {missing}: {s!r}")
        if name == "SHRINES" and e["k"] not in KINDS:
            bad.append(f"SHRINES[{i}].k = {e['k']!r}, not one of {sorted(KINDS)}")
n = len(g.vb_get("STATUES")) + len(g.vb_get("SHRINES"))
print(f"monument text: {n} entries, {len(GLYPHS)} glyphs, {cols} columns; "
      + ("all fit" if not bad else f"{len(bad)} PROBLEMS"))
for b in bad:
    print("  " + b)
