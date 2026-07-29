-- tempest.lua : a Tempest homage for Voxatron  (pure Lua, no designer assets)
--
-- Played *down* the depth axis rather than across the floor.  The web is a
-- tapered tube running from the far wall (y = FAR_Y) to just in front of the
-- camera (y = NEAR_Y); the claw rides the near rim and everything climbs
-- toward you.  Perspective does most of the work, but the tube is tapered in
-- cross-section as well, so the far end reads as genuinely distant rather
-- than merely a bit smaller.
--
-- Volume is 128(x) x 128(y, 0 = back) x 64(z, 0 = TOP), so larger z is *lower*
-- on screen and larger y is *nearer the camera*.  Two consequences shape the
-- whole cart:
--
--   * There is no distance fog in the renderer, so depth has to be cued by
--     the cart.  Every radial edge is drawn in bands that brighten toward the
--     player, which is what Tempest's coloured webs did anyway.
--   * Anything drawn on an object's far face is hidden by the object itself.
--     Detail therefore goes on the +y side: the claw's muzzle points at the
--     camera, enemy wings converge forward, and the HUD sits on a slice in
--     front of the near rim.
--
-- Concatenated build order is the section numbering below.

-- =============================================================== 01_config ==
CX, CZ    = 64, 32       -- centre of the tube's cross-section
RX, RZ    = 48, 26       -- half-extents of the near rim
FAR_Y     = 6            -- far rim: the mouth enemies climb out of
NEAR_Y    = 116          -- near rim: the lane the claw runs on
TAPER     = 0.42         -- cross-section scale at the far rim
HUD_Y     = 123          -- HUD slice, in front of every piece of geometry
BANDS     = 5            -- depth bands per radial edge (the depth cue)

P_SPD     = 0.22         -- lanes per frame
P_COOL    = 6
MAX_SHOTS = 6
SHOT_SPD  = 0.055        -- depth per frame, near -> far
ESHOT_SPD = 0.011
ZAPS      = 2            -- superzapper charges per level

-- pico-8 palette: 1 navy, 2 plum, 3 dark green, 8 red, 9 orange, 10 yellow,
-- 11 green, 12 blue, 13 indigo, 14 pink, 15 peach.  Colour 0 is empty space,
-- never a paint colour.
-- ramp[1] is the far end and ramp[2] doubles as the colour of the far rim, so
-- it has to be dim but not invisible: a rim in colour 1 vanishes into the
-- black background and the mouth stops reading as a mouth.
LEVEL_COLS = {
  { ramp = { 1, 13, 13, 12, 12 }, rim = 12, acc =  7 },   -- classic blue
  { ramp = { 1,  2,  8,  8,  8 }, rim =  8, acc = 10 },   -- red
  { ramp = { 1,  3,  3, 11, 11 }, rim = 11, acc = 10 },   -- green
  { ramp = { 1,  2, 13, 14, 14 }, rim = 14, acc =  7 },   -- pink
  { ramp = { 1,  4,  9,  9, 10 }, rim = 10, acc =  7 },   -- amber
  { ramp = { 1, 13, 12, 12,  7 }, rim =  7, acc = 12 },   -- white
}
DIM_RAMP = { 1, 1, 1, 13, 13 }   -- attract mode: the web must not fight the text

-- Web shapes, cycled by level.  Corner lists are in -1..1 units and get
-- resampled to an even lane count; "circle" and "star" are parametric.
PLUS = {
  {  0.4, -1.0 }, {  0.4, -0.4 }, {  1.0, -0.4 }, {  1.0,  0.4 },
  {  0.4,  0.4 }, {  0.4,  1.0 }, { -0.4,  1.0 }, { -0.4,  0.4 },
  { -1.0,  0.4 }, { -1.0, -0.4 }, { -0.4, -0.4 }, { -0.4, -1.0 },
}
SHAPES = {
  { name = "circle", kind = "circle", n = 16 },
  { name = "square", kind = "poly",   n = 16, closed = true,
    cor = { { 1, -1 }, { 1, 1 }, { -1, 1 }, { -1, -1 } } },
  { name = "vee",    kind = "poly",   n = 16, closed = false,
    cor = { { -1, -0.55 }, { 0, 0.9 }, { 1, -0.55 } } },
  { name = "star",   kind = "star",   n = 16 },
  { name = "cross",  kind = "poly",   n = 16, closed = true, cor = PLUS },
  { name = "flat",   kind = "poly",   n = 16, closed = false,
    cor = { { -1, 0.45 }, { 1, 0.45 } } },
}

SCORE_FLIP = 150
SCORE_TANK = 100
SCORE_SPKR =  50
EXTRA_LIFE = 20000

-- ================================================================= 02_util ==
function sfx_safe(n) pcall(play_sound, n) end
function music_safe(n, f) pcall(play_music, n, f) end
function clamp(v, lo, hi) return mid(lo, v, hi) end
function round(v) return flr(v + 0.5) end
function pick(t) return t[flr(rnd(#t)) + 1] end
function lerp(a, b, t) return a + (b - a) * t end

-- pico-8's sin is negated relative to the usual convention; fold that away so
-- the shape code reads as plain trigonometry.
function sn(t) return -sin(t) end

-- ================================================================== 03_web ==
-- The web is a list of cross-section vertices (offsets from the tube axis)
-- plus a closed/open flag.  Lane l spans vertex l and vertex l+1, so a closed
-- web has as many lanes as vertices and an open one has one fewer.
--
-- Vertices and lanes are indexed from 0, which makes the wrap arithmetic on
-- closed webs plain modulo rather than a nest of +1/-1.

-- Split a corner list into n lanes.
--
-- Not by walking the perimeter at even arc-length steps, which is the obvious
-- way and is wrong: it lands vertices wherever they fall, so a plus sampled at
-- 16 comes out rotationally symmetric but not mirror symmetric, and the
-- anisotropic RX/RZ scaling then turns that into one visibly lopsided arm.
-- Instead every corner gets a vertex and each edge is given a whole number of
-- lanes in proportion to its length, which preserves whatever symmetry the
-- shape has.
function resample(cor, n, closed)
  local m = #cor
  local last = closed and m or m - 1
  local lens, total = {}, 0
  for i = 1, last do
    local a, b = cor[i], cor[i % m + 1]
    local dx, dz = b[1] - a[1], b[2] - a[2]
    lens[i] = sqrt(dx * dx + dz * dz)
    total = total + lens[i]
  end

  local cnt, used = {}, 0
  for i = 1, last do
    cnt[i] = max(1, flr(lens[i] / total * n))
    used = used + cnt[i]
  end
  -- hand the rounding slack to whichever edge is currently coarsest (or take
  -- it back from the finest), so lane widths stay as even as the shape allows
  while used ~= n do
    local best, bs = 1, used < n and -1 or 1e9
    for i = 1, last do
      local s = lens[i] / cnt[i]
      if used < n then
        if s > bs then best, bs = i, s end
      elseif cnt[i] > 1 and s < bs then
        best, bs = i, s
      end
    end
    cnt[best] = cnt[best] + (used < n and 1 or -1)
    used = used + (used < n and 1 or -1)
  end

  local px, pz, k = {}, {}, 0
  for i = 1, last do
    local a, b = cor[i], cor[i % m + 1]
    for j = 0, cnt[i] - 1 do
      local f = j / cnt[i]
      px[k] = RX * lerp(a[1], b[1], f)
      pz[k] = RZ * lerp(a[2], b[2], f)
      k = k + 1
    end
  end
  if not closed then                    -- open webs need the far end capped
    px[k] = RX * cor[m][1]
    pz[k] = RZ * cor[m][2]
    k = k + 1
  end
  return px, pz, k
end

function web_build(lv)
  local sh = SHAPES[(lv - 1) % #SHAPES + 1]
  local col = LEVEL_COLS[(lv - 1) % #LEVEL_COLS + 1]
  local px, pz, nv = {}, {}, sh.n
  local closed = true

  if sh.kind == "circle" or sh.kind == "star" then
    for i = 0, sh.n - 1 do
      local t = i / sh.n
      local r = 1
      if sh.kind == "star" and i % 2 == 1 then r = 0.55 end
      px[i] = RX * r * cos(t)
      pz[i] = RZ * r * sn(t)
    end
  else
    closed = sh.closed
    px, pz, nv = resample(sh.cor, sh.n, closed)
  end

  web = {
    px = px, pz = pz, nv = nv, closed = closed,
    nl = closed and nv or nv - 1,
    ramp = col.ramp, rim = col.rim, acc = col.acc, name = sh.name,
  }
end

-- Vertex lookup: closed webs wrap, open ones clamp at the ends.
function vert(i)
  if web.closed then
    i = i % web.nv
  else
    i = clamp(i, 0, web.nv - 1)
  end
  return web.px[i], web.pz[i]
end

function ydepth(d) return FAR_Y + (NEAR_Y - FAR_Y) * d end
function scale_at(d) return TAPER + (1 - TAPER) * d end

-- Vertex i, projected to depth d.  Both the taper and y are linear in d, so
-- a radial edge stays a straight line and can be banded by simple lerps.
function wvert(i, d)
  local s = scale_at(d)
  local px, pz = vert(i)
  return CX + px * s, CZ + pz * s
end

-- Fractional vertex, so flips and claw movement slide instead of stepping.
function wvert_f(lf, d)
  local i = flr(lf)
  local f = lf - i
  local ax, az = wvert(i, d)
  local bx, bz = wvert(i + 1, d)
  return lerp(ax, bx, f), lerp(az, bz, f)
end

function lane_edges(lf, d)
  local ax, az = wvert_f(lf, d)
  local bx, bz = wvert_f(lf + 1, d)
  return ax, az, bx, bz
end

function lane_mid(lf, d)
  local ax, az, bx, bz = lane_edges(lf, d)
  return (ax + bx) / 2, (az + bz) / 2
end

-- Signed shortest way round from lane a to lane b.
function lane_delta(a, b)
  local n = web.nl
  local d = b - a
  if web.closed then d = (d + n / 2) % n - n / 2 end
  return d
end

function lane_wrap(l)
  if web.closed then return l % web.nl end
  return clamp(l, 0, web.nl - 1)
end

-- Outward normal of a lane, used to flare the claw's prongs off the rim.
function lane_out(lf, d, len)
  local mx, mz = lane_mid(lf, d)
  local ox, oz = mx - CX, mz - CZ
  local l = sqrt(ox * ox + oz * oz)
  if l < 0.001 then return 0, len end
  return ox / l * len, oz / l * len
end

function rim_draw(d, c)
  local y = ydepth(d)
  local lastx, lastz = wvert(0, d)
  for i = 1, web.nv - (web.closed and 0 or 1) do
    local x, z = wvert(i, d)
    line3d(lastx, y, lastz, x, y, z, c)
    lastx, lastz = x, z
  end
end

function web_draw(dim)
  local ramp = dim and DIM_RAMP or web.ramp
  local rimc = dim and 13 or web.rim
  -- Radial edges, banded so the tube brightens toward the player.  This is
  -- the only depth cue the renderer does not supply for free.
  local shift = (mode == "warp") and flr(warpt / 4) or 0
  for i = 0, web.nv - 1 do
    local x0, z0 = wvert(i, 0)
    local x1, z1 = wvert(i, 1)
    for b = 0, BANDS - 1 do
      local t0, t1 = b / BANDS, (b + 1) / BANDS
      line3d(lerp(x0, x1, t0), ydepth(t0), lerp(z0, z1, t0),
             lerp(x0, x1, t1), ydepth(t1), lerp(z0, z1, t1),
             ramp[(b + shift) % BANDS + 1])
    end
  end
  rim_draw(0, ramp[2])
  -- The near rim is where the claw lives, so it gets drawn twice for weight.
  rim_draw(1, rimc)
  local y = NEAR_Y + 1
  local lastx, lastz = wvert(0, 1)
  for i = 1, web.nv - (web.closed and 0 or 1) do
    local x, z = wvert(i, 1)
    line3d(lastx, y, lastz, x, y, z, rimc)
    lastx, lastz = x, z
  end
end

-- =============================================================== 04_spikes ==
-- One spike per lane, growing out of the far rim toward the player.  Spikers
-- lay them; player fire trims them back; they are what can kill you on the
-- dive between levels.
function spikes_init()
  spikes = {}
  for l = 0, web.nl - 1 do spikes[l] = 0 end
end

function spike_hit(l, amount)
  if spikes[l] <= 0 then return false end
  spikes[l] = max(0, spikes[l] - amount)
  return true
end

function spikes_draw()
  for l = 0, web.nl - 1 do
    local h = spikes[l]
    if h > 0.02 then
      local x0, z0 = lane_mid(l, 0)
      local x1, z1 = lane_mid(l, h)
      line3d(x0, ydepth(0), z0, x1, ydepth(h), z1, 11)
      vset(flr(x1), flr(ydepth(h)), flr(z1), 10)
    end
  end
end

-- =============================================================== 05_player ==
function player_init()
  plr = { lf = start_lane(), cool = 0, inv = 60 }
  plr.lane = round(plr.lf) % web.nl
end

-- Closed webs start the claw at the bottom of the screen, open ones in the
-- middle: both are where a player's eye already is.
function start_lane()
  if not web.closed then return flr(web.nl / 2) end
  local best, bestz = 0, -1e9
  for l = 0, web.nl - 1 do
    local _, z = lane_mid(l, 1)
    if z > bestz then best, bestz = l, z end
  end
  return best
end

function player_update()
  local dir = 0
  if btn(0) then dir = dir - 1 end
  if btn(1) then dir = dir + 1 end
  if dir ~= 0 then
    plr.lf = lane_wrap(plr.lf + dir * P_SPD)
    plr.lane = round(plr.lf) % web.nl
  end

  if plr.cool > 0 then plr.cool = plr.cool - 1 end
  if plr.inv > 0 then plr.inv = plr.inv - 1 end

  if btn(4) and plr.cool <= 0 and #shots < MAX_SHOTS then
    add(shots, { lane = plr.lane, d = 1, pd = 1 })
    plr.cool = P_COOL
    sfx_safe("player_fire")
  end

  if btnp(5) and zaps > 0 then superzap() end
end

function player_draw()
  if plr.inv > 0 and frame % 6 < 3 then return end
  local y = NEAR_Y
  local ax, az, bx, bz = lane_edges(plr.lf, 1)
  local mx, mz = (ax + bx) / 2, (az + bz) / 2
  local ox, oz = lane_out(plr.lf, 1, 4)
  -- Everything past the bar is drawn toward +y, i.e. on the face turned
  -- toward the camera, or the claw would hide its own detail.
  line3d(ax, y, az, bx, y, bz, 10)
  line3d(ax, y, az, ax + ox, y + 4, az + oz, 10)
  line3d(bx, y, bz, bx + ox, y + 4, bz + oz, 10)
  line3d(ax + ox, y + 4, az + oz, mx, y + 2, mz, 9)
  line3d(bx + ox, y + 4, bz + oz, mx, y + 2, mz, 9)
  line3d(mx, y + 2, mz, mx, y + 5, mz, plr.cool > 3 and 7 or 8)
end

function player_die()
  if plr.inv > 0 or mode ~= "play" then return end
  local x, z = lane_mid(plr.lf, 1)
  boom(x, NEAR_Y, z, 26, { 10, 9, 8, 7 })
  sfx_safe("player_die")
  lives = lives - 1
  mode = "dying"
  modet = 0
end

function superzap()
  zaps = zaps - 1
  sfx_safe("superzapper_blast")
  zapflash = 12
  if zaps == 1 then
    -- first charge clears the web
    for i = #ens, 1, -1 do enemy_kill(ens[i], i, false) end
  else
    -- second charge takes the nearest single enemy, as the cabinet did
    local best, bi = nil, 0
    for i = 1, #ens do
      if best == nil or ens[i].d > best.d then best, bi = ens[i], i end
    end
    if best then enemy_kill(best, bi, false) end
  end
end

-- ================================================================ 06_shots ==
function shots_update()
  for i = #shots, 1, -1 do
    local s = shots[i]
    s.pd = s.d
    s.d = s.d - SHOT_SPD
    local gone = false

    -- spike tips: a shot that reaches one trims it and is spent
    if s.d <= spikes[s.lane] and spikes[s.lane] > 0 then
      spike_hit(s.lane, 0.09)
      local x, z = lane_mid(s.lane, s.d)
      boom(x, ydepth(s.d), z, 4, { 11, 10 })
      sfx_safe("spike_hit")
      gone = true
    end

    if not gone then
      for j = #eshots, 1, -1 do
        local e = eshots[j]
        if e.lane == s.lane and e.d <= s.pd and e.d >= s.d - 0.02 then
          deli(eshots, j)
          gone = true
          break
        end
      end
    end

    if not gone then
      for j = #ens, 1, -1 do
        local e = ens[j]
        if abs(lane_delta(round(e.lf) % web.nl, s.lane)) < 0.6
           and e.d <= s.pd + 0.03 and e.d >= s.d - 0.03 then
          enemy_kill(e, j, true)
          gone = true
          break
        end
      end
    end

    if gone or s.d <= 0 then deli(shots, i) end
  end

  for i = #eshots, 1, -1 do
    local e = eshots[i]
    e.d = e.d + ESHOT_SPD
    if e.d >= 1 then
      if abs(lane_delta(e.lane, plr.lf)) < 0.7 then player_die() end
      deli(eshots, i)
    end
  end
end

function shots_draw()
  for s in all(shots) do
    -- a bar across its lane, so it reads at every depth despite the taper
    local ax, az, bx, bz = lane_edges(s.lane, s.d)
    local y = ydepth(s.d)
    local mx, mz = (ax + bx) / 2, (az + bz) / 2
    line3d(lerp(mx, ax, 0.55), y, lerp(mz, az, 0.55),
           lerp(mx, bx, 0.55), y, lerp(mz, bz, 0.55), 7)
  end
  for s in all(eshots) do
    local x, z = lane_mid(s.lane, s.d)
    local y = ydepth(s.d)
    line3d(x - 2, y, z, x + 2, y, z, 14)
    line3d(x, y, z - 1, x, y, z + 1, 8)
  end
end

-- ============================================================== 07_enemies ==
-- Three from the cabinet: flippers walk the tube and hunt along the rim,
-- tankers carry two flippers, spikers lay the spikes.  All of them keep a
-- float lane so a flip tweens instead of teleporting.
function enemy_spawn()
  local roll = rnd(1)
  local kind = "flip"
  if level >= 2 and roll < 0.28 then kind = "tank"
  elseif level >= 2 and roll < 0.5 then kind = "spkr" end
  local l = flr(rnd(web.nl))
  local speed = 0.0032 + level * 0.00035
  local e = { kind = kind, lf = l, tl = l, d = 0, spd = speed, wob = rnd(1) }
  if kind == "spkr" then
    e.spd = speed * 1.6
    e.dir = 1
    e.top = 0.35 + rnd(0.45)
  end
  add(ens, e)
  if kind == "spkr" then sfx_safe("spiker_spawn") end
end

function flip_start(e)
  if not web.closed and (e.tl <= 0 or e.tl >= web.nl - 1) then
    -- open webs have walls: turn round rather than walking off the end
    e.tl = clamp(e.tl + (e.tl <= 0 and 1 or -1), 0, web.nl - 1)
  else
    e.tl = lane_wrap(e.tl + (rnd(1) < 0.5 and -1 or 1))
  end
  e.flipping = true
  sfx_safe("flipper_hop")
end

function flip_step(e, spd)
  local d = lane_delta(e.lf, e.tl)
  if abs(d) <= spd then
    e.lf = e.tl
    e.flipping = false
  else
    e.lf = lane_wrap(e.lf + (d > 0 and spd or -spd))
  end
end

function enemy_update(e)
  if e.kind == "spkr" then
    e.d = clamp(e.d + e.spd * e.dir, 0, 1)
    spikes[round(e.lf) % web.nl] = max(spikes[round(e.lf) % web.nl], e.d)
    if e.d >= e.top then e.dir = -1 end
    if e.d <= 0 and e.dir < 0 then
      -- retreats into the mouth once its spike is laid
      e.dead = true
    end
    return
  end

  if e.d < 1 then
    e.d = min(1, e.d + e.spd)
    if e.flipping then
      flip_step(e, 0.09)
    elseif e.kind == "flip" and rnd(1) < 0.022 then
      flip_start(e)
    end
    if e.kind == "flip" and e.d > 0.1 and e.d < 0.95
       and rnd(1) < 0.004 + level * 0.0004 then
      add(eshots, { lane = round(e.lf) % web.nl, d = e.d })
    end
    if e.d >= 1 then
      e.atrim = true
      if e.kind == "tank" then tank_split(e) end
      sfx_safe("rim_alarm")
    end
  else
    -- at the rim: walk round toward the claw and take it
    local d = lane_delta(e.lf, plr.lf)
    local step = 0.055
    if abs(d) <= step then
      e.lf = plr.lf
    else
      e.lf = lane_wrap(e.lf + (d > 0 and step or -step))
    end
    if abs(lane_delta(e.lf, plr.lf)) < 0.55 then player_die() end
  end
end

function tank_split(e)
  e.dead = true
  local x, z = lane_mid(e.lf, e.d)
  boom(x, ydepth(e.d), z, 8, { 11, 10, 7 })
  sfx_safe("tanker_burst")
  for s = -1, 1, 2 do
    local l = lane_wrap(round(e.lf) + s)
    add(ens, { kind = "flip", lf = l, tl = l, d = e.d, spd = e.spd * 1.1,
               wob = rnd(1) })
  end
end

function enemy_kill(e, i, scored)
  if scored then
    if e.kind == "flip" then add_score(SCORE_FLIP)
    elseif e.kind == "tank" then add_score(SCORE_TANK)
    else add_score(SCORE_SPKR) end
  end
  local x, z = lane_mid(e.lf, e.d)
  boom(x, ydepth(e.d), z, 12, { 10, 9, 8, 7 })
  sfx_safe("enemy_explode")
  if e.kind == "tank" and e.d < 0.9 then
    -- a shot tanker still lets its cargo out
    for s = -1, 1, 2 do
      local l = lane_wrap(round(e.lf) + s)
      add(ens, { kind = "flip", lf = l, tl = l, d = e.d, spd = e.spd * 1.1,
                 wob = rnd(1) })
    end
  end
  deli(ens, i)
end

function enemy_draw(e)
  local y = ydepth(e.d)
  local ax, az, bx, bz = lane_edges(e.lf, e.d)
  local mx, mz = (ax + bx) / 2, (az + bz) / 2
  -- depth-scaled forward reach: distant enemies must not out-grow their lane
  local fwd = 2 + 4 * e.d

  if e.kind == "flip" then
    local c = e.atrim and 14 or 8
    line3d(ax, y, az, bx, y, bz, c)
    line3d(ax, y, az, mx, y + fwd, mz, 10)
    line3d(bx, y, bz, mx, y + fwd, mz, 10)
    line3d(mx, y + fwd, mz, mx, y + fwd * 0.4, mz, c)
  elseif e.kind == "tank" then
    local ix, iz = lerp(ax, bx, 0.2), lerp(az, bz, 0.2)
    local jx, jz = lerp(ax, bx, 0.8), lerp(az, bz, 0.8)
    line3d(ix, y, iz, jx, y, jz, 11)
    line3d(ix, y, iz, mx, y + fwd, mz, 11)
    line3d(jx, y, jz, mx, y + fwd, mz, 11)
    line3d(ix, y, iz, mx, y - fwd * 0.5, mz, 3)
    line3d(jx, y, jz, mx, y - fwd * 0.5, mz, 3)
    line3d(mx, y + fwd, mz, mx, y + fwd * 0.5, mz, 10)
  else
    -- spiker: a twist of segments round the lane centre
    local ox, oz = lane_out(e.lf, e.d, 3)
    local w = flr(e.wob * 4 + frame * 0.25) % 4
    local sx = (w == 0 or w == 1) and ox or -ox
    local sz = (w == 0 or w == 3) and oz or -oz
    line3d(mx - sx, y, mz - sz, mx + sx, y + fwd * 0.5, mz + sz, 11)
    line3d(mx + sx, y + fwd * 0.5, mz + sz, mx - sx, y + fwd, mz - sz, 10)
  end
end

function enemies_update()
  for i = #ens, 1, -1 do
    local e = ens[i]
    enemy_update(e)
    if mode ~= "play" then return end
    if e.dead then deli(ens, i) end
  end
end

-- =================================================================== 08_fx ==
function boom(x, y, z, n, cols)
  for i = 1, n do
    add(fx, {
      x = x, y = y, z = z,
      vx = (rnd(2) - 1) * 1.6, vy = (rnd(2) - 1) * 1.2, vz = (rnd(2) - 1) * 1.6,
      life = 14 + rnd(12), c = pick(cols),
    })
  end
end

function fx_update()
  for i = #fx, 1, -1 do
    local p = fx[i]
    p.x = p.x + p.vx
    p.y = p.y + p.vy
    p.z = p.z + p.vz
    p.life = p.life - 1
    if p.life <= 0 or p.x < 0 or p.x > 127 or p.y < 0 or p.y > 127
       or p.z < 0 or p.z > 63 then
      deli(fx, i)
    end
  end
end

function fx_draw()
  for p in all(fx) do
    vset(flr(p.x), flr(p.y), flr(p.z), p.life < 6 and 5 or p.c)
  end
end

-- The superzapper flash: rings racing out of the mouth, drawn over the web.
function zap_draw()
  for k = 0, 2 do
    local d = ((zapflash / 12) + k * 0.33) % 1
    rim_draw(d, k == 0 and 7 or web.acc)
  end
end

-- ================================================================= 09_warp ==
-- The dive to the next level.  The camera is fixed by the host, so the rush
-- is sold by rings streaming toward the player and by the web's depth bands
-- scrolling the same way.  Spikes still standing are lethal: pick a clear
-- lane before the impact frame.
WARP_LEN    = 150
WARP_IMPACT = 100

function warp_update()
  warpt = warpt + 1
  player_update()
  fx_update()
  if warpt == 1 then sfx_safe("warp_dive") end
  if warpt == WARP_IMPACT then
    if spikes[plr.lane] > 0.45 then
      player_die()
      return
    end
  end
  if warpt >= WARP_LEN then
    level = level + 1
    level_init(level)
    mode = "play"
    modet = 0
  end
end

function warp_draw()
  for k = 0, 5 do
    local d = ((warpt / 30) + k / 6) % 1
    rim_draw(d, web.ramp[flr(d * BANDS) + 1])
  end
end

-- ================================================================== 10_hud ==
function add_score(n)
  score = score + n
  if flr(score / EXTRA_LIFE) > flr((score - n) / EXTRA_LIFE) then
    lives = lives + 1
    sfx_safe("extra_life")
  end
  if score > hiscore then
    hiscore = score
    dset(0, hiscore)
  end
end

-- The HUD lives on a slice in front of the near rim, so nothing occludes it.
-- x is inset to 12..112: the frustum clips a few columns at this depth.
function hud_draw()
  set_draw_slice(HUD_Y)
  print("score " .. score, 12, 3, 7)
  print("hi " .. hiscore, 12, 10, 10)
  print("lvl " .. level, 92, 3, web.rim)
  print("zap " .. zaps, 92, 10, zaps > 0 and 11 or 5)
  for i = 1, min(lives, 6) do
    local x = 12 + (i - 1) * 7
    line(x, 58, x + 4, 58, 10)
    line(x, 58, x + 2, 55, 10)
    line(x + 4, 58, x + 2, 55, 10)
  end
end

function banner(txt, z, c)
  set_draw_slice(HUD_Y)
  print(txt, 64 - #txt * 2, z, c)
end

-- ================================================================= 11_game ==
function level_init(lv)
  web_build(lv)
  spikes_init()
  ens, shots, eshots = {}, {}, {}
  zaps = ZAPS
  zapflash = 0
  warpt = 0
  spawn_left = 10 + lv * 2
  spawn_t = 50
  intro = 70
  -- The web shape changes with the level, so the old lane index means nothing
  -- on the new one: put the claw back where the eye already is.
  player_init()
  music_safe("level_theme", 1)
end

function new_game()
  score = 0
  lives = 3
  level = 1
  fx = {}
  web_build(1)
  level_init(1)
end

function _init()
  cartdata("voxbox_tempest")
  hiscore = dget(0)
  frame = 0
  modet = 0
  mode = "title"
  new_game()
  music_safe("title_theme")
end

function _update()
  frame = frame + 1
  modet = modet + 1
  if zapflash > 0 then zapflash = zapflash - 1 end

  if mode == "title" then
    fx_update()
    -- a slow demo: flippers climbing an empty web
    if frame % 45 == 0 and #ens < 4 then
      local l = flr(rnd(web.nl))
      add(ens, { kind = "flip", lf = l, tl = l, d = 0, spd = 0.004,
                 wob = rnd(1) })
    end
    for i = #ens, 1, -1 do
      local e = ens[i]
      e.d = e.d + e.spd
      if e.flipping then flip_step(e, 0.09)
      elseif rnd(1) < 0.02 then flip_start(e) end
      if e.d >= 1 then deli(ens, i) end
    end
    if btnp(4) then
      mode = "play"
      modet = 0
      new_game()
      sfx_safe("menu_select")
    end

  elseif mode == "play" then
    if intro > 0 then intro = intro - 1 end
    player_update()
    if mode ~= "play" then return end
    shots_update()
    if mode ~= "play" then return end
    enemies_update()
    if mode ~= "play" then return end
    fx_update()

    if spawn_left > 0 then
      spawn_t = spawn_t - 1
      if spawn_t <= 0 and #ens < 6 + flr(level / 2) then
        enemy_spawn()
        spawn_left = spawn_left - 1
        spawn_t = max(14, 46 - level * 2)
      end
    elseif #ens == 0 then
      mode = "warp"
      modet = 0
      warpt = 0
      sfx_safe("level_clear")
    end

  elseif mode == "warp" then
    warp_update()

  elseif mode == "dying" then
    fx_update()
    if modet > 70 then
      if lives <= 0 then
        mode = "over"
        modet = 0
        sfx_safe("game_over")
        music_safe("game_over_theme")
      else
        shots, eshots = {}, {}
        player_init()
        mode = "play"
        modet = 0
      end
    end

  elseif mode == "over" then
    fx_update()
    if modet > 90 and btnp(4) then
      mode = "title"
      modet = 0
      ens = {}
      web_build(1)
      music_safe("title_theme")
    end
  end
end

function _draw()
  clv()
  web_draw(mode == "title")
  spikes_draw()

  if mode == "warp" then warp_draw() end
  if zapflash > 0 then zap_draw() end

  for e in all(ens) do enemy_draw(e) end
  shots_draw()
  fx_draw()

  if mode ~= "dying" and mode ~= "over" and mode ~= "title" then
    player_draw()
  end

  if mode == "title" then
    banner("tempest", 8, web.rim)
    banner("a voxbox cart", 16, 13)
    banner("left right  rotate", 40, 7)
    banner("x fire   z superzapper", 47, 7)
    if frame % 40 < 26 then banner("press x to start", 56, 10) end
  else
    hud_draw()
    if mode == "play" and intro > 0 then
      banner("level " .. level .. "  " .. web.name, 20, web.rim)
    elseif mode == "warp" then
      banner("dive", 20, 7)
      if warpt < WARP_IMPACT and spikes[plr.lane] > 0.45 then
        banner("spike ahead", 27, 8)
      end
    elseif mode == "over" then
      banner("game over", 24, 8)
      if modet > 90 and frame % 40 < 26 then banner("press x", 32, 7) end
    end
  end
end
