#!/usr/bin/env python3
"""Generates reference outputs (numpy / torch / scipy / librosa) used by the
Dart DSP tests in test/dsp_test.dart.

    python tools/reference/make_dsp_fixtures.py test/fixtures

Requires: numpy, scipy, torch, librosa.
"""
import json
import os
import sys

import numpy as np
import scipy.signal
import torch
import librosa


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    rng = np.random.default_rng(1234)
    fx = {}

    # rfft / irfft
    for n in (16, 960, 7680):
        x = rng.standard_normal(n)
        X = np.fft.rfft(x)
        fx[f'rfft_{n}'] = {'x': x.tolist(), 're': X.real.tolist(), 'im': X.imag.tolist()}

    # torch.stft / istft (reflect padding, periodic hann)
    sig = rng.standard_normal(5000).astype(np.float32)
    for n_fft, hop in ((512, 128), (960, 480), (7680, 1024)):
        w = torch.hann_window(n_fft, periodic=True)
        S = torch.stft(torch.from_numpy(sig), n_fft=n_fft, hop_length=hop, window=w,
                       center=True, return_complex=True).numpy()
        y = torch.istft(torch.from_numpy(S), n_fft=n_fft, hop_length=hop, window=w,
                        center=True).numpy()
        # Only keep a few bins/frames to bound the fixture size.
        fx[f'stft_{n_fft}_{hop}'] = {
            'bins': S.shape[0], 'frames': S.shape[1],
            'probe': [[int(b), int(t), float(S[b, t].real), float(S[b, t].imag)]
                      for b, t in [(0, 0), (3, 1), (S.shape[0] // 2, S.shape[1] // 2),
                                   (S.shape[0] - 1, S.shape[1] - 1), (10, S.shape[1] - 1)]],
            'istft_len': int(y.shape[0]),
            'istft_probe': [[i, float(y[i])] for i in (0, 1, 100, y.shape[0] // 2, y.shape[0] - 1)],
        }
    fx['stft_signal'] = sig.tolist()

    # librosa (constant padding in librosa >= 0.10)
    S = librosa.stft(sig, n_fft=640, hop_length=432)
    fx['librosa_640_432'] = {
        'bins': S.shape[0], 'frames': S.shape[1],
        'probe': [[0, 0, float(S[0, 0].real), float(S[0, 0].imag)],
                  [50, 3, float(S[50, 3].real), float(S[50, 3].imag)],
                  [320, S.shape[1] - 1, float(S[320, -1].real), float(S[320, -1].imag)]],
    }

    # scipy.signal.resample_poly
    t = np.arange(4410) / 44100.0
    tone = (np.sin(2 * np.pi * 440 * t) + 0.3 * np.sin(2 * np.pi * 5000 * t)).astype(np.float64)
    for (a, b) in ((44100, 22050), (44100, 14700), (7350, 14700), (22050, 44100), (44100, 48000)):
        y = scipy.signal.resample_poly(tone, b, a)
        fx[f'resample_{a}_{b}'] = {'len': int(y.shape[0]),
                                   'probe': [[i, float(y[i])] for i in (0, 5, y.shape[0] // 3, y.shape[0] - 1)]}
    fx['resample_signal'] = tone.tolist()

    with open(os.path.join(out_dir, 'dsp_reference.json'), 'w') as f:
        json.dump(fx, f)
    print('wrote', os.path.join(out_dir, 'dsp_reference.json'))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'test/fixtures')
