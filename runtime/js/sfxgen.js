// sfxgen.js : turn a sound *name* into an sfx.json spec.
//
// The problem this solves: in a real Voxatron cart the sounds live in the
// .vx.png resource tree, not in the Lua. Given a .lua file the audio data does
// not exist anywhere in the input — it is missing content, not something that
// can be extracted. But Voxatron looks audio up **by name** and a missing name
// is silence rather than an error, so the engine is free to decide what a name
// means and can never break a cart by getting it wrong.
//
// Cart authors name sounds semantically ("shoot", "bigboom", "gameover"), so
// generation is two stages:
//
//   1. a keyword lexicon picks an archetype — the shape of the sound;
//   2. a hash of the name seeds variation *within* that archetype, so `boom`
//      and `bigboom` differ, and each is identical on every run and machine.
//
// Output is a spec in audio/sfx.json format, never PCM. That keeps the "two
// renderers, one spec" contract intact (synth.js in the browser,
// tools/sfxgen.py as the reference) and makes generation the first draft of
// authoring: export the spec, tweak it, ship it back as a sidecar pack.
//
// The archetypes are shaped after the 15 hand-authored iso-defender sounds,
// which are effectively a tuned instance of this table.

// ------------------------------------------------------------------ rng ----
// FNV-1a for the seed, then Park-Miller — the same PRNG the rest of the
// project uses. Deterministic across runs, browsers and machines.
function seedFor(name) {
  let h = 0x811c9dc5;
  const s = String(name);
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return ((h >>> 0) % 2147483646) + 1;
}

function rngFrom(seed) {
  let s = seed;
  const next = () => { s = (s * 16807) % 2147483647; return (s - 1) / 2147483646; };
  return {
    next,
    int: (a, b) => a + Math.floor(next() * (b - a + 1)),
    pick: (arr) => arr[Math.floor(next() * arr.length)],
    chance: (p) => next() < p,
  };
}

const clampVol = (v) => Math.max(0, Math.min(7, Math.round(v)));
const clampPitch = (p) => Math.max(0, Math.min(63, Math.round(p)));
// a spec step is [pitch, wave, vol] or [pitch, wave, vol, fx]
const S = (p, w, v, fx) => (fx ? [clampPitch(p), w, clampVol(v), fx]
                               : [clampPitch(p), w, clampVol(v)]);

// falls from `from` to 1 across n steps
const fade = (i, n, from = 6) => from - ((from - 1) * i) / Math.max(1, n - 1);

// ----------------------------------------------------------- archetypes ----
const ARCHETYPES = {
  // pulse, fast downward slide, snappy — fires many times a second, so it has
  // to stay short and out of the way of the explosions
  shoot: (r) => {
    const w = r.pick(['pulse', 'sqr']);
    const top = r.int(46, 56), n = r.int(4, 6), fall = r.int(2, 4);
    return { speed: r.int(1, 2), steps: Array.from({ length: n }, (_, i) =>
      S(top - i * fall, w, fade(i, n), i === 0 ? null : i === n - 1 ? 'fadeout' : 'slide')) };
  },

  // noise + drop, fast attack, exponential-ish tail
  explode: (r) => {
    const top = r.int(24, 36), n = r.int(7, 12);
    return { speed: r.int(4, 6), steps: Array.from({ length: n }, (_, i) =>
      S(top - (i * (top - 4)) / n, 'noise', fade(i, n, 7),
        i === 0 ? null : i < n / 2 ? 'drop' : 'fadeout')) };
  },

  // saw, downward drop, harsh
  hurt: (r) => {
    const top = r.int(34, 42), n = r.int(6, 9);
    return { speed: r.int(2, 3), steps: Array.from({ length: n }, (_, i) =>
      S(top - i * r.int(2, 3) * (1 - i / (n * 2)), 'saw', fade(i, n),
        i === 0 ? null : i < n / 2 ? 'drop' : 'fadeout')) };
  },

  // rising square — the classic hop
  jump: (r) => {
    const base = r.int(30, 38), n = r.int(4, 6), rise = r.int(3, 5);
    return { speed: 1, steps: Array.from({ length: n }, (_, i) =>
      S(base + i * rise, r.pick(['sqr', 'pulse']), fade(i, n, 5),
        i === 0 ? null : i === n - 1 ? 'fadeout' : 'slide')) };
  },

  // two- or three-note blip up: coins, rescues, deliveries
  pickup: (r) => {
    const w = r.pick(['tri', 'organ']);
    const base = r.int(36, 44);
    const iv = r.pick([[0, 4, 7], [0, 5, 7], [0, 7, 12], [0, 3, 7]]);
    const steps = iv.map((d, i) => S(base + d, w, 5 + (i === iv.length - 1 ? 1 : 0)));
    steps.push(S(base + iv[iv.length - 1], w, 3, 'fadeout'));
    return { speed: r.int(2, 4), steps };
  },

  // very short triangle blip: menus, cursors, clicks
  ui: (r) => {
    const base = r.int(42, 50), n = r.int(3, 4);
    return { speed: 1, steps: Array.from({ length: n }, (_, i) =>
      S(base + (i < 2 ? 0 : 2), 'tri', fade(i, n, 4), i === n - 1 ? 'fadeout' : null)) };
  },

  // organ run resolving upward: level clear, success
  win: (r) => {
    const base = r.int(33, 38);
    const scale = r.pick([[0, 4, 7, 11, 12], [0, 4, 7, 12, 16], [0, 5, 7, 12, 14]]);
    const steps = scale.map((d, i) => S(base + d, 'organ', 5 + (i > 2 ? 1 : 0)));
    const top = base + scale[scale.length - 1];
    for (let i = 0; i < r.int(3, 5); i++) steps.push(S(top, 'organ', 5 - i, 'fadeout'));
    return { speed: r.int(4, 6), steps };
  },

  // slow descent: game over, failure
  lose: (r) => {
    const top = r.int(36, 42), n = r.int(5, 7), w = r.pick(['tri', 'saw']);
    return { speed: r.int(6, 8), steps: Array.from({ length: n }, (_, i) =>
      S(top - i * r.int(2, 4), w, fade(i, n, 5), i === n - 1 ? 'fadeout' : null)) };
  },

  // low noise thump: footsteps, landings
  thud: (r) => {
    const n = 3;
    return { speed: r.int(2, 3), steps: Array.from({ length: n }, (_, i) =>
      S(18 - i * 4, 'noise', fade(i, n, 5), i === 0 ? null : 'fadeout')) };
  },

  // phaser sweep with vibrato: warps, teleports
  warp: (r) => {
    const base = r.int(26, 32), n = r.int(8, 11), rise = r.int(2, 3);
    const down = r.chance(0.35);
    return { speed: r.int(2, 4), steps: Array.from({ length: n }, (_, i) =>
      S(base + (down ? -1 : 1) * i * rise, 'phaser',
        i < n - 2 ? 4 + Math.min(2, i) : 3 - (i - (n - 3)),
        i === 0 ? null : i < n - 2 ? 'vib' : 'fadeout')) };
  },

  // two-tone alternating square: alarms, warnings
  alarm: (r) => {
    const lo = r.int(36, 42), hi = lo + r.pick([5, 7, 8]);
    const pairs = r.int(3, 4), steps = [];
    for (let i = 0; i < pairs; i++) {
      steps.push(S(lo, 'sqr', 5), S(lo, 'sqr', 5));
      steps.push(S(hi, 'sqr', 5), S(hi, 'sqr', i === pairs - 1 ? 4 : 5,
        i === pairs - 1 ? 'fadeout' : null));
    }
    return { speed: r.int(4, 6), steps };
  },

  // rising arpeggio: extra life, heal, big reward
  fanfare: (r) => {
    const base = r.int(33, 37), w = r.pick(['sqr', 'pulse']);
    const iv = [0, 4, 7, 12, 7, 12, 16, 19];
    const steps = iv.map((d, i) => S(base + d, w, 5 + (i > 5 ? 1 : 0)));
    for (let i = 0; i < 3; i++) steps.push(S(base + 19, w, 5 - i * 2, i ? 'fadeout' : null));
    return { speed: r.int(3, 5), steps };
  },

  // short tilted-saw click: placing, dropping, ticking
  tick: (r) => {
    const base = r.int(46, 52);
    return { speed: r.int(1, 2), steps: [
      S(base, 'tsaw', 5), S(base, 'tsaw', 4), S(base - 3, 'tsaw', 2, 'fadeout')] };
  },

  // pulse with heavy vibrato, rising and unstable: charging, mutating
  charge: (r) => {
    const base = r.int(28, 34), n = r.int(9, 12);
    return { speed: r.int(3, 5), steps: Array.from({ length: n }, (_, i) =>
      S(base + i * 1.2, 'pulse', i < n - 3 ? 4 + Math.min(2, i / 3) : 4 - (i - (n - 4)),
        i === 0 ? null : i < n - 3 ? 'vib' : 'fadeout')) };
  },
};

// First match wins, so order is specificity order. Every one of the reference
// cart's 15 sound names lands on a sensible archetype here.
//
// Two kinds of keyword, because plain substring matching is a trap: `ow` for
// "ouch" also fires inside "unkn-ow-n", and `get` inside "tar-get".
//   words  matched against whole tokens (split on non-alphanumerics and
//          camelCase), so short ones are safe;
//   parts  matched as substrings of the punctuation-stripped name, so
//          "game_over", "game-over" and "gameOver" all hit "gameover". Keep
//          these four characters or longer.
const LEXICON = [
  { arch: 'fanfare', words: ['1up', 'oneup', 'life', 'lives'],
    parts: ['extralife', 'levelup', 'heal', 'health', 'revive', 'powerup'] },
  { arch: 'shoot', words: ['fire', 'gun', 'pew', 'shot'],
    parts: ['shoot', 'laser', 'bullet', 'missile', 'beam', 'blaster', 'plasma'] },
  { arch: 'explode', words: ['die', 'dead', 'kill'],
    parts: ['boom', 'bomb', 'explo', 'blast', 'burst', 'destro', 'detonat', 'crash', 'smash'] },
  { arch: 'hurt', words: ['ow', 'hit', 'hurt'],
    parts: ['damage', 'ouch', 'pain', 'injur', 'wound'] },
  { arch: 'jump', words: ['hop'],
    parts: ['jump', 'leap', 'bounce', 'spring'] },
  { arch: 'pickup', words: ['get', 'gem', 'coin', 'star', 'item'],
    parts: ['pickup', 'collect', 'loot', 'reward', 'bonus', 'rescue', 'deliver', 'score', 'gather'] },
  { arch: 'lose', words: ['lose', 'lost', 'fail'],
    parts: ['gameover', 'defeat', 'failure'] },
  { arch: 'win', words: ['win', 'won'],
    parts: ['victor', 'complete', 'success', 'clear', 'finish', 'fanfare', 'jingle', 'triumph'] },
  { arch: 'warp', words: ['dash', 'zoom'],
    parts: ['warp', 'teleport', 'portal', 'whoosh', 'swoosh'] },
  { arch: 'alarm', words: ['error', 'deny', 'buzz'],
    parts: ['alarm', 'alert', 'warn', 'danger', 'siren', 'invalid'] },
  { arch: 'thud', words: ['step', 'land', 'thud', 'walk', 'foot'],
    parts: ['stomp', 'impact', 'footstep', 'landing'] },
  { arch: 'charge', words: ['grow', 'spawn'],
    parts: ['mutate', 'charge', 'power', 'morph', 'transform', 'summon'] },
  { arch: 'ui', words: ['ui', 'click', 'menu', 'beep', 'blip', 'move', 'nav', 'tab'],
    parts: ['select', 'cursor', 'button', 'toggle', 'navigate', 'hover'] },
  { arch: 'tick', words: ['mine', 'drop', 'tap', 'type', 'key', 'tick'],
    parts: ['place'] },
];

// Nothing matched: still pick deterministically from the harmless middle of
// the table rather than defaulting everything to one sound.
const FALLBACKS = ['ui', 'tick', 'pickup', 'shoot', 'thud', 'jump'];

export function archetypeFor(name) {
  const s = String(name).toLowerCase();
  const flat = s.replace(/[^a-z0-9]/g, '');
  const tokens = new Set(String(name)
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')     // camelCase -> two tokens
    .toLowerCase().split(/[^a-z0-9]+/).filter(Boolean));
  for (const { arch, words, parts } of LEXICON) {
    if (words.some((w) => tokens.has(w))) return arch;
    if (parts.some((p) => flat.includes(p))) return arch;
  }
  return FALLBACKS[seedFor(s) % FALLBACKS.length];
}

export function specForSfx(name) {
  const r = rngFrom(seedFor(String(name).toLowerCase()));
  return ARCHETYPES[archetypeFor(name)](r);
}

// ---------------------------------------------------------------- music ----
const NOTE_NAMES = ['c', 'c#', 'd', 'd#', 'e', 'f', 'f#', 'g', 'g#', 'a', 'a#', 'b'];
const MINOR = [0, 2, 3, 5, 7, 8, 10];
const MAJOR = [0, 2, 4, 5, 7, 9, 11];
// leads stay pentatonic: it is the cheapest way to keep generated melody from
// landing on the intervals that make procedural music grate
const PENT_MINOR = [0, 3, 5, 7, 10];
const PENT_MAJOR = [0, 2, 4, 7, 9];

const noteName = (semi, octave) => {
  const n = ((semi % 12) + 12) % 12;
  return NOTE_NAMES[n] + (octave + Math.floor(semi / 12));
};

// stingers (game over, victory, a level jingle) play once; everything else loops
const ONESHOT = ['gameover', 'defeat', 'victor', 'jingle', 'clear', 'fanfare',
                 'complete', 'lose', 'fail', 'win'];

export function specForMusic(name) {
  const key = String(name).toLowerCase();
  const flat = key.replace(/[^a-z0-9]/g, '');
  const r = rngFrom(seedFor(key));
  const loop = !ONESHOT.some((w) => flat.includes(w));

  const minor = r.chance(0.65);
  const scale = minor ? MINOR : MAJOR;
  const pent = minor ? PENT_MINOR : PENT_MAJOR;
  const root = r.int(-3, 4);                 // semitones from C
  const spb = 4;
  const bpm = loop ? r.int(88, 138) : r.int(70, 120);

  // i–VI–III–VII / i–iv–v–i style walks, kept diatonic
  const prog = r.pick(minor
    ? [[0, 5, 2, 6], [0, 3, 4, 0], [0, 5, 3, 4], [0, 6, 5, 4]]
    : [[0, 5, 3, 4], [0, 3, 4, 4], [0, 4, 5, 3], [0, 2, 3, 4]]);
  const bars = loop ? 4 : 2;
  const perBar = 16;
  const total = bars * perBar;

  const bass = [], lead = [], pad = [], kick = [], snare = [];
  for (let b = 0; b < bars; b++) {
    const deg = prog[b % prog.length];
    const chordRoot = root + scale[deg % scale.length];
    for (let i = 0; i < perBar; i++) {
      // bass: root on the downbeat and the half-bar
      bass.push(i === 0 || i === 8 ? noteName(chordRoot, 2) : i === 1 || i === 9 ? '.' : '-');
      // pad: one long chord tone per bar
      pad.push(i === 0 ? noteName(chordRoot, 3) : '.');
      // lead: pentatonic walk on the eighths, with rests for breathing room
      if (i % 2 === 0 && r.chance(0.72)) {
        const d = pent[r.int(0, pent.length - 1)];
        lead.push(noteName(root + d + (r.chance(0.25) ? 12 : 0), 4));
      } else {
        lead.push(i % 2 === 1 ? '.' : '-');
      }
      kick.push(i % 4 === 0 ? 'c2' : '-');
      snare.push(i % 8 === 4 ? 'c3' : '-');
    }
  }
  // let the last note ring rather than cutting off at the loop point
  for (let i = total - 2; i < total; i++) if (lead[i] === '-') lead[i] = '.';

  const channels = [
    { wave: 'saw', vol: 5, seq: bass.join(' ') },
    { wave: r.pick(['pulse', 'tri']), vol: 4, seq: lead.join(' ') },
    { wave: r.pick(['organ', 'phaser']), vol: 2, seq: pad.join(' ') },
  ];
  if (loop || r.chance(0.5)) {
    channels.push({ wave: 'kick', vol: 6, seq: kick.join(' ') });
    channels.push({ wave: 'snare', vol: 3, seq: snare.join(' ') });
  }
  return { bpm, spb, loop, channels };
}
