#!/usr/bin/env python3
"""voxbox phase 4: reference audio synthesiser (numpy).

Renders audio/sfx.json — PICO-8-style SFX steps and tracker-lite music —
to PCM. This is the spec; runtime/js/synth.js mirrors it operation for
operation (same waveforms, same envelopes, same Park-Miller noise seed),
so both produce the same sounds from the same JSON.

Usage:
    python3 tools/sfxgen.py --wavs out_dir     # render everything to WAV
    python3 tools/sfxgen.py --stats            # per-sound duration/RMS/centroid
"""
import argparse
import json
import os
import wave

import numpy as np

SR = 22050
A4_PITCH = 33          # PICO-8 pitch units: 33 = A4 = 440 Hz
HERE = os.path.dirname(os.path.abspath(__file__))
SPEC_PATH = os.path.join(os.path.dirname(HERE), "audio", "sfx.json")

NOTE_SEM = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}


def pitch_freq(p):
    """PICO-8 pitch units -> Hz."""
    return 440.0 * 2.0 ** ((p - A4_PITCH) / 12.0)


def note_freq(token):
    """'c3' / 'f#2' / 'bb1' -> Hz (c4 = 261.63)."""
    name = token[0]
    rest = token[1:]
    sem = NOTE_SEM[name]
    if rest.startswith("#"):
        sem += 1
        rest = rest[1:]
    elif rest.startswith("b") and len(rest) > 1:
        sem += -1
        rest = rest[1:]
    octave = int(rest)
    return 440.0 * 2.0 ** ((sem + 12 * octave - 57) / 12.0)


def lcg_noise(n, seed=1234):
    """Park-Miller LCG noise in [-1,1] — identical sequence in synth.js."""
    out = np.empty(n)
    s = seed
    for i in range(n):
        s = (s * 16807) % 2147483647
        out[i] = (s / 2147483647.0) * 2.0 - 1.0
    return out


# one shared noise table; indexed by sample-and-hold phase for pitched noise
NOISE_TABLE = lcg_noise(1 << 15)
NOISE_MASK = (1 << 15) - 1


def tri(ph):
    x = ph % 1.0
    return 1.0 - 4.0 * np.abs(x - 0.5)


def osc(wave_name, ph, ph2=None):
    x = ph % 1.0
    if wave_name == "tri":
        return tri(ph)
    if wave_name == "tsaw":
        return np.where(x < 0.875, x / 0.875 * 2 - 1, (1 - x) / 0.125 * 2 - 1)
    if wave_name == "saw":
        return 2 * x - 1
    if wave_name == "sqr":
        return np.where(x < 0.5, 1.0, -1.0)
    if wave_name == "pulse":
        return np.where(x < 0.3125, 1.0, -1.0)
    if wave_name == "organ":
        return 0.7 * tri(ph) + 0.3 * tri(ph * 2.0)
    if wave_name == "phaser":
        return 0.5 * tri(ph) + 0.5 * tri(ph2 if ph2 is not None else ph * 1.013)
    raise ValueError(wave_name)


def smooth(a, win):
    if win <= 1:
        return a
    k = np.ones(win) / win
    return np.convolve(a, k, mode="same")


# ---------------------------------------------------------------- sfx ------

def render_sfx(spec):
    """spec = {speed, steps:[[pitch, wave, vol, fx?], ...]} -> float32 mono."""
    speed = spec["speed"]
    steps = spec["steps"]
    spf = int(round(SR * speed / 120.0))     # samples per step
    n = spf * len(steps)
    freq = np.empty(n)
    vol = np.empty(n)
    wave_of_step = []

    for i, st in enumerate(steps):
        pitch, wave_name, v = st[0], st[1], st[2]
        fx = st[3] if len(st) > 3 else "none"
        sl = slice(i * spf, (i + 1) * spf)
        t = np.linspace(0.0, 1.0, spf, endpoint=False)
        p = np.full(spf, float(pitch))
        vv = np.full(spf, v / 7.0)
        if fx == "slide" and i > 0:
            p = steps[i - 1][0] + (pitch - steps[i - 1][0]) * t
        elif fx == "vib":
            p = pitch + 0.3 * np.sin(2 * np.pi * 7.5 * t * (speed / 120.0))
        elif fx == "drop":
            p = pitch - 12.0 * t
        elif fx == "fadein":
            vv = vv * t
        elif fx == "fadeout":
            vv = vv * (1.0 - t)
        freq[sl] = pitch_freq(p)
        vol[sl] = vv
        wave_of_step.append(wave_name)

    vol = smooth(vol, 64)                      # declick
    ph = np.cumsum(freq) / SR
    ph2 = np.cumsum(freq * 1.013) / SR         # phaser detune partner

    out = np.empty(n)
    for i, wave_name in enumerate(wave_of_step):
        sl = slice(i * spf, (i + 1) * spf)
        if wave_name == "noise":
            idx = (np.cumsum(freq[sl]) * 4.0 / SR).astype(np.int64) & NOISE_MASK
            out[sl] = NOISE_TABLE[idx]
        else:
            out[sl] = osc(wave_name, ph[sl], ph2[sl])
    return (out * vol * 0.8).astype(np.float32)


# --------------------------------------------------------------- music -----

def parse_seq(seq):
    """token list -> [(freq_or_None, start_step, n_steps)] ('.' extends)."""
    toks = seq.split()
    segs = []
    for i, tk in enumerate(toks):
        if tk == ".":
            if segs and segs[-1][1] + segs[-1][2] == i:
                f, s, ln = segs[-1]
                segs[-1] = (f, s, ln + 1)
        elif tk != "-":
            segs.append((note_freq(tk), i, 1))
    return segs, len(toks)


def render_channel(ch, step_dur, total_steps):
    n = int(round(total_steps * step_dur * SR))
    buf = np.zeros(n + SR // 4)                 # room for release tails
    wave_name = ch["wave"]
    amp = ch["vol"] / 7.0
    segs, _ = parse_seq(ch["seq"])

    for f0, start, ln in segs:
        dur = ln * step_dur
        m = int(round((dur + 0.025) * SR))      # +25 ms release tail
        t = np.arange(m) / SR
        if wave_name == "kick":
            freq = 160.0 * np.exp(-t * 30.0) + 45.0
            ph = np.cumsum(freq) / SR
            seg = np.sin(2 * np.pi * ph) * np.exp(-t * 25.0)
        elif wave_name == "snare":
            idx = (np.arange(m) * 2200 * 4 // SR).astype(np.int64) & NOISE_MASK
            seg = NOISE_TABLE[idx] * np.exp(-t * 35.0)
        else:
            ph = f0 * t
            seg = osc(wave_name, ph)
            # pluck-ish: fast attack, decay to 55%, release after note end
            env = np.minimum(t / 0.003, 1.0)
            env *= 0.55 + 0.45 * np.exp(-t / max(dur, 1e-3))
            env *= np.clip((dur + 0.025 - t) / 0.025, 0.0, 1.0)
            seg = seg * env
        s0 = int(round(start * step_dur * SR))
        buf[s0:s0 + m] += seg * amp
    return buf[:n]


def render_music(spec):
    step_dur = 60.0 / (spec["bpm"] * spec["spb"])
    total = max(len(ch["seq"].split()) for ch in spec["channels"])
    mix = np.zeros(int(round(total * step_dur * SR)))
    for ch in spec["channels"]:
        mix += render_channel(ch, step_dur, total)
    mix = np.tanh(mix * 0.8) * 0.9              # soft clip
    return mix.astype(np.float32)


# ---------------------------------------------------------------- io -------

def load_spec(path=SPEC_PATH):
    with open(path) as f:
        return json.load(f)


def render_all(spec):
    out = {}
    for name, s in spec["sfx"].items():
        out[name] = render_sfx(s)
    for name, s in spec["music"].items():
        out[name] = render_music(s)
    return out


def write_wav(path, samples):
    pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def stats(samples):
    rms = float(np.sqrt(np.mean(samples ** 2)))
    mag = np.abs(np.fft.rfft(samples.astype(np.float64)))
    freqs = np.fft.rfftfreq(len(samples), 1.0 / SR)
    centroid = float((freqs * mag).sum() / max(mag.sum(), 1e-9))
    return {"dur": round(len(samples) / SR, 3), "rms": round(rms, 4),
            "centroid_hz": round(centroid, 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wavs", metavar="DIR", help="render all sounds to WAVs")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--spec", metavar="FILE", default=SPEC_PATH,
                    help="pack to render (default: audio/sfx.json). Point this "
                         "at a pack exported from the browser to listen to "
                         "auto-generated sounds on the desktop.")
    args = ap.parse_args()

    bank = render_all(load_spec(args.spec))
    if args.wavs:
        os.makedirs(args.wavs, exist_ok=True)
        for name, samples in bank.items():
            write_wav(os.path.join(args.wavs, f"{name}.wav"), samples)
        print(f"wrote {len(bank)} wavs to {args.wavs}")
    if args.stats or not args.wavs:
        for name, samples in bank.items():
            print(f"{name:10s} {stats(samples)}")


if __name__ == "__main__":
    main()
