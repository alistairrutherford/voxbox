// synth.js : JS mirror of tools/sfxgen.py — renders audio/sfx.json to
// Float32Array PCM. Same waveforms, same envelopes, same Park-Miller noise
// seed; tools/sfxgen.py is the reference implementation, keep them in step.
export const SR = 22050;
const A4_PITCH = 33;
const NOTE_SEM = { c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11 };

const pitchFreq = (p) => 440 * Math.pow(2, (p - A4_PITCH) / 12);

function noteFreq(token) {
  const name = token[0];
  let rest = token.slice(1);
  let sem = NOTE_SEM[name];
  if (rest.startsWith('#')) { sem += 1; rest = rest.slice(1); }
  else if (rest.startsWith('b') && rest.length > 1) { sem -= 1; rest = rest.slice(1); }
  return 440 * Math.pow(2, (sem + 12 * parseInt(rest, 10) - 57) / 12);
}

// Park-Miller LCG noise table, seed 1234 (identical to sfxgen.py)
const NOISE_BITS = 15;
const NOISE_MASK = (1 << NOISE_BITS) - 1;
const NOISE_TABLE = (() => {
  const t = new Float64Array(1 << NOISE_BITS);
  let s = 1234;
  for (let i = 0; i < t.length; i++) {
    s = (s * 16807) % 2147483647;
    t[i] = (s / 2147483647) * 2 - 1;
  }
  return t;
})();

const frac = (x) => x - Math.floor(x);
const tri = (ph) => 1 - 4 * Math.abs(frac(ph) - 0.5);

function osc(wave, ph, ph2) {
  const x = frac(ph);
  switch (wave) {
    case 'tri': return tri(ph);
    case 'tsaw': return x < 0.875 ? (x / 0.875) * 2 - 1 : ((1 - x) / 0.125) * 2 - 1;
    case 'saw': return 2 * x - 1;
    case 'sqr': return x < 0.5 ? 1 : -1;
    case 'pulse': return x < 0.3125 ? 1 : -1;
    case 'organ': return 0.7 * tri(ph) + 0.3 * tri(ph * 2);
    case 'phaser': return 0.5 * tri(ph) + 0.5 * tri(ph2 !== undefined ? ph2 : ph * 1.013);
    default: throw new Error(`wave ${wave}`);
  }
}

// moving-average declick matching np.convolve(a, ones(64)/64, 'same'):
// out[i] = sum(a[i-32 .. i+31]) / 64, zero-padded at the edges
function smooth64(a) {
  const n = a.length;
  const prefix = new Float64Array(n + 1);
  for (let i = 0; i < n; i++) prefix[i + 1] = prefix[i] + a[i];
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const lo = Math.max(0, i - 32);
    const hi = Math.min(n, i + 32);
    out[i] = (prefix[hi] - prefix[lo]) / 64;
  }
  return out;
}

// ---------------------------------------------------------------- sfx -----

export function renderSfx(spec) {
  const { speed, steps } = spec;
  const spf = Math.round((SR * speed) / 120);
  const n = spf * steps.length;
  const freq = new Float64Array(n);
  const vol = new Float64Array(n);

  for (let i = 0; i < steps.length; i++) {
    const [pitch, , v] = steps[i];
    const fx = steps[i][3] || 'none';
    const prev = i > 0 ? steps[i - 1][0] : pitch;
    for (let k = 0; k < spf; k++) {
      const t = k / spf;
      let p = pitch;
      let vv = v / 7;
      if (fx === 'slide') p = prev + (pitch - prev) * t;
      else if (fx === 'vib') p = pitch + 0.3 * Math.sin(2 * Math.PI * 7.5 * t * (speed / 120));
      else if (fx === 'drop') p = pitch - 12 * t;
      else if (fx === 'fadein') vv *= t;
      else if (fx === 'fadeout') vv *= 1 - t;
      freq[i * spf + k] = pitchFreq(p);
      vol[i * spf + k] = vv;
    }
  }

  const env = smooth64(vol);
  const out = new Float32Array(n);
  let ph = 0, ph2 = 0, nph = 0;
  for (let i = 0; i < steps.length; i++) {
    const wave = steps[i][1];
    for (let k = 0; k < spf; k++) {
      const j = i * spf + k;
      ph += freq[j] / SR;
      ph2 += (freq[j] * 1.013) / SR;
      let s;
      if (wave === 'noise') {
        nph += (freq[j] * 4) / SR;
        s = NOISE_TABLE[Math.floor(nph) & NOISE_MASK];
      } else {
        s = osc(wave, ph, ph2);
      }
      out[j] = s * env[j] * 0.8;
    }
  }
  return out;
}

// --------------------------------------------------------------- music ----

function parseSeq(seq) {
  const toks = seq.trim().split(/\s+/);
  const segs = [];
  for (let i = 0; i < toks.length; i++) {
    const tk = toks[i];
    if (tk === '.') {
      const last = segs[segs.length - 1];
      if (last && last.start + last.len === i) last.len += 1;
    } else if (tk !== '-') {
      segs.push({ f0: noteFreq(tk), start: i, len: 1 });
    }
  }
  return { segs, total: toks.length };
}

function renderChannel(ch, stepDur, totalSteps, buf) {
  const amp = ch.vol / 7;
  const { segs } = parseSeq(ch.seq);
  for (const { f0, start, len } of segs) {
    const dur = len * stepDur;
    const m = Math.round((dur + 0.025) * SR);
    const s0 = Math.round(start * stepDur * SR);
    if (ch.wave === 'kick') {
      let ph = 0;
      for (let k = 0; k < m && s0 + k < buf.length; k++) {
        const t = k / SR;
        ph += (160 * Math.exp(-t * 30) + 45) / SR;
        buf[s0 + k] += Math.sin(2 * Math.PI * ph) * Math.exp(-t * 25) * amp;
      }
    } else if (ch.wave === 'snare') {
      for (let k = 0; k < m && s0 + k < buf.length; k++) {
        const t = k / SR;
        const idx = Math.floor((k * 2200 * 4) / SR) & NOISE_MASK;
        buf[s0 + k] += NOISE_TABLE[idx] * Math.exp(-t * 35) * amp;
      }
    } else {
      for (let k = 0; k < m && s0 + k < buf.length; k++) {
        const t = k / SR;
        let env = Math.min(t / 0.003, 1);
        env *= 0.55 + 0.45 * Math.exp(-t / Math.max(dur, 1e-3));
        env *= Math.min(Math.max((dur + 0.025 - t) / 0.025, 0), 1);
        buf[s0 + k] += osc(ch.wave, f0 * t) * env * amp;
      }
    }
  }
}

export function renderMusic(spec) {
  const stepDur = 60 / (spec.bpm * spec.spb);
  const total = Math.max(...spec.channels.map((c) => c.seq.trim().split(/\s+/).length));
  const n = Math.round(total * stepDur * SR);
  const mix = new Float64Array(n + Math.floor(SR / 4));
  for (const ch of spec.channels) renderChannel(ch, stepDur, total, mix);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = Math.tanh(mix[i] * 0.8) * 0.9;
  return out;
}
