# Browser Voxatron-style Engine — Project Plan

Working name: **voxbox**. A browser runtime that executes Voxatron 0.3.5b-style
pure-Lua cartridges, targeting `iso-defender/build/voxel_defender.lua` as the
reference workload. The user drops a `.lua` file onto the page and it plays.

---

## 0. Scope, fixed by the reference cart

The target game is unusually easy to host because it is *pure script* — no
designer actors, rooms, props or emitters. Auditing `iso-defender/src/*.lua`
gives the complete API surface we must implement. Nothing else is needed for v1.

**Voxel drawing** (call-site counts across `src/`):

| Call | Sites | Meaning |
|---|---:|---|
| `vset(x,y,z,col)` | 39 | set one voxel |
| `boxfill(x0,y0,z0,x1,y1,z1,col)` | 30 | solid axis-aligned box |
| `sphere(x,y,z,r,col)` | 13 | filled sphere |
| `line3d(x0,y0,z0,x1,y1,z1,col)` | 6 | 3D Bresenham |
| `box(...)` | 1 | hollow box |
| `clv()` | 1 | clear the volume |
| `vget(x,y,z)` | 0 | read voxel (stub returns 0) |

**Slice/2D drawing** — the HUD is painted onto the back wall:

`set_draw_slice(y, absolute)` then `print(s,x,z,col)`, `pset`, `line`.
`circ`/`circfill` are unused but cheap to add.

**Input**: `button(n) → 0/1` for n = 0..5 (left, right, up, down, X, O).
There is no `btnp`; the cart edge-detects itself (`02_util.lua:poll_buttons`).

**Audio**: `play_sound(name)`, `play_music(name, fade)`, `stop_sound`,
`stop_music`. Always reached through `sfx_safe`/`music_safe`, which `pcall`
them — see §5.

**PICO-8 stdlib**: `cos`/`sin` (turns, y-flipped), `atan2`, `flr`, `ceil`,
`sqrt`, `abs`, `max`, `min`, `mid`, `rnd`, `srand`, `add`, `del`, `all`,
`tostr`, plus 16-colour palette semantics.

**Lifecycle**: `_init()` once, then `_update()` + `_draw()` at 30 Hz.

**Volume**: 128 × 128 × 64, **z = 0 at the top**, ground at z = 50.
Budget observed in the existing headless tests: ~350 draw calls/frame peak.

`test/headless.py` already encodes all of this as a working shim — it is the
de-facto spec and the conformance oracle for the new engine.

---

## 1. Language decision (read this first)

The request asked for Python where possible. Being straight about the trade-off:

**Python cannot be the frame-loop runtime.** Getting Python into the browser
means Pyodide (~8–12 MB cold start), and we would *still* need a Lua VM inside
it to run the cart. A pure-Python Lua interpreter under Pyodide will not hold
30 fps with a 1 MB voxel volume; it would be roughly two orders of magnitude off.

**Recommended split:**

| Layer | Language | Why |
|---|---|---|
| Lua VM | **Wasmoon** (Lua 5.4 → WASM) | near-native; Fengari (pure JS) is the fallback if we need Lua 5.3 semantics or easier debugging |
| Voxel raster + volume buffer | **JS + WASM (Rust or C)** | 1 MB volume touched every frame; must not cross the VM boundary per voxel |
| Renderer | **WebGL2 shader** | raymarch a 3D texture |
| Audio | **WebAudio** | see §5 |
| **Build, asset pipeline, SFX authoring/rendering, conformance tests, dev server, CI** | **Python** | this is where Python earns its place and where most of the interesting work is |

So: Python owns everything offline and authored; the browser runtime is
JS/WASM. If you'd rather pay the size and perf cost to keep the runtime in
Python too, say so before Phase 1 — it changes the architecture, not the plan's
shape.

---

## 2. Architecture

```
┌─ index.html ─────────────────────────────────────────────────────┐
│  Loader UI      drag/drop or file picker, multi-file ordering,   │
│                 reset/reload, error console, sound-name monitor  │
├──────────────────────────────────────────────────────────────────┤
│  Host (JS)      lifecycle @30Hz, input map, VM sandbox           │
│    ├── Lua VM (wasmoon)  ← the cart's Lua source                 │
│    ├── voxbox-core (WASM)                                        │
│    │     Uint8Array volume[128*128*64]  (palette indices)        │
│    │     clv/vset/box/boxfill/sphere/line3d                      │
│    │     slice raster: print/pset/line/circ + 3x5 PICO-8 font    │
│    ├── Renderer (WebGL2)  volume → R8UI 3D texture → raymarch    │
│    └── Audio (WebAudio)   synth bank from sfx.json (§5)          │
└──────────────────────────────────────────────────────────────────┘

tools/  (Python)
    build.py        concat src/NN_*.lua → cartridge (reuses iso-defender/build.sh logic)
    sfxgen.py       author + render sound/music specs, preview as WAV
    conform.py      run headless shim vs engine, diff draw-command traces
    serve.py        dev server with COOP/COEP headers for SAB, live reload
```

### Why a shared volume buffer matters

Lua calls the primitives (~350/frame); the primitives write into WASM linear
memory; the renderer uploads that memory as a 3D texture. Voxel writes never
cross into JS individually. `boxfill(0,0,50,127,127,63,c)` — the ground — is
one call filling ~230k voxels, done as a memset-per-row inside WASM.

### Renderer

Fixed isometric camera matching Voxatron's default. Fragment shader
raymarches (DDA) the 3D texture front-to-back, first non-zero voxel wins,
palette lookup from a 16-entry LUT, cheap face-normal shading from the DDA
step axis so cubes read as cubes. Full-screen quad; no meshing, no geometry
upload. 1 MB `texSubImage3D` per frame at 30 Hz ≈ 30 MB/s — comfortable.

Coordinate convention is fixed once, in the shader: **z = 0 is up**.

### Fallback path

If WebGL2 is unavailable: a Canvas2D painter's-algorithm renderer that sorts
by depth and splats voxel quads. Correct, ugly, ~5× slower. Ship it behind a
flag so the engine degrades rather than dies.

---

## 3. Loader interface

The cart is a plain Lua chunk with globals — the whole cart shares one
environment, which makes loading trivially simple:

- **Single file**: drop `voxel_defender.lua`, done.
- **Multiple files**: drop `src/` (webkitdirectory or drag a folder). Sort by
  filename — the `01_`…`09_` prefixes are already the required load order, per
  `ASSEMBLY.md`. Show the resolved order and let the user drag to reorder.
- **URL param**: `?cart=<url>` for sharing, same-origin or CORS-permitted only.
- **Reset**: tear down the Lua state entirely and re-create it, so a reload is
  genuinely clean (globals, RNG seed, audio voices).
- **Errors**: Lua errors surface in an overlay with the traceback and the
  offending source line, not just the console. `_update` throwing pauses the
  loop instead of spinning at 30 fps of stack traces.
- **Sandbox**: the Lua environment is a fresh table containing *only* the
  engine API + the PICO-8 stdlib. No `io`, `os`, `require`, `loadstring`,
  `package`. A loaded cart cannot touch the page or the network.

---

## 4. Audio: the `sfx_safe` question

### What the cart actually does

```lua
function sfx_safe(name)  local ok=pcall(play_sound,name)  return ok  end
function music_safe(name,fade) pcall(play_music,name,fade) end
```

Every audio call is name-based and failure-tolerant by design — `ASSEMBLY.md`
states plainly that the game runs silently until resources with those names
exist. That is a gift: **the engine can never break the game with audio**, and
we are free to decide what a name means.

The complete set, from `ASSEMBLY.md` and confirmed by grepping the call sites:

- **Sounds (15)**: `shoot` `eshoot` `boom` `bigboom` `rescue` `deliver` `warp`
  `bomb` `mine` `alarm` `hurt` `mutate` `clear` `ui` `1up`
- **Music (7)**: `title` `music1` `music2` `music3` `jingle` `gameover` `victory`

### Recommendation: synthesise, from a Python-authored spec

Do **not** ship WAV/OGG assets. Ship a small `sfx.json` and synthesise.
Reasons: no binary assets, tiny payload, trivially editable, and it matches the
PICO-8 aesthetic the cart is written in.

**The model** — a PICO-8 SFX, deliberately: 32 steps, a speed (frames/step),
and per step a `{note, waveform, volume, effect}`. Eight waveforms: triangle,
tilted saw, saw, square, pulse, organ, noise, phaser. Seven effects: none,
slide, vibrato, drop, fade-in, fade-out, arpeggio. This is a well-understood,
compact, expressive model, and anyone who has used PICO-8 can author for it.

**Two renderers, one spec** — this is the key move:

1. `tools/sfxgen.py` (numpy) renders `sfx.json` → WAV files. Used for
   authoring, listening on the desktop, regression-diffing waveforms in CI, and
   as the reference implementation.
2. `audio/synth.js` renders the same `sfx.json` at load time into
   `AudioBuffer`s via `OfflineAudioContext`, then playback is a plain
   `BufferSourceNode`. One synth pass at boot (~22 short sounds, milliseconds),
   zero per-shot cost afterwards.

The Python renderer is the spec; the JS renderer is validated against it by
comparing RMS envelopes and spectral centroids per sound in `conform.py`.

**Starting sound design** (`shoot` fires up to 6×/second — keep it short and
out of the way of `boom`):

| name | ~ms | sketch |
|---|---:|---|
| `shoot` | 90 | pulse, fast downward slide C6→G5, snappy decay |
| `eshoot` | 110 | square, downward slide a fifth lower, slightly duller |
| `boom` | 260 | noise + drop effect, fast attack, exponential fade |
| `bigboom` | 550 | layered noise + low triangle drop, longer tail |
| `rescue` | 300 | triangle arpeggio up, major triad |
| `deliver` | 420 | organ, rising 4-note fanfare |
| `warp` | 350 | phaser, wide vibrato, pitch sweep up then out |
| `bomb` | 700 | noise sweep down + sub-bass drop, screen-clearing weight |
| `mine` | 140 | short tilted-saw click, high |
| `alarm` | 500 | square, two-tone alternating, slight detune |
| `hurt` | 220 | saw, downward drop, harsh |
| `mutate` | 400 | pulse with heavy vibrato, rising and unstable |
| `clear` | 900 | organ ascending run, resolves up an octave |
| `ui` | 60 | triangle blip |
| `1up` | 600 | classic four-note rising arpeggio |

**Music** — same file, one level up: a tracker-lite format (4 channels ×
patterns of 32 notes + an order list + loop point). Seven short loops. Reuse
the same waveform code, sequenced by a WebAudio lookahead scheduler (25 ms
timer, 100 ms schedule horizon) so timing does not depend on the frame loop.
`music_safe(name, fade)` maps `fade` to a gain ramp; the cart passes `1` in one
place (`09_main.lua:46`) and omits it elsewhere.

**Diagnostics** — because unknown names are silently swallowed by `pcall`, the
loader shows a live panel of every sound/music name the cart requested and
whether the bank had it. That turns "why is it quiet" into a one-glance answer,
and it is how we'd onboard any *other* cart's sound set.

**Missing names**: an unknown name is not an error. Options, user-selectable:
silent (matches Voxatron), or auto-synth — hash the name to seed a plausible
sound. Default silent; auto-synth is a fun toggle for unknown carts.

---

## 5. Conformance strategy

We already have a trusted oracle: `iso-defender/test/headless.py` plays the
whole campaign under a Lua shim and asserts on real game state.

1. Extend that shim to record an ordered **draw-command trace** per frame
   (op + args) instead of merely counting calls.
2. Add a `--trace` mode to the browser engine emitting the identical format.
3. `tools/conform.py` runs both from the same RNG seed and the same scripted
   input sequence and diffs. Divergence at frame N with a specific op is a
   precise bug report.

This catches the things that actually bite: `sin` sign convention, `atan2`
argument order and turn units, `rnd` distribution, integer truncation in `flr`,
and `set_draw_slice`'s absolute-vs-relative flag.

Fixed seed + scripted input also gives us frame-hash golden tests for the
renderer.

---

## 6. Phases

**Phase 0 — spec extraction (Python). ✅ DONE 2026-07-18.** Canonical shim is
`voxbox/shim/picovox.lua` (deterministic trig/PRNG/`pairs` + trace recorder) —
one Lua file executed by every host is a stronger contract than a manifest.
Oracle: `voxbox/tools/trace_run.py` (lupa, Lua 5.5); differ:
`voxbox/tools/conform.py`.

**Phase 1 — headless JS runtime. ✅ DONE 2026-07-18.** Vendored wasmoon 1.16.0
(Lua 5.4/WASM) runs the cart in the browser via `voxbox/app.py` (Flask) +
`voxbox/runtime/conform.html`, streaming its trace back. Node never needed.
Result: 4000-frame traces **bit-identical** to the oracle (631,810 lines,
including a level-1 clear); game logic ~0.6 ms/frame in-browser.

**Phase 2 — renderer. ✅ DONE 2026-07-18.** WebGL2 perspective raymarcher
(`voxbox/runtime/js/render.js`) with per-face shading + blurred drop shadows;
volume + primitives in JS (`volume.js`, `box()` = 12-edge wireframe per the
landing pad); 3×5 font; keyboard input; 30 Hz loop. Title and level 1 verified
in-browser against `game.jpg` — HUD/radar/pad/colonists/shadows all match.
CPU cost ~0.1 ms/frame. Note: rAF starves in occluded tabs (automation);
`window.voxbox.step(n)` drives frames synchronously.

**Phase 3 — input + loader UI. ✅ DONE 2026-07-18** (loader UI dropped per
§8). Keyboard (arrows/WASD, X, Z/C), standard-mapping gamepad polled per
frame, touch overlay (auto-shown on touch devices, `?touch=1` to force),
error overlay, sound-name monitor with missing-name flagging.

**Phase 4 — audio. ✅ DONE 2026-07-18.** `voxbox/audio/sfx.json` (15 SFX +
7 music tracks), rendered by both `tools/sfxgen.py` (numpy reference) and
`runtime/js/synth.js` (browser) — parity verified (exact durations, RMS to
4 decimals on tonal sounds). Music loops pre-render to AudioBuffers instead
of live sequencing — simpler than the planned lookahead scheduler and just as
authentic. Deterministic noise via shared Park-Miller seed. AudioContext
unlocks on first input; sounds requested before that are skipped (pcall-safe),
pending music starts on unlock. WAV previews at `/sfx/<name>.wav`.

**Phase 5 — polish. ✅ DONE 2026-07-18** (with Phase 3's gamepad + touch).
Shipped: pause/resume + single-frame step, music mute (M key + panel button,
zero-gain mute so unmute resumes mid-track, preference persisted), PNG
screenshot, localStorage persistence of hiscore/unlocks restored into the Lua
state at boot — the cart-README limitation fixed without touching cart code.
Skipped as unnecessary: Canvas2D fallback (§8), dirty-region uploads
(pipeline ~0.1 ms/frame), GIF capture.

**Estimate: ~2.5 weeks** to a playable, audible `iso-defender` in the browser.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| Wasmoon/Lua boundary cost per primitive call | ~350 calls/frame is nothing; measured in Phase 1 before committing |
| 1 MB texture upload per frame | Well within WebGL2 budgets; dirty-rect uploads held in reserve for Phase 5 |
| PICO-8 math semantics drift (esp. `sin` sign, `atan2` turns) | Trace diffing against the Python oracle from Phase 1 |
| `set_draw_slice` semantics under-specified | The cart only uses `(0,true)` and `(1,true)` and world-y absolute — pin behaviour to observed usage, document the assumption |
| Overfitting the engine to one cart | The API manifest is the contract, not the game; keep the engine free of iso-defender specifics |
| 16.16 fixed-point overflow behaviour | Cart deliberately stays under 32767 (`01_config.lua`); use doubles and note the divergence rather than emulating overflow |

---

## 8. Revision: Flask-hosted, single-cart, Voxatron-faithful (2026-07-18)

Decision: skip the generic loader. A **Flask app on localhost:8080** serves the
engine with `iso-defender` baked in, and the renderer targets the original
Voxatron look as captured in `iso-defender/game.jpg`.

**Flask's role** (delivery + tooling host — the runtime is still JS/WASM in
the browser; Flask cannot join the frame loop):

```
app.py
  GET /            index.html + engine bundle
  GET /cart        build/voxel_defender.lua (runs build.sh first if src/ newer)
  GET /sfx.json    the sound bank spec
  GET /sfx/<name>  sfxgen.py-rendered WAV preview (authoring aid)
```

Edit `src/`, refresh the browser, play. No drag/drop, no multi-file ordering,
no URL params, no Canvas2D fallback, no multi-cart sandboxing. The error
overlay, sound-name monitor, and trace-diff conformance harness stay.

**The original look, decomposed from `game.jpg`** — four cheap features, no
expensive ones (no AO, no outlines, no dynamic lights visible):

1. **Perspective camera** from above-front (playfield converges to a
   trapezoid). Perspective ray generation in the raymarcher; same DDA shader.
2. **Per-face flat shading** — top faces bright, side faces darker (visible on
   the slab edge and scenery voxels). Face normal comes free from the DDA step
   axis.
3. **Straight-down drop shadows** (soft dark blobs under ship/scenery): a
   128×128 column-occupancy map computed in one WASM pass per frame, used to
   darken ground hits.
4. **Volume floats in black; HUD text is voxels with depth** — the cart draws
   the HUD on back-wall slices y=0 and y=1, so faithful volume rendering gives
   the 2-voxel-thick score text automatically.

**Revised phases**: Phase 3 shrinks to input mapping + error overlay (~1 day);
Phase 2 gains the fidelity items (+2 days); Phase 5 drops the Canvas2D
fallback. **New estimate: ~1.5 weeks.**

---

## 9. Open questions

1. **Lua 5.4 (Wasmoon) vs 5.3 (Fengari)** — the cart uses no version-sensitive
   features I found; recommend Wasmoon for speed, revisit if integer division
   or `goto` shows up in other carts.
2. ~~How faithful to Voxatron's actual look?~~ **Resolved in §8**: match the
   original, which `game.jpg` shows is four cheap features (perspective camera,
   face shading, drop shadows, black surround) — not the expensive lighting
   pipeline feared.
3. **Multi-cart ambitions?** If this should run other people's Voxatron carts,
   the `.vx.png` cartridge format (there are two in `iso-defender/build/`)
   needs a parser, and designer actors/rooms/emitters become in scope. That is
   a much larger project. v1 assumes pure-Lua carts only.
