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

3. **Text is 3x5 uppercase, ~31 characters across the whole volume.**

   **What we do:** every line of dialogue is written to fit **26 characters**,
   two lines maximum. This is a constraint on the comedy, and a good one —
   it forces one-liners.

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
| Room grid | up to 21 x 21 tiles | 126 x 126 voxels of a 128 volume |
| Generated chamber | 15..19 x 14..19 tiles | fills most of the grid; a room that sits small inside the footprint wastes the volume |
| Floor surface | z = 58 | **kept low on purpose** — see below |
| Wall height | 12 voxels, z = 46..58 | tall enough to hold torches, short enough not to swallow the room |
| Hero | 10 voxels tall, z = 48..57 | |
| Ceiling | none | open-topped, as every isometric game does |

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

22 degrees of azimuth and 38 of elevation. The elevation shows the floor plan;
the azimuth is deliberately short of the textbook 45, because the HUD and all
the dialogue live on a y-slice and a slice seen at 45 degrees skews the 3x5
font past comfortable reading.

---

## 2. Light: torches without a lighting engine

This is the heart of the look, and the part that has to be invented rather
than switched on.

### 2.0 Switching it off

Torchlight toggles from the title screen with `z`, remembered in `cartdata`
slot 2. Flat mode forces every cell to one level: the room is evenly lit, the
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
- Stairs down in the room furthest from the entrance by graph distance.

### 3.2 Depth

Depth `d` scales monster tables, count, stats, and the theme (§2.2). Roughly:
d1–3 crypt, d4–6 caves, d7–9 hell, d10 boss. Difficulty is raised by *tables and
counts*, not by multiplying numbers — a deeper floor introduces new monsters and
new light conditions rather than the same rat with 4x HP.

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

**Armour is the other half of survival** and gets its own row of HUD pips beside
health, because a number buried in a text line does not read as something worth
going to look for. It subtracts from every hit, with a floor of 1 damage.

That floor is why the hero starts with **zero** armour: a single point reduces
every depth-1 monster to the minimum and makes the first floor harmless. The
fix for dying on floor 1 was making armour *findable* there — every piece used
to be gated behind `d >= 2`, so the one floor where you had none was also the
only floor where none could drop.

Max health rising with depth is also what keeps the numbers honest as monster
damage scales, and the HUD pips show empty slots as well as full ones so both
are legible.

Movement is **turn-based on a tile grid** — four directions, animated over ~6
frames. This suits 6 buttons, suits the fixed camera, and means the world only
changes on a turn, which is most of the performance budget won back.

---

## 5. Monsters and ghosts

### 5.1 Body plans

Six drawing functions, parameterised by palette and size, cover the whole
menagerie: `biped`, `blob`, `floater`, `quadruped`, `swarm`, `tall`. A monster
is data: plan, ramp, stats, behaviour, bark list.

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
| 4 | Disappointed Ghost | floater | lowers your damage by sighing |
| 5 | Cave Troll | tall | smashes walls — the room changes shape |
| 5 | Spider Matriarch | quadruped | webs slow you |
| 6 | Lich Accountant | biped | summons; denies your expenses |
| 6 | Ghost Landlord | floater | charges rent in gold |
| 7 | Floating Eye | floater | casts a random spell each turn |
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
camera ray reaching it decreases monotonically in y. That argument is correct
and the placement was still wrong: a near slice is also far closer to the
camera than the room, so the 3×5 font renders magnified and sprawls across the
frame. **Built at y = 2 instead** — painted on the back wall, at the room's own
distance, the way Voxel Defender does it.

That trades the occlusion guarantee for a measured one. The usable band on the
back plane is not obvious and not worth deriving: it was found by drawing a
grid of labelled test rows and reading them off a screenshot.

| Band | Result, floor at z = 48 | Result, floor at z = 58 |
|---|---|---|
| z < 11 | cropped off the top | clear |
| z = 11..32 | clear full width | clear |
| z = 33..38 | room hides the left half | clear |
| z ≥ 39 | room hides the left half | drifts right, usable for the minimap |

The first column is why the floor was dropped ten voxels (§1.1): four cramped
rows became a comfortable band from z = 2 down to z = 38. Rows drift right as
z grows, because the plane is seen at 22 degrees of azimuth — which is why the
right-hand column sits at x = 60 rather than further left.

One more thing the font imposes, found the same way: `font.js` has **46 glyphs**
— A–Z, 0–9 and `! + , - . / ? ( ) _`. There is no `|` and no `:`, and a missing
glyph still advances the cursor, so a health bar built from pipes renders as an
invisible row of spaces. Health is drawn with `line`; labels use `-` not `:`.

Two lines, 26 characters each:

```
I'M ALL BONE, NO PLAN
SORRY IN ADVANCE
I DIED DOING WHAT I LOVED
WHICH WAS, REGRETTABLY, THIS
OPEN ME. I AM DEFINITELY
A CHEST.
THAT'LL BE 40 GOLD, PLEASE
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

- Drop shadows under hero and monsters — free from the engine
- Torch flames: 6–8 animated voxels per torch, warm ramp, 3-frame cycle
- Torch smoke: dark particles rising and fading
- Light map with warm pools, cold stone, and flicker (§2)
- Dithered ghosts and dithered spell shields (§5.2)
- Screen shake by world offset
- Room transition: **dissolve** — the old room's voxels erased in a
  deterministic pseudo-random order over 8 frames, the new room built up the
  same way
- Destructible props: crates, barrels and pots burst into particles that
  inherit the prop's ramp
- Animated liquid tiles: water and lava cycle their ramp along a sine, so the
  surface visibly moves
- Blood and scorch decals painted into the floor's colour map, persisting for
  the room's lifetime
- Floating damage numbers, `print` on a near slice
- Stairs down: a slow whirlpool of particles descending into the floor
- Chest opening: lid rotates via three `boxfill`s over 5 frames, contents rise
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

- Arrows: move / attack by bumping
- X: context action — pick up, open, descend, talk
- Z: open the **radial item ring** — hold Z, arrows select, release to use.
  One button, no cursor, no menus.

HUD on the back wall at y = 2 (§5.4 on why, and on the band that is actually
visible): health as pips, depth, gold, torch fuel as a shrinking bar. The
**minimap** is the explored dungeon graph —
chambers and corridors both — drawn with `line` on the same slice. Small, in a
corner, and it is what gives back the sense of a whole level that the one-room
view removes.

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
