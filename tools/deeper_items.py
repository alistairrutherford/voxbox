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
    local p = { x = 1, y = 1, kind = "shrine", si = si, used = false }
    local before = hp .. "/" .. torchfuel .. "/" .. gold .. "/" .. arm
    prop_touch(p)
    local after = hp .. "/" .. torchfuel .. "/" .. gold .. "/" .. arm
    local hp2 = hp
    prop_touch(p)                       -- second touch must do nothing
    log = log .. sh.k .. ": " .. before .. " -> " .. after ..
          (hp == hp2 and " (reuse ok)" or " (REUSE BUG)") .. "  "
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
KINDS = {"heal", "torch", "arm", "gold"}
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
