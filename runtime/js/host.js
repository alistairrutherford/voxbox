// host.js : the voxbox shell.
//
// Split in two, because a cart is now swappable at runtime:
//
//   shell    created once — WebGL renderer, volume, input, audio bank, the
//            30/60 Hz fixed-step loop, and the panel.
//   session  one per cart — the Lua state, its sandbox, the resolved
//            entrypoints and the cart's saved state. Disposed and rebuilt on
//            load, so a reload is genuinely clean (globals, RNG, coroutines)
//            rather than a best-effort unwind.
//
// Carts arrive by drag/drop (file or folder), the file picker, ?cart=<url>, or
// the built-in /cart the dev server bakes in.
import { Volume } from './volume.js';
import { Renderer } from './render.js';
import { AudioBank } from './audio.js';

const $ = (s) => document.querySelector(s);
const q = new URLSearchParams(location.search);

const KEYMAP = {
  ArrowLeft: 0, ArrowRight: 1, ArrowUp: 2, ArrowDown: 3,
  KeyA: 0, KeyD: 1, KeyW: 2, KeyS: 3,
  KeyX: 4, KeyZ: 5, KeyC: 5,
};

// ---------------------------------------------------------- cart identity --
// SHA-256 over the concatenated sources, truncated to 64 bits — enough that
// two different carts will not share a storage namespace by accident.
// crypto.subtle needs a secure context (localhost counts), so plain-http hosts
// fall back to FNV-1a under a distinct "f" prefix rather than silently
// colliding with the strong scheme.
function fnvId(chunks) {
  let h = 0x811c9dc5;
  for (const c of chunks) {
    for (let i = 0; i < c.src.length; i++) {
      h ^= c.src.charCodeAt(i);
      h = Math.imul(h, 0x01000193);
    }
  }
  return (h >>> 0).toString(16).padStart(8, '0');
}

async function cartId(chunks) {
  if (!crypto?.subtle) return `f${fnvId(chunks)}`;
  const src = chunks.map((c) => c.src).join('\0');
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(src));
  return [...new Uint8Array(buf, 0, 8)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

const saveKey = (id) => `voxbox_save:${id}`;
const stubKey = (id) => `voxbox_extra_stubs:${id}`;
const dataKey = (id) => `voxbox_cartdata:${id}`;
const MUTE_KEY = 'voxbox_mute';   // a shell preference, not a per-cart one

// Storage keys were FNV-1a before SHA-256; carry a save across so it is not
// silently orphaned. Cart-agnostic: the old key is derived from cart content,
// exactly like the new one.
function migrateSave(id, chunks) {
  if (localStorage.getItem(saveKey(id))) return;
  const old = saveKey(fnvId(chunks));
  const v = localStorage.getItem(old);
  if (v) { localStorage.setItem(saveKey(id), v); localStorage.removeItem(old); }
}

// Names the manifest never listed, discovered by catching the Lua error and
// replayed on the next load so the cart gets further. Per-cart and
// session-scoped: a debugging aid for this cart, not a persisted decision.
const extraStubs = (id) => {
  try { return JSON.parse(sessionStorage.getItem(stubKey(id)) || '[]'); }
  catch { return []; }
};
const addExtraStub = (id, name) => {
  const l = extraStubs(id);
  if (!l.includes(name)) sessionStorage.setItem(stubKey(id), JSON.stringify([...l, name]));
};

// ------------------------------------------------------------ cart sources --
const LUA = /\.lua$/i;
const JSON_RE = /\.json$/i;
const MANIFEST_RE = /\.voxbox\.json$/i;

// Every cart loads the same way, bundled or not: fetch the .lua, then look
// beside it for the sidecars. There is no privileged cart and no special route.
async function cartFromUrl(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: HTTP ${r.status}`);
  const src = await r.text();
  const stem = url.replace(LUA, '');
  return {
    name: url.split('/').pop() || url,
    chunks: [{ name: 'cart', src }],
    // the documented sidecar convention: cart.lua -> cart.sfx.json / cart.voxbox.json
    sfxUrl: `${stem}.sfx.json`,
    manifestUrl: `${stem}.voxbox.json`,
  };
}

// Chunks share one sandbox env, so a multi-file cart just loads in filename
// order — ASSEMBLY.md's 01_..09_ prefixes already encode the required order.
// A .json in the same drop is taken as the cart's authored sound pack.
async function cartFromFiles(entries) {
  const lua = entries.filter((e) => LUA.test(e.path));
  if (!lua.length) throw new Error('no .lua files in that drop');
  lua.sort((a, b) => a.path.localeCompare(b.path));
  const chunks = await Promise.all(lua.map(async (e) => ({
    name: e.path.split('/').pop().replace(LUA, ''),
    src: await e.file.text(),
  })));
  const name = lua.length === 1 ? lua[0].path
    : `${lua[0].path.split('/').slice(0, -1).join('/') || 'drop'} (${lua.length} files)`;

  // *.voxbox.json is the per-cart manifest; any other .json is a sound pack
  let sfxPack = null, manifest = null;
  for (const e of entries.filter((e) => JSON_RE.test(e.path))) {
    let parsed;
    try { parsed = JSON.parse(await e.file.text()); }
    catch (err) { console.warn(`${e.path}: ${err.message}, ignoring`); continue; }
    if (MANIFEST_RE.test(e.path)) manifest = parsed;
    else if (parsed.sfx || parsed.music) sfxPack = parsed;
    else console.warn(`${e.path}: no "sfx" or "music" key, ignoring`);
  }
  return { name: manifest?.name || name, chunks, sfxPack, manifest };
}

// Directory drops arrive as FileSystemEntry trees; plain file drops don't.
async function entriesFromDrop(dt) {
  const roots = [...dt.items]
    .filter((i) => i.kind === 'file')
    .map((i) => i.webkitGetAsEntry?.())
    .filter(Boolean);
  if (!roots.length) return [...dt.files].map((f) => ({ path: f.name, file: f }));

  const out = [];
  const walk = async (entry, prefix) => {
    const path = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isFile) {
      out.push({ path, file: await new Promise((res, rej) => entry.file(res, rej)) });
      return;
    }
    const reader = entry.createReader();
    for (;;) {
      // readEntries returns at most 100 per call: keep going until it's empty
      const batch = await new Promise((res, rej) => reader.readEntries(res, rej));
      if (!batch.length) break;
      for (const child of batch) await walk(child, path);
    }
  };
  for (const r of roots) await walk(r, '');
  return out;
}

// ---------------------------------------------------------------- monitors --
// Every sound/music name the cart asked for, and where it came from:
// authored (a pack), generated (synthesised from the name), or silent. Because
// unknown names are swallowed by design, this panel is the one-glance answer to
// "why is it quiet" — and the list of names worth authoring.
function soundMonitor() {
  const counts = new Map();
  const musicNames = new Set();
  const el = $('#sounds');
  let musicNow = '-', musicSrc = 'silent';
  const render = () => {
    const rows = [...counts.entries()]
      .sort((a, b) => b[1].n - a[1].n)
      .map(([n, r]) => {
        const hot = performance.now() - r.t < 300 ? ' hot' : '';
        return `<div class="${r.src}${hot}">${n} <span>x${r.n}</span></div>`;
      });
    el.innerHTML = `<div class="mus ${musicSrc}">music: ${musicNow}</div>` + rows.join('');
  };
  setInterval(render, 250);
  return {
    sfx(n, src) {
      const r = counts.get(n) || { n: 0, t: 0, src };
      r.n++; r.t = performance.now(); r.src = src;
      counts.set(n, r);
    },
    music(n, src) {
      musicNow = n ?? '-';
      musicSrc = n == null ? 'silent' : src;
      if (n != null) musicNames.add(n);
    },
    // the export handoff: everything the cart has ever asked for
    requested: () => ({ sfx: [...counts.keys()], music: [...musicNames] }),
    reset() {
      counts.clear(); musicNames.clear();
      musicNow = '-'; musicSrc = 'silent'; render();
    },
  };
}

// Live view of manifest names the cart called that have no implementation.
// "value" stubs are red because they return a made-up number the cart consumes
// — the game is misbehaving, not merely quiet. "void" stubs only lose visuals
// or audio, so the cart's logic is still correct.
function apiMonitor(getSession) {
  const el = $('#api');
  let undeclared = new Set();
  const render = () => {
    const s = getSession();
    const rows = (s ? s.lua.doStringSync('return vb_stubs()') || '' : '')
      .split('\n').filter(Boolean)
      .map((line) => {
        const [kind, n, name] = line.split(' ');
        return `<div class="${kind}">${name} <span>x${n}</span></div>`;
      });
    for (const name of undeclared) rows.unshift(`<div class="undecl">${name} — undeclared</div>`);
    el.innerHTML = rows.length ? rows.join('')
      : '<div style="color:#666">all called API implemented</div>';
    $('#restub').style.display = undeclared.size ? '' : 'none';
  };
  setInterval(render, 500);
  return {
    reset() { undeclared = new Set(); render(); },
    // "attempt to call a nil value (global 'foo')" / "index a nil value (global 'foo')"
    note(id, e) {
      const m = /(?:global|field) '(\w+)'/.exec(e.message || String(e));
      if (!m) return null;
      undeclared.add(m[1]);
      addExtraStub(id, m[1]);
      render();
      return m[1];
    },
  };
}

// Manifest text is cart-supplied, so it is escaped before it ever reaches
// innerHTML — a dropped cart must not be able to inject markup into the page.
const esc = (s) => String(s).replace(/[&<>"]/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function showError(e, hint) {
  const el = $('#error');
  el.style.display = 'block';
  el.textContent = `ERROR\n${e.message || e}\n${e.stack || ''}`
    + (hint ? `\n\n${hint}` : '');
}
const clearError = () => { $('#error').style.display = 'none'; };

// -------------------------------------------------------------------- shell --
async function boot() {
  const status = (m) => { $('#status').textContent = m; };
  status('loading lua vm…');

  const factory = new wasmoon.LuaFactory('/vendor/wasmoon/dist/glue.wasm');
  // Unknown sound names auto-synthesise by default; unknown *music* names stay
  // silent unless asked for, because a generated melodic loop grates far more
  // readily than a generated one-shot.
  const bank = new AudioBank({
    autoSfx: q.get('autosfx') !== '0',
    autoMusic: q.get('automusic') === '1',
  });
  const text = (u) => fetch(u).then((r) => r.text());
  const [shim, manifest, sandbox] = await Promise.all([
    text('/shim/picovox.lua'),
    text('/shim/api.lua'),
    text('/shim/sandbox.lua'),
  ]);

  const vol = new Volume();
  const kb = new Uint8Array(8);        // keyboard
  const pad = new Uint8Array(8);       // gamepad (polled per frame)
  const tch = new Uint8Array(8);       // touch overlay
  const mon = soundMonitor();

  let session = null;                  // null while (re)loading
  let cart = null;                     // the currently loaded cart source
  const apiMon = apiMonitor(() => session);

  // ---- cartdata (pico-8 persistent store) ------------------------------
  // 64 numeric slots behind localStorage. PICO-8 namespaces these by the *id
  // string* passed to cartdata(), not by the cart, so two carts sharing an id
  // share a save — that is the documented behaviour and carts rely on it, but
  // it does mean a dropped cart can read another's data if it guesses the id.
  // A cart that never calls cartdata() gets an implicit store keyed on its own
  // hash, so dset() still persists instead of vanishing.
  const CD_SLOTS = 64;
  const cd = { key: null, slots: new Float64Array(CD_SLOTS), dirty: false };

  function openCartData(id) {
    cd.key = dataKey(id);
    cd.slots.fill(0);
    cd.dirty = false;
    let existed = false;
    try {
      const raw = localStorage.getItem(cd.key);
      if (raw) {
        const arr = JSON.parse(raw);
        if (Array.isArray(arr)) {
          existed = true;
          for (let i = 0; i < Math.min(CD_SLOTS, arr.length); i++) {
            cd.slots[i] = Number(arr[i]) || 0;
          }
        }
      }
    } catch { /* corrupt store: start zeroed */ }
    return existed;
  }

  function flushCartData() {
    if (!cd.dirty || !cd.key) return;
    try {
      localStorage.setItem(cd.key, JSON.stringify([...cd.slots]));
      cd.dirty = false;
    } catch { /* private mode etc: ignore */ }
  }

  const cdIndex = (i) => {
    const n = Math.floor(Number(i));
    return Number.isFinite(n) && n >= 0 && n < CD_SLOTS ? n : -1;
  };

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
    line: (a, b, c2, d, e) => vol.line(a, b, c2, d, e),
    circ: (a, b, c2, d) => vol.circ(a, b, c2, d),
    circfill: (a, b, c2, d) => vol.circfill(a, b, c2, d),
    print: (s, x, z, c) => vol.print(s, x, z, c),
    // pget, draw_voxmap and blit_voxmap are deliberately absent: registering
    // them as no-ops would make the manifest read them as implemented and hide
    // them from the API panel. Left unset, they become recording stubs and a
    // cart that needs voxel models says so on screen.
    button: (n) => (kb[n] || pad[n] || tch[n]) ? 1 : 0,
    play_sound: (n) => { mon.sfx(n, bank.play(n)); },
    stop_sound: () => {},
    play_music: (n, fade) => { mon.music(n, bank.music(n, fade)); },
    stop_music: () => { mon.music(null); bank.stopMusic(); },
    cartdata: (id) => openCartData(String(id)),
    dget: (i) => (cdIndex(i) < 0 ? 0 : cd.slots[cdIndex(i)]),
    dset: (i, v) => {
      const n = cdIndex(i);
      if (n < 0) return;                  // pico-8 ignores out-of-range slots
      cd.slots[n] = Number(v) || 0;
      cd.dirty = true;
    },
  };

  // ---- session lifecycle ----------------------------------------------
  async function loadCart(next) {
    // save the outgoing cart before its session and store key go away, then
    // tear down first, so a failed load leaves nothing half-alive
    persist();
    const old = session;
    session = null;
    if (old) { try { old.lua.global.close(); } catch { /* already closed */ } }
    bank.stopMusic();
    mon.reset();
    apiMon.reset();
    clearError();
    vol.clv();

    cart = next;
    const id = await cartId(cart.chunks);
    showCart();
    status('loading cart…');

    // ---- per-cart manifest (<cart>.voxbox.json) ------------------------
    // Everything the engine would otherwise have to hardcode about a specific
    // cart lives here as data: display name, camera, sound pack, and which
    // globals are worth persisting.
    let man = cart.manifest || null;
    if (!man && cart.manifestUrl) {
      try {
        const r = await fetch(cart.manifestUrl);
        if (r.ok) man = await r.json();     // absent is the normal case
      } catch { /* not there: no overrides */ }
    }
    if (man?.name) { cart = { ...cart, name: man.name }; showCart(); }
    showControls(man);

    // camera: URL params stay authoritative, being explicit user intent
    if (man?.camera) {
      renderer.setCamera({
        pos: vec('cam', man.camera.pos || CAM.pos),
        target: vec('tgt', man.camera.target || CAM.target),
        fovDeg: q.get('fov') ? Number(q.get('fov')) : (man.camera.fov ?? CAM.fovDeg),
        aspect: CAM.aspect,
      });
    } else {
      renderer.setCamera(CAM);
    }

    // Drop shadows need to know where the ground is. Default is to derive it
    // from the volume each frame (see Volume.groundPlane); a cart whose scene
    // defeats the heuristic can pin or disable it.
    //   "groundZ": 50      fixed plane
    //   "groundZ": false   no drop shadows
    //   absent / "auto"    derive
    const rawGround = q.get('ground') ?? man?.groundZ;
    renderer.setGround(
      rawGround == null || rawGround === 'auto' ? { mode: 'auto' }
        : rawGround === false || rawGround === 'off' || rawGround === 'false'
          ? { mode: 'off' }
          : Number.isFinite(Number(rawGround))
            ? { mode: 'fixed', z: Number(rawGround) }
            : { mode: 'auto' });

    // The sound pack belongs to the cart, not the shell: a dropped sidecar
    // wins, then ?sfx=<url>, then the manifest, then the cart's own sidecar
    // URL. Anything left over auto-synthesises from the name (see sfxgen.js).
    let pack = cart.sfxPack || null;
    const explicit = q.get('sfx');
    if (!pack && !explicit && man?.sfx && typeof man.sfx === 'object') pack = man.sfx;
    const sfxUrl = explicit || (typeof man?.sfx === 'string' ? man.sfx : cart.sfxUrl);
    if (!pack && sfxUrl) {
      try {
        const r = await fetch(sfxUrl);
        if (r.ok) pack = await r.json();
        // a missing sidecar is the normal case, so only an explicit ?sfx= that
        // 404s is worth complaining about
        else if (explicit) console.warn(`sound pack ${sfxUrl}: HTTP ${r.status}`);
      } catch (e) { console.warn(`sound pack ${sfxUrl}: ${e.message}`); }
    }
    const authored = bank.setPack(pack);
    console.log(`sound pack: ${authored} authored`
      + `, auto-sfx ${bank.autoSfx ? 'on' : 'off'}`
      + `, auto-music ${bank.autoMusic ? 'on' : 'off'}`);

    const lua = await factory.createEngine();
    // canonical shim first (deterministic math/pairs + trace stubs), then the
    // manifest and sandbox, then the JS host API overrides the shim's
    // trace-recorder draw ops, and only then is the cart built an environment.
    await lua.doString(shim);
    await lua.doString(manifest);
    await lua.doString(sandbox);
    for (const [name, fn] of Object.entries(api)) lua.global.set(name, fn);
    for (const name of extraStubs(id)) {
      lua.global.set('__stub_name', name);
      lua.doStringSync('vb_stub(__stub_name)');
    }
    const coverage = lua.doStringSync('local r,s = vb_build() return r.."/"..(r+s)');
    console.log(`api coverage: ${coverage} implemented`);

    for (const chunk of cart.chunks) {
      lua.global.set('__src', chunk.src);
      const err = lua.doStringSync(
        `local e = vb_load(__src, ${JSON.stringify(chunk.name)}) __src=nil return e`);
      if (err) {
        apiMon.note(id, { message: err });
        showError({ message: err });
        status('load failed');
        try { lua.global.close(); } catch { /* ignore */ }
        showLauncher();   // the error stays up; the user can pick another cart
        return;
      }
    }

    const update = lua.doStringSync('return vb_has("_update60")') ? '_update60' : '_update';
    const s = {
      lua, id,
      step: update === '_update60' ? 1000 / 60 : 1000 / 30,
      tick: `_tick() vb_call("${update}")`,
      saves: [],
    };

    // A cart that never calls cartdata() still gets a store, keyed on itself
    openCartData(id);
    lua.doStringSync(`srand(${Date.now() % 32767}) vb_call("_init")`);

    // Globals worth persisting are now declared by the cart's manifest rather
    // than hardcoded in the engine — the reference cart's README notes
    // Voxatron has no storage API, so its hiscore and level unlocks are
    // session-only, and builtin.voxbox.json is what fixes that. Carts using
    // cartdata/dget/dset need none of this.
    //   ["score"]              restore as saved
    //   {"hiscore": "max"}     never restore downward (monotonic values)
    const decl = man?.persistGlobals;
    const merge = Array.isArray(decl) ? Object.fromEntries(decl.map((n) => [n, 'set']))
      : (decl && typeof decl === 'object') ? decl : {};
    const num = (n) =>
      lua.doStringSync(`local v = vb_get("${n}") return type(v)=="number" and v or nil`);
    s.saves = Object.keys(merge).filter((n) => num(n) != null);
    s.num = num;
    migrateSave(id, cart.chunks);
    try {
      const saved = JSON.parse(localStorage.getItem(saveKey(id)) || '{}');
      for (const n of s.saves) {
        if (typeof saved[n] !== 'number') continue;
        lua.doStringSync(merge[n] === 'max'
          ? `vb_set("${n}", max(vb_get("${n}"), ${saved[n]}))`
          : `vb_set("${n}", ${saved[n]})`);
      }
    } catch { /* corrupt save: start fresh */ }

    acc = 0; last = performance.now();
    session = s;
    hideLauncher();
    status('running');
  }

  // carts with no declared save globals write nothing, so loading one does not
  // litter storage with an entry that holds no cart state
  function persist() {
    flushCartData();
    if (!session || !session.saves.length) return;
    try {
      const out = {};
      for (const n of session.saves) out[n] = session.num(n);
      localStorage.setItem(saveKey(session.id), JSON.stringify(out));
    } catch { /* private mode etc: ignore */ }
  }
  // The interval alone is not enough: browsers throttle timers hard in hidden
  // tabs (to about once a minute after a few minutes backgrounded), so a tab
  // that is switched away from and then closed would lose everything since the
  // last tick. Flush on the way out instead of hoping a timer fires.
  setInterval(persist, 2000);
  addEventListener('pagehide', persist);
  addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') persist();
  });

  // ---- cart panel ------------------------------------------------------
  // A cart's controls are its own business, so they come from its manifest:
  //   "controls": [["arrows", "move"], ["x", "fire"], "hold z to charge"]
  // A two-element pair renders as <kbd>keys</kbd> action; a bare string renders
  // as a plain line. The host's own bindings live in #host-controls and never
  // change, which is why they are kept separate.
  function showControls(man) {
    const list = Array.isArray(man?.controls) ? man.controls : null;
    const el = $('#cart-controls');
    if (!list) {
      el.innerHTML = cart
        ? '<div style="color:#666">cart controls unlisted — try '
          + '<kbd>arrows</kbd> and <kbd>x</kbd></div>'
        : '';
      return;
    }
    el.innerHTML = list.map((item) => (Array.isArray(item)
      ? `<div><kbd>${esc(item[0])}</kbd> ${esc(item[1] ?? '')}</div>`
      : `<div>${esc(item)}</div>`)).join('');
  }

  function showCart() {
    $('#cartname').textContent = cart ? cart.name : '—';
    const many = cart && cart.chunks.length > 1;
    $('#files').innerHTML = !many ? '' : cart.chunks.map((c, i) =>
      `<div>${i + 1}. ${c.name}`
      + `<button data-i="${i}" data-d="-1"${i === 0 ? ' disabled' : ''}>▲</button>`
      + `<button data-i="${i}" data-d="1"${i === cart.chunks.length - 1 ? ' disabled' : ''}>▼</button>`
      + '</div>').join('');
  }
  // Filename order is the documented contract (ASSEMBLY.md), so it is the
  // default; these are the escape hatch for a cart that numbers differently.
  $('#files').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b || !cart) return;
    const i = Number(b.dataset.i), j = i + Number(b.dataset.d);
    const chunks = [...cart.chunks];
    [chunks[i], chunks[j]] = [chunks[j], chunks[i]];
    loadCart({ ...cart, chunks }).catch(showError);
  });

  const openCart = async (make) => {
    try { await loadCart(await make()); }
    catch (e) { showError(e); status('load failed'); showLauncher(); }
  };

  // ---- launcher + idle scene -------------------------------------------
  // With no cart loaded the volume would just be black, which reads as broken.
  // Draw an empty Voxatron-style scene instead: a real slab through the real
  // renderer, so the drop shadow under the hovering cube is proof the pipeline
  // works before a cart is ever chosen.
  const IDLE_GROUND = 52;
  function drawIdle(t) {
    vol.clv();
    vol.boxfill(0, 0, IDLE_GROUND, 127, 127, 63, 5);          // slab body
    vol.boxfill(0, 0, IDLE_GROUND, 127, 127, IDLE_GROUND, 6); // slab top
    for (let y = 0; y < 128; y += 16) {                       // checker tiles
      for (let x = 0; x < 128; x += 16) {
        if (((x + y) / 16) % 2 === 0) {
          vol.boxfill(x, y, IDLE_GROUND, x + 15, y + 15, IDLE_GROUND, 13);
        }
      }
    }
    // Placed off-centre: the launcher card sits over the middle of the view,
    // so anything centred here would be hidden behind it. No voxel caption —
    // the HTML heading already says it, and better.
    const bob = (p) => Math.round(Math.sin(t / 900 + p) * 4);
    const cube = (cx, cy, cz, c) =>
      vol.boxfill(cx - 6, cy - 6, cz, cx + 6, cy + 6, cz + 12, c);
    cube(26, 30, 32 + bob(0), 12);
    cube(102, 24, 28 + bob(2), 8);
    cube(64, 106, 34 + bob(4), 10);
  }

  let idleAt = 0;
  function showLauncher() {
    document.body.classList.add('no-cart');
    status('no cart loaded');
    renderer.setCamera(CAM);
    renderer.setGround({ mode: 'auto' });
    idleAt = 0;                     // force a redraw on the next frame
  }
  const hideLauncher = () => document.body.classList.remove('no-cart');

  // Returning to the launcher is a full teardown, same as loading another cart,
  // so nothing of the old cart survives into the next one.
  function eject() {
    persist();
    const old = session;
    session = null;
    if (old) { try { old.lua.global.close(); } catch { /* already closed */ } }
    cart = null;
    bank.stopMusic();
    mon.reset();
    clearError();
    closePauseMenu(false);
    setPaused(false);
    showCart();
    showControls(null);
    showLauncher();
  }

  // ---- pause menu -------------------------------------------------------
  // Distinct from the `p` key, which is a quiet pause for single-frame
  // stepping: esc is the player-facing one, so it stops the audio and puts a
  // prompt on screen.
  let menuOpen = false;
  function openPauseMenu() {
    if (!session || menuOpen) return;
    menuOpen = true;
    kb.fill(0);                  // don't resume into a held direction
    setPaused(true);
    bank.suspend();
    $('#pause-cart').textContent = cart ? cart.name : '';
    document.body.classList.add('paused-menu');
    status('paused');
  }
  function closePauseMenu(resume = true) {
    if (!menuOpen) return;
    menuOpen = false;
    document.body.classList.remove('paused-menu');
    if (resume) { setPaused(false); bank.resume(); }
  }

  // one handler for both inputs: the folder one just arrives with
  // webkitRelativePath set, which is also what gives the load order its paths
  for (const id of ['#file', '#folder']) {
    $(id).addEventListener('change', (e) => {
      const files = [...e.target.files].map((f) => ({
        path: f.webkitRelativePath || f.name, file: f,
      }));
      if (files.length) openCart(() => cartFromFiles(files));
      e.target.value = '';
    });
  }
  const pickFiles = () => $('#file').click();
  const pickFolder = () => $('#folder').click();
  const playCart = (url) => openCart(() => cartFromUrl(url));
  $('#load').addEventListener('click', pickFiles);
  $('#loadfolder').addEventListener('click', pickFolder);
  $('#eject').addEventListener('click', eject);
  $('#pause-resume').addEventListener('click', () => closePauseMenu());
  $('#pause-quit').addEventListener('click', eject);
  $('#pick-files').addEventListener('click', pickFiles);
  $('#pick-folder').addEventListener('click', pickFolder);
  // bundled carts load by URL like any other, so they pick up their sidecars
  // for free — neither is privileged over the other
  $('#pick-builtin').addEventListener('click',
    () => playCart('/carts/voxel_defender.lua'));
  $('#pick-galaxian').addEventListener('click',
    () => playCart('/carts/galaxian.lua'));
  $('#pick-zaxxon').addEventListener('click',
    () => playCart('/carts/zaxxon.lua'));

  addEventListener('dragover', (e) => {
    e.preventDefault();
    document.body.classList.add('dragging');
  });
  addEventListener('dragleave', (e) => {
    if (e.relatedTarget === null) document.body.classList.remove('dragging');
  });
  addEventListener('drop', (e) => {
    e.preventDefault();
    document.body.classList.remove('dragging');
    openCart(async () => cartFromFiles(await entriesFromDrop(e.dataTransfer)));
  });

  // ---- renderer --------------------------------------------------------
  const canvas = $('#screen');
  // The default frames the whole 128x128x64 volume from above-front, since an
  // unknown cart may draw anywhere in it. iso-defender's tighter framing (which
  // crops to its play area to match the original look) lives in its manifest,
  // not here. A cart's manifest overrides the default; URL params override
  // both, e.g. /?cam=64,260,-95&tgt=64,60,36&fov=26
  const vec = (k, dflt) => q.get(k) ? q.get(k).split(',').map(Number) : dflt;
  const CAM = {
    pos: vec('cam', [64, 267, -116]),
    target: vec('tgt', [64, 64, 32]),
    fovDeg: q.get('fov') ? Number(q.get('fov')) : 45,
    aspect: canvas.width / canvas.height,
  };
  const renderer = new Renderer(canvas, CAM);

  // ---- pause / single-step -------------------------------------------
  let paused = false;
  const setPaused = (p) => {
    paused = p;
    $('#pause').textContent = paused ? 'resume' : 'pause';
    status(paused ? 'paused — n steps one frame' : 'running');
  };

  // ---- music mute -----------------------------------------------------
  const muteBtn = $('#mute');
  function showMute() {
    muteBtn.textContent = `music: ${bank.musicMuted ? 'off' : 'on'}`;
  }
  const toggleMute = () => {
    bank.setMusicMuted(!bank.musicMuted);
    try { localStorage.setItem(MUTE_KEY, bank.musicMuted ? '1' : '0'); }
    catch { /* private mode: preference just won't stick */ }
    showMute();
  };
  muteBtn.addEventListener('click', () => { bank.unlock(); toggleMute(); });
  if (localStorage.getItem(MUTE_KEY) === '1') bank.setMusicMuted(true);
  showMute();

  addEventListener('keydown', (e) => {
    if (e.code === 'Escape') {
      if (menuOpen) closePauseMenu(); else openPauseMenu();
      e.preventDefault();
      return;
    }
    // the pause menu swallows game input, and must not let a stray keypress
    // restart the audio context it just suspended
    if (menuOpen) return;
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

  // ---- screenshot + pause + restub ------------------------------------
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
  // reloads the cart in place rather than the page, so a dropped cart survives
  $('#restub').addEventListener('click', () => {
    if (cart) loadCart(cart).catch(showError);
  });

  // Export what the cart is actually using — authored entries as-is, generated
  // ones as editable specs — so auto-synth is the first draft of authoring
  // rather than a dead end. Drop the result back on the page to use it.
  $('#exportsfx').addEventListener('click', () => {
    const spec = bank.exportSpec(mon.requested());
    const blob = new Blob([JSON.stringify(spec, null, 1)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'sfx.json';
    a.click();
    URL.revokeObjectURL(a.href);
  });

  // A cart error halts stepping and surfaces the traceback rather than spinning
  // at 30 fps of stack traces. The Lua state is left open for inspection. An
  // undeclared global is recoverable: queue it as a stub and reload the cart.
  function onLuaError(s, e) {
    session = null;
    status('halted');
    console.error('cart error:', e);
    const name = apiMon.note(s.id, e);
    showError(e, name
      ? `'${name}' is not in the API manifest (shim/api.lua). It has been `
        + 'queued as a stub — press "stub & restart" to continue.'
      : null);
  }

  // debug handle; step(n) drives frames synchronously (rAF starves when the
  // tab is occluded, e.g. under browser automation — real users are unaffected).
  // It shares the loop's error handling so automated runs get the same
  // diagnosis a player would.
  window.voxbox = {
    kb, vol, renderer, bank,
    get lua() { return session?.lua; },
    get cart() { return cart; },
    load: (c) => loadCart(c),
    loadUrl: (u) => openCart(() => cartFromUrl(u)),
    eject: () => eject(),
    step(n = 1) {
      const s = session;
      if (!s) return null;
      try {
        for (let i = 0; i < n; i++) s.lua.doStringSync(s.tick);
        s.lua.doStringSync('vb_call("_draw")');
      } catch (e) {
        onLuaError(s, e);
        return null;
      }
      renderer.frame(vol);
      return s.lua.doStringSync('return vb_get("mode")');
    },
  };

  // ---- fixed-step loop -------------------------------------------------
  let last = performance.now(), acc = 0;
  let luaMs = 0, gpuMs = 0, frames = 0;

  function loop(now) {
    requestAnimationFrame(loop);
    window.__ticks = (window.__ticks || 0) + 1;
    const dt = now - last; last = now;
    if (!session) {
      // idle scene, throttled: nothing here needs 30 fps and this is a screen
      // people may leave sitting open
      acc = 0;
      if (document.body.classList.contains('no-cart') && now - idleAt >= 100) {
        idleAt = now;
        drawIdle(now);
        renderer.frame(vol);
      }
      return;
    }
    if (paused) { acc = 0; return; }
    const s = session;
    acc += dt;
    if (acc > s.step * 4) acc = s.step;   // tab was hidden: don't spiral
    pollPad();
    let stepped = false;
    const t0 = performance.now();
    try {
      while (acc >= s.step) {
        s.lua.doStringSync(s.tick);
        acc -= s.step;
        stepped = true;
        window.__steps = (window.__steps || 0) + 1;
      }
      if (stepped) s.lua.doStringSync('vb_call("_draw")');
    } catch (e) {
      onLuaError(s, e);
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

  // A ?cart= URL is explicit intent, so it boots straight into the game;
  // otherwise start at the launcher rather than assuming the built-in cart.
  // (?cart=/cart restores the old boot-straight-into-iso-defender behaviour.)
  if (q.get('cart')) await openCart(() => cartFromUrl(q.get('cart')));
  else showLauncher();
}

boot().catch(showError);
