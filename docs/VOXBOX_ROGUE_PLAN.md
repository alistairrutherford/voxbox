# Voxel Rogue — Project Plan

Working name: **deeper**. A colourful, funny, turn-based roguelike cart for
voxbox: isometric room-at-a-time dungeon crawling with torchlight, wearable
armour, joke spells, and a menagerie of monsters and ghosts who talk back.

Written as a plan against **this** engine, not a generic one. Section 0 is the
part that matters most: several of the requested features do not exist in the
renderer and have to be built in the cart instead. Where that is true it says
so, and says what the cart does instead.

---

## 0. What the engine gives, and what it does not

Everything below was read out of `runtime/js/render.js`, `runtime/js/volume.js`,
`runtime/js/host.js` and `shim/api.lua`, not assumed.

### Given, free

| Capability | Where | Use here |
|---|---|---|
| 128 x 128 x 64 voxel volume | `volume.js:9` | one room per volume |
| Perspective raymarcher, per-cart camera | `render.js:160` | fixed isometric view |
| Per-face flat shading: top 1.0, y-face 0.80, x-face 0.66, underside 0.5 | `render.js:79` | free form-reading on every box |
| Straight-down drop shadows on a derived ground plane | `render.js:81`, `volume.js:165` | **hero and monster shadows on the floor, for nothing** |
| `boxfill`, `box`, `sphere`, `line3d`, `vset` | `volume.js` | all loop inside JS: one Lua call each, cheap |
| 2D ops on a y-slice: `line`, `circ`, `circfill`, `print`, `rect` | `volume.js:110+` | HUD, speech bubbles, minimap |
| 3x5 uppercase font, 4px advance | `volume.js:141` | ~31 glyphs across the volume |
| Deterministic `rnd`/`srand` (Park-Miller, float-safe) | `picovox.lua:75` | **seeded dungeons that regenerate identically** |
| `cartdata` / `dget` / `dset`, 64 numeric slots | `host.js:278` | meta-progression |
| `persistGlobals` sidecar, numeric globals only | `host.js:490` | run resume |
| manifest `config` block, arriving as the `CONFIG` global | `host.js` | look flags and dialogue authored as data, not code |
| Sound synthesised from the sound's *name* | `sfxgen.js` | ~40 sounds with no audio authored |

### Not given — and what we do instead

1. **There is no lighting.** The fragment shader multiplies a palette colour by
   a constant per face and nothing else. There are no point lights, no falloff,
   no additive blending, and voxels are fully opaque. A torch cannot illuminate
   anything by existing.

   **What we do:** the cart keeps its own **light map** — on a grid finer than
   the tiles — and *chooses the palette index* for each floor and wall voxel
   from a 4-step ramp indexed by light level. Warm ramps near torches, cold ramps away from them. This is
   real, visible, coloured, flickering torchlight — it just lives in the cart's
   colour choice rather than in the shader. Section 2 is entirely about this.
   Section 12 offers a small optional engine change if we later want true
   smooth falloff.

2. **The cart cannot move the camera.** It is set once from the sidecar
   (`host.js:395`). No scrolling, no camera shake, no zoom.

   **What we do:** one room per volume, hard cuts between rooms. Impact is sold
   by a flash on the near sill; offsetting every drawn voxel would be a true
   shake and is the obvious next step, since the cart draws everything.

3. **Text is 3x5 uppercase, ~31 characters across the whole volume.** The
   font is a fixed bitmap with a 4-voxel advance (`font.js`) and there is no
   scale: one voxel is the smallest mark the renderer can make, so the font
   cannot be made smaller, and apparent size is set by how far the slice is
   from the camera — the HUD is already on the farthest plane there is.

   **What we do:** every line of dialogue is written to fit **24 characters**,
   two lines maximum. This is a constraint on the comedy, and a good one —
   it forces one-liners. 24 rather than the whole width because the minimap
   holds the right-hand column (§9).

   If a row ever has to hold more, the lever is the font rather than the
   layout: a variable advance (`I` and `1` are 2 voxels wide, not 4) would fit
   roughly a third more characters for four lines of `volume.js`. That is an
   engine change, so it is not on the critical path.

4. **Only 15 colours** (index 0 is empty space, never a paint colour).

   **What we do:** colour is spent deliberately. Each depth band gets a theme
   of two ramps (a stone ramp and a torch ramp) plus accent colours reserved
   for the hero, monsters and spell effects. Section 2.2.

5. **`draw_voxmap` / `blit_voxmap` are unimplemented** — they need `.vx.png`
   models the engine cannot load. Everything is drawn from primitives, like
   every other bundled cart.

6. **The raymarch loop is capped at 320 DDA steps** (`render.js:75`). A
   diagonal ray across a full 128 x 128 x 64 volume is exactly at that bound.
   Tall walls at an isometric angle push toward it. Phase 0 checks for black
   speckling; the fix if it appears is one number in the shader.

### The occlusion trap, restated

The camera looks from +y toward the back, so **anything on an object's far face
is hidden by the object itself**. This has bitten this project three times. For
an isometric room it means the two *near* walls would stand between the camera
and the room. Section 1.2 handles it by design, not by luck.

---

## 1. The view: one room per volume

### 1.1 Grid and dimensions

| Thing | Value | Why |
|---|---|---|
| Tile footprint | 6 x 6 voxels | hero reads at ~10 voxels tall; smaller and armour is invisible |
| Light cell | 1 x 1 voxel | six to a tile — light is finer than the grid it lights (§2.1) |
| Room grid | 21 x 15 tiles | **wide, not square** — see below |
| Generated chamber | 18..21 x 12..15 tiles | fills the grid; a room that sits small inside the footprint wastes the volume |
| Floor surface | z = 58 | **kept low on purpose** — see below |
| Wall height | 12 voxels, z = 46..58 | tall enough to hold torches, short enough not to swallow the room |
| Hero | 10 voxels tall, z = 48..57 | |
| Ceiling | none | open-topped, as every isometric game does |

**The footprint is wide because the screen is.** A square grid at this camera
projects to something nearly square, so filling the frame's width overflowed
its height and left nowhere for a HUD. 21 x 15 projects to roughly the frame's
own shape: 97% of the width used, with a quarter of the height clear above the
room. Fewer tiles than a square grid, but every tile is ~1.3x bigger on screen,
which is what "scale up the play area" actually meant.

The floor height is not a free parameter. Once the floor plan fills the
footprint there is no empty space *inside* the volume for a HUD, so the only
place left is the back plane above the walls — and how much of that is visible
is set by how low the room sits. Dropping the floor from z = 48 to z = 58 turns
a cramped z = 11..32 band into z = 2..38. **Room size and HUD space trade
directly against each other**, and the trade is paid in floor height.

`groundZ` is pinned to 58 in the sidecar rather than left on `auto`. The
derivation would find the floor in a plain room, but a node full of pillars and
sill walls shifts the mode of the topmost voxels, and the drop shadows then
jump as you walk between rooms.

### 1.2 Cutaway walls

Only the two **far** walls (low y, low x) are drawn full height. The two near
walls are drawn as a 4-voxel sill — enough to read as an edge, too low to
occlude anything. This is the standard isometric cutaway, and here it is not a
stylistic choice but a requirement of the camera.

Torches go on **all four** walls, not just the far pair. The first version put
them only on the far walls, reasoning that a near-wall torch would have its
flame hidden by its own bracket — but the near walls are only a sill, so a
flame mounted above sill height clears it and is perfectly visible. The
occlusion rule that keeps *detail* off near faces does not apply to something
standing proud of a low wall. Once rooms grew to fill the footprint, far-wall
lighting alone left the near half of every room black.

### 1.3 Camera

Tuned live with the URL parameters the host already supports
(`/?cam=…&tgt=…&fov=…`), against an objective gate: the largest node a floor
can generate in frame, with the hero at the near corner not clipped. What it
settled at:

```json
"camera": { "pos": [123, 204, -77], "target": [58, 64, 52], "fov": 42 }
```

12 degrees of azimuth and 38 of elevation. The elevation shows the floor plan;
the azimuth is deliberately short of the textbook 45, because the HUD and all
the dialogue live on a y-slice and a tilted slice skews the 3x5 font.

Azimuth is a direct trade against HUD space, and it was measured rather than
guessed. At the same 97% width:

| azimuth | clear strip | usable HUD rows | row skew |
|---|---|---|---|
| 22° | 17% | 1 | 0.27 |
| 16° | 20% | 2 | 0.21 |
| **12°** | **25%** | **4** | **0.16** |
| 8° | 29% | 5 | 0.11 |
| 0° | 38% | 7 | 0.00 |

12° keeps two wall faces visible — the thing that makes it read as isometric —
while quadrupling the HUD rows. Framing itself is solved numerically: project
the eight corners of a full-grid node, translate the camera along its own
right/up axes until the box is centred horizontally and its bottom edge sits at
-0.97, then shrink fov until it just fits.

---

## 2. Light: torches without a lighting engine

This is the heart of the look, and the part that has to be invented rather
than switched on.

### 2.0 Switching it off

Torchlight is `config.fx.torchlight` in the manifest. It was a row on the
title screen toggled with `z` and remembered in `cartdata` slot 2, which spent
one of six rows of a 3x5 font on the only line there that was neither a control
nor a score — and flat mode is a thing you decide once about a machine, not
between runs. Flat mode forces every cell to one level: the room is evenly lit, the
pools disappear, and the light map collapses from ~590 run-length boxes to 3 —
so it is a performance option as much as a legibility one. The Pot Helm's −2
vision joke is inert while it is off, which is the honest cost.

### 2.1 The light map

**Light runs on its own grid, per voxel, not per tile.** Tile size is set by
how wide a creature has to be to read at this camera; light wants to be as fine
as the volume allows, and nothing requires the two to agree. Per-tile light at
a 6-voxel tile looks like a rendering fault rather than a torch.

- A `light[cell]` array in the range 0..3 over cells of `LS = 1` voxel.
- Recomputed **on room entry** from torch positions: for each torch, add
  falloff over a radius of 5 tiles; take the max across torches; add 1 where
  the hero's own carried torch reaches; clamp.
- Falloff is **Euclidean**, so pools are round. Chebyshev distance is a shade
  cheaper and gives square pools, which at this resolution read as a bug. No
  `sqrt` is needed — the three band edges are compared as squared distances.
- Line of sight is deliberately *not* modelled per tile — it is expensive and,
  in a single convex-ish room, invisible. Props cast no light shadows. If a
  room type ever needs it (a pillared hall), a cheap Bresenham occlusion pass
  runs once on entry, not per frame.
- **Flicker:** each torch carries a phase; every 4 frames its radius wobbles by
  ±0.5 tile. Only the boundary tiles change level, so the picture breathes
  without churning.
- **Count is 1..4 per node**, drawn at random from the eligible wall tiles —
  not one every N tiles along every wall. Even spacing lit the whole perimeter
  and the room read as flat. A few pools with darkness between them is what
  makes torchlight look like torchlight, and it is also what gives the hero's
  own torch something to do.

### 2.1c Masonry

Walls are three bands rather than one slab: a capping course on top, the body,
and a skirting at the floor in the theme's accent. One extra `boxfill` per wall
run each, and the renderer's per-face shading does the rest. Floors get seams
on every third gridline — every tile edge would be correct and would also
multiply the floor's run count, and every third reads as large slabs anyway.

**All three courses take their colour from the run's own light level**, and for
a while none of them did. The cap was hoisted out of the loop as the top of the
stone ramp and the skirting was the bare accent index, so every wall in every
room was capped in the brightest white it had and skirted in full accent —
under a torch and in pitch darkness alike. That drew a bright wireframe over
the whole floor plan and fought the torchlight everywhere: exactly the mistake
§2.1b is careful to avoid for the mottling, committed at far greater visual
weight, and it was most of why the dark half of a room never looked dark. The
cap is now a step up the same ramp, which still reads as a separate course
because the renderer shades a top face at 1.0 against the body's 0.80 anyway.

Seams take the *bottom* of the ramp, because a seam is a groove. That is the
one colour that is right at every light level without splitting those long
boxes per tile: a dark line between flagstones under a torch, and the same
index as the floor — invisible — in an unlit stretch. At a mid index it was
brighter than the floor it crossed wherever the room was dark.

The accent is a **ramp** (`accr`) as well as a bare index, since trim is a
material and §2.2's rule applies to it. Each theme's accent ramp is
deliberately not its own stone: green trim on green warren stone is not trim,
it is a slightly different green.

### 2.1b Stone texture

Flagstones are mottled by nudging the **light level** per tile by ±1, from an
arithmetic hash rather than `rnd()` so the dungeon's PRNG stream is untouched.

**Off by default**, behind `config.textures` in the manifest, while the look is
undecided. It is not only a look: mottling breaks up runs that would otherwise
merge, so switching it off took the worst-case frame from 790 draw calls to 676
and a full node's floor from 388 runs to 340. The table stays allocated and all
zero when it is off, so the RLE inner loop reads it unconditionally either way.

Perturbing light rather than painting a speckle colour is the whole trick: the
mottling then reads correctly in every ramp, at every brightness, and in flat
mode too. A fixed speckle colour would fight the torchlight and look wrong in
half the themes. It costs one table lookup and two compares per cell in the RLE
inner loop, and walls get it free since they are already coloured per tile.

### 2.2 Ramps

A material is not a colour, it is a **4-step ramp indexed by light level**.

| Ramp | 0 (dark) | 1 | 2 | 3 (bright) |
|---|---|---|---|---|
| Stone, crypt | 1 navy | 5 dark grey | 6 light grey | 7 white |
| Stone, warm (torchlit) | 1 | 4 brown | 9 orange | 10 yellow |
| Moss / caves | 1 | 3 dark green | 11 green | 10 yellow |
| Blood / hell | 1 | 2 plum | 8 red | 14 pink |
| Ice | 1 | 13 indigo | 12 blue | 7 white |

Each depth band picks a stone ramp and a torch ramp; a tile's colour is
`lerp` between them by proximity to the nearest torch, then quantised to the
light level. Warm pools of light on cold stone, from nothing but index choice.

**The joke that uses the system:** the Pot Helm is +1 armour and −2 vision. It
literally subtracts 2 from every light level. Comedy that costs one line of
code and is instantly legible.

### 2.3 Drawing the room within budget

Painting every light cell would be over two thousand draw calls. Instead:

- **Two RLE passes: across, then down.** Encode each row of the light map into
  runs of equal colour, then merge a run into the identical run above it,
  growing one `boxfill` down the rows. Together these make the cost track the
  number of light-level *changes* rather than the resolution — a big unlit
  stretch of floor collapses back to one box however finely it was sampled,
  which is the whole reason a three-times finer light map is affordable.
- The inner loop runs once per light cell — ~10k times a rebuild at per-voxel
  resolution — so it is written for that: colour inlined rather than called,
  tile index from a precomputed lookup rather than a divide, and an integer
  merge key rather than a built string. Those three changes alone took the pass
  from 5.05 ms to 1.43 ms.
- Measured on the largest node a floor generates: ~590 floor runs and ~50 wall
  runs, rebuilt in 3.4 ms every fourth frame.
- The runs are **cached in a Lua table** and only recomputed when a light level
  actually changes (a flicker step, a torch dying, a Light spell). The volume
  is still cleared and redrawn every frame — we re-issue cached runs, we do not
  recompute them.
- Contingency if this is still too heavy: **stop calling `clv`.** The volume
  persists between frames, so the static room could be drawn once on entry and
  only the moving entities erased and redrawn. It is more bookkeeping and it is
  not needed unless the counter says so. Gate it on measurement (§11).

### 2.4 The torch as a mechanic, not decoration

Rogue has a hunger clock. We have a **torch clock**: the hero's carried torch
burns down over ~250 turns, its radius shrinking from 4 tiles to 1. Wall
sconces refill it. Running out does not kill you — it makes the room dark
enough that monsters get the first hit, and the screen becomes genuinely
frightening for a moment.

This makes the lighting system load-bearing. Every torch on a wall is a
resource, an escape route and a light source at once.

**And it decides who sees you.** Aggro was a flat six tiles whatever the light,
which meant the cart's one genuinely unique system was decoration: torchlight
chose how the room *looked* and nothing else. How far something notices you now
scales with how lit **you** are — eight tiles carrying a lit torch, three with
it out — and anything that strikes from an unlit tile it has never been angry
in gets `AMBUSH` extra damage for the hit you never saw coming.

That makes **dousing** a real verb, and it lives in the ring (§9). It costs a
turn, it blinds you to everything the wall sconces do not light, and it stops
the fuel burning while it is out — so the stealth dial and the clock are the
*same* dial rather than two systems competing for attention. Wall sconces stop
being scenery: they are the light you keep when you give up your own.

One trap here was invisible and worth recording. A radius of zero is not "no
light": the falloff loop still runs once, over the hero's own cell, where
`d2 = 0 <= 0` lights it to full. Doused, the hero was standing in a one-cell
pool at level 3, so aggro never dropped, nothing adjacent was ever in the dark,
and the entire mechanic did nothing while looking exactly as though it worked.
The skip has to be explicit, and only a probe that walked to the darkest tile
in the node and read the number back could tell the difference.

---

## 3. The dungeon: generated from a seed

### 3.1 Structure

- A **graph of rooms**, not a scrolling map. Generation: place 6–12
  non-overlapping rectangles on a coarse 3 x 3 or 4 x 3 lattice, connect with a
  spanning tree plus 1–2 extra edges for loops, then assign each edge a door.
- **Corridors are nodes in their own right** — long thin rooms, 3 tiles wide —
  drawn by the same code, holding their own torches, props, monsters and light
  map. One per graph edge, never chained, so walking the dungeon does not become
  a slideshow of cuts. See §14.
- Each room gets a **kind**: plain, pillared, flooded, treasure, shrine,
  library, kitchen (jokes live here), guard post, boss. Kind drives props,
  monster table and torch count.
- **Pillars are placed by count, not by probability.** A pillared chamber gets
  **1–4**, drawn at random from the 3-spaced lattice. Rolling each lattice cell
  at even odds instead put twelve in a full-size chamber, which read as a field
  of crates rather than architecture — and a per-cell probability silently
  scales with room area, the same trap that took monster density from 2 to 5
  (§14). Anything that should have a bounded count has to *be* a count.
- **Some pillars are monuments**, and a monument is meant to be a find: 8% of
  pillars become a shrine and a further 12% a statue. They occupy the wall tile
  they replaced, so they block and shade exactly as a pillar did — the only
  difference is that bumping one does something. Statues have names and a line
  to deliver; shrines fire once and are then spent. Measured over 8 floors that
  is **~1 monument per floor**, against the 7.5 a fifth-of-twelve-pillars gave,
  where they were furniture rather than an event. The shrine that repairs armour deliberately
  mends the *most damaged piece you are wearing*, and the whetstone puts a
  point back on the weapon slot — both tied to the slots in §4.2 and §4.3
  rather than inventing a second currency.
- **Monument text lives in the manifest, not the cart.** It is the one part of
  this game that is pure content, so `config.statues` and `config.shrines` in
  `deeper.voxbox.json` carry it and the cart keeps only a fallback for running
  with no manifest at all. Statues are text alone and the list costs nothing to
  extend — 20 of them at the time of writing. A shrine also names a kind, and
  only the four the cart implements (`heal`, `torch`, `arm`, `gold`) do
  anything, so shrine *types* are bounded by code while shrine *text* is not:
  14 shrines across those four effects. An unrecognised kind still speaks and
  is still spent once, so a typo in the JSON degrades rather than crashes, and
  `tools/deeper_items.py` checks every line against the shipped font and the
  row width.
- Stairs down in the room furthest from the entrance by graph distance.

### 3.2 Depth

Depth `d` scales monster tables, count, stats, and the theme (§2.2). Roughly:
d1–3 crypt, d4–6 caves, d7–9 hell, d10 boss. Difficulty is raised by *tables and
counts*, not by multiplying numbers — a deeper floor introduces new monsters and
new light conditions rather than the same rat with 4x HP.

The roster is a **sliding five-deep window** over the bestiary, so early
monsters retire as you descend — and the window has to stop sliding once its
bottom passes the deepest entry in the book. It did not. The bestiary tops out
at d9, so from depth 14 the range was 10–14, the pool came out empty, and the
`#pool == 0` guard quietly returned monster 1: every monster on floors 14 and
below was **a sewer rat with scaled health**, and nothing said so. Precisely
the shape of the armour-56 bug — the difficulty switching itself off in
silence — which is the argument for the harness printing rosters rather than
someone playing far enough down to notice. Anchoring the window to
`min(d, MON_DMAX)` holds the last roster for however deep a run goes.

**Health and damage scale apart, and the split is the whole difficulty curve.**
They shared one factor at first, so both grew 2.7x by depth 13 while the hero
capped at 7 damage and 7 armour. Armour is a *flat* subtraction, so as monster
damage grew it removed a smaller and smaller share of it — at depth 1 it
cancelled a rat outright, at depth 13 it took 39% off the boss. The two curves
crossed at **depth 9**, past which the game was unwinnable in a straight fight
even in the best kit the dungeon can produce, and the descent probe reaches
depth 13 in twelve attempts out of twelve. Nothing said so; it simply stopped
being possible.

Health now keeps scaling and damage stops at `DMG_CAP_D = 8`. Deep floors are
long rather than lethal, and because max health keeps rising with depth while
incoming damage does not, the hits you can survive grow *faster* than the hits
you need to land — so the curve converges instead of diverging:

| depth | 1 | 5 | 7 | 9 | 13 | 17 | 21 | 25 |
|---|---|---|---|---|---|---|---|---|
| hits needed | 1 | 5 | 6 | 6 | 8 | 10 | 11 | 13 |
| hits survived | 16 | 12 | 7 | 8 | 10 | 12 | 14 | 16 |

That is the toughest monster each floor can roll, against the best kit the
dungeon offers. It was `LOSE` from depth 9 down before the split.

### 3.4 Boss floors

**Every tenth floor is held by a boss, and the stairs do not work until it is
dead.** That gives a run a shape it did not have — the only way one used to end
was dying — and it puts a wall across the depth curve at a place the numbers
can be tuned for, instead of letting descent run to depth 30 where nothing was
ever balanced. The boss is placed in the stair node, so it stands between you
and the way down by construction rather than by a rule enforced elsewhere.

The fight is built from pieces that already exist. Nothing here needs a new
verb — you bump it, exactly as you bump everything:

| piece | what it does |
|---|---|
| **armour** | the boss wears its own, subtracting from your damage roll the way yours subtracts from its. Bare-handed you do the floored minimum of 1; the weapon slot is what makes it winnable, so progression *is* the mechanic |
| **health** | its damage is heavy against a full set of armour, but it only lands every other turn — it telegraphs, and the wind-up is a real turn you may spend retreating, drinking, casting or trading |
| **drain** | every landed strike takes a point off your best piece, so the fight erodes the thing keeping you alive. Spare pieces and the tidy-kit shrine are the counter-play (§4.2) |
| **escalate** | at each third of its health it calls two monsters from the floor's own roster and gains damage. It never introduces something you have not already met on the way down |

Its stats are **not** multipliers on a bestiary row — a multiplier on top of the
depth curve compounds into nonsense, and the first attempt gave the depth-10
boss 198 health and 26 damage: a forty-turn fight that killed a full-health
hero in two. They are stated as what the fight should *be* — this many landed
hits long, costing this share of a health bar — and the numbers fall out of
that and the game's own constants, so they stay correct if the weapon or
armour cap ever moves.

Tuned against a simulation running the real combat code, because the closed
form was wrong twice: escalation and the armour drain interact, and by the
seventh landed strike there is no armour left to subtract, which no static
estimate caught. What it settled at:

| depth | boss | full kit + 1 draught | full kit, no draught | bare-handed |
|---|---|---|---|---|
| 10 | 75hp arm2 dmg7 | **win**, 10/34 left, 15 turns | dead on turn 14 | dead |
| 20 | 60hp arm3 dmg9 | **win**, 17/54 left, 15 turns | win, 3/54 left | dead |
| 30 | 45hp arm4 dmg11 | **win**, 23/74 left, 15 turns | win, 9/74 left | dead |

A gear check with a resource cost, consistent across tiers. `tools/deeper_items.py`
runs that simulation every time, so a change to armour, weapons or the damage
curve cannot quietly make the boss trivial or impossible.

### 3.3 Save is a seed, not a map

Because `rnd` is a deterministic Park-Miller PRNG seeded by `srand`, **the
dungeon never needs to be serialised.** A run is fully described by:

`run_seed`, `depth`, hero stats, and a packed inventory bitfield

— all numbers, which is exactly what `persistGlobals` can persist (`host.js:490`
handles numeric globals only). Re-entering the game reseeds and regenerates the
identical floor. This is a genuine fit between the design and the engine's
determinism, and it is worth designing around rather than working around.

Per-room state that must survive backtracking within a floor (opened chests,
dead monsters) is a per-room bitfield held in memory for the current floor only,
and discarded on descent.

---

## 4. The hero, and armour you can see

Drawn from primitives as a set of parts: boots, greaves, torso, pauldrons,
helm, weapon hand, shield hand. Each part is a `boxfill` or two, and each has a
**colour ramp of its own** so it also responds to the light map — a polished
breastplate near a torch is yellow-white, the same breastplate in the dark is
navy.

Wearing armour changes the drawn shape, not only the palette: a helm adds
voxels above the head, pauldrons widen the silhouette, a shield adds a slab on
the off hand. At 9 voxels tall with a 5-voxel shoulder span there is enough
room for this to read at the isometric angle — Phase 0 proves it with a
side-by-side of naked and fully armoured.

Armour tiers use the ramps: leather (brown), chain (grey), plate (white),
enchanted (accent hue). Sets give bonuses. Joke pieces are real items with real
mechanics:

| Item | Effect |
|---|---|
| Pot Helm | +1 armour, −2 light level (§2.2) |
| Boots of Slightly Wrong Trousers | +2 speed, direction inverted 1 turn in 6 |
| Shield of Aggressive Interior Design | blocks well; rearranges the room's props on every block |
| Cuirass of Unwarranted Confidence | +2 damage, −3 accuracy, hero adopts a swagger walk cycle |

### 4.1 Recovery

Rogue regenerated health with time, and so does this. Without it a run is a
one-way ratchet to zero: no amount of good play buys anything back, and the
only question is how many rooms you last. Three sources, in ascending order of
how much you have to earn them:

| Source | Amount | What it is for |
|---|---|---|
| Natural regen, hunted | +1 every 14 turns | too slow to out-heal a fight, so it only pays for *breaking off* |
| Natural regen, calm | +1 every 3 turns | once nothing in the node is awake. One rate cannot do both jobs: slow enough to matter in a fight makes walking somewhere quiet pure tedium, so leaving the fight switches rate |
| Bread, healing draught | +6, +14 | the common drop; food is deliberately frequent in the loot table |
| Reaching a new floor | +8, and +2 max | makes the stairs worth pushing for rather than something you fall down at 2 hp |

Two rates only mean something if breaking off is a decision, and for a long
time it was not: **nothing followed you through a door**, so any fight could be
ended by stepping through a doorway and the calm rate was free. Anything angry
and adjacent when you leave now has a `FOLLOW_ODDS` chance of coming with you,
up to `FOLLOW_MAX`, keeping its health and its temper. Retreat buys distance,
not a fresh start.

### 4.2 Armour

**Three slots, not a counter** — helm, chest, shield — each holding at most one
piece, rated rather than additive. A piece replaces what is in its slot only if
it is better; a worse duplicate is refused and left on the floor. Best possible
loadout is 2 + 3 + 2 = **7**, and that is the number the damage curve is tuned
against.

It was a bare counter first, and every pickup added to it. Since the equipped
flags were set but never *read*, duplicates stacked without limit: taking every
piece a floor offers reached **armour 56 by floor 6**, and with damage floored
at 1 that means every monster in the game does the minimum from floor 2 onward.
The difficulty was switching itself off and nothing said so.

Progression falls out of what each floor can drop: helms and breastplates from
floor 1 (max 5), shields from floor 2 (max 7). Across 200 floor-1 seeds, 171
offer some armour and 91 offer a breastplate, for a mean of 2.4 available if
you collect all of it.

The wraith's drain damages the *best piece* by a point rather than shaving the
total, which gives repair a path identical to acquisition: find another of that
kind and it replaces the damaged one. Nothing else restores armour, and nothing
needs to.

Armour gets its own row of HUD pips beside health, because a number buried in a
text line does not read as something worth going to look for. Every group draws
its **empty** slots as well as its full ones — that is the whole point of pips
over a number, and armour drew only what you had for a long time, quietly
hiding six sevenths of the thing it existed to advertise.

### 4.3 The weapon, and why offence is a slot too

A fourth rated slot, run exactly like the three armour ones: `dmg` is derived
from it and never assigned, a better weapon replaces what you carry, a worse
one is refused and left on the floor. Ratings 1..4 — sharp stick, short sword,
war hammer, rune blade — laddered by depth the way armour is, so there is
something to find on floor 1 and somewhere left to go for five floors after it.

It had to exist because **offence was the one number in the game that could
only go down.** Damage was the constant 2 the hero started with; the sad
ghost's sigh and a botched Percussive Maintenance took points off it
permanently, and nothing — no item, no shrine, no floor — gave one back.
Meanwhile monsters scale `1 + (depth-1) * 0.14`. The harness prints the curve:

| depth | toughest monster | hits, bare-handed | hits, best weapon |
|---|---|---|---|
| 1 | 6 hp | 2 | 1 |
| 5 | 31 hp | 11 | 5 |
| 9 | 84 hp | 28 | 12 |
| 13 | 107 hp | 36 | 16 |

Bare-handed is the old curve, and it is not difficulty, it is arithmetic.
Armour progressed 0→7 and offence progressed not at all, so a deep floor got
harder only in the sense that everything took three times as many identical
bumps. Mean damage now grows 2.3× against health's 2.7×, which leaves the game
*slightly* harder with depth — which is the point of depth.

Two consequences follow from making it a slot rather than a number. A botched
Percussive Maintenance chips the **rating**, so the repair path is the
acquisition path, exactly as with the wraith's drain — find a better one, or a
whetstone shrine. And the sad ghost's sigh becomes a **timed** debuff (−2 for
12 turns) instead of a permanent tax: base damage is 2 with a floor of 1, so
the *first* sigh used to take everything it could, from a monster that deals no
damage at all and therefore carried no risk to balance it. Measured over 400
bumps it now costs 5.05 damage per hit against 2.96 while it lasts, and then
wears off.

The weapon is drawn on the hero and grows with its rating, because §4's whole
argument is that equipment should change the silhouette. Bare-handed draws no
weapon at all, which is the clearest possible statement that you have not found
one yet.

The damage floor of 1 is why the hero starts with **zero** armour: a single
point reduces every depth-1 monster to the minimum and makes the first floor
harmless. The fix for dying on floor 1 was making armour *findable* there —
every piece used to be gated behind `d >= 2`, so the one floor where you had
none was also the only floor where none could drop.

Max health rising with depth is also what keeps the numbers honest as monster
damage scales, and the HUD pips show empty slots as well as full ones so both
are legible.

Movement is **turn-based on a tile grid** — four directions, animated over ~6
frames. This suits 6 buttons, suits the fixed camera, and means the world only
changes on a turn, which is most of the performance budget won back.

---

## 5. Monsters and ghosts

### 5.1 Body plans

Eight drawing functions, parameterised by palette and size, cover the whole
menagerie: `biped`, `blob`, `floater`, `quadruped`, `swarm`, `tall`. A monster
is data: plan, ramp, stats, behaviour, bark list.

Each is built from parts rather than a box and a lid — silhouette first (legs,
torso, shoulders, head), then the details that give a species away (horns,
snouts, tails, wings), then eyes on the +y face where the camera can see them.
**Height is free**: z is not constrained by the tile grid the way width is, so
detail goes upward. A tile is 6 voxels across, but a creature can be 14 tall.

### 5.2 Ghosts, honestly

Voxels are opaque; there is no alpha. A ghost is drawn **dithered** — only
voxels where `(x + y + z) % 2 == phase` are set, with `phase` alternating every
few frames. In a voxel raymarcher this reads convincingly as translucent and
shimmering, and it costs nothing. It is the engine-honest answer to "ghost",
and better looking than a faked alpha would be.

### 5.3 The menagerie (starter list, ~18 + boss)

| Depth | Monster | Plan | Gimmick |
|---|---|---|---|
| 1 | Sewer Rat | quadruped | fast, weak, numerous |
| 1 | Goblin Intern | biped | flees below half health |
| 1 | Apologetic Slime | blob | splits when hit |
| 2 | Skeleton | biped | reassembles itself once |
| 2 | Bat Cloud | swarm | erratic movement, hard to hit |
| 2 | Ghost of a Minor Poet | floater | harmless until you interrupt him |
| 3 | Mimic | blob | disguised as a chest |
| 3 | Cultist | biped | buffs other monsters |
| 3 | Hound | quadruped | charges in straight lines |
| 4 | Wraith | floater | drains armour durability |
| 4 | Animated Armour | biped | drops the armour it is wearing |
| 4 | Disappointed Ghost | floater | sighs, and your damage drops for 12 turns |
| 5 | Cave Troll | tall | smashes walls — the room changes shape |
| 5 | Spider Matriarch | quadruped | webs slow you |
| 6 | Lich Accountant | biped | summons; denies your expenses |
| 6 | Ghost Landlord | floater | charges rent in gold |
| 7 | Floating Eye | **eye** | confuses your directions for a few turns |
| 2 | Tomb Beetle | quad | wears armour of its own — teaches the rule four floors before the boss uses it, on something that cannot kill you |
| 3 | Chandelier Rat | quad | takes gold and runs. A pickpocket rather than a tax: you *can* chase it, and that is the mistake |
| 4 | Sconce Wraith | ghost | puts out the nearest wall torch when it notices you. **The only monster that attacks the light map instead of the hero** (§2.4) — bump the wall to relight it |
| 5 | The Understudy | biped | drops a *weapon*. The slot's only source besides the loot table and the boss |
| 5 | Centipede | **serpent** | one monster across three tiles, dragging its body through the squares its head has already stood in |
| 6 | Grief | ghost | `follows` you anywhere and moves every other turn. You can outrun it; you cannot lose it |
| 7 | The Echo | eye | says your own last spell back at you. Half the table is a gift when it lands — it is not clever, only loud |
| 8 | The Auditor | biped | writes down a *rating*, weapon slot included. The only thing that takes your blade back |
| 9 | The Committee | biped | three of them, and any survivor revives the fallen. Cannot be won by trading hits — which is what the fireball scroll has been waiting for |
| 8 | Regret | floater | follows you between rooms |
| 10 | The Dungeon Manager | boss | escalates |

### 5.4 Dialogue

Ghosts and the talkative monsters carry a small bark list; some have a real
interaction (the Ghost Landlord takes gold and leaves; the Minor Poet gives an
item if you let him finish). Barks fire on spot, on hit and on death, throttled
so the screen is never chattering.

A bark appears in a **fixed banner at the top of the HUD slice**, tagged with
the speaker's name — *not* floating above the speaker. The cart is never told
the camera, so it cannot project a world position onto the screen; a bubble
placed "above the monster" would be guesswork that breaks the moment the camera
is retuned. A fixed banner is honest and always readable.

The HUD slice was planned for y = 118, in front of the room, on the argument
that **a voxel at y = 118 cannot be occluded by anything at y < 118**, since a
camera ray reaching it decreases monotonically in y. That argument is correct,
and the *text* still belongs at y = 2 — a near slice is far closer to the
camera, so the 3×5 font renders magnified and a line of dialogue sprawls across
the frame. **Text is built at y = 2**, painted on the back wall at the room's
own distance, the way Voxel Defender does it. The near slice comes back below,
for the things that are not text.

That trades the occlusion guarantee for a measured one, and the measurement was
first taken off a screenshot of labelled test rows. Reading it off a picture was
the mistake. **A row of constant z is not a row of constant screen height.** The
plane is seen at 12 degrees of azimuth, so its right-hand end sits nearer the
camera and rides *up* the frame: a row at z = 12 on the left is level with
z = 2.3 by x = 124. Every full-width line is tilted by about ten voxels — two
glyph heights — and the end that leaves the frame is the left one, where
health, depth and dialogue live. That was the truncation.

So the plane is projected rather than photographed: take the manifest camera,
build its basis the way `render.js:160` does, and solve. The band that is
actually clear, for a row drawn at one z:

| Band, floor at z = 58 | Result |
|---|---|
| z < 12 | the left end leaves the top of the frame |
| z = 12..40 | clear, full width — four rows at 7 voxels of pitch |
| z > 40 | into the far wall's top corner, the highest thing the room draws |

**The tilt stays.** Levelling a row is easy to compute — the correction is
linear in x and its slope is linear in z, both exact to a hundredth of a voxel
— and it was built and thrown away. `print` puts a whole string down at one z,
so levelling has to reach *inside* the string, emitting characters in runs that
share a corrected z; every word then comes out as a staircase. A cleanly set
line sitting at the angle its plane is seen at reads better than a level line
made of ragged letters, and it is one draw call instead of nine. The lesson is
that the tilt was never the bug. Four rows was.

### 5.4b The second plane

Four rows is one short, which is what pushed health off the top of the frame in
the first place. Rather than tighten the pitch until the rows touch, the pips
move **in front of** the room, onto a near slice at y = 104.

Anything at y > 90 is nearer the camera than the largest node can reach, so the
original occlusion argument holds and nothing can hide it. The wedge of frame
below the room's near edge is exactly one row tall, and the row is found the
same way the band was:

| Row at y = 104 | Result |
|---|---|
| z ≤ 45 | the left end runs off the side of the frame, the right end into the room |
| z = 46..49 | clear — up to 26 columns, x = 8..108 |
| z ≥ 50 | off the bottom of the frame |

It is the nearest plane anything in the game is drawn on, so the pips come out
half again as large as the text above them — which suits health and armour,
the two things you look at most, and would not have suited dialogue. Both
qualities of the near slice, the one that made it wrong for text and the one
that makes it right here, are the same fact about distance.

One more consequence of the tilt, found on the title screen: **a block of
centred rows is centred as a block**, every row starting at the same x, rather
than each row centred on its own length. Otherwise the right-hand end of a long
line lands at the same screen height as the left-hand end of the shorter line
below it, and the two collide however generous the pitch. Sharing a left edge
makes the gap between two rows the same at every x, so it cannot close.

One more thing the font imposes: `font.js` has **50 glyphs** — A–Z, 0–9 and
`! " ' ( ) + , - . / : ? _`. There is no `|`, and a missing glyph still
advances the cursor, so a health bar built from pipes renders as an invisible
row of spaces. Health is drawn with `line`. (`:` and `'` were added to the font
after this section was first written; the harness reads the glyph set out of
`font.js` rather than restating it, so authored text is checked against the
font that ships.)

Two lines, 24 characters each:

```
I'M ALL BONE, NO PLAN
SORRY IN ADVANCE
I DIED DOING WHAT I LOVE
WHICH WAS, SADLY, THIS
OPEN ME. I AM DEFINITELY
A CHEST.
THAT'LL BE 40 GOLD
YOUR EXPENSES ARE DENIED
I EXPECTED MORE FROM YOU
```

---

## 6. Spells and particles

Particles are `vset` calls — one Lua/JS boundary crossing each, so the budget
is **120 live particles**, enforced by the emitter. Each particle is position,
velocity, life and a ramp; particles pick their colour by *life remaining*, so
every effect fades through its ramp for free.

Casting wraps the hero in an **aura**: a ring of particles orbiting at the
hero's waist for the duration, coloured by school. That is the "nice particle
effect around the character", and because it orbits rather than explodes it
persists visibly while the spell is active.

| Spell | Effect | Voxel effect |
|---|---|---|
| Fireball | damage in a radius | `sphere` grows over 4 frames, bursts into 60 particles |
| Magic Missile | homing, reliable | jittered `line3d` bolt, 3 segments, redrawn each frame |
| Frost Nova | freeze in radius | expanding particle ring; frozen monsters redrawn in the ice ramp |
| Light | +2 light level, 40 turns | the whole light map brightens — the most spectacular spell in the game, and the cheapest |
| Percussive Maintenance | knock everything back | screen shake (world offset ±1), 10% chance to break your own weapon |
| Summon Disappointed Ghost | an ally that sighs | dithered ally follows you, lowers enemy damage |
| Scroll of Mild Inconvenience | enemies drop weapons | they must spend turns picking them up |
| Polymorph: Self | you are a chicken | body plan swaps to `quadruped`; fast, cannot attack |
| Identify | tells you what an item is | lies 30% of the time, confidently |
| Unwarranted Confidence | +damage, −accuracy | hero's walk cycle becomes a swagger |

---

## 7. Voxel effects catalogue

Everything here is achievable with the primitives that exist. Ticked off as
each phase lands.

**Every one that has landed is a named flag under `config.fx` in the manifest**
(§10), because a look is a judgement and a judgement wants to be revisable
without a code edit — which is how `textures` came to be off. They default on;
turn one off to see what it was doing.

- Drop shadows under hero and monsters — free from the engine
- Torch flames: 6–8 animated voxels per torch, warm ramp, 3-frame cycle
- Torch smoke: dark particles rising and fading
- Light map with warm pools, cold stone, and flicker (§2)
- Dithered ghosts and dithered spell shields (§5.2)
- Screen shake by world offset
- **`wall_floor`** — walls never fall below light level 1. Index 1 of every
  ramp is the same navy, so an unlit wall and the unlit floor in front of it
  were *literally the same colour*: outside the torch pools the room had no
  shape at all, and only the capping course gave an edge away, one voxel of it.
  One clamp, and the dark is legible without lighting what stands in it
- **`jitter`** — light pools get ragged edges instead of compass-drawn arcs, by
  perturbing the squared *distance* per cell rather than the level. Dithering
  the boundary is the textbook answer and is wrong here: a checkerboard has no
  runs, so it would wreck the two RLE passes that make the light map
  affordable. Perturbing the distance moves *where* a band falls, so interiors
  stay solid and the run count grows only along the boundary. Measured at
  3.16 ms against 3.4 ms before it — no cost at all. The offsets scale with the
  pool's radius, so the outer edge moves about a voxel at any size; the inner
  bands move more, which reads as the flame guttering
- **`theme_torches`** — each depth's pools use their own ramp. All five themes
  named the same orange before, so only the unlit stone ever changed and half
  the point of two ramps per theme was switched off by one repeated field
- **`arches`** — a lintel over each far-wall doorway. A doorway is a gap, and
  from across a dark room a gap looks like nothing, so a node's exits were
  invisible until you stood on them. Far walls only: a near wall is a
  four-voxel sill with nothing above it to arch (§1.2)
- **`hero_crest`** — two voxels of pink on the hero's head, in a fixed colour
  the light map never touches. Everything else about him is drawn from the same
  ramps as a statue, so an armoured hero beside a monument read as a second
  monument, and in an unlit corner he vanished. The trick the monsters' eyes
  already use
- **`dissolve`** — rooms assemble over 8 frames on entry, in an arithmetic hash
  order rather than `rnd()` so the dungeon's PRNG stream is untouched. The
  engine offers only a hard cut, but the cart draws every voxel itself, so it
  can simply withhold most of them for a few frames
- Destructible props: crates, barrels and pots burst into particles that
  inherit the prop's ramp
- **`liquid`** — water cycles its ramp along a travelling sine. Drawn *over*
  the floor's cached runs rather than inside them: the runs are rebuilt only
  when a light level changes, and animating them per frame would throw away
  exactly the saving that makes the light map affordable. A puddle is a dozen
  tiles, so overdrawing costs a dozen boxfills and leaves the cache alone
- **`decals`** — blood and scorch stay where they were made for the life of the
  floor, so a room you have fought in looks different from one you have not.
  They light like everything else, so a stain in an unlit corner is navy and
  invisible — the rule the capping course had to learn
- **`damage_numbers`** — and they are *exact*, not guessed. The cart is never
  told where the camera is, so a number placed "near the monster on screen"
  would be arithmetic on a projection it cannot do — the reason §5.4 put barks
  in a fixed banner. But `print` draws on a y-slice, so setting the slice to
  the target's own y and printing at its x puts the glyphs in the world at
  exactly the right place, for free, with no projection at all
- Stairs down: a slow whirlpool of particles descending into the floor
- Title parade: six real monsters, one of every body plan, walking a ring on
  the demo slab. Drawn by the same `plan_draw` the dungeon uses — which is why
  that function takes a position and colours rather than a monster, since the
  title screen has no tile grid, no node and no light map to look them up in.
  It costs a fixed ring position, a lighting level and nothing else, and the
  engine's drop shadows come free. Cast by *name*, so reordering the bestiary
  cannot silently change the line-up
- **Chests**, on the floor rather than replacing a pillar: bump to open, and
  the contents roll out beside it because you cannot stand where it is. They
  exist mostly so the Mimic's joke has something to land on — it is drawn by
  the *same* `chest_draw` a real one uses, so there is no tell to spot, which
  is the whole gag and the reason the chest had to come first
- Wall damage from the Cave Troll: tiles removed from the room grid, changing
  both the geometry and the light map

---

## 8. Audio

Around 40 sounds, every one synthesised from its name by `sfxgen.js` — no audio
authored. Names are chosen for the lexicon in `sfxgen.js:191`: `sword_hit`,
`fireball_blast`, `ghost_warn`, `chest_open`, `coin_pickup`, `stairs_warp`,
`potion_powerup`, `player_die`, `level_clear`. Anything the lexicon does not
match still gets a deterministic sound rather than silence.

If a particular sound wants authoring later, the panel's **export sfx.json**
button emits the generated spec as the starting point — the intended on-ramp,
not a rewrite.

---

## 9. HUD, minimap and controls

Six buttons is the whole input surface.

- Arrows: move / attack by bumping, or bump a monument to read it
- X: context action — pick up, open, descend, talk
- **Scrolls and potions prompt before they are taken** (`x` yes, `z` no), and a
  refused one stays on the floor. Everything else is unambiguously good and is
  taken silently; a chicken potion is not. Walking off a refused scroll lets it
  ask again.
- Z: open the **ring** — hold Z, arrows select, release to use. One button, no
  cursor, no menus.

The ring is the reason six buttons is enough. Z used to cast `spells[1]` and
nothing else: no choice at all, and a fireball you were saving went off because
it happened to be first in the list. Held, it lists **everything you can do
this turn that is not walking into something** — and that framing is what lets
two new verbs arrive without spending a button each:

| entry | what it is |
|---|---|
| torch | douse it to move unseen, light it to see (§2.4). Always present |
| stones | thrown at whatever shares your row or column with clear ground between |
| each scroll | cast, in the order you want rather than the order you found them |

Stones aim themselves, and that is a consequence rather than a shortcut: the
arrows are busy selecting while the ring is open, so a second aiming mode would
need a button there is not one of. Lining yourself up with something is already
a real decision on a grid, so making that *be* the aim rewards positioning. A
throw that finds nothing costs no turn — it never happened.

The HUD is on two planes, and §5.4 is why. On the back wall at y = 2, four rows
anchored at x = 0 and 7 voxels apart; on a near slice at y = 104, the one row
that fits below the room:

| Plane | Row | Left column, 24 characters | Right column, x ≥ 98 |
|---|---|---|---|
| y = 2 | 0 | depth, theme name, gold | torch fuel, a shrinking bar |
| y = 2 | 1 | how many things the ring holds, or the boss's health | minimap |
| y = 2 | 2 | speaker, the pick-up prompt, or the ring's selection | ” |
| y = 2 | 3 | the line itself, the item's name, or the ring's dots | ” |
| y = 104 | — | health pips, then armour, then weapon | |

The **minimap** is the explored dungeon graph — chambers and corridors both —
drawn with `line` on the same slice. It has its own column rather than a free
corner, because a bark is full-width and transient and the two would otherwise
fight for the same voxels every time something spoke. That column is what sets
the 24-character line: it is not the frame that runs out, it is the map.

`rect` and `rectfill` are *not* implemented (`host.js:328` registers neither);
they would silently become recording stubs and draw nothing. The minimap uses
four `line` calls per node instead.

---

## 10. Persistence

- `cartdata("voxbox_deeper")`: deepest depth reached, best gold, runs
  completed, unlocked starting kits. 64 numeric slots is ample.
- `persistGlobals` in the sidecar: `run_seed`, `depth`, hero stats and packed
  inventory, so a closed tab resumes the run (§3.3).
- Death is permanent, and clears the resume state. The meta-progression in
  `cartdata` survives.

---

## 11. Performance budget, and how it is measured

The working figure was **≤ 350 draw calls per frame**, inherited from the other
carts. Measurement retired it. The worst case built on purpose — largest node a
floor can generate, 8 monsters, 78 live particles — costs **~790 draw calls at
5.4 ms of Lua and 0.5 ms of draw, against a 33 ms frame**. Draw calls were
never the constraint; frame time is, and it is at 16%. Note where that went:
`_draw` is 3.9 ms of it, which is the Lua-to-JS boundary crossings, and the
light rebuild is 3.4 ms amortised over four frames.

| Bucket | Measured, worst case |
|---|---|
| Floor (RLE runs, both passes) | 590 |
| Walls (tile resolution) | 50 |
| Torches, stairs | 40 |
| Hero + armour | 12 |
| Monsters (8 on screen) | 55 |
| Particles (`vset`) | 78 |
| HUD, minimap, barks | 20 |

That table has moved twice since. Turning stone texture off (§2.1b) took the
worst case to **661**, because runs the mottling was breaking up merge again;
the §7 effects have since taken it to **798 draw calls, 5.26 ms of `_draw`**,
with the light rebuild still at **3.16 ms** — the jitter costs nothing
measurable. Against a budget that was never the binding constraint this is
noise, and it is recorded only because the harness prints the number and an
unexplained change in it should be a question. Note what it also says about the
rejected HUD levelling in §5.4 — nine calls a line instead of one would have
spent a third of that saving on making the text worse.

**The budget probe measured the wrong frame for one commit and said 251.**
`dissolve` (§7) withholds most of a room for eight frames after `enter()`, and
`probe_worst` drew its frame immediately after entering — so the ceiling check
was measuring a transition. It now clears `dissolve` first. A performance
number that improves by two thirds for no reason is not good news, it is a
broken instrument, and this is the second time in this project that a
suspiciously good measurement turned out to be one (§4.2's armour counter was
the first).

### 11.1 The harnesses

`tools/cartlab.py` loads a cart under lupa with the canonical shim, so a test
can call the cart's own functions and read its globals without any hooks in the
cart itself. It installs the manifest's `config` block the same way the host
does, deliberately: if the two boots disagree the harnesses are testing a cart
nobody plays. Three suites sit on top of it:

| Tool | Answers |
|---|---|
| `tools/deeper_structure.py` | 80 floors: is every node reachable, is every exit mirrored, does every door open onto walkable floor, does every node fit the grid and have a torch |
| `tools/deeper_play.py` | scripted play, the survival probe, combat against all 19 monsters, every body plan and item through the draw path, every spell, 12 descents, worst-case frame cost |
| `tools/deeper_items.py` | armour slots and the drain/repair loop, what floor 1 offers over 200 seeds, torch counts, monument placement and effects, the scroll prompt, and every authored monument line against the shipped font and the row width |

The survival probe is the difficulty regression test, and it has a known
ceiling: its bot visits only ~3.7 of a floor's nodes, so it under-reports
anything that depends on exploring. Read it as a worst case, not an average.

**Build the instrument first.** Phase 0 adds a per-frame primitive counter to
the host's stats line — an idea already outstanding in this repo, and this is
the cart that needs it. Without it, "is the room too expensive?" is a matter of
opinion; with it, it is a number on screen.

The project's rule applies: **measure, don't squint.** Several past "bugs" here
were mirages. If the room looks wrong, diff `gl.readPixels` output; if it feels
slow, read the counter.

---

## 12. Optional engine change: a real light volume

Not needed for v1, and explicitly *not* in the critical path. Offered because
the brief asked for lighting effects and the cart-side approach, while good,
quantises to 4 levels.

- Add a second 3D texture, a **light volume at 32 x 32 x 16** (16 KB, LINEAR
  filtered so it interpolates smoothly), uploaded per frame alongside the
  volume.
- The shader multiplies the final colour by the sampled light instead of using
  it only for face shading: about 4 lines in `render.js`, plus an upload.
- The cart writes into it with a new `lset(x, y, z, level)` primitive.

The result is smooth, continuous falloff and coloured light that the palette
cannot express. The cost is an API addition and, more importantly, a change to
the renderer — which means **`tools/conform.py` must be re-run and stay
identical** (the trace is draw calls, so it should be untouched, and that is
exactly the check).

Recommendation: ship the cart-side light map first. It is genuinely good, it
needs no engine change, and it may make this section unnecessary. Decide after
Phase 2, looking at it.

---

## 13. Phases and gates

Each phase ends with something runnable and a gate that is a measurement, not
an impression.

**Phase 0 — spike (the risky things, first).**
One hand-built room, no gameplay. Camera tuned; cutaway walls; light map with
two torches; hero drawn naked and fully armoured side by side; primitive
counter added to the stats line.
*Gate:* all four room corners in frame; no DDA speckling at the walls
(§0.6); armour readable at the isometric angle; draw calls for a static room
under 180.

**Phase 1 — the room renderer.**
Materials and ramps, RLE floor and walls, torch flames and flicker, props,
doors, dissolve transition.
*Gate:* a room redraws inside budget with flicker running; the light map
visibly pools warm near torches.

**Phase 2 — hero and traversal.**
Turn-based grid movement, collision, doors, room-to-room cuts, torch clock,
minimap.
*Gate:* walk a hand-built 4-room dungeon end to end; 4000-frame
`tools/trace_run.py` run with no error and all coordinates in bounds.

**Phase 3 — generation and depth.**
Room graph, room kinds, stairs, depth themes and tables, the seed-only save.
*Gate:* the same seed regenerates an identical floor across both hosts;
100 generated floors are all fully connected (assert in a test harness run).

**Phase 4 — monsters.**
Body plans, dithered ghosts, AI, combat, death effects, the menagerie table.
*Gate:* 8 monsters on screen inside budget; a full floor cleared without a
Lua error over a long scripted run.

**Phase 5 — items and spells.**
Armour with visible parts and set bonuses, the particle system with its 120
cap, the spell table, auras.
*Gate:* particle cap holds under simultaneous effects; light-affecting items
and spells demonstrably change the room.

**Phase 6 — voice.**
Bark system, speech bubbles, interactive ghosts, the humour pass across items,
spells, monsters and death messages.
*Gate:* every line fits 26 characters; bubbles never occluded by their
speaker.

**Phase 7 — polish.**
Audio names, `cartdata`, resume, boss floor, title and death screens, launcher
button, README entry and screenshots.
*Gate:* the cart reports all called API implemented in the panel, as the other
three bundled carts do.

---

## 14. Risks and open questions

| Risk | Assessment |
|---|---|
| **Draw budget for a full room** | Retired by measurement: worst case is 3.4 ms of a 33 ms frame (§11). The `clv` escape hatch was never needed. |
| **Isometric occlusion** | Designed out with cutaway walls (§1.2) rather than discovered later. Torches on far walls only. |
| **DDA step cap at tall walls** | Cheap to check in Phase 0, one number to fix. |
| **4 light levels may band visibly** | Largely answered by the finer grid and Euclidean falloff (§2.1). Dithering the boundary is the next fix; §12 is the one after. |
| **26-character dialogue** | A constraint on the writing, not a technical risk. One-liners are funnier anyway. |
| **Scope** | This is much larger than the three existing carts (480–880 lines). Expect 2,000+ lines. The phase boundaries are all playable, so it can stop early and still be a game. |
| **Difficulty drifting as content changes** | Real, and it bit once: growing rooms from 12x10 to 18x17 silently took `flr(area/55)` from 2 monsters to 5, all inside the aggro radius of one room. Density is now per *depth*, not per area. A scripted survival probe (40 naive runs that never retreat) is the regression test — it should sit near 2/40 deaths on floor 1. |

**Resolved: corridors are rooms in their own right.** A corridor is a node in
the dungeon graph exactly like a chamber — its own tile grid, its own torches,
its own light map, its own monsters — and it is drawn by the same code, because
the only thing that makes it a corridor is that it is 3 tiles wide and long.
Generate few and long, so the hard cuts while walking stay rare: one corridor
per graph edge, never chained.

The payoff is that ambushes have somewhere to happen and the dungeon has a
shape you can feel. It also costs nothing: `node_build` does not know or care
which kind it is building.
