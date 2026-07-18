// audio.js : WebAudio playback over the synthesised bank (synth.js).
// SFX play as one-shot BufferSources; music tracks are pre-rendered loops
// (loop point = end of the authored pattern). The AudioContext can only
// start after a user gesture — call resume() from input handlers; sounds
// requested before that are simply skipped (the cart pcall-wraps everything).
import { SR, renderBank } from './synth.js';

export class AudioBank {
  constructor() {
    this.ctx = null;
    this.bank = new Map();       // name -> {pcm, loop}
    this.buffers = new Map();    // name -> AudioBuffer (lazy)
    this.musicSrc = null;
    this.musicGain = null;
    this.masterSfx = 0.5;
    this.musicVol = 0.45;
    this.musicMuted = false;
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

  async load(url) {
    const spec = await fetch(url).then((r) => r.json());
    this.bank = renderBank(spec);
    return this.bank.size;
  }

  has(name) { return this.bank.has(name); }

  resume() {
    if (!this.ctx) this.ctx = new AudioContext();
    if (this.ctx.state === 'suspended') this.ctx.resume();
  }

  _buffer(name) {
    let buf = this.buffers.get(name);
    if (!buf) {
      const entry = this.bank.get(name);
      buf = this.ctx.createBuffer(1, entry.pcm.length, SR);
      buf.getChannelData(0).set(entry.pcm);
      this.buffers.set(name, buf);
    }
    return buf;
  }

  play(name) {
    if (!this.ctx || this.ctx.state !== 'running' || !this.bank.has(name)) return;
    const src = this.ctx.createBufferSource();
    src.buffer = this._buffer(name);
    const g = this.ctx.createGain();
    g.gain.value = this.masterSfx;
    src.connect(g).connect(this.ctx.destination);
    src.start();
  }

  music(name, fade) {
    if (!this.ctx || this.ctx.state !== 'running') { this.pendingMusic = [name, fade]; return; }
    this.stopMusic(0.25);
    if (name == null || !this.bank.has(name)) return;
    const src = this.ctx.createBufferSource();
    src.buffer = this._buffer(name);
    src.loop = this.bank.get(name).loop;
    const g = this.ctx.createGain();
    const t = this.ctx.currentTime;
    const target = this.musicMuted ? 0 : this.musicVol;
    if (fade) {
      g.gain.setValueAtTime(0, t);
      g.gain.linearRampToValueAtTime(target, t + 1.0);
    } else {
      g.gain.value = target;
    }
    src.connect(g).connect(this.ctx.destination);
    src.start();
    this.musicSrc = src;
    this.musicGain = g;
  }

  stopMusic(ramp = 0.25) {
    if (this.musicSrc) {
      const t = this.ctx.currentTime;
      this.musicGain.gain.setValueAtTime(this.musicGain.gain.value, t);
      this.musicGain.gain.linearRampToValueAtTime(0, t + ramp);
      this.musicSrc.stop(t + ramp);
      this.musicSrc = null;
      this.musicGain = null;
    }
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
}
