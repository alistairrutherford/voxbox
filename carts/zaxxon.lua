-- zaxxon.lua : an isometric-shooter homage for Voxatron  (pure Lua, no assets)
--
-- The genre's defining idea is that *altitude* is the whole game: you have to
-- read how high you are to clear a wall or line up a shot. That maps onto a
-- voxel volume better than it ever did onto a sprite screen, because the engine
-- casts a real drop shadow — the shadow sliding under your ship IS the altitude
-- gauge, exactly as the original intended it to be read.
--
-- The fortress scrolls from the back of the volume toward the camera. You hold
-- station near the front and move in x (across) and z (up/down).
-- Volume is 128(x) x 128(y, 0 = far) x 64(z, 0 = TOP), so larger z is *lower*.
-- Concatenated build order is the section numbering below.

-- =============================================================== 01_config ==
GROUND    = 52          -- z of the fortress deck
ALT_TOP   = 16          -- highest the ship may fly (smallest z)
ALT_BOT   = 46          -- lowest; 6 voxels of clearance over the deck
PLR_Y     = 98          -- the ship holds this depth; the world comes to it
SCROLL    = 1.6
P_SPD     = 2.1
P_ASPD    = 1.3
SHOT_SPD  = 5.5
ESHOT_SPD = 2.0
FUEL_MAX  = 100
FUEL_BURN = 0.055       -- ~60s on a full tank
P_COOL    = 5

-- pico-8 palette: 7 white, 8 red, 9 orange, 10 yellow, 11 green, 12 blue,
-- 13 lavender, 14 pink, 15 peach
C_DECK    = 1
C_PANEL   = 13
C_RAIL    = 12
C_STRIPE  = 14

ZONES = { "fortress", "space", "fortress", "boss" }
ZLEN  = { 1500, 950, 1700, 0 }

-- ================================================================= 02_util ==
function sfx_safe(n) pcall(play_sound, n) end
function music_safe(n, f) pcall(play_music, n, f) end
function clamp(v, lo, hi) return mid(lo, v, hi) end
function approach(v, t, s) return v + clamp(t - v, -s, s) end
function near(a, b, r) return abs(a - b) <= r end
function pick(t) return t[flr(rnd(#t)) + 1] end
function hit3(a, b, rx, ry, rz)
  return near(a.x, b.x, rx) and near(a.y, b.y, ry) and near(a.z, b.z, rz)
end

-- ================================================================ 03_world ==
function world_init()
  stars = {}
  for i = 1, 90 do
    add(stars, { x = rnd(128), y = rnd(128), z = rnd(40) + 14, c = pick({7, 6, 12, 14, 10}) })
  end
end

function stars_update()
  for s in all(stars) do
    s.y = s.y + SCROLL * 1.15
    if s.y > 127 then
      s.y = s.y - 128
      s.x = rnd(128)
      s.z = rnd(40) + 14
    end
  end
end

function has_deck() return zone_kind ~= "space" end

function world_draw()
  if has_deck() then
    boxfill(0, 0, GROUND, 127, 127, 63, C_DECK)
    -- rungs sliding toward the camera: the sense of speed comes from these
    local off = flr(scrolled) % 18
    for i = -1, 8 do
      local y = i * 18 + off
      if y >= 0 and y <= 126 then
        boxfill(0, y, GROUND, 127, y + 1, GROUND, C_PANEL)
      end
    end
    -- centre lane + edge rails, so x position is readable at a glance
    boxfill(63, 0, GROUND, 64, 127, GROUND, C_STRIPE)
    boxfill(0, 0, GROUND - 3, 3, 127, GROUND, C_RAIL)
    boxfill(124, 0, GROUND - 3, 127, 127, GROUND, C_RAIL)
  end
  -- Stars only in the void. Over the fortress they read as bullets, and the
  -- sliding rungs already carry the sense of speed.
  if not has_deck() then
    for s in all(stars) do
      vset(flr(s.x), flr(s.y), flr(s.z), s.c)
    end
  end
end

-- =============================================================== 04_player ==
function player_init()
  plr = { x = 64, y = PLR_Y, z = 34, cool = 0, inv = 70 }
end

function player_update()
  if plr.inv > 0 then plr.inv = plr.inv - 1 end
  if btn(0) then plr.x = plr.x - P_SPD end
  if btn(1) then plr.x = plr.x + P_SPD end
  if btn(2) then plr.z = plr.z - P_ASPD end   -- up = smaller z
  if btn(3) then plr.z = plr.z + P_ASPD end
  plr.x = clamp(plr.x, 8, 119)
  plr.z = clamp(plr.z, ALT_TOP, ALT_BOT)

  if plr.cool > 0 then plr.cool = plr.cool - 1 end
  if btn(4) and plr.cool <= 0 then
    add(shots, { x = plr.x, y = plr.y - 6, z = plr.z + 1 })
    plr.cool = P_COOL
    sfx_safe("shoot")
  end

  fuel = fuel - FUEL_BURN
  if fuel <= 25 and frame % 45 == 0 then sfx_safe("warn_fuel") end
  if fuel <= 0 then fuel = 0 player_die("out of fuel") end
end

function player_draw()
  if plr.inv > 0 and frame % 8 < 4 then return end
  local x, y, z = flr(plr.x), PLR_Y, flr(plr.z)
  boxfill(x - 1, y - 5, z,     x + 1, y + 4, z + 2, 7)    -- fuselage
  boxfill(x - 7, y - 1, z + 1, x + 7, y + 1, z + 1, 12)   -- main wing
  boxfill(x - 4, y + 1, z + 1, x + 4, y + 3, z + 1, 12)
  boxfill(x - 1, y - 7, z + 1, x + 1, y - 5, z + 1, 8)    -- nose
  boxfill(x,     y + 3, z - 2, x,     y + 5, z + 1, 10)   -- tail fin
  vset(x, y - 2, z, 14)                                   -- canopy
  if frame % 4 < 2 then
    boxfill(x - 1, y + 5, z + 1, x + 1, y + 6, z + 1, 9)  -- exhaust
  end
end

function player_die(why)
  fx_boom(plr.x, plr.y, plr.z, 26, {7, 10, 9, 8})
  sfx_safe("player_crash")
  lives = lives - 1
  died_why = why
  if lives <= 0 then
    mode = "over"
    modet = 0
    if score > hiscore then hiscore = score dset(0, hiscore) end
    music_safe("game_over")
  else
    mode = "dying"
    modet = 0
  end
end

-- ============================================================== 05_objects ==
function objs_init() objs = {} boss = nil end

function spawn_wall()
  local gw = flr(rnd(12)) + 22
  add(objs, { kind = "wall", x = 64, y = -14, z = GROUND,
              gx = flr(rnd(74)) + 27, gw = gw,
              top = GROUND - (flr(rnd(3)) * 7 + 14), done = false })
end

function spawn_drum()
  add(objs, { kind = "drum", x = rnd(100) + 14, y = -10, z = GROUND - 4 })
end

function spawn_turret()
  add(objs, { kind = "turret", x = rnd(100) + 14, y = -10, z = GROUND - 3,
              t = flr(rnd(40)) })
end

function spawn_plane()
  add(objs, { kind = "plane", x = rnd(100) + 14, y = -10,
              z = rnd(ALT_BOT - ALT_TOP) + ALT_TOP, w = rnd(1), t = 0 })
end

function objs_spawn()
  local n = frame % 1000
  if zone_kind == "space" then
    if frame % max(16, 34 - wave * 3) == 0 then spawn_plane() end
    if frame % 150 == 0 then spawn_drum() end
  else
    if frame % max(70, 130 - wave * 8) == 0 then spawn_wall() end
    if frame % 55 == 0 then spawn_drum() end
    if frame % max(40, 80 - wave * 6) == 0 then spawn_turret() end
    if frame % 110 == 0 then spawn_plane() end
  end
end

function objs_update()
  for i = #objs, 1, -1 do
    local o = objs[i]
    o.y = o.y + SCROLL

    if o.kind == "plane" then
      o.t = o.t + 1
      o.y = o.y + 0.7
      o.x = o.x + sin(o.t / 55) * 1.1
      o.z = approach(o.z, plr.z, 0.35)
      if o.t % 40 == 0 and o.y < PLR_Y - 12 and rnd(1) < 0.5 then eshoot(o) end
    elseif o.kind == "turret" then
      o.t = o.t + 1
      if o.t % max(45, 90 - wave * 8) == 0 and o.y > 10 and o.y < PLR_Y - 10 then
        eshoot(o)
      end
    elseif o.kind == "wall" and not o.done and o.y >= PLR_Y - 3 then
      o.done = true
      local through = abs(plr.x - o.gx) < o.gw / 2
      local over = plr.z < o.top
      if not (through or over) and plr.inv <= 0 then
        player_die("hit a wall")
        return
      end
      score = score + 10
    end

    -- Walls are full-height, so once one is nearer the camera than the ship it
    -- paints straight over it. They have done their job by then, so retire them
    -- the moment they are behind you rather than letting them hide the ship.
    local gone = (o.kind == "wall") and (o.y > PLR_Y + 8) or (o.y > 134)
    if gone then deli(objs, i) end
  end
end

function obj_draw(o)
  local x, y, z = flr(o.x), flr(o.y), flr(o.z)
  if o.kind == "wall" then
    local l0, l1 = 0, flr(o.gx - o.gw / 2)
    local r0, r1 = flr(o.gx + o.gw / 2), 127
    if l1 >= l0 then
      boxfill(l0, y, o.top, l1, y + 3, GROUND, 12)
      boxfill(l0, y, o.top, l1, y + 3, o.top + 1, 10)   -- bright cap: read this
    end
    if r1 >= r0 then
      boxfill(r0, y, o.top, r1, y + 3, GROUND, 12)
      boxfill(r0, y, o.top, r1, y + 3, o.top + 1, 10)
    end
    -- gap posts, so the opening is unmistakable
    boxfill(l1, y, o.top - 3, l1 + 1, y + 3, o.top, 11)
    boxfill(r0 - 1, y, o.top - 3, r0, y + 3, o.top, 11)
  elseif o.kind == "drum" then
    boxfill(x - 3, y - 3, z, x + 3, y + 3, z + 4, 8)
    boxfill(x - 3, y - 3, z + 1, x + 3, y + 3, z + 2, 10)
    boxfill(x - 2, y - 2, z - 1, x + 2, y + 2, z - 1, 9)
  elseif o.kind == "turret" then
    boxfill(x - 4, y - 4, z + 1, x + 4, y + 4, z + 3, 3)
    boxfill(x - 2, y - 2, z - 2, x + 2, y + 2, z + 1, 11)
    boxfill(x - 1, y - 6, z - 1, x + 1, y - 2, z, 6)     -- barrel
    vset(x, y, z - 3, (frame % 20 < 10) and 8 or 9)
  elseif o.kind == "plane" then
    boxfill(x - 1, y - 3, z, x + 1, y + 3, z + 2, 10)
    boxfill(x - 5, y - 1, z + 1, x + 5, y + 1, z + 1, 14)
    boxfill(x - 1, y - 5, z + 1, x + 1, y - 3, z + 1, 8)
    vset(x, y, z, 7)
  end
end

-- ---- boss ------------------------------------------------------------------
function boss_spawn()
  boss = { x = 64, y = 6, z = 20, hp = 22 + wave * 8, t = 0, flash = 0 }
  music_safe("boss_theme", 1)
end

function boss_update()
  local b = boss
  b.t = b.t + 1
  b.y = approach(b.y, 46, 0.35)
  b.x = 64 + sin(b.t / 150) * 26
  if b.flash > 0 then b.flash = b.flash - 1 end
  if b.y > 40 then
    if b.t % max(26, 60 - wave * 6) == 0 then
      for d = -1, 1 do
        add(eshots, { x = b.x + d * 9, y = b.y + 10, z = b.z + 16, vx = d * 0.5 })
      end
      sfx_safe("enemy_shoot")
    end
  end
end

function boss_draw()
  local b = boss
  local x, y, z = flr(b.x), flr(b.y), flr(b.z)
  local body = (b.flash > 0) and 7 or 12
  -- The camera looks from +y toward the back, so every detail that is meant to
  -- be seen has to sit on the *near* face. Put the eyes or the core at y-6 and
  -- the torso hides them completely.
  boxfill(x - 20, y - 6, z + 10, x + 20, y + 6, z + 26, body)   -- torso
  boxfill(x - 9,  y - 5, z,      x + 9,  y + 5, z + 9,  13)     -- head
  vset(x - 4, y + 5, z + 4, 8) vset(x + 4, y + 5, z + 4, 8)     -- eyes
  boxfill(x - 27, y - 4, z + 12, x - 20, y + 4, z + 18, 11)     -- arms
  boxfill(x + 20, y - 4, z + 12, x + 27, y + 4, z + 18, 11)
  boxfill(x - 14, y - 4, z + 26, x - 5, y + 4, GROUND, 5)       -- legs
  boxfill(x + 5,  y - 4, z + 26, x + 14, y + 4, GROUND, 5)
  -- the core: the only thing worth shooting, so it faces you
  local cc = (frame % 8 < 4) and 8 or 10
  boxfill(x - 5, y + 6, z + 14, x + 5, y + 7, z + 22, cc)
  boxfill(x - 3, y + 7, z + 16, x + 3, y + 8, z + 20, 7)
end

function boss_hit(s)
  local b = boss
  if not near(s.x, b.x, 6) or not near(s.z, b.z + 18, 5) then return false end
  if not near(s.y, b.y + 7, 7) then return false end
  b.hp = b.hp - 1
  b.flash = 3
  fx_boom(s.x, s.y, s.z, 3, {10, 9, 7})
  sfx_safe("explode")
  if b.hp <= 0 then
    fx_boom(b.x, b.y + 4, b.z + 16, 40, {7, 10, 9, 8, 14})
    sfx_safe("big_explosion")
    score = score + 2000
    boss = nil
    zone_advance()
  end
  return true
end

-- ================================================================ 06_shots ==
function eshoot(o)
  add(eshots, { x = o.x, y = o.y + 4, z = o.z - 1, vx = 0 })
  sfx_safe("enemy_shoot")
end

function shots_init() shots = {} eshots = {} end

function shots_update()
  for i = #shots, 1, -1 do
    local s = shots[i]
    s.y = s.y - SHOT_SPD
    if s.y < -6 then deli(shots, i) end
  end
  for i = #eshots, 1, -1 do
    local s = eshots[i]
    s.y = s.y + ESHOT_SPD
    s.x = s.x + (s.vx or 0)
    if s.y > 134 then
      deli(eshots, i)
    elseif plr.inv <= 0 and hit3(s, plr, 5, 5, 4) then
      deli(eshots, i)
      player_die("shot down")
      return
    end
  end
end

function shot_collisions()
  for i = #shots, 1, -1 do
    local s = shots[i]
    local gone = false
    if boss and boss_hit(s) then
      deli(shots, i)
      gone = true
    end
    if not gone then
      for j = #objs, 1, -1 do
        local o = objs[j]
        if o.kind ~= "wall" and hit3(s, o, 5, 5, 5) then
          deli(shots, i)
          obj_killed(o, j)
          gone = true
          break
        end
      end
    end
  end
end

function obj_killed(o, j)
  if o.kind == "drum" then
    fuel = min(fuel + 22, FUEL_MAX)
    score = score + 50
    fx_boom(o.x, o.y, o.z, 12, {10, 9, 8})
    sfx_safe("fuel_bonus")
    popup(o, "fuel")
  elseif o.kind == "turret" then
    score = score + 100
    fx_boom(o.x, o.y, o.z, 14, {11, 7, 10})
    sfx_safe("explode")
  else
    score = score + 150
    fx_boom(o.x, o.y, o.z, 14, {14, 10, 7})
    sfx_safe("explode")
  end
  deli(objs, j)
  if score >= nextlife then
    lives = lives + 1
    nextlife = nextlife + 10000
    sfx_safe("extra_life")
  end
end

function shots_draw()
  for s in all(shots) do
    local x, y, z = flr(s.x), flr(s.y), flr(s.z)
    boxfill(x, y, z, x, y + 3, z, 10)
    vset(x, y - 1, z, 7)
  end
  for s in all(eshots) do
    local x, y, z = flr(s.x), flr(s.y), flr(s.z)
    boxfill(x, y - 2, z, x, y + 1, z, 8)
    vset(x, y + 2, z, 9)
  end
end

-- =================================================================== 07_fx ==
function fx_init() parts = {} pops = {} end

function fx_boom(x, y, z, n, cols)
  for i = 1, n do
    local a = rnd(1)
    local sp = rnd(1.7) + 0.3
    add(parts, { x = x, y = y, z = z,
                 vx = cos(a) * sp, vy = sin(a) * sp, vz = rnd(1.4) - 0.7,
                 life = 12 + rnd(12), c = pick(cols) })
  end
end

function popup(o, txt)
  add(pops, { x = o.x, z = o.z, t = 0, txt = txt })
end

function fx_update()
  for i = #parts, 1, -1 do
    local p = parts[i]
    p.x = p.x + p.vx
    p.y = p.y + p.vy + SCROLL * 0.5
    p.z = p.z + p.vz
    p.vz = p.vz + 0.05
    p.life = p.life - 1
    if p.life <= 0 or (has_deck() and p.z >= GROUND) or p.y > 130 then
      deli(parts, i)
    end
  end
  for i = #pops, 1, -1 do
    pops[i].t = pops[i].t + 1
    if pops[i].t > 26 then deli(pops, i) end
  end
end

function fx_draw()
  for p in all(parts) do vset(flr(p.x), flr(p.y), flr(p.z), p.c) end
end

-- ================================================================== 08_hud ==
-- The camera views the volume three-quarter on, so the back wall is seen at an
-- angle and bare glyphs there look like debris hanging in space. Backing them
-- with a solid board turns the HUD into a scoreboard standing at the end of the
-- field, which reads as deliberate from any angle. The board is drawn on the
-- same slice as the text, so the text simply overwrites it -- put the backing
-- one slice nearer the camera and it would hide everything.
-- The board's foot rests on the far edge of the deck, so it reads as a banner
-- standing at the end of the run rather than glyphs adrift in space. HUD_Z is
-- its top edge; everything below is measured from there.
HUD_Z = GROUND - 22

function hud_draw()
  set_draw_slice(0, true)
  boxfill(0, 0, HUD_Z, 127, 0, GROUND, 1)
  line(0, HUD_Z, 127, HUD_Z, 12)

  print("score " .. score, 3, HUD_Z + 3, 7)
  print("hi " .. hiscore, 3, HUD_Z + 10, 10)
  print(zone_name(), 84, HUD_Z + 3, 11)
  for i = 1, min(lives - 1, 6) do pset(86 + i * 4, HUD_Z + 11, 12) end

  -- fuel: the clock you are always racing
  local fw = flr(fuel * 38 / FUEL_MAX)
  print("fuel", 3, HUD_Z + 17, 6)
  line(20, HUD_Z + 17, 58, HUD_Z + 17, 5)
  if fw > 0 then
    local c = (fuel <= 25) and ((frame % 16 < 8) and 8 or 9) or 11
    line(20, HUD_Z + 17, 20 + fw, HUD_Z + 17, c)
  end

  -- Altitude ladder. It seconds the shadow rather than replacing it: the
  -- shadow sliding along the deck is the gauge you actually fly by.
  print("alt", 66, HUD_Z + 17, 6)
  local gx0, gx1 = 84, 122
  local gz = HUD_Z + 19
  line(gx0, gz, gx1, gz, 5)
  line(gx0, gz - 3, gx0, gz, 6)    -- deck end
  line(gx1, gz - 3, gx1, gz, 6)    -- ceiling end
  local gx = gx1 - flr((plr.z - ALT_TOP) * (gx1 - gx0) / (ALT_BOT - ALT_TOP))
  line(gx, gz - 4, gx, gz + 1, 10)
end

function pops_draw()
  for o in all(pops) do
    if o.t % 4 < 3 then
      set_draw_slice(1, true)
      -- above the scoreboard, in the clear air, so it never fights the score
      print(o.txt, clamp(flr(o.x) - 6, 1, 112), clamp(flr(o.z) - 22, 10, HUD_Z - 7), 10)
    end
  end
end

function banner(txt, z, c)
  set_draw_slice(0, true)
  print(txt, 64 - #txt * 2, z, c)
end

-- ================================================================= 09_main ==
frame = 0

function zone_name()
  if zone_kind == "boss" then return "boss" end
  return "zone " .. wave .. "-" .. zone_i
end

function zone_advance()
  zone_i = zone_i + 1
  if zone_i > #ZONES then zone_i = 1 wave = wave + 1 end
  zone_kind = ZONES[zone_i]
  zone_left = ZLEN[zone_i]
  objs = {}
  eshots = {}
  if zone_kind == "boss" then
    boss_spawn()
  else
    music_safe("zone_theme", 1)
  end
  mode = "clear"
  modet = 0
  sfx_safe("zone_clear")
end

function zone_update()
  if zone_kind == "boss" then
    if boss then boss_update() end
    return
  end
  zone_left = zone_left - SCROLL
  if zone_left <= 0 then zone_advance() end
end

function new_game()
  score = 0
  lives = 3
  wave = 1
  zone_i = 1
  zone_kind = ZONES[1]
  zone_left = ZLEN[1]
  nextlife = 10000
  fuel = FUEL_MAX
  scrolled = 0
  died_why = ""
  objs_init()
  shots_init()
  fx_init()
  player_init()
end

function _init()
  cartdata("voxbox_zaxxon")
  hiscore = dget(0)
  world_init()
  new_game()
  mode = "title"
  modet = 0
  music_safe("title_theme")
end

function _update()
  frame = frame + 1
  modet = modet + 1
  stars_update()
  fx_update()
  if mode ~= "title" then scrolled = scrolled + SCROLL end

  if mode == "title" then
    if btnp(4) then
      new_game()
      mode = "play"
      modet = 0
      sfx_safe("menu_select")
      music_safe("zone_theme", 1)
    end

  elseif mode == "play" then
    player_update()
    if mode ~= "play" then return end     -- fuel ran out this frame
    objs_spawn()
    objs_update()
    if mode ~= "play" then return end     -- flew into a wall
    shots_update()
    if mode ~= "play" then return end
    shot_collisions()
    zone_update()

    -- ramming anything solid
    if plr.inv <= 0 then
      for i = #objs, 1, -1 do
        local o = objs[i]
        if o.kind ~= "wall" and hit3(o, plr, 6, 6, 5) then
          fx_boom(o.x, o.y, o.z, 10, {10, 9})
          deli(objs, i)
          player_die("collision")
          return
        end
      end
    end

  elseif mode == "clear" then
    if modet > 70 then mode = "play" modet = 0 end

  elseif mode == "dying" then
    if modet > 70 then
      shots_init()
      objs = {}
      fuel = max(fuel, 40)
      player_init()
      mode = "play"
      modet = 0
    end

  elseif mode == "over" then
    if modet > 90 and btnp(4) then
      new_game()
      mode = "title"
      modet = 0
      music_safe("title_theme")
    end
  end
end

function _draw()
  clv()
  world_draw()

  if mode == "title" then
    banner("zaxxon", 8, 10)
    banner("a voxbox cart", 16, 12)
    banner("arrows fly   x fires", 24, 6)
    banner("shoot drums for fuel", 30, 11)
    if frame % 40 < 26 then banner("press x to start", 38, 7) end
    return
  end

  for o in all(objs) do obj_draw(o) end
  if boss then boss_draw() end
  shots_draw()
  fx_draw()
  if mode ~= "dying" and mode ~= "over" then player_draw() end
  hud_draw()
  pops_draw()

  if mode == "clear" then
    banner(zone_kind == "boss" and "warning: boss" or zone_name(), 26, 10)
  elseif mode == "over" then
    banner("game over", 26, 8)
    banner(died_why, 34, 6)
    if modet > 90 and frame % 40 < 26 then banner("press x", 42, 7) end
  end
end
