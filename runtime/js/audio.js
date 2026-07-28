// audio.js : WebAudio playback over a name -> spec -> PCM pipeline.
//
// A name resolves in three steps:
//
//   1. the cart's authored pack (a sidecar sfx.json, ?sfx=<url>, or the
//      built-in pack) — exact, hand-tuned;
//   2. a spec generated from the name (sfxgen.js) — deterministic, plausible,
//      and the reason an unknown cart is audible at all;
//   3. silence — which is what Voxatron itself does for an unknown name, so it
//      is always a valid answer.
//
// Specs render to PCM lazily and are cached, because the set of names a cart
// will ask for is not knowable ahead of time. Both stages produce specs in
// audio/sfx.json format, never PCM directly, so a generated pack can be
// exported, hand-tweaked and shipped back as an authored one.
//
// SFX play as one-shot BufferSources; music tracks are pre-rendered loops (loop
// point = end of the authored pattern). The AudioContext can only start after a
// user gesture — call unlock() from input handlers; sounds requested before
// that are simply skipped.
import { SR, renderSfx, renderMusic } from './synth.js';
import { specForSfx, specForMusic } from './sfxgen.js';

const EMPTY = { sfx: {}, music: {} };

export class AudioBank {
  constructor({ autoSfx = true, autoMusic = false } = {}) {
    this.ctx = null;
    this.autoSfx = autoSfx;
    this.autoMusic = autoMusic;
    this.pack = EMPTY;            // authored specs
    this.gen = { sfx: {}, music: {} };  // generated specs, cached
    this.pcm = new Map();         // "kind:name" -> {pcm, loop}
    this.origin = new Map();      // "kind:name" -> "authored" | "generated"
    this.buffers = new Map();     // "kind:name" -> AudioBuffer
    this.musicSrc = null;
    this.musicGain = null;
    this.masterSfx = 0.5;
    this.musicVol = 0.45;
    this.musicMuted = false;
  }

  // Swapping the pack invalidates every rendered sound, since the same name may
  // now resolve to a different spec.
  setPack(pack) {
    this.pack = pack && (pack.sfx || pack.music) ? pack : EMPTY;
    this.gen = { sfx: {}, music: {} };
    this.pcm.clear();
    this.origin.clear();
    this.buffers.clear();
    return Object.keys(this.pack.sfx || {}).length
      + Object.keys(this.pack.music || {}).length;
  }

  async loadPack(url) {
    return this.setPack(await fetch(url).then((r) => r.json()));
  }

  // mute keeps the current track playing at zero gain, so unmuting resumes
  // mid-track instead of restarting
  setMusicMuted(m) {
    this.musicMuted = m;
    if (this.musicGain && this.ctx) {
      const t = this.ctx.currentTime;
      this.musicGain.gain.cancelScheduledValues(t);
      this.musicGain.gain.setValueAtTime(this.musicGain.gain.value, t);
      this.musicGain.gain.linearRampToValueAtTime(m ? 0 : this.musicVol, t + 0.2);
    }
  }

  // ---- resolution ------------------------------------------------------
  specFor(name, kind) {
    const authored = (this.pack[kind] || {})[name];
    if (authored) return [authored, 'authored'];
    if (kind === 'sfx' ? !this.autoSfx : !this.autoMusic) return [null, 'silent'];
    const cache = this.gen[kind];
    // numeric ids (pico-8 `sfx(3)`) hash just as well as names
    cache[name] ||= kind === 'sfx' ? specForSfx(name) : specForMusic(name);
    return [cache[name], 'generated'];
  }

  _entry(name, kind) {
    const key = `${kind}:${name}`;
    if (this.pcm.has(key)) return this.pcm.get(key);
    const [spec, origin] = this.specFor(name, kind);
    if (!spec) return null;
    const e = kind === 'sfx'
      ? { pcm: renderSfx(spec), loop: false }
      : { pcm: renderMusic(spec), loop: spec.loop !== false };
    this.pcm.set(key, e);
    this.origin.set(key, origin);
    return e;
  }

  // "authored" | "generated" | "silent" — what the panel reports per name
  sourceOf(name, kind = 'sfx') {
    if (this.origin.has(`${kind}:${name}`)) return this.origin.get(`${kind}:${name}`);
    return this.specFor(name, kind)[1];
  }

  _buffer(name, kind, entry) {
    const key = `${kind}:${name}`;
    let buf = this.buffers.get(key);
    if (!buf) {
      buf = this.ctx.createBuffer(1, entry.pcm.length, SR);
      buf.getChannelData(0).set(entry.pcm);
      this.buffers.set(key, buf);
    }
    return buf;
  }

  // ---- playback --------------------------------------------------------
  play(name) {
    const entry = this._entry(name, 'sfx');
    const src = this.sourceOf(name, 'sfx');
    if (!entry || !this.ctx || this.ctx.state !== 'running') return src;
    const node = this.ctx.createBufferSource();
    node.buffer = this._buffer(name, 'sfx', entry);
    const g = this.ctx.createGain();
    g.gain.value = this.masterSfx;
    node.connect(g).connect(this.ctx.destination);
    node.start();
    return src;
  }

  music(name, fade) {
    if (!this.ctx || this.ctx.state !== 'running') {
      this.pendingMusic = [name, fade];
      return this.sourceOf(name, 'music');
    }
    this.stopMusic(0.25);
    if (name == null) return 'silent';
    const entry = this._entry(name, 'music');
    const src = this.sourceOf(name, 'music');
    if (!entry) return src;
    const node = this.ctx.createBufferSource();
    node.buffer = this._buffer(name, 'music', entry);
    node.loop = entry.loop;
    const g = this.ctx.createGain();
    const t = this.ctx.currentTime;
    const target = this.musicMuted ? 0 : this.musicVol;
    if (fade) {
      g.gain.setValueAtTime(0, t);
      g.gain.linearRampToValueAtTime(target, t + 1.0);
    } else {
      g.gain.value = target;
    }
    node.connect(g).connect(this.ctx.destination);
    node.start();
    this.musicSrc = node;
    this.musicGain = g;
    return src;
  }

  stopMusic(ramp = 0.25) {
    this.pendingMusic = null;
    if (this.musicSrc) {
      const t = this.ctx.currentTime;
      this.musicGain.gain.setValueAtTime(this.musicGain.gain.value, t);
      this.musicGain.gain.linearRampToValueAtTime(0, t + ramp);
      this.musicSrc.stop(t + ramp);
      this.musicSrc = null;
      this.musicGain = null;
    }
  }

  resume() {
    if (!this.ctx) this.ctx = new AudioContext();
    if (this.ctx.state === 'suspended') this.ctx.resume();
  }

  // Pausing the whole context freezes music mid-bar and resumes it there,
  // which is what a pause menu should do. Never creates a context: if audio
  // was never unlocked there is nothing to suspend.
  suspend() {
    if (this.ctx && this.ctx.state === 'running') this.ctx.suspend();
  }

  // first user gesture: start the context and any music that was requested
  // while it was still locked
  unlock() {
    this.resume();
    if (this.pendingMusic && this.ctx) {
      const [name, fade] = this.pendingMusic;
      this.pendingMusic = null;
      // resume() may complete asynchronously; retry once it runs
      const tryStart = () => {
        if (this.ctx.state === 'running') this.music(name, fade);
        else setTimeout(tryStart, 100);
      };
      tryStart();
    }
  }

  // Everything authored plus everything generated, as one sfx.json. This is the
  // authoring handoff: export it, tweak it, ship it back as a pack.
  //
  // `requested` (the names the cart has actually asked for) is generated on
  // demand even when that kind is switched off, so exporting while music is
  // silent still yields a complete pack to start editing from.
  exportSpec(requested = {}) {
    const out = {
      sfx: { ...(this.pack.sfx || {}), ...this.gen.sfx },
      music: { ...(this.pack.music || {}), ...this.gen.music },
    };
    for (const kind of ['sfx', 'music']) {
      for (const name of requested[kind] || []) {
        if (name == null || out[kind][name]) continue;
        out[kind][name] = kind === 'sfx' ? specForSfx(name) : specForMusic(name);
      }
    }
    return out;
  }
}
