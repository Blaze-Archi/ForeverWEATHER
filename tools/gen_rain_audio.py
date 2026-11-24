#!/usr/bin/env python3
"""ForeverWEATHER 1.6: synthesises the rain loops in art/sound/rainPuddles/.

Everything is generated, nothing is recorded or taken from anywhere, so the sounds carry no licence of their own.
Each loop is built on a circular buffer: the noise is shaped in the frequency domain over the whole buffer and every
drop impact is added modulo the buffer length, so the end runs seamlessly into the start (no crossfade, no click).

  rain_light.ogg    sparse drops ticking on the ground and leaves, a soft hiss behind them
  rain_heavy.ogg    a downpour: a dense roar of countless drops with a low rush under it
  rain_muffled.ogg  that downpour heard through a roof or a car body (low-passed, the highs gone)
  rain_roof.ogg     rain drumming on a car's roof heard from inside: dense, dull taps over a low rush (1.6.1)

Usage:  python3 tools/gen_rain_audio.py [out_dir]       (needs numpy; ffmpeg with libvorbis for the .ogg files)
"""
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

SR = 44100
SECONDS = 10.0
N = int(SR * SECONDS)
rng = np.random.default_rng(20261123)


def shaped_noise(n, shape):
    """White noise shaped by a magnitude response shape(freqs_hz) over a circular buffer (seamless loop)."""
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1.0 / SR)
    spec *= shape(f)
    out = np.fft.irfft(spec, n)
    return out / (np.std(out) + 1e-12)


def lowpass(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def highpass(f, fc, order=2):
    x = (f / max(fc, 1e-3)) ** (2 * order)
    return np.sqrt(x / (1.0 + x))


def pink(f):
    return 1.0 / np.sqrt(np.maximum(f, 20.0))


def circular_convolve(signal, kernel):
    n = len(signal)
    k = np.zeros(n)
    k[:len(kernel)] = kernel
    return np.fft.irfft(np.fft.rfft(signal) * np.fft.rfft(k), n)


def impulses(n, rate, amp_shape=2.5):
    """A sparse train of drop impacts: Poisson times, amplitudes from a heavy-tailed law (a few big drops)."""
    count = rng.poisson(rate * n / SR)
    train = np.zeros(n)
    pos = rng.integers(0, n, count)
    amp = rng.pareto(amp_shape, count) + 0.2
    amp /= np.percentile(amp, 99) + 1e-9
    np.add.at(train, pos, np.minimum(amp, 1.5) * rng.choice([-1.0, 1.0], count))
    return train


def grain_noise(ms, lo, hi):
    """A drop hitting the ground: a few milliseconds of band-limited noise (most of a real drop's tick lies between
    about 1 and 6 kHz), a fast attack and an exponential tail."""
    m = max(int(SR * ms / 1000.0), 8)
    t = np.arange(m) / SR
    env = (1.0 - np.exp(-t / 0.0002)) * np.exp(-t / (ms / 1000.0 / 3.0))
    pad = 4 * m
    f = np.fft.rfftfreq(pad, 1.0 / SR)
    g = np.fft.irfft(np.fft.rfft(rng.standard_normal(pad)) * highpass(f, lo) * lowpass(f, hi), pad)[:m]
    return g / (np.std(g) + 1e-12) * env


def grain_tap(ms, lo, hi, thump_hz, thump_ms, thump_amp):
    """1.6.1: a drop on a car's roof heard from inside: a short, dull tap (band-limited noise - the headliner takes the
    highs) and, the bigger the drop, a quick thump of the panel. The thump is damped within a few cycles (Q of about 1 to
    4), so it has no pitch and does not ring: a lined steel roof drums under rain, it does not jingle."""
    tap = grain_noise(ms, lo, hi)
    m = max(len(tap), int(SR * thump_ms * 6 / 1000.0))
    t = np.arange(m) / SR
    out = np.zeros(m)
    out[:len(tap)] += tap
    if thump_amp > 0.0:
        out += (thump_amp * np.sin(2 * np.pi * thump_hz * t + rng.uniform(0, 2 * np.pi))
                * np.exp(-t / (thump_ms / 1000.0)) * (1.0 - np.exp(-t / 0.0006)))
    return out


def drops(n, rate, grains, amp_shape=2.5):
    out = np.zeros(n)
    for g in grains:
        out += circular_convolve(impulses(n, rate / len(grains), amp_shape), g)
    return out / (np.std(out) + 1e-12)


def stereo(make):
    """Two decorrelated channels of the same recipe (a wide, enveloping ambience for a 2D sound)."""
    return np.stack([make(), make()], axis=1)


def normalise(x, rms_db=-17.0, peak_db=-4.5):   # (Vorbis overshoots sharp ticks by up to ~3 dB)
    x = x / (np.sqrt(np.mean(x ** 2)) + 1e-12) * 10 ** (rms_db / 20.0)
    lim = 10 ** (peak_db / 20.0)
    # soft knee for the rare biggest drops instead of turning everything down: linear below 70 % of the limit, then
    # bent smoothly toward it (never beyond)
    knee = 0.7 * lim
    a = np.abs(x)
    over = a > knee
    a[over] = knee + (lim - knee) * np.tanh((a[over] - knee) / (lim - knee))
    return np.sign(x) * a


def light():
    hiss = shaped_noise(N, lambda f: highpass(f, 500) * lowpass(f, 6000) * pink(f)) * 0.3
    ticks = drops(N, 55, [grain_noise(2.5, 900, 6000), grain_noise(4.0, 400, 3500), grain_noise(1.5, 1500, 7000)], 2.2)
    patter = drops(N, 160, [grain_noise(1.2, 1200, 6000)], 3.5) * 0.35
    return hiss + ticks + patter


def heavy():
    roar = shaped_noise(N, lambda f: highpass(f, 200) * lowpass(f, 5000) * pink(f) ** 0.8)
    rush = shaped_noise(N, lambda f: highpass(f, 40) * lowpass(f, 350)) * 0.5
    dense = drops(N, 1800, [grain_noise(1.5, 800, 6000), grain_noise(3.0, 400, 3000), grain_noise(2.0, 1000, 5000)], 3.0) * 0.5
    big = drops(N, 70, [grain_noise(6.0, 200, 2000)], 2.0) * 0.3
    return roar + rush + dense + big


def muffled(src):
    # through a roof or a car body: the highs go first (two poles at 450 Hz), a little low-mid boom remains
    return circular_filter(src, lambda f: lowpass(f, 550, 2) * (1.0 + 0.6 * np.exp(-((f - 140.0) / 90.0) ** 2)))


def circular_filter(x, shape):
    f = np.fft.rfftfreq(len(x), 1.0 / SR)
    return np.fft.irfft(np.fft.rfft(x) * shape(f), len(x))


def roof():
    # 1.6.1: rain drumming on a car's roof heard from inside. A dense patter of short, dull taps, the bigger drops with a
    # quick, heavily damped thump of the panel, over the low rush of the drumming; the lined roof softens everything
    # above about 2.5 kHz and the cabin adds a little low boom. Dozens of different taps, each on a random train of its
    # own, so nothing repeats and nothing rings. (1.6.0: six ringing metal pings at 1.7 to 3.6 kHz - it jingled.)
    taps = drops(N, 600, [grain_tap(rng.uniform(0.8, 2.5), rng.uniform(200, 400), rng.uniform(1300, 2800),
                                    rng.uniform(120, 260), rng.uniform(2.0, 4.0), rng.uniform(0.0, 0.5))
                          for _ in range(32)], 3.0)
    big = drops(N, 45, [grain_tap(rng.uniform(3.0, 6.0), rng.uniform(100, 200), rng.uniform(800, 1500),
                                  rng.uniform(80, 170), rng.uniform(4.0, 7.0), rng.uniform(0.8, 1.4))
                        for _ in range(16)], 2.2) * 0.8
    rush = shaped_noise(N, lambda f: highpass(f, 60) * lowpass(f, 700) * pink(f) ** 0.5) * 0.35
    return circular_filter(taps + big + rush,
                           lambda f: lowpass(f, 2500, 2) * (1.0 + 0.35 * np.exp(-((f - 170.0) / 110.0) ** 2)))


def write_wav(path, x):
    pcm = (np.clip(x, -1.0, 1.0) * 32767.0).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(pcm.shape[1] if pcm.ndim == 2 else 1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'art', 'sound', 'rainPuddles')
    os.makedirs(out_dir, exist_ok=True)
    heavy_st = stereo(heavy)
    sounds = {
        'rain_light': normalise(stereo(light), -19.0, -7.0),       # (its crisp ticks overshoot most in Vorbis)
        'rain_heavy': normalise(heavy_st, -16.0),
        'rain_muffled': normalise(np.stack([muffled(heavy_st[:, 0]), muffled(heavy_st[:, 1])], axis=1), -18.0),
        'rain_roof': normalise(stereo(roof), -18.0),
    }
    with tempfile.TemporaryDirectory() as tmp:
        for name, x in sounds.items():
            wav = os.path.join(tmp, name + '.wav')
            write_wav(wav, x)
            ogg = os.path.join(out_dir, name + '.ogg')
            subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', wav, '-c:a', 'libvorbis', '-q:a', '3', ogg],
                           check=True)
            print('%-14s %6.1f KB' % (name, os.path.getsize(ogg) / 1024.0))


if __name__ == '__main__':
    main()
