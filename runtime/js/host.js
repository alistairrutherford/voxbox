// host.js : boots wasmoon, loads the canonical shim + cart, registers the
// JS-side Voxatron API (volume primitives, buttons, audio monitor), and runs
// the 30 Hz fixed-step loop with the WebGL2 renderer.
import { Volume } from './volume.js';
import { Renderer } from './render.js';
import { AudioBank } from './audio.js';

const STEP = 1000 / 30;
const $ = (s) => document.querySelector(s);

const KEYMAP = {
  ArrowLeft: 0, ArrowRight: 1, ArrowUp: 2, ArrowDown: 3,
  KeyA: 0, KeyD: 1, KeyW: 2, KeyS: 3,
  KeyX: 4, KeyZ: 5, KeyC: 5,
};

function soundMonitor() {
  const counts = new Map();
  const el = $('#sounds');
  let musicNow = '-';
  const render = () => {
    const rows = [...counts.entries()]
      .sort((a, b) => b[1].n - a[1].n)
      .map(([n, r]) => {
        const cls = !r.ok ? ' class="miss"'
          : performance.now() - r.t < 300 ? ' class="hot"' : '';
        return `<div${cls}>${n}${r.ok ? '' : ' ?'} <span>x${r.n}</span></div>`;
      });
    el.innerHTML = `<div class="mus">music: ${musicNow}</div>` + rows.join('');
  };
  setInterval(render, 250);
  return {
    sfx(n, ok = true) {
      const r = counts.get(n) || { n: 0, t: 0, ok };
      r.n++; r.t = performance.now(); r.ok = ok;
      counts.set(n, r);
    },
    music(n) { musicNow = n ?? '-'; },
  };
}

function showError(e) {
  const el = $('#error');
  el.style.display = 'block';
  el.textContent = `LUA ERROR\n${e.message || e}\n${e.stack || ''}`;
}

async function boot() {
  const status = (m) => { $('#status').textContent = m; };
  status('loading lua vm…');

  const factory = new wasmoon.LuaFactory('/vendor/wasmoon/dist/glue.wasm');
  const bank = new AudioBank();
  const [lua, shim, cart, nSounds] = await Promise.all([
    factory.createEngine(),
    fetch('/shim/picovox.lua').then((r) => r.text()),
    fetch('/cart').then((r) => r.text()),
    bank.load('/sfx.json'),
  ]);
  console.log(`audio bank: ${nSounds} sounds synthesised`);

  // canonical shim first (deterministic math/pairs + trace stubs), then the
  // JS host API overrides its trace-recorder draw ops, then the cart.
  await lua.doString(shim);

  const vol = new Volume();
  const kb = new Uint8Array(8);        // keyboard
  const pad = new Uint8Array(8);       // gamepad (polled per frame)
  const tch = new Uint8Array(8);       // touch overlay
  const mon = soundMonitor();

  // standard-mapping gamepad: dpad 14/15/12/13, left stick, A/X fire, B/Y bomb
  function pollPad() {
    pad.fill(0);
    const gp = navigator.getGamepads?.()?.[0];
    if (!gp) return;
    const ax = gp.axes[0] || 0, ay = gp.axes[1] || 0;
    if (ax < -0.4 || gp.buttons[14]?.pressed) pad[0] = 1;
    if (ax > 0.4 || gp.buttons[15]?.pressed) pad[1] = 1;
    if (ay < -0.4 || gp.buttons[12]?.pressed) pad[2] = 1;
    if (ay > 0.4 || gp.buttons[13]?.pressed) pad[3] = 1;
    if (gp.buttons[0]?.pressed || gp.buttons[2]?.pressed) pad[4] = 1;
    if (gp.buttons[1]?.pressed || gp.buttons[3]?.pressed) pad[5] = 1;
  }

  const api = {
    clv: () => vol.clv(),
    vset: (x, y, z, c) => vol.vset(x, y, z, c),
    vget: (x, y, z) => vol.vget(x, y, z),
    box: (a, b, c2, d, e, f, g) => vol.box(a, b, c2, d, e, f, g),
    boxfill: (a, b, c2, d, e, f, g) => vol.boxfill(a, b, c2, d, e, f, g),
    sphere: (x, y, z, r, c) => vol.sphere(x, y, z, r, c),
    line3d: (a, b, c2, d, e, f, g) => vol.line3d(a, b, c2, d, e, f, g),
    set_draw_slice: (y, _abs) => vol.setSlice(y),
    pset: (x, z, c) => vol.pset(x, z, c),
    pget: () => 0,
    line: (a, b, c2, d, e) => vol.line(a, b, c2, d, e),
    circ: (a, b, c2, d) => vol.circ(a, b, c2, d),
    circfill: (a, b, c2, d) => vol.circfill(a, b, c2, d),
    print: (s, x, z, c) => vol.print(s, x, z, c),
    draw_voxmap: () => {},
    blit_voxmap: () => {},
    button: (n) => (kb[n] || pad[n] || tch[n]) ? 1 : 0,
    play_sound: (n) => { mon.sfx(n, bank.has(n)); bank.play(n); },
    stop_sound: () => {},
    play_music: (n, fade) => { mon.music(n); bank.music(n, fade); },
    stop_music: () => { mon.music(null); bank.stopMusic(); },
  };
  for (const [name, fn] of Object.entries(api)) lua.global.set(name, fn);

  status('loading cart…');
  await lua.doString(cart);
  lua.doStringSync(`srand(${Date.now() % 32767}) _init()`);

  // persistence: the cart's own README notes Voxatron has no storage API, so
  // hiscore/level unlocks are session-only there — restore them here instead
  const SAVE_KEY = 'voxbox_save';
  try {
    const saved = JSON.parse(localStorage.getItem(SAVE_KEY) || '{}');
    if (saved.hiscore > 0) lua.doStringSync(`hiscore=max(hiscore or 0,${saved.hiscore})`);
    if (saved.unlocked > 1) lua.doStringSync(`unlocked=max(unlocked or 1,${saved.unlocked})`);
    if (saved.muted) bank.setMusicMuted(true);
  } catch { /* corrupt save: start fresh */ }
  function persist() {
    try {
      localStorage.setItem(SAVE_KEY, JSON.stringify({
        hiscore: lua.doStringSync('return hiscore or 0'),
        unlocked: lua.doStringSync('return unlocked or 1'),
        muted: bank.musicMuted,
      }));
    } catch { /* private mode etc: ignore */ }
  }
  setInterval(persist, 2000);

  const canvas = $('#screen');
  // camera tunable via URL while matching the original look, e.g.
  // /?cam=64,260,-95&tgt=64,60,36&fov=26
  const q = new URLSearchParams(location.search);
  const vec = (k, dflt) => q.get(k) ? q.get(k).split(',').map(Number) : dflt;
  const renderer = new Renderer(canvas, {
    pos: vec('cam', [64, 268, -115]),
    target: vec('tgt', [64, 56, 40]),
    fovDeg: q.get('fov') ? Number(q.get('fov')) : 27,
    aspect: canvas.width / canvas.height,
  });

  // ---- pause / single-step -------------------------------------------
  let paused = false;
  const setPaused = (p) => {
    paused = p;
    $('#pause').textContent = paused ? 'resume' : 'pause';
    status(paused ? 'paused — n steps one frame' : 'running');
  };

  // ---- music mute -----------------------------------------------------
  const muteBtn = $('#mute');
  const showMute = () => {
    muteBtn.textContent = `music: ${bank.musicMuted ? 'off' : 'on'}`;
  };
  const toggleMute = () => { bank.setMusicMuted(!bank.musicMuted); showMute(); };
  muteBtn.addEventListener('click', () => { bank.unlock(); toggleMute(); });
  showMute();

  addEventListener('keydown', (e) => {
    bank.unlock();   // audio can only start after a user gesture
    if (e.code in KEYMAP) { kb[KEYMAP[e.code]] = 1; e.preventDefault(); }
    else if (e.code === 'KeyM') toggleMute();
    else if (e.code === 'KeyP') setPaused(!paused);
    else if (e.code === 'KeyN' && paused) window.voxbox.step(1);
  });
  addEventListener('pointerdown', () => bank.unlock());
  addEventListener('keyup', (e) => {
    if (e.code in KEYMAP) { kb[KEYMAP[e.code]] = 0; e.preventDefault(); }
  });

  // ---- touch overlay (shown on touch devices or with ?touch=1) --------
  if ('ontouchstart' in window || q.get('touch')) {
    document.body.classList.add('touch-on');
  }
  for (const el of document.querySelectorAll('#touch .tb')) {
    const b = Number(el.dataset.b);
    const on = (e) => { tch[b] = 1; el.setPointerCapture?.(e.pointerId); e.preventDefault(); };
    const off = () => { tch[b] = 0; };
    el.addEventListener('pointerdown', on);
    el.addEventListener('pointerup', off);
    el.addEventListener('pointercancel', off);
    el.addEventListener('lostpointercapture', off);
  }

  // ---- screenshot + pause buttons -------------------------------------
  $('#shot').addEventListener('click', () => {
    renderer.frame(vol);           // fresh render: GL buffer isn't preserved
    canvas.toBlob((blob) => {
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'voxbox.png';
      a.click();
      URL.revokeObjectURL(a.href);
    });
  });
  $('#pause').addEventListener('click', () => setPaused(!paused));

  status('running');
  // debug handle; step(n) drives frames synchronously (rAF starves when the
  // tab is occluded, e.g. under browser automation — real users are unaffected)
  window.voxbox = {
    kb, vol, lua, renderer, bank,
    step(n = 1) {
      for (let i = 0; i < n; i++) lua.doStringSync('_update()');
      lua.doStringSync('_draw()');
      renderer.frame(vol);
      return lua.doStringSync('return mode');
    },
  };
  let last = performance.now(), acc = 0, dead = false;
  let luaMs = 0, gpuMs = 0, frames = 0;

  function loop(now) {
    if (dead) return;
    requestAnimationFrame(loop);
    window.__ticks = (window.__ticks || 0) + 1;
    acc += now - last; last = now;
    if (acc > STEP * 4) acc = STEP;   // tab was hidden: don't spiral
    if (paused) { acc = 0; return; }
    pollPad();
    let stepped = false;
    const t0 = performance.now();
    try {
      while (acc >= STEP) {
        lua.doStringSync('_update()');
        acc -= STEP;
        stepped = true;
        window.__steps = (window.__steps || 0) + 1;
      }
      if (stepped) lua.doStringSync('_draw()');
    } catch (e) {
      dead = true;
      console.error('loop death:', e);
      showError(e);
      return;
    }
    const t1 = performance.now();
    if (stepped) {
      renderer.frame(vol);
      const t2 = performance.now();
      luaMs += t1 - t0; gpuMs += t2 - t1; frames++;
      if (frames >= 30) {
        $('#stats').textContent =
          `lua ${(luaMs / frames).toFixed(2)}ms  ` +
          `draw ${(gpuMs / frames).toFixed(2)}ms`;
        luaMs = gpuMs = frames = 0;
      }
    }
  }
  requestAnimationFrame(loop);
}

boot().catch(showError);
