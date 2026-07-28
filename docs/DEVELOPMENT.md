# voxbox — development notes

A browser runtime for pure-Lua Voxatron cartridges. Hand it a `.lua` cart and
it loads, runs and makes noise. Self-contained: everything it needs is in this
repository.

## Status

- **Phase 0 — done.** `shim/picovox.lua` is the canonical Voxatron 0.3.5b /
  PICO-8 API, deterministic across Lua VMs (polynomial trig, float-safe
  Park-Miller PRNG, sorted-order `pairs`), with a built-in draw/audio trace
  recorder. `shim/driver.lua` replays a scripted session as a pure function
  of frame number.
- **Phase 1 — done.** The cart runs under vendored wasmoon (Lua 5.4/WASM) in
  the browser, served by Flask. 4000-frame traces are **bit-identical** to the
  Python/lupa (Lua 5.5) oracle: 631,810 lines, zero divergence. Game logic
  costs ~0.6 ms/frame in the browser (budget: 33 ms).
- **Phase 2 — done.** The game is playable at `http://localhost:8080/`:
  volume buffer + all primitives in JS (`runtime/js/volume.js`), WebGL2
  perspective raymarcher with per-face shading and blurred drop shadows
  (`runtime/js/render.js`), 3x5 voxel font, keyboard input, 30 Hz fixed-step
  loop. Whole CPU pipeline ~0.1 ms/frame. Camera tunable via URL:
  `/?cam=64,268,-115&tgt=64,56,40&fov=27` (those are the defaults).
- **Phase 4 — done.** All 15 SFX + 7 music tracks synthesised from
  `audio/sfx.json` (PICO-8-style steps; tracker-lite music with kick/snare).
  Two renderers, one spec: `tools/sfxgen.py` (numpy, the reference) and
  `runtime/js/synth.js` (verified: durations/RMS match to 4 decimals for
  tonal sounds, ~2% on noise). Music loops pre-render to AudioBuffers — no
  live sequencer. WAV previews: `/sfx/<name>.wav` or
  `python3 tools/sfxgen.py --wavs build/wavs`. The panel flags any name the
  cart requests that the bank lacks (red "?").
- **Phase 3 — done.** Keyboard + standard-mapping gamepad (stick/d-pad,
  A/X fire, B/Y bomb) + touch overlay (auto on touch devices, or `?touch=1`).
- **Phase 5 — done.** Pause/resume (`p` or button), single-frame step (`n`),
  music mute (`m` or the panel button; keeps the track running at zero gain so
  unmute resumes mid-song), PNG screenshot button, and localStorage
  persistence of hiscore + level unlocks + mute preference (restores into the
  Lua state at boot — fixes the cart's documented session-only limitation).
  Skipped as unnecessary: Canvas2D fallback (per plan §8), dirty-region
  texture uploads (whole pipeline is ~0.1 ms/frame), GIF capture.

### Generic-cart work (see [VOXBOX_GENERIC_PLAN.md](VOXBOX_GENERIC_PLAN.md))

- **Phase 1 — done.** The cart now runs in a sandboxed `_ENV` built from an API
  manifest (`shim/api.lua`), not the raw Lua globals: no `io`/`os`/`require`/
  `package`/`load`/`debug`, and no `math.random`. Manifest names with no
  implementation become *recording stubs* — `void` ones degrade honestly
  (nothing drawn/played), `value` ones are flagged red in the new **api** panel
  because their return value is a lie the cart consumes. Names outside the
  manifest stay `nil` and keep ordinary Lua semantics; when one is called, the
  host pulls the name out of the Lua error and offers "stub & restart". The
  PICO-8 stdlib is filled in (`sgn` `count` `foreach` `sub` `split` `tonum`
  `ord` `chr` bit ops `time` `printh` `deli` `btn` `btnp`), and `pairs` no
  longer raises on table or boolean keys. Verified: the 4000-frame trace is
  still bit-identical to the pre-refactor oracle on both hosts.

- **Phase 2 — done.** Carts are swappable at runtime. `host.js` is now a
  persistent *shell* (renderer, volume, input, audio bank, fixed-step loop,
  panel) plus a disposable *session* (Lua state, sandbox, entrypoints, saves),
  so loading a cart disposes the old state outright rather than unwinding
  globals. Sources: drag/drop a `.lua` file **or a folder** (walked
  recursively, sorted by filename per the `01_`…`09_` convention, with ▲▼
  overrides), the `load .lua…` picker, or `?cart=<url>`.
  Entrypoints are probed, not assumed — `_update60` switches the loop to 60 Hz
  and a missing `_draw` is tolerated. A cart error halts the loop and shows the
  traceback; an undeclared global is queued and **stub & restart** reloads the
  cart in place. Saved state and the queued-stub list are namespaced by a cart
  hash, so one cart cannot read or clobber another's.

- **Phase 3 — done (cart identity + persistence).** Storage is namespaced by a
  SHA-256 of the cart sources (FNV-1a fallback outside a secure context), with
  migration through both older key schemes so no existing save is orphaned.
  `cartdata`/`dget`/`dset` are real: 64 numeric slots over `localStorage`,
  keyed on the `cartdata()` id string as PICO-8 does — so two carts sharing an
  id share a save — and a cart that never calls `cartdata()` still gets an
  implicit store keyed on its own hash. The `hiscore`/`unlocked` poking is gone
  from engine code; a `<cart>.voxbox.json` sidecar now declares `name`,
  `camera`, `sfx` and `persistGlobals` (`["score"]` restores as saved,
  `{"hiscore":"max"}` never restores downward), and
  [carts/voxel_defender.voxbox.json](../carts/voxel_defender.voxbox.json) is what keeps the reference cart's
  behaviour without any iso-defender specifics in the host. Saves also flush on
  cart swap and on `pagehide`/`visibilitychange`, since browsers throttle
  timers to roughly once a minute in a backgrounded tab.

- **Phase 5 — done (geometry + camera).** The last cart constant is gone.
  128×128×64 stays (it is the platform), but `GROUND_Z` is no longer declared
  anywhere: the shadow plane is **derived** from the volume each frame as the
  mode of the per-column topmost voxel, guarded by how much of the scene that
  plane accounts for. On the reference cart it lands on z=50 — the same value
  `01_config.lua` uses — and follows the title screen's own floor at z=58.
  A plane that dominates is adopted at once (a cart changing scene genuinely
  moves its ground); a marginal one has to hold for 8 frames. Below 25%
  coverage, or at z=0 where nothing could cast, there are simply no shadows.
  `"groundZ": 50` pins it and `"groundZ": false` disables it, with `?ground=`
  to match. The shell camera now frames the whole volume for an unknown cart;
  iso-defender's tighter framing lives in its manifest, not in engine code.

- **Phase 4 — done (audio for an unknown cart).** In a real Voxatron cart the
  sounds live in the `.vx.png` resource tree, not the Lua — given a `.lua` file
  the audio data simply isn't in the input. But Voxatron looks audio up *by
  name* and a missing name is silence, not an error, so the engine gets to
  decide what a name means. The pipeline is now `name → spec → PCM`, resolved
  in three steps: the cart's **authored** pack, else a spec **generated** from
  the name, else **silent**. `runtime/js/sfxgen.js` picks an archetype from a
  keyword lexicon (`shoot|laser|pew` → pulse downslide, `boom|explo|die` →
  noise drop, …) and seeds variation within it from a hash of the name, so
  `boom` and `bigboom` differ and both are identical on every run. Numeric
  PICO-8-style ids (`sfx(3)`) hash the same way. Packs are per-cart: a dropped
  `.json`, `?sfx=<url>`, `<cart>.sfx.json` beside the cart, or the built-in
  pack. Music defaults to silent (`?automusic=1` opts in) because generated
  loops grate far more readily than generated one-shots. The generator emits
  *specs*, never PCM, so **export sfx.json** hands you an editable pack —
  `python3 tools/sfxgen.py --spec exported.json --wavs out/` renders it — and
  auto-synth becomes the first draft of authoring rather than a dead end. The
  audio panel colours every name by origin.

## Playing

```sh
python3 voxbox/app.py     # then open http://localhost:8080/
```

It opens on a **launcher** over an empty idle scene — a real slab rendered
through the real pipeline, so the renderer is visibly working before any cart
is chosen. From there:

- **load .lua file(s)…** — one file or several (loaded in filename order)
- **load folder…** — a whole directory, sidecars included
- **play iso-defender** — the reference cart
- **play galaxian** — a bundled Galaxian clone ([carts/galaxian.lua](../carts/galaxian.lua)),
  written in pure Voxatron Lua as a worked example of a cart the engine did not
  grow up around: swaying formation, diving attackers, waves, and a hiscore
  stored through `cartdata`/`dget`/`dset`. All of its audio is auto-synthesised
  from the sound names.
- or drop a file, several, or a folder anywhere on the page

The same buttons live in the **cart** panel while a cart is running, with
**eject** to return to the launcher. <kbd>esc</kbd> opens a pause menu —
resume or quit to the launcher — and suspends the audio context so music
freezes mid-bar and resumes there. (<kbd>p</kbd> remains the quiet pause used
with <kbd>n</kbd> for single-frame stepping; it deliberately shows no menu.)

The **controls** panel is filled from the cart's manifest, so it describes
whatever is loaded rather than the reference cart:

```json
"controls": [["arrows / wasd", "fly"], ["x", "fire"], "hold z to charge"]
```

A `[keys, action]` pair renders the keys as a `<kbd>`; a bare string renders as
a plain line. Cart-supplied text is HTML-escaped. The host's own bindings
(<kbd>esc</kbd>/<kbd>p</kbd>/<kbd>n</kbd>/<kbd>m</kbd>, gamepad) are listed
separately, since they are not a cart's concern. `?cart=<url>` skips the launcher and boots
straight in — e.g. `?cart=/carts/voxel_defender.lua` boots directly into the
reference cart. Unknown sound names auto-synthesise (`?autosfx=0` to silence
them); unknown music stays silent unless `?automusic=1`.

Arrows/WASD fly, X fires, Z/C smart bomb, hold Down+Z warp.
P pauses (N steps one frame while paused), M mutes music.
Gamepads use the standard mapping; touch controls appear on touch devices
(force with `?touch=1`).
`window.voxbox.step(n)` drives frames synchronously from the console
(useful under automation, where an occluded tab starves rAF).

## Layout

```
shim/picovox.lua      canonical API shim + trace recorder (single source of truth)
shim/api.lua          API manifest: allowlist + per-name stub policy
shim/sandbox.lua      cart environment builder + lenient recording stubs
shim/driver.lua       deterministic scripted input session
runtime/js/sfxgen.js  sound name -> sfx.json spec (keyword archetypes + name hash)
tools/trace_run.py    Python oracle: lupa + shim + cart -> trace_py.txt
tools/conform.py      trace differ (first divergence + op-count drift)
tools/import_cart.py  pull a cart in from an external source tree
docs/                 design plans: VOXBOX_ENGINE_PLAN, VOXBOX_GENERIC_PLAN
app.py                flask dev server (localhost:8080)
carts/                bundled carts, each with a .voxbox.json sidecar:
                        voxel_defender.lua (the reference cart), galaxian.lua
runtime/conform.html  browser conformance runner (streams trace to flask)
runtime/vendor/wasmoon/   vendored wasmoon 1.16.0 (index.js + glue.wasm)
```

## Conformance loop

```sh
python3 tools/trace_run.py --frames 4000     # oracle -> trace_py.txt
python3 app.py                                # serve on :8080
open "http://localhost:8080/?frames=4000"     # runner -> trace_js.txt (streamed)
python3 tools/conform.py trace_py.txt trace_js.txt
```

Both hosts read the same bytes: `tools/trace_run.py` loads
`carts/voxel_defender.lua` from disk and the browser runner is served the same
file, so they cannot diverge on cart content.

Carts developed in another source tree are pulled in explicitly rather than
rebuilt behind your back:

```sh
python3 tools/import_cart.py ../some-game/src --name some-game
```

A directory is concatenated in filename order (the `01_`…`09_` load-order
convention); a single `.lua` file is copied as-is.

## Determinism rules (why traces can be identical)

Anything that could differ between Lua VMs or libm builds lives in
`picovox.lua` in pure Lua, using only IEEE-exact operations:

1. `sin`/`cos`: quarter-wave Taylor polynomial (|err| < 4e-6), not libm.
2. `atan2`: octant reduction + minimax polynomial.
3. `rnd`/`srand`: Park-Miller MINSTD in float arithmetic (all intermediates
   < 2^53, exact in doubles). No bitops (they differ across Lua versions).
4. `pairs`: iterates keys in sorted order — the cart's wave spawner
   (`05_enemies.lua:47`) iterates a hash table, and hash order is per-VM.
5. `mid`: arithmetic median, no `table.sort`.
6. Trace numbers: integers as `%d`, else `%.4f` — identical strings given
   identical doubles.
