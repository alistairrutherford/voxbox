# voxbox — generic cartridge plan

Follow-on to [VOXBOX_ENGINE_PLAN.md](VOXBOX_ENGINE_PLAN.md). That plan shipped a
browser Voxatron runtime with `iso-defender` baked in (§8 explicitly cut the
generic loader from §3 to get one cart playable). This plan reverses that
decision: **hand voxbox any pure-Lua Voxatron cartridge and it loads, runs, and
makes noise.**

Scope is deliberately *pure-Lua* carts — a `.lua` file, as `iso-defender` is.
Full `.vx.png` designer cartridges (rooms, actors, props, emitters, voxel
models, authored audio resources) are out of scope; see §5 for why that matters
most for audio.

---

## 1. Where we are

The cart-agnostic parts are already cart-agnostic, which is why this is a
scoping change rather than a rewrite:

- `shim/picovox.lua` — VM-portable PICO-8 math/stdlib, deterministic by
  construction. Reusable as-is.
- `runtime/js/volume.js` — the Voxatron *display volume*. 128×128×64 is a
  platform constant in 0.3.5b, not an `iso-defender` choice. It stays.
- `runtime/js/render.js` — raymarches an R8UI 3D texture. Knows nothing about
  the game.
- `audio/sfx.json` + `tools/sfxgen.py` + `runtime/js/synth.js` — the right
  *shape* (one spec, two renderers), populated with one cart's content.

### What is welded to `iso-defender`

| Location | Baked in |
|---|---|
| `app.py:18,53` | `/cart` hardcodes the iso-defender path and runs its `build.sh` |
| `runtime/js/host.js:113` | assumes `_init` exists and is the only entrypoint |
| `runtime/js/host.js:117-133` | persistence pokes the cart's `hiscore`/`unlocked` globals |
| `runtime/js/host.js:140-145` | camera hand-tuned to match `iso-defender/game.jpg` |
| `runtime/js/volume.js:10` | `GROUND_Z = 50` — a cart constant leaking into the renderer's shadow model (`render.js:66`) |
| `audio/sfx.json` | all 22 names are iso-defender's |
| `shim/picovox.lua` | implements precisely the API this one cart calls |
| `shim/driver.lua` | input schedule written against this cart's menus |

The API surface is the load-bearing problem. Missing today: most of the PICO-8
stdlib (`sgn`, `count`, `foreach`, `sub`, `split`, `ord`/`chr`, `tonum`,
`time`, bit ops, `printh`), the PICO-8 input API (`btn`/`btnp` — this cart uses
Voxatron's `button` and edge-detects itself), and `draw_voxmap`/`blit_voxmap`
are outright no-ops (`host.js:101-102`). Any other cart dies on
`attempt to call a nil value` within seconds.

---

## 2. Phase 1 — make arbitrary carts *run*

Three moves, and the first is the highest-value change in this whole document.

### 2.1 Lenient shim + API manifest

Install a manifest of every known Voxatron/PICO-8 global. Names we implement
resolve to the real thing; names we don't resolve to a recording stub. The page
shows a live panel of every stubbed call the cart made.

This converts "port the entire Voxatron API on spec" into an incremental,
evidence-driven loop: run a cart, read the panel, implement what it actually
used.

**Stubbing is only safe for void functions.** A stubbed `sphere()` draws
nothing — degraded but honest. A stubbed `vget()` or `sgn()` returns a
plausible number and *silently corrupts game logic*, which is worse than a
crash. So the manifest carries a per-name policy:

- `void` — side-effecting, returns nothing. Safe to stub. Panel shows amber.
- `value` — the cart uses the return. Stub returns a documented default and the
  panel shows **red**: "this cart's behaviour is wrong until this is real."

**Why a manifest instead of a catch-all `__index`:** a metamethod that returns
a no-op for any unknown global breaks ordinary Lua. `if not player then
player = {} end` would see a truthy function. Unknown *non-API* names must stay
`nil` and keep normal semantics.

**Manifest gaps are recoverable.** When a cart calls a name we never listed, the
host parses the global's name out of the Lua error, reports it in the panel as
*undeclared*, and offers "stub it and restart". Deliberately a button and not
automatic — silently stubbing an unknown value-returning function is exactly
the corruption hazard above.

> Honest caveat: PICO-8 stdlib names are certain. Voxatron-specific names
> beyond those the reference cart uses are best-effort and should be corrected
> against the real 0.3.5b API notes. The undeclared-global loop exists precisely
> because the manifest starts incomplete.

### 2.2 Fill in the PICO-8 stdlib

Everything trivially implementable in pure Lua gets implemented rather than
stubbed, because most of it is `value`-policy and a stub would lie: `sgn`,
`count`, `foreach`, `sub`, `split`, `tonum`, `ord`, `chr`, `band`/`bor`/`bxor`/
`bnot`/`shl`/`shr`, `time`/`t`, `printh`, `deli`, `btn`/`btnp`, plus fidelity
gaps in what exists (`add`'s 3-arg insert form, `all(nil)`, `tostr`'s hex flag).

### 2.3 Sandbox

Plan §3 called for it and it was never built — a cart currently gets wasmoon's
full global table. Load the cart with a fresh `_ENV` containing only the
manifest API + a vetted Lua subset. No `io`, `os`, `require`, `package`,
`load`, `dofile`, `debug`, and no `math.random` (breaks determinism).

Cart globals then live in that env, so the host reaches entrypoints and state
through accessors instead of `doString`.

### 2.4 Bug fixes that block generic carts

- `picovox.lua:99` sorts `pairs` keys with `a<b`, which raises
  *attempt to compare two table values* if a cart uses tables as keys —
  `set[obj]=true` is a very common Lua idiom. Rank by type first.

### 2.5 Verification

The project has a bit-exact oracle. If a 4000-frame trace still matches
`trace_py.txt` after the refactor, it is provably behaviour-preserving. That is
the acceptance test for Phase 1.

---

## 3. Phase 2 — loader and lifecycle ✅ DONE

`host.js` split into a persistent **shell** (renderer, volume, input, audio
bank, fixed-step loop, panel) and a disposable **session** (Lua state, sandbox,
entrypoints, saves). Loading a cart tears the old session down first, so a
failed load leaves nothing half-alive.

Sources: drag/drop a file or a folder (walked recursively via
`webkitGetAsEntry`, sorted by filename, with ▲▼ overrides for carts that number
differently), the file picker, `?cart=<url>`, and the built-in `/cart`.
Entrypoints are probed — `_update60` switches the loop to 60 Hz.

Two things the phase turned up that were not in the original list:

- **`step()` bypassed the loop's error handling**, so under automation (where
  rAF is starved in an occluded tab) a cart crash threw raw and lost the
  recovery affordance entirely. Both paths now share one handler.
- **Saved state had to be namespaced immediately**, not deferred to phase 3 —
  the moment a second cart can load, one shared `voxbox_save` key means cart B
  reads and clobbers cart A's state. Keyed on an FNV-1a hash of the sources
  (storage namespacing only; phase 3 upgrades to SHA-256). Mute moved to a
  global key, being a shell preference rather than a cart's.

Original list, for reference:

- Drag/drop a file or a folder (filename-sorted; the `01_`…`09_` convention is
  the documented load order), `?cart=<url>`, file picker.
- **Launcher on startup** (added after the phase landed). Booting straight into
  the built-in cart made a generic runtime look like one game with a loader
  bolted on. It now opens on a launcher over an idle scene — drawn through the
  real Volume and Renderer, so the drop shadow under a hovering cube is proof
  the pipeline works before a cart exists. `?cart=` still boots straight in,
  since a URL is explicit intent.
- **`load folder…` button.** Drag-and-drop was the only way to load a
  directory, because a plain file dialog cannot select one; `webkitdirectory`
  on a second hidden input fixes that. It carries no `accept` filter, so a
  folder's `sfx.json` and `<cart>.voxbox.json` come along with the Lua — the
  button path now reaches parity with drop.
- **`eject`** tears the session down and returns to the launcher, the same
  teardown as loading another cart.
- **`controls` in the manifest.** The controls panel described iso-defender's
  bindings whatever was loaded — the last place the engine still assumed one
  cart. It now renders `[keys, action]` pairs from the manifest, escaped,
  with the host's own bindings kept in a separate block since they are not a
  cart's concern.
- **`esc` pause menu** (resume / quit to launcher), which also suspends the
  AudioContext so music freezes and resumes mid-bar. Kept distinct from the
  existing `p` pause: that one is the quiet pause used with `n` for
  single-frame stepping, and a modal over it would defeat the purpose. The
  menu also clears held keys, so a run does not resume into a stuck direction,
  and swallows keypresses so a stray key cannot restart the audio it just
  suspended.
- Genuine teardown: dispose the Lua state and recreate it. Don't try to unwind
  globals.
- Probe entrypoints instead of assuming: call `_init` only if present, support
  `_update60` at 60 Hz alongside `_update`, tolerate a missing `_draw`.
- Errors pause the loop and show the traceback (already done) rather than
  spinning at 30 fps of stack traces.

---

## 4. Phase 3 — cart identity and persistence ✅ DONE

Storage namespacing landed early in phase 2 out of necessity; the rest is now
in place.

- **SHA-256 cart id** (truncated to 64 bits), with FNV-1a retained under a
  distinct prefix for non-secure contexts where `crypto.subtle` is unavailable.
  Saves migrate through the chain `voxbox_save` → FNV key → SHA key.
- **`cartdata`/`dget`/`dset`** over `localStorage`: 64 numeric slots, keyed on
  the id string passed to `cartdata()` rather than on the cart, because that is
  PICO-8's documented behaviour and carts rely on the sharing. Worth being
  explicit that this means a dropped cart can read another's store if it
  guesses the id — acceptable for a local tool where the user supplies the
  carts, but it is a real property of the design, not an oversight. A cart that
  never calls `cartdata()` gets an implicit store keyed on its own hash so
  `dset()` still persists.
- **`<cart>.voxbox.json` sidecar manifest** carrying `name`, `camera`, `sfx`
  and `persistGlobals`. This is what finally removes iso-defender specifics
  from engine code: the `hiscore`/`unlocked` names now live in
  `voxbox/builtin.voxbox.json` as data. `persistGlobals` accepts `["score"]`
  (restore as saved) or `{"hiscore": "max"}` (never restore downward, which is
  what monotonic values want). URL camera params still beat the manifest.

One finding worth recording: **the 2-second persist interval was not
sufficient on its own.** Browsers throttle timers in hidden tabs to roughly
once a minute, so a tab switched away from and then closed lost everything
since the last tick — and a cart swap dropped up to two seconds of the
outgoing cart's state. Saves now flush explicitly on swap and on
`pagehide`/`visibilitychange`. This surfaced only because the automation tab
reports `visibilityState: 'hidden'`, which made the throttling reproducible.

---

## 5. Phase 4 — audio for an unknown cart ✅ DONE

Implemented as designed below, in `runtime/js/sfxgen.js` (generator),
`runtime/js/audio.js` (resolution) and the host's per-cart pack loading.
Deviations and findings worth recording:

- **Substring keyword matching was a trap.** The first lexicon matched `ow`
  (for "ouch") inside "unkn**ow**n" and `get` inside "tar**get**", so
  `zzz_unknown_thing` generated a *hurt* sound. Keywords are now split into
  `words` (matched against whole tokens, split on punctuation and camelCase)
  and `parts` (substrings of the punctuation-stripped name, four characters
  minimum). That also makes `gameover`, `game_over`, `game-over` and
  `gameOver` all resolve identically.
- **Built-in-ness had to move onto the cart source.** It was set by the boot
  path, so reloading `/cart` by hand silently dropped its authored pack and
  regenerated `shoot`. It is now derived from the URL.
- **`tools/sfxgen.py` needed `--spec`.** The documented export → tweak →
  render loop was not actually runnable: the reference renderer only ever read
  the hardcoded pack.
- **Parity holds for generated specs.** A pack exported from the browser and
  rendered by `tools/sfxgen.py` matches the JS renderer's RMS to four decimals
  on tonal sounds, ~2% on noise — the same tolerance the hand-authored pack has.

Original design follows.

State the constraint plainly: **in a real Voxatron cart the sounds live in the
`.vx.png` resource tree, not in the Lua.** Given a `.lua` file, the audio data
does not exist anywhere in the input. This is not an extraction problem — it is
missing content. `iso-defender/ASSEMBLY.md` is explicit that the game runs
silent until resources with those names are created in the designer.

That constraint is also the opening. Voxatron audio is looked up **by name**,
and a missing name is silence, not an error — so the engine is free to decide
what a name means and can never break a cart by getting it wrong.

### The design: one pipeline, three sources

Refactor the contract to `name → spec → PCM`, where *spec* is today's
`sfx.json` entry format. Both renderers already consume specs; the only new
component is spec *generation*.

**(a) Authored sidecar.** `<cart>.sfx.json` beside the cart, or `?sfx=<url>`.
Exactly today's format, so the existing 22-sound pack becomes the reference
pack rather than a dead end.

**(b) Procedural auto-synthesis — the default.** Generate the spec from the
name. Plan §4 floated "hash the name to seed a plausible sound"; go further,
because cart authors name sounds semantically. Two stages:

1. **Keyword → archetype lexicon.** `shoot|laser|pew|fire` → pulse downslide;
   `boom|explo|blast|die` → noise + drop; `hit|hurt|damage` → saw drop;
   `jump|hop` → rising square; `coin|pickup|get|item` → two-note blip up;
   `ui|click|menu|select|beep` → short tri blip; `win|clear|complete` → organ
   ascending run; `lose|gameover` → descending; `warp|teleport|power` → phaser
   sweep; `alarm|warn` → two-tone square. The existing 15 hand-authored sounds
   *are* a tuned instance of this table — lift them in as seed data.
2. **Name hash seeds variation within the archetype** (centre pitch, step
   count, decay, wave). Deterministic, so `boom` and `bigboom` differ and each
   is stable across sessions.

Fall back to hash-only archetype selection when nothing matches.

**(c) Numeric IDs.** PICO-8-style `sfx(3)` has no name to key on. Feed the
integer into the same generator as the hash seed, and alias `sfx`/`music` to
`play_sound`/`play_music` in the manifest.

Two things make this more than a gimmick:

- **The generator emits a spec, not PCM.** The browser can *export* the
  auto-generated pack as `sfx.json`; the user tweaks it by hand or via
  `python3 tools/sfxgen.py --wavs` and ships it back as the sidecar. Auto-synth
  becomes the first draft of authoring rather than a parallel system, and the
  "two renderers, one spec" invariant survives intact.
- **The sound monitor is already the UI.** It knows every name the cart
  requested; add per-row state (generated / authored / silent) and an export
  button and the workflow is done.

**Music defaults differently.** Generated melodic loops grate far more readily
than generated one-shots. Default music to silent with the requested names
listed in the panel; make procedural music opt-in (`?automusic=1`). The
tracker-lite renderer can do it — key, bpm and progression from the name hash —
but it should not be what a first-time user hears.

---

## 6. Phase 5 — de-hardcode geometry and camera ✅ DONE

`128×128×64` stayed: it is the platform. `GROUND_Z` is gone, and of the three
options the plan offered, **deriving it** was the right one — it is the only
one that makes a dropped cart look right with no configuration.

`Volume.groundPlane()` returns the mode of the per-column topmost voxel plus
that plane's share of occupied columns. In a Voxatron-style scene the ground is
the flat slab most columns belong to, so the mode *is* the plane, and coverage
is how a real slab is told apart from a cart that is only floating objects.
Below 25% coverage, or at z=0 where nothing could be above to cast, there are
no shadows — better than shadows on an invented plane. `"groundZ": 50` pins it,
`"groundZ": false` disables it, `?ground=` overrides both.

The camera default now frames the whole volume; iso-defender's tighter framing
moved into `builtin.voxbox.json`. Per-cart camera overrides had already landed
in phase 3.

Two findings:

- **A flat settling window was the wrong stabiliser.** Requiring a new plane to
  hold for 15 frames stopped the mode flickering, but it also meant half a
  second of shadows cast on the old plane whenever a cart changed scene — the
  reference cart's title screen has its floor at z=58 and its levels at z=50,
  so the transition was visibly wrong. Confidence decides instead: a dominant
  plane is adopted immediately, and only a marginal reading has to settle.
- **`groundZ` of 0 is degenerate.** Nothing can be above the top of the volume,
  so the blur always produced an empty map. Treated as "no ground", which also
  skips the work.

---

## 7. Non-goals and known ceilings

- **Perf.** `iso-defender`'s ~350 draw calls/frame is why the all-JS design
  runs at 0.1 ms/frame. A cart doing tens of thousands of `vset`s per frame pays
  a wasmoon boundary crossing each time — the one thing that could make a
  generic cart unplayable while this one is fine. Plan §2's WASM-linear-memory
  volume was the mitigation and was correctly skipped for one cart. Don't build
  it speculatively; *do* add a per-frame primitive counter to the stats line so
  we find out before a user does. (`clv()` also fills 1 MB and `buildShadow()`
  recomputes a 16k 3×3 blur every frame unconditionally.)
- **Sorted `pairs`.** O(n log n) plus an allocation per call. It exists for
  trace conformance, not for gameplay. Make it conditional on determinism mode
  once there is a second cart to measure; keep it on by default until then,
  since it is what the oracle verifies.
- **`app.py` is not needed for playback.** Once the cart is client-side the
  runtime is static files plus vendored wasmoon and can deploy to GitHub Pages.
  Keep Flask purely as the conformance/trace harness.
- **`driver.lua` does not generalise.** Replace the scripted schedule with
  recorded input logs (frame → button bitmask), which also yields shareable
  repro cases for any cart.

---

## 8. Order of work

1. **Phase 1 ✅** — manifest + lenient stubs + stdlib + sandbox. Arbitrary carts
   run instead of crashing. Verified by an unchanged 4000-frame trace.
2. **Phase 2 ✅** — loader, teardown, entrypoint probing.
3. **Phase 3 ✅** — SHA-256 cart id, `cartdata`/`dget`/`dset`, sidecar manifest.
4. **Phase 4 ✅** — audio: `name → spec → PCM`, archetype generator, spec
   export, sidecar loading.
5. **Phase 5** — `GROUND_Z`/camera into a per-cart profile.

Phases 1–2 are the bulk of "drop a `.lua` and it plays". Phase 4 is where the
interesting design work is. Only phase 5 remains.
