# deeper — worklog

What changed, why, and what the instruments said. The design lives in
[VOXBOX_ROGUE_PLAN.md](VOXBOX_ROGUE_PLAN.md); this is the record of the work
and, more usefully, of the things that turned out to be wrong.

`§n` below means a section of *this* file; references to the plan say so.

Covers the six commits `0476596` … `0e5707c` (`git diff de98708 HEAD`):
+2,762 / −297 across the cart, its manifest, `runtime/js/host.js` and the three
harnesses. The cart went from 1,807 to 3,261 lines and the bestiary from 19
monsters to 28.

---

## 1. The HUD, and a rejected fix

<sub>`0476596`</sub>

**The complaint:** health was cut off the top-left of the frame.

**What it actually was:** the back plane is seen at 12° of azimuth, so a row of
constant `z` is *not* a row of constant screen height — its right-hand end sits
nearer the camera and rides up the frame. A full-width line tilts by about ten
voxels, and the left end, where health and depth and dialogue live, is the end
that goes off the top. The pip rows at `z = 7..8` projected to `py = -12`.

**The fix that was wrong:** levelling the rows — picking a `z` per character so
each row is horizontal. It works, and it looks worse: `print` puts a whole
string down at one `z`, so levelling has to step *inside* the string and every
word comes out a staircase. Reverted. A cleanly set line at the plane's own
angle beats a level line made of ragged letters.

**The fix that stuck:** stop asking one band to hold everything. Text stays on
the back plane at `y = 2`; health, armour and weapon pips moved to a near slice
at `y = 104`, *in front of* the room. Anything at `y > 90` is nearer than the
largest node can reach, so it cannot be occluded — and the wedge of frame below
the room's near edge is exactly one row tall (`z = 46..49` clears; 45 and 50 do
not). The font is half again as large there for being that much nearer.

Banners are also block-left-aligned rather than each row centred on its own
length: on a sloped plane the right-hand end of a long line lands at the same
height as the left-hand end of the shorter line below it, and the two collide
however generous the pitch.

**On making the font smaller:** you cannot. It is a fixed 3×5 bitmap with a
4-voxel advance and no scale; one voxel is the smallest mark the renderer can
make. Apparent size is set by distance, and the HUD is already on the farthest
plane there is. The lever, if a row ever needs more, is a *variable* advance in
`volume.js` — an engine change, ~30% more characters per row.

---

## 2. A data channel from the manifest to the cart

<sub>`0476596`</sub>

`persistGlobals` carries numbers *out* of a cart and back in. There was nothing
going the other way, so anything authored had to be code.

Added `config` to the manifest, arriving as the `CONFIG` global before the cart
chunk loads (`luaLiteral` in `runtime/js/host.js`, mirrored in
`tools/cartlab.py` so the harnesses test what ships). It carries tables and
strings. Everything in it is an override — with no manifest at all the cart
sees `CONFIG = nil` and every built-in default applies, so dropping
`deeper.lua` on the page alone still works.

Strings are escaped a byte at a time into Lua's `\ddd` form, always three
digits: JSON's `\uXXXX` is not Lua syntax, and a short escape followed by a
literal digit swallows it.

This is what made the rest of the session possible: **statue and shrine text,
and every visual flag, are now data.**

---

## 3. Content moved out of the cart

<sub>`0476596`</sub>

20 statues and 20 shrines in `deeper.voxbox.json`. Statues are text alone, so
the list costs nothing to grow. Shrines name a `kind`, and only the six the
cart implements do anything — `heal`, `torch`, `arm`, `whet`, `gold`, `wish` —
with an unrecognised kind still speaking and still being spent, so a typo in
the JSON degrades rather than crashes.

---

## 4. The critique, and what it found

<sub>`1d3d869`</sub>

A read of the whole cart plus measurement. The four largest findings:

### The masonry ignored the light map

`capc` was hoisted out of the wall loop as `RAMPS[theme.cold][4]` and the
skirting was the bare `theme.acc`. Every wall top was the brightest white in
the ramp and every wall base full accent, in pitch darkness exactly as much as
under a torch — a bright wireframe traced over the whole room, fighting the
torchlight everywhere. Two of the three boxfills per wall run were unlit.

This is precisely the mistake the plan's §2.1b argues against for the flagstone mottling,
made at far greater visual weight. All three courses now take their colour from
the run's own light level.

### Damage was a one-way ratchet

`dmg` started at 2 and could only ever go *down* — the sad ghost's sigh took a
permanent point per turn from a monster that deals no damage at all, and
nothing in the game gave it back. Meanwhile monster health scaled 2.7× by depth
13. Armour progressed 0→7; offence progressed not at all.

Fixed by making the weapon a **fourth rated slot**, run exactly like the three
armour ones, and by making the sigh a timed debuff.

### The difficulty curve inverted at depth 9

Measured, fully equipped, against the toughest monster each floor can roll:

| depth | 1 | 5 | 7 | **9** | 11 | 13 |
|---|---|---|---|---|---|---|
| hits needed | 1 | 5 | 6 | **12** | 14 | 16 |
| hits survived | 16 | 12 | 7 | **5** | 4 | 4 |

Past depth 8 the game was unwinnable in a straight fight — and the descent
probe reaches depth 13 in twelve attempts out of twelve. The cause: armour is a
*flat* subtraction against multiplicative damage. At depth 1 it cancels a rat
outright; at depth 13 it removes 39% of a hit.

### Instruments beat opinions

Everything above was found by reading and measuring, not by playing. That
theme runs through the whole session — see §9.

---

## 5. Generation and balance

<sub>`1d3d869`, `e223714`</sub>

- **Damage scaling capped at depth 8**, health left to grow. Deep floors are
  long rather than lethal, and because max health keeps rising while incoming
  damage does not, hits-survived now grows *faster* than hits-needed — the
  curve converges instead of diverging.
- **Boss floors every 10th depth**, in the stair node, stairs locked until it
  is dead. Built from pieces that already exist: its own armour (so the weapon
  slot is the mechanic), a telegraphed strike on alternate turns, armour drain,
  and escalation at each health third. Stats stated as *what the fight should
  be* — 15 landed hits, a share of a health bar — rather than as multipliers on
  a bestiary row, because a multiplier on top of the depth curve compounds:
  the first attempt gave the depth-10 boss 198 health and 26 damage.

  | depth | boss | full kit + draught | full kit, none | bare-handed |
  |---|---|---|---|---|
  | 10 | 75hp arm2 dmg7 | **win**, 10/34 left | dead turn 14 | dead |
  | 20 | 60hp arm3 dmg9 | **win**, 17/54 left | win, 3/54 left | dead |
  | 30 | 45hp arm4 dmg11 | **win**, 23/74 left | win, 9/74 left | dead |

- **Pillars placed by count, not probability** — 1–4 per pillared chamber. A
  per-cell roll silently scales with room area, the same trap that took monster
  density from 2 to 5. Monuments went from ~7.5 per floor to ~1.2, so bumping
  one is an event rather than furniture.

---

## 6. Look

<sub>`f1b006c`, `e223714`, `78e2a6d`</sub>

Ten flags under `config.fx`, all on by default except `textures`:

| flag | what it fixes |
|---|---|
| `wall_floor` | index 1 of every ramp is the same navy, so an unlit wall and the unlit floor in front of it were *literally the same colour* — the room had no shape outside the torch pools |
| `jitter` | compass-drawn pool edges. Perturbs the squared *distance* per cell, not the level: dithering would wreck the RLE, since a checkerboard has no runs |
| `theme_torches` | all five themes named the same orange, so only unlit stone ever changed |
| `arches` | a doorway is a gap, and from across a dark room a gap looks like nothing |
| `hero_crest` | the hero is drawn from the same ramps as a statue, and vanished in unlit corners |
| `dissolve` | rooms assemble over 8 frames instead of cutting in |
| `liquid` | water cycles its ramp, drawn *over* the cached runs so the cache survives |
| `decals` | blood and scorch persist for the floor's life, lit like everything else |
| `damage_numbers` | printed on the target's own y-slice, so it is **exact** — no projection, which is the thing the cart cannot do |
| `textures` | the flagstone mottling, still on trial |

Plus `torchlight`, moved here from a row on the title screen.

Also: the title screen's six orbiting dots became a **parade of seven real
monsters**, one of every body plan, drawn by the same `plan_draw` the dungeon
uses. Where the ring sits was measured frame by frame against the projected
text band — any further back and the cave troll's horns occlude the last line.

---

## 7. Mechanics

<sub>`e223714`, `0e5707c`</sub>

- **Light drives the AI.** How far something notices you scales with how lit
  *you* are: eight tiles with a torch, three without. Something striking from
  an unlit tile it was never angry in gets the first hit. This is the only
  place the light map touches the rules rather than the picture.
- **Douse**, in the ring. Costs a turn, blinds you to everything the sconces do
  not light, and **stops the fuel burning** — so stealth and the torch clock
  are the same dial rather than two systems competing.
- **The ring.** Hold z, arrows pick, release. Holds everything you can do this
  turn that is not walking into something: torch, stones, each scroll. That
  framing is what let two new verbs arrive without spending a button each.
- **Stones** aim themselves along a row or column — the arrows are busy
  selecting, and lining yourself up is already a decision on a grid.
- **Retreat costs something.** Angry adjacent monsters follow you through a
  door at 45%, capped at 2, keeping their health and temper.
- **Gold has a sink**: wishing wells, priced against depth.
- Wired up `spell_swap`, read by `try_move` since the first version with
  nothing ever setting it, by giving the floating eye its missing gimmick.
- Throttled barks: `m.said` only ever limited each monster to one line in its
  *life*, so eight still spoke on the same turn.

---

## 8. Nine monsters, and chests

<sub>`0e5707c`</sub>

| | |
|---|---|
| **Tomb Beetle** d2 | armour of its own, four floors before the boss uses it |
| **Chandelier Rat** d3 | takes gold and runs — a pickpocket, not a tax |
| **Sconce Wraith** d4 | puts out the nearest torch. The only monster that attacks the *light map*; bump the wall to relight it |
| **The Understudy** d5 | drops a weapon |
| **Centipede** d5 | one monster across three tiles, a train |
| **Grief** d6 | follows anywhere, moves every other turn |
| **The Echo** d7 | says your own last spell back at you |
| **The Auditor** d8 | takes a *rating*, weapon included |
| **The Committee** d9 | three of them; any survivor revives the fallen |

Three needed real plumbing: `mon_at` became `mon_covers` so nothing walks
through a centipede's middle; torches gained a `lit` flag threaded through the
light map and the draw; committee members go *down* rather than dying.

**Chests** came first, because the Mimic's joke needed something to land on —
and the Mimic is drawn by the *same* `chest_draw` a real one uses, so there is
no tell to spot.

The floating eye also got its own `eye` body plan. It had been using `ghost` —
dithered bands — so the one monster whose entire name is a description had the
least descriptive body in the book.

---

## 9. What the instruments caught

The most valuable output of the session. Every one of these was invisible in
play and would have shipped.

| found | what it was |
|---|---|
| `die()` fired **3×** | `mons_turn` ran on after the hero fell, so every remaining monster attacked the corpse — the death screen named whoever hit *last*, not who killed you |
| roster **empty past d13** | the five-deep window never stopped sliding; the `#pool == 0` guard quietly returned monster 1, so every monster on floors 14+ was a sewer rat with scaled health |
| douse did **nothing** | a radius of zero is not "no light" — the falloff loop still runs once over the hero's own cell, where `d2 = 0 <= 0` lights it to full. Aggro never dropped, and the mechanic looked exactly as though it worked |
| floating eye **unkillable** | 484 bumps against 16 health. Not how it looked: the inverted step walked the hero off, the eye chased into the vacated square, and the next bump swung at empty floor |
| draw budget said **251** | `probe_worst` drew its frame straight after `enter()`, so `dissolve` was withholding most of the room. A performance number improving by two thirds for no reason is a broken instrument |
| weapon ladder **broken** | inserting stones mid-table shifted every weapon index by one, so `item_roll` handed out stones where it meant a sharp stick and never rolled the rune blade. The table's own comment warned about this |
| harness labels **stale** | `26/19 fought back` against a bestiary of 28; `probe_curve` still filtering bosses the old way |

The rule earned twice over: **a suspiciously good measurement is a broken
instrument, not good news.**

---

## 10. Where it stands

| | |
|---|---|
| cart | 3,261 lines |
| bestiary | 28 monsters, 8 body plans |
| items | 19, across 4 rated slots |
| authored text | 20 statues, 20 shrines, all ≤ 24 columns |
| flags in the manifest | 11 |
| worst-case frame | ~690–1030 draw calls (varies with seed), `_draw` 5.3–5.7 ms, light rebuild 3.2 ms every 4th frame, against 33 ms |
| structure | 80 floors, 0 link / geometry / reachability errors |
| combat | 0 unkillable, all 28 draw |
| descent | depth 10 in 9/12 attempts — the boss stops the other 3 |

### Still open

- **No ending.** Boss floors repeat every 10; nothing terminates a run but
  death. A final boss at some depth would close it.
- **Plan §7 leftovers**: destructible props, the Cave Troll's wall-smashing, a true
  screen shake by world offset (the near-sill flash stands in).
- **The ring is linear, not radial.** Functionally the same; the plan's §9
  describes a radial one.
- **`conform.py` has not been re-run** since `host.js` gained the config
  channel. The change adds no draw calls so the trace should be identical —
  which is exactly why it is worth confirming rather than assuming.
- **Survival probe drifts** — 0/40 → 4/40 → 1/40 across the session as content
  changed. The plan's §14 wants ~2/40. It visits only ~3.5 nodes a run, so read it as a
  worst case, not an average.
