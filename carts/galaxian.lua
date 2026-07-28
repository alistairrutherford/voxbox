-- galaxian.lua : a Galaxian clone for Voxatron  (pure Lua, no designer assets)
--
-- Played on the floor of the display volume rather than a flat 2D screen: the
-- formation hangs at the back (low y), the player defends the front (high y),
-- and everything floats above the deck so the engine's drop shadows sell the
-- depth. Shots run along -y/+y, dives arc in x and bob in z.
--
-- Volume is 128(x) x 128(y, 0 = back) x 64(z, 0 = TOP), so larger z is *lower*.
-- Concatenated build order is the section numbering below.

-- =============================================================== 01_config ==
DECK      = 50          -- z of the floor surface; play happens above it
FLY_Z     = 40          -- cruising height of ships
ARENA_L   = 6
ARENA_R   = 121
PLAYER_Y  = 108
FORM_X0   = 22          -- left column of the formation
FORM_Y0   = 20          -- back row of the formation
COL_DX    = 17
ROW_DY    = 13
COLS      = 6
ROWS      = 4
P_SPD     = 2.2
P_COOL    = 7
MAX_SHOTS = 2           -- Galaxian rations the player's fire
SHOT_SPD  = 4.5
ESHOT_SPD = 1.9
DIVE_SPD  = 1.35

-- pico-8 palette: 7 white, 8 red, 9 orange, 10 yellow, 11 green, 12 blue,
-- 13 lavender, 14 pink, 15 peach
KINDS = {
  { body = 10, wing =  8, eye = 7, crest =  8, pts = 60 },  -- flagship
  { body = 14, wing =  2, eye = 7, crest = 15, pts = 40 },  -- pink
  { body = 12, wing =  1, eye = 7, crest =  7, pts = 30 },  -- blue
  { body = 11, wing =  3, eye = 7, crest = 10, pts = 20 },  -- green
}
STAR_COLS = { 7, 6, 12, 14, 10, 13 }
BOOM_COLS = { 10, 9, 8, 7, 14 }

-- ================================================================= 02_util ==
function sfx_safe(n) pcall(play_sound, n) end
function music_safe(n, f) pcall(play_music, n, f) end
function clamp(v, lo, hi) return mid(lo, v, hi) end
function approach(v, t, s) return v + clamp(t - v, -s, s) end
function hit(ax, ay, bx, by, rx, ry)
  return abs(ax - bx) <= rx and abs(ay - by) <= ry
end
function pick(t) return t[flr(rnd(#t)) + 1] end

-- ================================================================ 03_stars ==
-- A scrolling starfield painted straight onto the deck, so the arena reads as
-- moving even when nothing else does.
function stars_init()
  stars = {}
  for i = 1, 80 do
    add(stars, { x = rnd(128), y = rnd(128), s = rnd(1.6) + 0.5, c = pick(STAR_COLS) })
  end
end

function stars_update()
  for s in all(stars) do
    s.y = s.y + s.s
    if s.y > 127 then
      s.y = s.y - 128
      s.x = rnd(128)
      s.c = pick(STAR_COLS)
    end
  end
end

-- One colour for the whole slab: the renderer shades top and side faces
-- differently, so it still reads as solid. Deliberately not black — drop
-- shadows darken what they land on, and nothing is darker than black, so a
-- black deck would throw away the depth cue the ships' shadows give.
function deck_draw()
  boxfill(0, 0, DECK, 127, 127, 63, 1)     -- dark blue slab
  for gx = 0, 127, 16 do                   -- lane grid
    line3d(gx, 0, DECK, gx, 127, DECK, 13)
  end
  for s in all(stars) do
    vset(flr(s.x), flr(s.y), DECK, s.c)
  end
end

-- =============================================================== 04_player ==
function player_init()
  plr = { x = 64, y = PLAYER_Y, cool = 0, inv = 60 }
end

function player_update()
  if plr.inv > 0 then plr.inv = plr.inv - 1 end
  if btn(0) then plr.x = plr.x - P_SPD end
  if btn(1) then plr.x = plr.x + P_SPD end
  plr.x = clamp(plr.x, ARENA_L, ARENA_R)
  if plr.cool > 0 then plr.cool = plr.cool - 1 end
  if btn(4) and plr.cool <= 0 and #shots < MAX_SHOTS then
    add(shots, { x = plr.x, y = plr.y - 5, z = FLY_Z + 1 })
    plr.cool = P_COOL
    sfx_safe("shoot")
  end
end

function player_draw()
  -- blink away half the frames while respawn-invulnerable
  if plr.inv > 0 and frame % 8 < 4 then return end
  local x, y, z = flr(plr.x), flr(plr.y), FLY_Z
  boxfill(x - 1, y - 5, z,     x + 1, y + 3, z + 3, 7)   -- fuselage
  boxfill(x - 6, y,     z + 1, x + 6, y + 2, z + 2, 12)  -- wings
  boxfill(x - 4, y + 2, z,     x - 2, y + 4, z + 2, 12)  -- left fin
  boxfill(x + 2, y + 2, z,     x + 4, y + 4, z + 2, 12)  -- right fin
  boxfill(x - 1, y - 6, z + 1, x + 1, y - 5, z + 2, 10)  -- nose
  vset(x, y - 1, z, 14)                                  -- cockpit
  if frame % 6 < 3 then                                  -- engine flare
    boxfill(x - 1, y + 4, z + 1, x + 1, y + 5, z + 2, 9)
  end
end

function player_die()
  boom(plr.x, plr.y, FLY_Z, 20)
  sfx_safe("player_explode")
  lives = lives - 1
  if lives <= 0 then
    mode = "over"
    modet = 0
    music_safe("game_over")
    if score > hiscore then hiscore = score dset(0, hiscore) end
  else
    mode = "dying"
    modet = 0
  end
end

-- ============================================================== 05_enemies ==
function wave_init()
  ens = {}
  for r = 0, ROWS - 1 do
    for c = 0, COLS - 1 do
      local hx = FORM_X0 + c * COL_DX
      local hy = FORM_Y0 + r * ROW_DY
      add(ens, {
        hx = hx, hy = hy, x = hx, y = hy, z = FLY_Z,
        kind = r + 1, st = "form", t = 0, dir = 1,
      })
    end
  end
  dive_t = 100
  eshots = {}
end

-- The whole block slides side to side; dives are launched off that live
-- position so a diver peels away from where it was actually drawn.
function formation_sway()
  swing = sin(frame / 260) * 10
  bob   = sin(frame / 170) * 2
end

function launch_dive()
  local pool = {}
  for e in all(ens) do
    if e.st == "form" then add(pool, e) end
  end
  if #pool == 0 then return end
  local e = pick(pool)
  e.st = "dive"
  e.t = 0
  e.dir = (rnd(1) < 0.5) and -1 or 1
  sfx_safe("dive")
end

function enemy_update(e)
  if e.st == "form" then
    e.x = e.hx + swing
    e.y = e.hy + bob
    e.z = FLY_Z
  elseif e.st == "dive" then
    e.t = e.t + 1
    e.y = e.y + DIVE_SPD
    -- wobbling homing swoop: drifts toward the player while weaving
    e.x = e.x + sgn(plr.x - e.x) * 0.45 + sin(e.t / 45) * 1.3 * e.dir
    e.x = clamp(e.x, ARENA_L, ARENA_R)
    e.z = FLY_Z + sin(e.t / 55) * 4
    if e.t % 17 == 0 and rnd(1) < 0.4 and e.y < 116 then
      espawn(e)
    end
    if e.y > 132 then          -- off the front: loop round to the back
      e.st = "back"
      e.y = -12
      e.z = FLY_Z
    end
  elseif e.st == "back" then
    local tx, ty = e.hx + swing, e.hy + bob
    e.x = approach(e.x, tx, 2.2)
    e.y = approach(e.y, ty, 2.2)
    if abs(e.x - tx) < 1.5 and abs(e.y - ty) < 1.5 then e.st = "form" end
  end
end

function enemy_draw(e)
  local k = KINDS[e.kind]
  local x, y, z = flr(e.x), flr(e.y), flr(e.z)
  local flap = (frame + e.hx) % 26 < 13 and 0 or 1
  boxfill(x - 3, y - 2, z,        x + 3, y + 2, z + 3, k.body)
  boxfill(x - 6, y - 1, z + flap, x - 3, y + 1, z + flap + 1, k.wing)
  boxfill(x + 3, y - 1, z + flap, x + 6, y + 1, z + flap + 1, k.wing)
  boxfill(x - 1, y - 4, z,        x + 1, y - 3, z + 2, k.crest)
  vset(x - 2, y - 2, z + 1, k.eye)
  vset(x + 2, y - 2, z + 1, k.eye)
  if e.st == "dive" then                    -- thruster while attacking
    vset(x, y + 3, z + 1, (frame % 4 < 2) and 9 or 10)
  end
end

function enemy_kill(e, i, diving)
  local k = KINDS[e.kind]
  local pts = diving and k.pts * 2 or k.pts
  score = score + pts
  add(pops, { x = e.x, y = e.y, z = e.z, n = pts, t = 0 })
  boom(e.x, e.y, e.z, 12)
  sfx_safe("explode")
  deli(ens, i)
  if score >= nextlife then
    lives = lives + 1
    nextlife = nextlife + 5000
    sfx_safe("extra_life")
  end
end

-- ================================================================ 06_shots ==
function espawn(e)
  add(eshots, { x = e.x, y = e.y + 3, z = e.z + 1 })
  sfx_safe("enemy_shoot")
end

function shots_update()
  for i = #shots, 1, -1 do
    local s = shots[i]
    s.y = s.y - SHOT_SPD
    if s.y < -4 then deli(shots, i) end
  end
  for i = #eshots, 1, -1 do
    local s = eshots[i]
    s.y = s.y + ESHOT_SPD
    if s.y > 130 then deli(eshots, i) end
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

function boom(x, y, z, n)
  for i = 1, n do
    local a = rnd(1)
    local sp = rnd(1.8) + 0.4
    add(parts, {
      x = x, y = y, z = z,
      vx = cos(a) * sp, vy = sin(a) * sp, vz = rnd(1.6) - 0.8,
      life = 14 + rnd(12), c = pick(BOOM_COLS),
    })
  end
end

function fx_update()
  for i = #parts, 1, -1 do
    local p = parts[i]
    p.x = p.x + p.vx
    p.y = p.y + p.vy
    p.z = p.z + p.vz
    p.vz = p.vz + 0.06                     -- settle toward the deck
    p.life = p.life - 1
    if p.life <= 0 or p.z >= DECK then deli(parts, i) end
  end
  for i = #pops, 1, -1 do
    local o = pops[i]
    o.t = o.t + 1
    o.z = o.z - 0.35
    if o.t > 34 then deli(pops, i) end
  end
end

function fx_draw()
  for p in all(parts) do
    vset(flr(p.x), flr(p.y), flr(p.z), p.c)
  end
end

-- ================================================================== 08_hud ==
function hud_draw()
  set_draw_slice(0, true)
  print("score " .. score, 3, 3, 7)
  print("hi " .. max(score, hiscore), 3, 10, 10)   -- tracks live, like the cabinet
  print("wave " .. wave, 100, 3, 12)
  for i = 1, min(lives - 1, 5) do          -- spare ships, as little chevrons
    local x = 100 + (i - 1) * 6
    pset(x + 1, 11, 7)
    line(x, 12, x + 2, 12, 12)
    pset(x, 13, 12)
    pset(x + 2, 13, 12)
  end
end

-- Score popups float on the back wall above where the kill happened, which
-- keeps them legible without cluttering the play deck.
function pops_draw()
  for o in all(pops) do
    if o.t % 4 < 3 then
      set_draw_slice(1, true)
      print(tostr(o.n), clamp(flr(o.x) - 4, 1, 116), clamp(flr(o.z) - 18, 18, 44), 10)
    end
  end
end

function banner(txt, z, c)
  set_draw_slice(0, true)
  print(txt, 64 - #txt * 2, z, c)
end

-- ================================================================= 09_main ==
frame = 0

function new_game()
  score = 0
  lives = 3
  wave = 1
  nextlife = 5000
  shots = {}
  fx_init()
  player_init()
  wave_init()
end

function _init()
  cartdata("voxbox_galaxian")
  hiscore = dget(0)
  stars_init()
  new_game()
  mode = "title"
  modet = 0
  music_safe("title_theme")
end

function _update()
  frame = frame + 1
  modet = modet + 1
  stars_update()
  formation_sway()
  fx_update()

  if mode == "title" then
    for e in all(ens) do enemy_update(e) end
    if btnp(4) then
      new_game()
      mode = "play"
      modet = 0
      sfx_safe("menu_select")
      music_safe("wave_theme", 1)
    end

  elseif mode == "play" then
    player_update()
    shots_update()

    dive_t = dive_t - 1
    if dive_t <= 0 then
      launch_dive()
      dive_t = max(20, 95 - wave * 7) + rnd(45)
    end

    for i = #ens, 1, -1 do
      local e = ens[i]
      enemy_update(e)
      local killed = false
      -- player shots
      for j = #shots, 1, -1 do
        local s = shots[j]
        if hit(e.x, e.y, s.x, s.y, 5, 4) then
          deli(shots, j)
          enemy_kill(e, i, e.st == "dive")
          killed = true
          break
        end
      end
      -- ramming the player
      if not killed and plr.inv <= 0 and e.st == "dive"
         and hit(e.x, e.y, plr.x, plr.y, 6, 5) then
        enemy_kill(e, i, true)
        player_die()
        return
      end
    end

    for j = #eshots, 1, -1 do
      local s = eshots[j]
      if plr.inv <= 0 and hit(s.x, s.y, plr.x, plr.y, 4, 4) then
        deli(eshots, j)
        player_die()
        return
      end
    end

    if #ens == 0 then
      mode = "clear"
      modet = 0
      sfx_safe("wave_clear")
      music_safe("wave_clear_jingle")
    end

  elseif mode == "dying" then
    shots_update()
    if modet > 60 then
      shots = {}
      eshots = {}
      player_init()
      mode = "play"
      modet = 0
    end

  elseif mode == "clear" then
    if modet > 90 then
      wave = wave + 1
      shots = {}
      player_init()
      wave_init()
      mode = "play"
      modet = 0
      music_safe("wave_theme", 1)
    end

  elseif mode == "over" then
    for e in all(ens) do enemy_update(e) end
    if modet > 100 and btnp(4) then
      mode = "title"
      modet = 0
      new_game()
      music_safe("title_theme")
    end
  end
end

function _draw()
  clv()
  deck_draw()

  if mode == "title" then
    for e in all(ens) do enemy_draw(e) end
    -- All title text has to clear z~34: the formation hangs in front of the
    -- back wall and occludes anything painted lower than that.
    banner("galaxian", 10, 10)
    banner("a voxbox cart", 18, 12)
    banner("arrows move   x fires", 25, 5)
    if frame % 40 < 26 then banner("press x to start", 32, 7) end
  else
    for e in all(ens) do enemy_draw(e) end
    shots_draw()
    fx_draw()
    if mode ~= "dying" and mode ~= "over" then player_draw() end
    hud_draw()
    pops_draw()
    if mode == "clear" then
      banner("wave " .. wave .. " cleared", 30, 11)
    elseif mode == "over" then
      banner("game over", 30, 8)
      if modet > 100 and frame % 40 < 26 then banner("press x", 40, 7) end
    end
  end
end
