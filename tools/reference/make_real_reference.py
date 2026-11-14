#!/usr/bin/env python3
"""Separates a clip with UVR's own code and the real models.

The result is the reference for `test/real_models_test.dart`, which runs the
app's Dart separation on the same clip with the same models and compares.

    tools/fetch_models.sh build/uvr-models
    python tools/reference/make_real_reference.py \
        --uvr /path/to/ultimatevocalremovergui --models build/uvr-models \
        --audio song.wav --out build/real-reference

`song.wav` must be 44.1 kHz stereo; without --audio a synthetic clip is used
(a sung-like melody in the centre, a harmony on the sides, chords and drums).
Writes float WAV files into --out:
`mix.wav` (the input), `uvr_vocals.wav` (UVR-MDX-NET-Voc_FT), `uvr_lead.wav`
and `uvr_backing.wav` (6_HP-Karaoke-UVR applied to the vocals: lead vocal and
what was removed).

MDX runs UVR's demix loop around ONNX Runtime; VR runs UVR's `spec_utils`
around UVR's PyTorch network (`lib_v5/vr_network/nets.py`) with the `.pth`
weights. Requires numpy, scipy, torch, librosa, soundfile, onnxruntime.
"""
import argparse
import importlib
import json
import os
os.environ["ORT_DISABLE_TELEMETRY"] = "1"
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_separation_fixtures import MP, import_spec_utils, mdx_demix, vr_separate  # noqa: E402


def synth_song(seconds=14.0, sr=44100):
    """A deterministic stand-in for a song: lead "voice" in the centre, a
    harmony voice on the sides, pad chords, bass, kick and hi-hat."""
    n = int(seconds * sr)
    t = np.arange(n) / sr
    rng = np.random.default_rng(7)

    def voice(midi_notes, note_len, vibrato_phase):
        f = np.zeros(n)
        for i, m in enumerate(midi_notes * (int(seconds / note_len / len(midi_notes)) + 1)):
            a, b = int(i * note_len * sr), min(n, int((i + 1) * note_len * sr))
            if a >= n:
                break
            f[a:b] = 440 * 2 ** ((m - 69) / 12)
        f *= 1 + 0.01 * np.sin(2 * np.pi * 5.5 * t + vibrato_phase)
        phase = np.cumsum(f) / sr
        x = sum(np.sin(2 * np.pi * h * phase) / h for h in range(1, 12))
        # formant-like emphasis and a syllable envelope
        x += 0.6 * np.sin(2 * np.pi * 3 * phase) + 0.4 * np.sin(2 * np.pi * 7 * phase)
        env = np.clip(np.sin(np.pi * ((t / note_len) % 1)) * 2.5, 0, 1)
        return 0.11 * x * env

    lead = voice([64, 66, 68, 69, 68, 66, 64, 61], 0.5, 0.0)
    harmony = voice([68, 69, 71, 73, 71, 69, 68, 64], 0.5, 1.3)
    mix = np.stack([lead + 0.45 * harmony * 0.9, lead + 0.45 * harmony * 0.25])
    beat = 0.5
    for i, chord in enumerate([[57, 61, 64], [52, 56, 59], [54, 57, 61], [50, 54, 57]] * 8):
        a, b = int(i * 4 * beat * sr), min(n, int((i + 1) * 4 * beat * sr))
        if a >= n:
            break
        tt = t[a:b] - t[a]
        for k, m in enumerate(chord):
            f = 440 * 2 ** ((m - 69) / 12)
            w = 0.05 * (2 * np.abs(2 * ((f * tt) % 1) - 1) - 1)
            mix[0, a:b] += (0.7 - 0.2 * k) * w
            mix[1, a:b] += (0.3 + 0.2 * k) * w
        mix[:, a:b] += 0.12 * np.sin(2 * np.pi * 440 * 2 ** ((chord[0] - 24 - 69) / 12) * tt)
    for k in range(int(seconds / (beat / 2))):
        a = int(k * beat / 2 * sr)
        m = min(n - a, int(0.15 * sr))
        tt = np.arange(m) / sr
        if k % 2 == 0:
            mix[:, a:a + m] += 0.3 * np.exp(-tt / 0.05) * np.sin(2 * np.pi * (50 + 90 * np.exp(-tt / 0.02)) * tt)
        mix[:, a:a + m] += 0.04 * np.exp(-tt / 0.012) * rng.standard_normal(m)
    return (0.8 * mix / np.abs(mix).max()).astype(np.float32)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--uvr', required=True, help='path to an ultimatevocalremovergui checkout')
    ap.add_argument('--models', required=True, help='folder with the two downloaded models')
    ap.add_argument('--audio', help='44.1 kHz stereo WAV (default: a synthetic clip)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--mdx-dim-t', type=int, default=128)
    ap.add_argument('--mdx-overlap', type=float, default=0.5)
    ap.add_argument('--vr-window', type=int, default=320)
    args = ap.parse_args()

    import onnxruntime as ort
    ort.disable_telemetry_events()
    import soundfile as sf
    import torch

    if args.audio:
        mix, sr = sf.read(args.audio, dtype='float32', always_2d=True)
        if sr != 44100 or mix.shape[1] != 2:
            sys.exit('the clip must be 44.1 kHz stereo')
        mix = np.ascontiguousarray(mix.T)
    else:
        mix = synth_song()

    # Exactly the same byte-copy patch as the app; keep weights out of assets.
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
    from build_karaoke_graph import assemble
    from build_mdx_recipe import ASSETS
    with open(ASSETS / 'mdx_graph.json') as f:
        recipe = json.load(f)
    os.makedirs(args.out, exist_ok=True)
    dynamic = os.path.join(args.out, 'mdx-dynamic.onnx')
    assemble(recipe, (ASSETS / 'mdx_graph.bin').read_bytes(),
             os.path.join(args.models, 'UVR-MDX-NET-Voc_FT.onnx'), dynamic)
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    options.enable_cpu_mem_arena = False
    sess = ort.InferenceSession(dynamic, options, providers=['CPUExecutionProvider'])
    vocals = mdx_demix(mix, dim_t=args.mdx_dim_t, overlap=args.mdx_overlap,
                       model=lambda spek: sess.run(None, {'input': spek})[0])
    del sess

    su = import_spec_utils(args.uvr)
    nets = importlib.import_module('lib_v5.vr_network.nets')
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, 'vr_band_params.json')) as f:
        mp = MP(json.load(f)['3band_44100_msb2'])
    # UVR picks the network by file size: 6_HP-Karaoke-UVR is the 123821 KB class.
    model = nets.determine_model_capacity(mp.param['bins'] * 2, 123821)
    model.load_state_dict(torch.load(os.path.join(args.models, '6_HP-Karaoke-UVR.pth'), map_location='cpu'))
    model.eval()

    def mask(window):
        with torch.no_grad():
            return model(torch.from_numpy(window)).numpy()

    backing, lead = vr_separate(su, vocals, mp, window_size=args.vr_window, model=mask)

    os.makedirs(args.out, exist_ok=True)
    for name, x in [('mix', mix), ('uvr_vocals', vocals), ('uvr_lead', lead), ('uvr_backing', backing)]:
        sf.write(os.path.join(args.out, name + '.wav'), np.asarray(x, dtype=np.float32).T, 44100, subtype='FLOAT')
        print(f'wrote {name}.wav ({x.shape[-1] / 44100:.1f} s)')


if __name__ == '__main__':
    main()
