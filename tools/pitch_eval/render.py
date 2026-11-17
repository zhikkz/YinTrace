#!/usr/bin/env python3
"""Renders MIR-1K clips into the test conditions of the pitch evaluation.

    python tools/pitch_eval/render.py <MIR-1K dir> <out dir> [--every N]

MIR-1K (Hsu and Jang, 2010; http://mirlab.org/dataset/public/MIR-1K.zip):
1000 clips of Chinese pop songs sung by 19 amateur singers, 16 kHz stereo
with the accompaniment on the left and the voice on the right, and the
voice's pitch labelled by hand (`PitchLabel/*.pv`). It is not in the
training data of SwiftF0 0.3.0 (MDB-stem-synth, NSynth, PTDB-TUG,
MOCHA-TIMIT, CMU Arctic). The data stays on your machine; nothing of it
goes into the repository.

The clips are taken in name order, at most 16 per singer (spread over the
singer's clips), or every N-th of those. Each becomes 16 kHz mono float32
files, peak at -6 dBFS:

- clean: the voice alone (a separated vocal at its best, or the singer
  through headphones);
- mix+5, mix+0: the voice with the accompaniment 5 dB below it and at the
  same energy. mix+0 is MIR-1K's usual mix: `separate.dart` separates it
  the way an import does (sep+0), which is what the app measures. As
  conditions of their own they are stress tests: accompaniment left in a
  poorly separated vocal, or a phone speaker heard by the microphone
  while practising. The app never measures the pitch of a mix;
- reverb: the voice with a room (RT60 0.9 s) added at -3 dB (most
  commercial vocals).
"""
import argparse
import collections
import json
import os
import wave

import numpy as np


def rir(seconds=1.2, rt60=0.9, sr=16000, seed=0):
    r = np.random.default_rng(seed)
    n = int(seconds * sr)
    t = np.arange(n) / sr
    h = r.standard_normal(n) * np.exp(-6.9 * t / rt60)
    h = np.convolve(h, np.ones(4) / 4, mode='same')
    h[:int(0.02 * sr)] *= np.linspace(0, 1, int(0.02 * sr))
    return h / np.sqrt(np.sum(h ** 2))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('mir1k')
    p.add_argument('out')
    p.add_argument('--every', type=int, default=1)
    args = p.parse_args()
    os.makedirs(args.out, exist_ok=True)
    names = sorted(f[:-4] for f in os.listdir(os.path.join(args.mir1k, 'Wavfile')) if f.endswith('.wav'))
    by = collections.defaultdict(list)
    for n in names:
        by[n.split('_')[0]].append(n)
    pick = []
    for _, clips in sorted(by.items()):
        pick += clips[::max(1, len(clips) // 16)][:16]
    pick = pick[::args.every]
    h = rir()
    meta = []
    for name in pick:
        w = wave.open(os.path.join(args.mir1k, 'Wavfile', name + '.wav'))
        assert w.getframerate() == 16000 and w.getnchannels() == 2
        x = np.frombuffer(w.readframes(w.getnframes()), '<i2').reshape(-1, 2).astype(np.float64) / 32768
        acc, voc = x[:, 0], x[:, 1]
        labels = [float(v) for v in open(os.path.join(args.mir1k, 'PitchLabel', name + '.pv')).read().split()]
        ev, ea = np.sum(voc ** 2), np.sum(acc ** 2)
        conds = {'clean': voc}
        for sar in (5, 0):
            conds[f'mix{sar:+d}'] = voc + np.sqrt(ev / max(ea, 1e-12) / 10 ** (sar / 10)) * acc
        wet = np.convolve(voc, h)[:len(voc)]
        conds['reverb'] = voc + 0.7 * wet * np.sqrt(ev / max(np.sum(wet ** 2), 1e-12))
        for c, y in conds.items():
            (y / max(1e-9, np.max(np.abs(y))) * 0.5).astype('<f4').tofile(os.path.join(args.out, f'{name}.{c}.f32'))
        meta.append({'name': name, 'samples': len(voc), 'labels': labels})
    json.dump({'conditions': ['clean', 'mix+5', 'mix+0', 'reverb'], 'clips': meta},
              open(os.path.join(args.out, 'meta.json'), 'w'))
    print(f'{len(meta)} clips from {len(by)} singers')


if __name__ == '__main__':
    main()
