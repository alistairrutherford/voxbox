-- voxel-killer-bunny.lua : a walkable voxel diorama for voxbox.
--
-- One scene, not a level generator: a grass island with a rock ridge, a
-- waterfall pouring out of it, a river running down to the near corner, a red
-- hump-back bridge, flagstone paths, trees, boulders -- and a bunny with a
-- sword you can walk around it and jump with.
--
-- The volume is 128(x) x 128(y, 0 = far wall) x 64(z, 0 = TOP), so *larger z
-- is lower*. Every height in here is a z and therefore counts downward:
-- Z_LAWN 46 is the grass and Z_PLAT 38 is eight voxels *above* it, not below.
--
-- Everything static is baked into one display list at _init and replayed each
-- frame, because none of it moves: the terrain is ~1000 tile columns, which
-- run-length merges down to a few hundred boxes, and re-deriving them thirty
-- times a second would be thirty times the work for the same picture. Only the
-- water, the bunny and the HUD are drawn from scratch each frame.
--
-- Concatenated build order is the section numbering below.

-- =============================================================== 01_config ==
TILE  = 4               -- voxels per map tile; 32 tiles x 4 = the full 128
GRID  = 32
SUB   = 2               -- voxels per rock sub-cell: the ridge is built finer

Z_LAWN  = 46            -- the grass everything else is measured against
Z_STEP  = 42            -- one terrace up
Z_PLAT  = 38            -- the far plateau, two up: a jump, not a step
Z_BED   = 50            -- river bed
Z_WATER = 47            -- top of the water: one voxel of bank, or the near
                        -- side of the channel hides the river at this camera
Z_FILL  = 51            -- earth begins here, under every surface
Z_FLOOR = 60            -- and the island ends here: the slab's underside

-- pico-8 palette: 0 black, 1 navy, 2 wine, 3 dark green, 4 brown, 5 gray,
-- 6 light gray, 7 white, 8 red, 9 orange, 10 yellow, 11 green, 12 blue,
-- 13 lavender, 14 pink, 15 peach
-- The palette has exactly two greens, so "a shade darker" is a step, not a
-- nudge: the ground takes the dark one and the foliage the bright one, which
-- is the only ordering available and does the job of separating a canopy from
-- the grass it stands on. Tufts are leaf-coloured for the same reason -- at
-- the ground's colour they would simply disappear.
C_GRASS  = 3            -- ground
C_LEAF   = 11           -- foliage
C_EARTH  = 1            -- the slab's flank: dark, so the grass reads as a lid
C_ROCK   = 5
C_ROCK_L = 6
C_TRUNK  = 4
C_STONE  = 6            -- flagstones
C_STONE_D= 5
C_WATER  = 12
C_WATER_D= 1
C_FOAM   = 7
C_BRIDGE = 8
C_BRIDGE_D = 2          -- the bridge's underside and legs
C_BOULDER= 0
C_FUR    = 7
C_EAR    = 14
C_EYE    = 8
C_MUZZLE = 15
C_BLADE  = 6

SPD      = 1.15         -- voxels per frame at 30Hz
SPD_WADE = 0.55         -- the river is worth avoiding, not fatal
GRAV     = 0.38
JUMP     = -2.7         -- up is -z: this apexes ~9 voxels, enough for a terrace
STEP_UP  = 2            -- anything taller than this has to be jumped

-- ================================================================== 02_map ==
-- Row = y (0 = far wall), column = x. The camera stands off the near-left
-- corner, so this text is the render turned: the map's top-right corner is the
-- far corner of the picture and its bottom-left corner is the near one. Rows
-- run steeply up and to the left on screen, columns shallowly up and right.
--
--   .  lawn          -  terrace        =  plateau      #  rock
--   o  flagstones    O  flagstones on the terrace
--   ~  river         W  the fall itself, coming out of the ridge
MAP = {
  "--------############============",
  "--------############============",
  "--------##########WW============",
  "--------.#########WW.===========",
  "-------...#######.WW.===========",
  "-------.....####..~~~.==========",
  "------............~~~..=========",
  "-----..............~~~-------OOO",
  "----...............~~~.-----O-O-",
  "---................~~~..-----OO-",
  "--..................~~~..---OOO-",
  "....................~~~...-OOO--",
  "....................~~~...o-OO--",
  ".....................~~~..ooo...",
  "...................o.~~~..oo....",
  "..................oo.~~~.ooo....",
  "..................oo..~~~..oo...",
  "................ooo...~~~..ooo..",
  "................oo....~~~...ooo.",
  "..............o.oo....~~~~...ooo",
  ".............oo.o......~~~.ooo.o",
  ".............oo........~~~.ooooo",
  "............o.o........~~~~.oooo",
  "...........ooo..........~~~.o..o",
  "..........oooo..........~~~..ooo",
  ".........oooo...........~~~~..oo",
  ".........oo..............~~~...o",
  "........oooo.............~~~...o",
  "........ooo..............~~~~...",
  "........o.................~~~...",
  ".......oo.................~~~...",
  ".......ooo................~~~...",
}

function tile(c, r)
  if c < 0 or c >= GRID or r < 0 or r >= GRID then return "." end
  return sub(MAP[r + 1], c + 1, c + 1)
end

-- An arithmetic hash, not rnd(): the scene has to look the same every time the
-- cart is loaded, and rnd() would also make the build order matter.
function hsh(c, r, n)
  return flr(c * 37 + r * 101 + c * r) % n
end

-- The ridge is tallest along the far wall and steps down toward the grass,
-- with a taper at both ends so it meets the lawn rather than stopping dead.
--
-- It is the one part of the ground built at HALF a tile, because a 4-voxel
-- step is the smallest crag a tile grid can express and rock at that grain
-- reads as masonry. The massing stays per tile -- otherwise the ridge turns
-- to gravel -- and only a plus-or-minus-one course is picked per sub-cell,
-- which is what puts the notches and ledges in the face.
function rock_top(sx, sy)
  local c, r = flr(sx / SUB), flr(sy / SUB)
  local flank = max(0, abs(c - 13) - 4)
  local base = 8 + r * 4 + hsh(c, r, 7) + flr(flank * 2)
  return min(Z_LAWN - 3, base + hsh(sx * 3, sy * 5, 4) - 1)
end

function rock_col(c, r)
  -- the ridge is seen side-on and side faces are shaded to two thirds, so it
  -- is built from the pale grey and salted with the dark one, not the other
  -- way round: the reverse comes out nearly black
  return (hsh(c, r, 5) < 2) and C_ROCK or C_ROCK_L
end

function level_z(ch)
  if ch == "-" or ch == "O" then return Z_STEP end
  if ch == "=" then return Z_PLAT end
  return Z_LAWN
end

-- Surface of a tile, and the colour of the column under it. A nil colour means
-- "nothing static here": the river is redrawn every frame and the rock is laid
-- in its own finer pass, so both drop out of the tile-sized run merge.
function surface(c, r)
  local ch = tile(c, r)
  if ch == "~" or ch == "W" or ch == "#" then return Z_BED, nil end
  return level_z(ch), C_GRASS
end

-- What the bunny stands on at a world position: the tile surface, raised by a
-- voxel where flagstones are laid, and overridden by the bridge deck inside
-- its span.
function ground(x, y)
  local c, r = flr(x / TILE), flr(y / TILE)
  local ch = tile(c, r)
  local bz = bridge_z(x, y)
  if bz then return bz end
  if ch == "~" or ch == "W" then return Z_BED end
  if ch == "#" then return rock_top(flr(x / SUB), flr(y / SUB)) end
  if ch == "o" or ch == "O" then return level_z(ch) - 1 end
  return level_z(ch)
end

-- ================================================================ 03_scene ==
-- The display list is a flat number array rather than a list of tables: it is
-- rebuilt once and walked every frame, so seven slots beat an allocation.
scene = {}
balls  = {}     -- spheres, replayed after the boxes: canopies over trunks
rivers = {}     -- {c, r} of every water tile, animated per frame
falls  = {}     -- {c, r, ztop} of the waterfall columns
solids = {}     -- {x, y, radius} the bunny cannot walk into: trunks, boulders

function box_add(x0, y0, z0, x1, y1, z1, c)
  local n = #scene
  scene[n + 1] = x0 scene[n + 2] = y0 scene[n + 3] = z0
  scene[n + 4] = x1 scene[n + 5] = y1 scene[n + 6] = z1
  scene[n + 7] = c
end

-- sphere() costs one call across the Lua/JS boundary and then loops in JS, so
-- a ball is cheaper per voxel than the dozen boxes it takes to fake one -- and
-- it is round at the voxel rather than at the slab.
function ball_add(x, y, z, r, c)
  local n = #balls
  balls[n + 1] = x balls[n + 2] = y balls[n + 3] = z
  balls[n + 4] = r balls[n + 5] = c
end

function scene_draw()
  for i = 1, #scene, 7 do
    boxfill(scene[i], scene[i + 1], scene[i + 2],
            scene[i + 3], scene[i + 4], scene[i + 5], scene[i + 6])
  end
  for i = 1, #balls, 5 do
    sphere(balls[i], balls[i + 1], balls[i + 2], balls[i + 3], balls[i + 4])
  end
end

-- ---- terrain ---------------------------------------------------------------
-- Every draw call costs the same trip across the Lua/JS boundary whatever it
-- paints -- about fifteen microseconds, against two for the voxels a ground
-- column actually writes -- so the box *count* is the frame budget and area is
-- nearly free. Hence two merge passes, the same pair the roguelike runs over
-- its light map: join equal cells along a row, then join identical runs down
-- the rows. An unbroken lawn becomes one box however many tiles it covers, and
-- what is left costs what the scene actually changes.
--
-- probe(i, j) returns the surface z and colour of cell (i, j); a nil colour
-- means "nothing static here" and drops the cell out of both passes.
function build_layer(n, cell, probe)
  local rows = {}
  for j = 0, n - 1 do
    local list = {}
    local i0, iz, ic = nil, nil, nil
    for i = 0, n do                          -- one past the end flushes the run
      local z, col
      if i < n then z, col = probe(i, j) end
      if z ~= iz or col ~= ic then
        if i0 and ic then add(list, { i0, i - 1, iz, ic }) end
        i0, iz, ic = i, z, col
      end
    end
    rows[j] = list
  end

  for j = 0, n - 1 do
    for a in all(rows[j]) do
      if not a.taken then
        local j1 = j
        for k = j + 1, n - 1 do              -- how far down does this run hold?
          local same = nil
          for b in all(rows[k]) do
            if not b.taken and b[1] == a[1] and b[2] == a[2]
               and b[3] == a[3] and b[4] == a[4] then same = b break end
          end
          if not same then break end
          same.taken = true
          j1 = k
        end
        box_add(a[1] * cell, j * cell, a[3],
                (a[2] + 1) * cell - 1, (j1 + 1) * cell - 1, Z_FILL - 1, a[4])
      end
    end
  end
end

function build_terrain()
  -- one slab for everything below the surface, so each column only has to
  -- carry its own material -- which is what makes merging the runs worthwhile
  box_add(0, 0, Z_FILL, 127, 127, Z_FLOOR, C_EARTH)

  build_layer(GRID, TILE, surface)

  for r = 0, GRID - 1 do
    for c = 0, GRID - 1 do
      local ch = tile(c, r)
      if ch == "o" or ch == "O" then
        -- a 3x3 stone in a 4x4 tile: the missing voxel is the grass seam that
        -- makes a path read as flagstones rather than as a grey stripe
        local z = level_z(ch) - 1
        local col = C_STONE
        if hsh(c, r, 3) == 0 then col = C_STONE_D end
        box_add(c * TILE, r * TILE, z, c * TILE + 2, r * TILE + 2, z, col)
      elseif ch == "~" then
        river_span(c, r)
      elseif ch == "W" then
        -- the fall starts a little below the rock it comes out of, and each
        -- row nearer the camera starts lower again, so the sheet reads as
        -- water arcing off the lip rather than as a block of blue
        add(falls, { c, r, rock_top(c * SUB, SUB) + 3 + (r - 2) * 6 })
        river_span(c, r)
      end
    end
  end

  build_rock()
end

-- The ridge, laid at half-tile resolution through the same two passes. A face
-- of equal courses still collapses to one box, so the finer grain only costs
-- where the rock is actually broken -- which is where the detail was wanted.
function build_rock()
  build_layer(GRID * TILE / SUB, SUB, function(sx, sy)
    local c, r = flr(sx * SUB / TILE), flr(sy * SUB / TILE)
    if tile(c, r) ~= "#" then return nil, nil end
    return rock_top(sx, sy), rock_col(c, r)
  end)
end

-- ---- props -----------------------------------------------------------------
-- A canopy is a cluster of overlapping balls, offset off the trunk so the
-- silhouette is lumpy rather than symmetrical. Stacked slabs were cheaper and
-- looked it: five or six flat steps is a ziggurat, where a ball is round at
-- every voxel of its radius and two of them meet in a saddle no box can cut.
-- Each entry is {across, forward, up, radius} from the foot of the trunk.
CANOPY = {
  {  0,  0, 18,  9 }, {  0,  0, 25,  5 }, { -5,  1, 15,  5 },
  {  4, -4, 16,  5 }, { -2, -5, 21,  5 }, {  5,  3, 20,  5 },
  {  1,  5, 13,  4 },
}

function tree(c, r, big)
  local x, y = c * TILE + 2, r * TILE + 2
  local g = ground(x, y)
  local s = big and 1 or 0.68
  local function sc(v) return flr(v * s + 0.5) end

  -- three courses, each narrower than the one under it: a trunk that tapers
  -- has a shape, and the flare at the bottom is where it meets the grass
  box_add(x - sc(3), y - sc(3), g - sc(2), x + sc(3), y + sc(3), g, C_TRUNK)
  box_add(x - sc(2), y - sc(2), g - sc(10), x + sc(2), y + sc(2), g - sc(2), C_TRUNK)
  box_add(x - sc(1), y - sc(1), g - sc(21), x + sc(1), y + sc(1), g - sc(10), C_TRUNK)

  for l in all(CANOPY) do
    ball_add(x + sc(l[1]), y + sc(l[2]), g - sc(l[3]), sc(l[4]), C_LEAF)
  end
  add(solids, { x, y, sc(2) + 2 })
end

-- Boulders are stacked a course at a time instead of in four slabs. The radius
-- shrinks toward the cap and each course sits a voxel off the one below it, so
-- the sides break into ledges: that stagger is the whole difference between a
-- rock and a lump, and it costs a dozen boxes.
function boulder(c, r)
  local x, y = c * TILE + 2, r * TILE + 2
  local g = ground(x, y)
  local h = 13
  for i = 0, h - 1 do
    local rad = flr(6 - (i / h) * 4.2 + 0.5)
    local jx = hsh(c + i * 3, r, 3) - 1
    local jy = hsh(c, r + i * 3, 3) - 1
    box_add(x - rad + jx, y - rad + jy, g - i - 1,
            x + rad + jx, y + rad + jy, g - i,
            i > h - 5 and C_ROCK or C_BOULDER)   -- a grey cap on a dark stone
  end
  add(solids, { x, y, 7 })
end

function tuft(c, r)
  local x, y = c * TILE, r * TILE
  local g = ground(x + 1, y + 1)
  box_add(x, y, g - 1, x + 2, y + 2, g - 1, C_LEAF)
end

function flower(c, r)
  local x, y = c * TILE + 1, r * TILE + 1
  local g = ground(x, y)
  box_add(x, y, g - 2, x + 1, y + 1, g, C_LEAF)
  box_add(x - 1, y - 1, g - 5, x + 2, y + 2, g - 3, C_FUR)
  box_add(x, y, g - 6, x + 1, y + 1, g - 6, C_EYE)
end

-- ---- the bridge ------------------------------------------------------------
-- Hump-backed, and built a slice at a time so the arch is a curve rather than
-- three steps. Its deck is also the ground function's answer inside the span,
-- which is the only reason the bunny can cross rather than wade.
BR_X0, BR_X1 = 76, 104
BR_Y0, BR_Y1 = 54, 62
BR_Z,  BR_H  = 45, 4.2

function bridge_deck(x)
  local t = (x - BR_X0) / (BR_X1 - BR_X0)
  return BR_Z - flr(BR_H * -sin(t * 0.5) + 0.5)      -- pico-8 sin is negated
end

function bridge_z(x, y)
  if x < BR_X0 or x > BR_X1 or y < BR_Y0 or y > BR_Y1 then return nil end
  return bridge_deck(x)
end

function build_bridge()
  -- The arch is sampled per voxel of span but emitted per *step* of it: a
  -- half sine over 29 voxels only ever takes five values, so the deck is five
  -- boxes and not twenty-nine. The curve is identical either way.
  local x0, z0 = BR_X0, bridge_deck(BR_X0)
  for x = BR_X0, BR_X1 + 1 do
    local z = x <= BR_X1 and bridge_deck(x) or nil
    if z ~= z0 then
      box_add(x0, BR_Y0, z0, x - 1, BR_Y1, z0 + 2, C_BRIDGE)             -- deck
      box_add(x0, BR_Y0, z0 + 3, x - 1, BR_Y1, z0 + 3, C_BRIDGE_D)  -- underside
      box_add(x0, BR_Y0, z0 - 4, x - 1, BR_Y0 + 1, z0 - 1, C_BRIDGE)    -- rails
      box_add(x0, BR_Y1 - 1, z0 - 4, x - 1, BR_Y1, z0 - 1, C_BRIDGE)
      x0, z0 = x, z
    end
  end
  for x in all({ BR_X0 + 6, BR_X1 - 6 }) do
    box_add(x - 1, BR_Y0, bridge_deck(x) + 3, x + 1, BR_Y0 + 1, Z_BED, C_BRIDGE_D)
    box_add(x - 1, BR_Y1 - 1, bridge_deck(x) + 3, x + 1, BR_Y1, Z_BED, C_BRIDGE_D)
  end
end

function build_props()
  tree(2, 2, false)    tree(6, 6, false)    tree(11, 7, true)
  tree(20, 27, true)   tree(27, 1, true)    tree(24, 9, false)
  tree(1, 11, true)

  boulder(2, 18)  boulder(4, 22)  boulder(3, 26)

  flower(28, 5)

  for p in all({ {3,3}, {12,10}, {21,25}, {27,6}, {5,19}, {9,24}, {30,13} }) do
    tuft(p[1], p[2])
  end

  build_bridge()
end

-- ---- water -----------------------------------------------------------------
-- The river is stored as one span per row rather than as tiles: it is three or
-- four wide, so a span is a whole cross-section of it and the travelling sine
-- then bands the water *across* the flow, which is the direction the ripples
-- want to run anyway. Ninety-one calls a frame become thirty-one.
function river_span(c, r)
  local last = rivers[#rivers]
  if last and last[3] == r and last[2] == c - 1 then last[2] = c return end
  add(rivers, { c, c, r })
end

-- Drawn every frame instead of baked, because the whole point of water is that
-- it moves.
function water_draw()
  for w in all(rivers) do
    local s = sin(w[1] * 0.021 + w[3] * 0.037 - tick * 0.008)
    local col = C_WATER                    -- no white down here: foam belongs
    if s < -0.15 then col = C_WATER_D end  -- to the fall, and reads as snow
    boxfill(w[1] * TILE, w[3] * TILE, Z_WATER,
            w[2] * TILE + 3, w[3] * TILE + 3, Z_BED, col)
  end

  -- The fall is banded the same way, down z instead of across x, and emitted a
  -- band at a time: a voxel-tall slice per z was thirty calls a column.
  for f in all(falls) do
    local c, r, ztop = f[1], f[2], f[3]
    local z0, col = ztop, nil
    for z = ztop, Z_BED + 1 do
      local k
      if z <= Z_BED then
        local s = sin(z * 0.06 + c * 0.05 - tick * 0.035)
        k = C_WATER
        if s > 0.4 then k = C_FOAM elseif s < -0.55 then k = C_WATER_D end
      end
      if k ~= col then
        if col then
          boxfill(c * TILE, r * TILE, z0, c * TILE + 3, r * TILE + 3, z - 1, col)
        end
        z0, col = z, k
      end
    end
  end
end

-- ================================================================= 04_bunny ==
-- Facing is one of four: the bunny is built from axis-aligned boxes, and a
-- fifth angle would need voxels the primitives cannot place. FACE is the
-- direction it looks in, and bpart() below rotates the whole animal into it.
FACE = { {0,1}, {0,-1}, {-1,0}, {1,0} }   -- near, far, left, right

function bunny_init()
  bx, by = 42, 42
  bz = ground(bx, by)
  bvz = 0
  bdir = 1                                 -- looking at the camera
  bair = false
  bwet = false
  bhop = 0                                 -- landing squash, in frames
end

-- Movement is resolved one axis at a time so a wall you walk into diagonally
-- slides you along it instead of stopping you dead.
function try_move(nx, ny)
  local g = ground(nx, ny)
  if g < bz - STEP_UP then return false end        -- too tall to step onto
  for s in all(solids) do
    local dx, dy = nx - s[1], ny - s[2]
    if dx * dx + dy * dy < s[3] * s[3] then return false end
  end
  return true
end

function bunny_update()
  local dx, dy = 0, 0
  if btn(0) then dx = -1 end
  if btn(1) then dx = 1 end
  if btn(2) then dy = -1 end
  if btn(3) then dy = 1 end

  if dx ~= 0 or dy ~= 0 then
    if dy > 0 then bdir = 1 elseif dy < 0 then bdir = 2
    elseif dx < 0 then bdir = 3 else bdir = 4 end
    local spd = bwet and SPD_WADE or SPD
    if dx ~= 0 and dy ~= 0 then spd = spd * 0.72 end
    if try_move(bx + dx * spd, by) then bx = mid(3, bx + dx * spd, 124) end
    if try_move(bx, by + dy * spd) then by = mid(3, by + dy * spd, 124) end
  end

  if btnp(4) and not bair then      -- button 4 is the x key in this host
    bvz = JUMP
    bair = true
    sfx_safe("jump")
  end

  bvz = bvz + GRAV
  bz = bz + bvz
  local g = ground(bx, by)
  if bz >= g then
    if bair and bvz > 1.2 then bhop = 4 sfx_safe("land") end
    bz, bvz, bair = g, 0, false
  elseif bvz > GRAV * 2 then
    bair = true                                    -- walked off a ledge
  end
  if bhop > 0 then bhop = bhop - 1 end

  local ch = tile(flr(bx / TILE), flr(by / TILE))
  local wet = (ch == "~" or ch == "W") and not bridge_z(bx, by)
  if wet and not bwet then sfx_safe("splash") end
  bwet = wet
end

-- One box of the bunny, given in the bunny's own frame: l runs across it, f
-- forward (where it is looking), u up from its feet. The frame is one of four
-- 90-degree rotations, so an axis-aligned box stays axis-aligned and this is
-- still a single boxfill -- which is the only reason the thing can have feet
-- and a muzzle and a sword instead of being one white slab.
function bpart(l0, f0, u0, l1, f1, u1, c)
  local fx, fy = FACE[bdir][1], FACE[bdir][2]
  local px, py = -fy, fx
  boxfill(bux + px * l0 + fx * f0, buy + py * l0 + fy * f0, buz - u0,
          bux + px * l1 + fx * f1, buy + py * l1 + fy * f1, buz - u1, c)
end

function bunny_draw()
  bux, buy, buz = flr(bx), flr(by), flr(bz)
  local sq = bhop > 0 and 2 or 0                   -- lands with a bend
  local tuck = bair and 2 or 0                     -- and tucks its feet up
  local lay = bair and 1 or 0                      -- ears go back in the air
  local top = 13 - sq

  bpart(-2, 0, tuck, -1, 2, tuck + 1, C_FUR)       -- feet, one either side
  bpart(1, 0, tuck, 2, 2, tuck + 1, C_FUR)
  bpart(-2, -2, 1, 2, 1, 7 - sq, C_FUR)            -- body
  bpart(-1, -3, 3, 1, -3, 5, C_FUR)                -- scut
  bpart(-1, -1, 7 - sq, 1, 1, 8 - sq, C_FUR)       -- neck: the notch that
  bpart(-2, -2, 8 - sq, 2, 2, top, C_FUR)          -- keeps the head a head

  bpart(-1, 2, top - 4, 1, 3, top - 3, C_MUZZLE)   -- muzzle
  bpart(0, 3, top - 3, 0, 3, top - 3, C_EAR)       -- nose
  bpart(-2, 2, top - 2, -1, 2, top - 1, C_EYE)     -- and the red eyes it is
  bpart(1, 2, top - 2, 2, 2, top - 1, C_EYE)       -- named for

  for l in all({ -2, 1 }) do                       -- ears, two voxels each
    bpart(l, -1 - lay, top, l + 1, 1 - lay, top + 7, C_FUR)
    bpart(l, 1 - lay, top + 1, l + 1, 1 - lay, top + 6, C_EAR)
  end

  bpart(3, 0, 4, 3, 1, 6, C_TRUNK)                 -- the sword: hilt at the hip
  bpart(3, 0, 6, 3, 0, 14, C_BLADE)                -- blade up past the ear
  bpart(2, 0, 6, 4, 0, 6, C_BLADE)                 -- crossguard

  -- a ripple where it stands in the river
  if bwet and not bair then
    local r = 4 + (tick % 20) / 10
    boxfill(bux - r, buy - r, Z_WATER - 1, bux + r, buy + r, Z_WATER - 1, C_FOAM)
  end
end

-- =================================================================== 05_hud ==
-- The boards hang on one y slice: print() draws into the current slice, so a
-- plate is a box and its legend is the same rectangle one voxel nearer the
-- camera.
--
-- The slice sits one voxel in front of the ridge's near face, and that is the
-- whole of the reasoning. Further back looks better -- screen-up runs mostly
-- along -y here, so depth is what lifts the boards clear of the play area --
-- but the ridge is 24 voxels deep and the boards are 18 tall, so a plane
-- *inside* it has crags both in front of and behind the same board. That does
-- not read as a sign standing in front of a mountain, it reads as a sign
-- sunk into one. In front of the rock the occlusion is unambiguous, and the
-- peaks still rise past the boards the way they do in the picture.
HUD_Y0, HUD_Y1 = 24, 28

HEART = {
  ".##.##.",
  "#######",
  "#######",
  ".#####.",
  "..###..",
  "...#...",
}

ARROW = {
  "..#..",
  ".#...",
  "#####",
  ".#...",
  "..#..",
}

-- A run of set pixels is one box, not one box each: a heart is thirty voxels
-- and eight runs, and at fifteen microseconds a call the difference between
-- those two numbers is worth more than the voxels are.
function stamp(pat, x, z, c)
  for r = 1, #pat do
    local row = pat[r]
    local i0 = nil
    for i = 1, #row + 1 do
      local on = i <= #row and sub(row, i, i) == "#"
      if on and not i0 then i0 = i end
      if not on and i0 then
        boxfill(x + i0 - 1, HUD_Y0, z + r - 1,
                x + i - 2, HUD_Y1 + 1, z + r - 1, c)
        i0 = nil
      end
    end
  end
end

function plate(x0, z0, x1, z1, c)
  boxfill(x0, HUD_Y0, z0, x1, HUD_Y1, z1, c)
end

function legend(s, x, z, c)
  set_draw_slice(HUD_Y1 + 1)
  print(s, x, z, c)
end

function hud_draw()
  plate(4, 0, 56, 8, 13)                     -- score
  plate(30, 1, 54, 7, 12)
  legend("SCORE", 7, 2, 7)
  legend("000000", 31, 2, 7)

  plate(66, 0, 126, 8, 13)                   -- hiscore
  plate(98, 1, 124, 7, 12)
  legend("HISCORE", 69, 2, 7)
  legend("000000", 99, 2, 7)

  plate(2, 10, 34, 18, 9)                    -- the sword you are carrying
  legend("SWORD", 4, 12, 0)
  stamp(ARROW, 26, 12, 0)

  plate(90, 10, 126, 18, 5)                  -- multiplier
  legend("MULT X 1", 93, 12, 7)

  for i = 0, 2 do                            -- lives
    local x = 60 + i * 9
    stamp(HEART, x, 11, 8)
    boxfill(x + 1, HUD_Y0, 11, x + 2, HUD_Y1 + 1, 11, C_EAR)
  end
end

-- ================================================================== 06_main ==
function sfx_safe(n) pcall(play_sound, n) end

function _init()
  tick = 0
  build_terrain()
  build_props()
  bunny_init()
end

function _update()
  tick = tick + 1
  bunny_update()
end

function _draw()
  clv()
  scene_draw()
  water_draw()
  bunny_draw()
  hud_draw()
end
