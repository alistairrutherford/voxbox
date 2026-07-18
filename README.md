# voxbox

Browser Voxatron-style engine for `iso-defender` (see
[../VOXBOX_ENGINE_PLAN.md](../VOXBOX_ENGINE_PLAN.md)).

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

## Playing

```sh
python3 voxbox/app.py     # then open http://localhost:8080/
```

Arrows/WASD fly, X fires, Z/C smart bomb, hold Down+Z warp.
P pauses (N steps one frame while paused), M mutes music.
Gamepads use the standard mapping; touch controls appear on touch devices
(force with `?touch=1`).
`window.voxbox.step(n)` drives frames synchronously from the console
(useful under automation, where an occluded tab starves rAF).

## Layout

```
shim/picovox.lua      canonical API shim + trace recorder (single source of truth)
shim/driver.lua       deterministic scripted input session
tools/trace_run.py    Python oracle: lupa + shim + cart -> trace_py.txt
tools/conform.py      trace differ (first divergence + op-count drift)
app.py                flask dev server (localhost:8080)
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

`GET /cart` rebuilds `iso-defender/build/voxel_defender.lua` automatically
when `src/` is newer, so editing the game and re-running conformance needs no
manual build step.

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
