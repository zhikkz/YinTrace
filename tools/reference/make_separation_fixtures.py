#!/usr/bin/env python3
"""Reference outputs for the Dart MDX / VR separation ports.

Runs UVR's own processing code (``lib_v5/spec_utils.py`` and the MDX
``demix`` loop from ``separate.py``) on a synthetic signal with deterministic
fake "models", and stores probes of the result in
``test/fixtures/separation_reference.json``. ``test/separation_test.dart``
runs the Dart pipelines with the same fake models and compares.

    python tools/reference/make_separation_fixtures.py --uvr /path/to/ultimatevocalremovergui

Requires numpy, scipy, torch, librosa, soundfile.
"""
import argparse
import json
import os
import sys
import types

import numpy as np

SR = 44100


def synth(seconds: float) -> np.ndarray:
    """Deterministic stereo test signal, shape (2, n), float32."""
    n = int(seconds * SR)
    t = np.arange(n, dtype=np.float64) / SR
    left = (0.30 * np.sin(2 * np.pi * 220.0 * t) + 0.20 * np.sin(2 * np.pi * 523.25 * t + 0.3)
            + 0.10 * np.sin(2 * np.pi * 3100.0 * t) + 0.05 * np.sin(2 * np.pi * 9000.0 * t + 1.1))
    right = (0.25 * np.sin(2 * np.pi * 330.0 * t + 0.7) + 0.20 * np.sin(2 * np.pi * 523.25 * t)
             + 0.08 * np.sin(2 * np.pi * 6200.0 * t))
    env = 0.6 + 0.4 * np.sin(2 * np.pi * 0.5 * t)
    return np.stack([left * env, right * env]).astype(np.float32)


# ---------------------------------------------------------------- fake models
def fake_mdx(spek: np.ndarray) -> np.ndarray:
    """[B, 4, F, T] -> same; frequency dependent gain + channel crosstalk."""
    f = np.arange(spek.shape[2], dtype=np.float32)
    g = (0.25 + 0.5 * (f % 7) / 6.0)[None, None, :, None]
    out = spek * g
    out[:, 0] += 0.1 * spek[:, 2]
    out[:, 1] += 0.1 * spek[:, 3]
    return out.astype(np.float32)


def fake_vr(x: np.ndarray) -> np.ndarray:
    """[B, 2, bins+1, W] magnitude -> mask in (0, 1)."""
    f = np.arange(x.shape[2], dtype=np.float32)[None, :, None]
    m0 = 1 / (1 + np.exp(-(6 * x[:, 0] - 3 * x[:, 1] + 0.01 * f - 1)))
    m1 = 1 / (1 + np.exp(-(5 * x[:, 1] + 0.005 * f - 0.5)))
    return np.stack([m0, m1], axis=1).astype(np.float32)


# ---------------------------------------------------------------- MDX (UVR separate.py)
def mdx_demix(mix, n_fft=7680, hop=1024, dim_f=3072, dim_t=256, overlap=0.25, compensate=1.021, model=None):
    """UVR's MDX demix loop. [model] maps a [1, 4, F, T] array to its prediction."""
    model = model or fake_mdx
    import torch
    trim = n_fft // 2
    chunk_size = hop * (dim_t - 1)
    gen_size = chunk_size - 2 * trim
    pad = gen_size + trim - (mix.shape[-1] % gen_size)
    mixture = np.concatenate((np.zeros((2, trim), dtype='float32'), mix, np.zeros((2, pad), dtype='float32')), 1)
    step = int((1 - overlap) * chunk_size)
    result = np.zeros((1, 2, mixture.shape[-1]), dtype=np.float32)
    divider = np.zeros((1, 2, mixture.shape[-1]), dtype=np.float32)
    window_t = torch.hann_window(window_length=n_fft, periodic=True)

    def stft(x):
        x = x.reshape([-1, x.shape[-1]])
        x = torch.stft(input=x, n_fft=n_fft, hop_length=hop, window=window_t, center=True, return_complex=True)
        x = torch.view_as_real(x).permute([0, 3, 1, 2])
        x = x.reshape([1, 2, 2, -1, x.shape[-1]]).reshape([1, 4, -1, x.shape[-1]])
        return x[..., :dim_f, :]

    def istft(x):
        n_bins = n_fft // 2 + 1
        x = torch.cat([x, torch.zeros([1, 4, n_bins - x.shape[2], x.shape[3]])], -2)
        x = x.reshape([1, 2, 2, n_bins, x.shape[3]]).reshape([-1, 2, n_bins, x.shape[3]])
        x = x.permute([0, 2, 3, 1])
        x = x[..., 0] + x[..., 1] * 1.j
        x = torch.istft(x, n_fft=n_fft, hop_length=hop, window=window_t, center=True)
        return x.reshape([1, 2, -1])

    for i in range(0, mixture.shape[-1], step):
        start, end = i, min(i + chunk_size, mixture.shape[-1])
        actual = end - start
        window = np.tile(np.hanning(actual)[None, None, :], (1, 2, 1))
        part = mixture[:, start:end]
        if end != i + chunk_size:
            part = np.concatenate((part, np.zeros((2, (i + chunk_size) - end), dtype='float32')), axis=-1)
        spek = stft(torch.tensor(np.array([part]), dtype=torch.float32))
        spek[:, :, :3, :] *= 0
        pred = torch.tensor(model(spek.numpy()))
        tar = istft(pred).numpy()
        tar[..., :actual] *= window
        divider[..., start:end] += window
        result[..., start:end] += tar[..., :end - start]
    tar_waves = (result / divider)[:, :, trim:-trim]
    return np.concatenate(tar_waves, axis=-1)[:, :mix.shape[-1]] * compensate


# ---------------------------------------------------------------- VR (UVR spec_utils)
def import_spec_utils(uvr_root):
    sys.modules.setdefault('audioread', types.ModuleType('audioread'))
    pkg = types.ModuleType('lib_v5')
    pkg.__path__ = [os.path.join(uvr_root, 'lib_v5')]
    sys.modules['lib_v5'] = pkg
    sys.modules['lib_v5.pyrb'] = types.ModuleType('lib_v5.pyrb')
    import importlib
    import librosa as _librosa
    su = importlib.import_module('lib_v5.spec_utils')
    su.wav_resolution = 'polyphase'
    # UVR targets librosa 0.9.2 (positional arguments, reflect padding).
    shim = types.SimpleNamespace(
        stft=lambda y, n_fft, hop_length: _librosa.stft(y, n_fft=n_fft, hop_length=hop_length, pad_mode='reflect'),
        istft=lambda s, hop_length: _librosa.istft(s, hop_length=hop_length),
        resample=lambda y, orig_sr, target_sr, res_type: _librosa.resample(
            y, orig_sr=orig_sr, target_sr=target_sr, res_type=res_type),
    )
    su.librosa = shim

    # cmb_spectrogram_to_wave allocates with np.ndarray(...), i.e. without
    # initialising the bins outside each band's crop range. Use zeros so the
    # reference is deterministic (that is what fresh allocations hold).
    class _NumpyProxy:
        def __getattr__(self, name):
            return getattr(np, name)

        @staticmethod
        def ndarray(shape, dtype=float):
            return np.zeros(shape, dtype=dtype)

    su.np = _NumpyProxy()
    return su


class MP:
    def __init__(self, param):
        p = json.loads(json.dumps(param))
        p['band'] = {int(k): v for k, v in p['band'].items()}
        for k in ['mid_side', 'mid_side_b', 'mid_side_b2', 'stereo_w', 'stereo_n', 'reverse']:
            p.setdefault(k, False)
        for b in p['band'].values():
            for k in ['hpf_start', 'hpf_stop', 'lpf_start', 'lpf_stop']:
                b.setdefault(k, 0)
        self.param = p


def vr_separate(su, wave, mp, window_size=512, offset=128, aggression=5, primary_stem='Instrumental', model=None):
    """UVR's VR inference. [model] maps a [1, 2, bins+1, W] magnitude window to its mask."""
    model = model or fake_vr
    import librosa
    bands_n = len(mp.param['band'])
    X_wave, X_spec_s = {}, {}
    for d in range(bands_n, 0, -1):
        bp = mp.param['band'][d]
        if d == bands_n:
            X_wave[d] = wave.astype(np.float32)
        else:
            X_wave[d] = librosa.resample(X_wave[d + 1], orig_sr=mp.param['band'][d + 1]['sr'],
                                         target_sr=bp['sr'], res_type='polyphase')
        X_spec_s[d] = su.wave_to_spectrogram(X_wave[d], bp['hl'], bp['n_fft'], mp, band=d, is_v51_model=False)
    X_spec = su.combine_spectrograms(X_spec_s, mp, is_v51_model=False)

    X_mag, X_phase = su.preprocess(X_spec)
    n_frame = X_mag.shape[2]
    pad_l, pad_r, roi_size = su.make_padding(n_frame, window_size, offset)
    X_mag_pad = np.pad(X_mag, ((0, 0), (0, 0), (pad_l, pad_r)), mode='constant')
    X_mag_pad /= X_mag_pad.max()
    patches = (X_mag_pad.shape[2] - 2 * offset) // roi_size
    masks = []
    for i in range(patches):
        start = i * roi_size
        win = X_mag_pad[None, :, :, start:start + window_size].astype(np.float32)
        m = model(win)[:, :, :, offset:-offset]
        masks.append(np.concatenate(m, axis=2))
    mask = np.concatenate(masks, axis=2)[:, :, :n_frame]
    aggressiveness = {'value': aggression / 100, 'split_bin': mp.param['band'][1]['crop_stop'],
                      'aggr_correction': mp.param.get('aggr_correction')}
    mask = su.adjust_aggr(mask, primary_stem == 'Vocals', aggressiveness)
    y_spec = mask * X_mag * np.exp(1.j * X_phase)
    v_spec = (1 - mask) * X_mag * np.exp(1.j * X_phase)
    y = su.cmb_spectrogram_to_wave(y_spec, mp, is_v51_model=False)
    v = su.cmb_spectrogram_to_wave(v_spec, mp, is_v51_model=False)
    return y, v


def probes(x, n=400):
    idx = np.linspace(0, x.shape[-1] - 1, n).astype(int)
    return {'idx': idx.tolist(), 'l': x[0, idx].astype(float).tolist(), 'r': x[1, idx].astype(float).tolist(),
            'rms': float(np.sqrt(np.mean(x.astype(np.float64) ** 2))), 'len': int(x.shape[-1])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--uvr', required=True, help='path to an ultimatevocalremovergui checkout')
    ap.add_argument('--out', default='test/fixtures/separation_reference.json')
    args = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, 'vr_band_params.json')) as f:
        data = json.load(f)

    mix = synth(8.0)
    fx = {'seconds': 8.0}
    fx['mdx'] = probes(mdx_demix(mix))

    su = import_spec_utils(args.uvr)
    for name in ['4band_v2_sn', '3band_44100_msb2']:
        mp = MP(data[name])
        y, v = vr_separate(su, mix, mp)
        fx[f'vr_{name}_primary'] = probes(y)
        fx[f'vr_{name}_secondary'] = probes(v)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w') as f:
        json.dump(fx, f)
    print('wrote', args.out)


if __name__ == '__main__':
    main()
