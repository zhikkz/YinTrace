#!/usr/bin/env python3
"""How good a live SwiftF0 frame is before all of its look-ahead arrived.

    python tools/pitch_eval/lookahead.py <rendered dir> [conditions...] [--every N]

The model hears 2815 samples on each side of a frame: a frame is exactly
what one run over the whole recording gives once 10 frames after it (176 ms
after its centre) are in the run. Live, every frame of waiting is shown
late. For L = 0..10 frames of audio after a frame's own hop, this runs the
bundled model on the audio up to there (with 11 frames of history, as
ModelPitchTracker does) and compares the frame with the final one and with
the MIR-1K labels.
"""
import argparse
import json
import os
import sys

import numpy as np
import onnxruntime as ort

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import Score, at, labels  # noqa: E402

HOP, HISTORY, AHEAD = 256, 11, 10
MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'assets', 'models', 'swift_f0.onnx')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('rendered')
    p.add_argument('conditions', nargs='*', default=['clean', 'mix+5'])
    p.add_argument('--every', type=int, default=3)
    args = p.parse_args()
    meta = json.load(open(os.path.join(args.rendered, 'meta.json')))
    o = ort.SessionOptions()
    o.intra_op_num_threads = 1
    sess = ort.InferenceSession(MODEL, o, providers=['CPUExecutionProvider'])
    clips = meta['clips'][::args.every]
    for cond in args.conditions:
        agree, close, both, total = np.zeros(AHEAD + 1), np.zeros(AHEAD + 1), np.zeros(AHEAD + 1), 0
        scores = [Score() for _ in range(AHEAD + 1)]
        for clip in clips:
            x = np.fromfile(os.path.join(args.rendered, f"{clip['name']}.{cond}.f32"), '<f4')
            n = len(x) // HOP
            hz, conf = np.zeros((AHEAD + 1, n)), np.zeros((AHEAD + 1, n))
            for e in range(1, n + 1):  # frames 0..e-1 have their hop
                a = max(0, e - 1 - AHEAD - HISTORY)
                seg = x[a * HOP:e * HOP]
                (pc,) = sess.run(None, {'audio': seg[None]})
                c = pc[1].astype(np.float64)
                c[np.abs(seg.reshape(-1, HOP)).max(axis=1)[:len(c)] < 1e-3] = 0
                for lag in range(AHEAD + 1):
                    i = e - 1 - lag
                    if i < 0:
                        break
                    hz[lag, i], conf[lag, i] = pc[0][i - a], c[i - a]
            final = conf[AHEAD] >= 0.5
            midi = 69 + 12 * np.log2(np.maximum(hz, 1e-9) / 440)
            t, gt = labels(clip)
            valid = slice(0, n - AHEAD)
            for lag in range(AHEAD + 1):
                v = conf[lag] >= 0.5
                agree[lag] += (v == final)[valid].sum()
                bv = (v & final)[valid]
                both[lag] += bv.sum()
                close[lag] += (np.abs(midi[lag] - midi[AHEAD])[valid][bv] <= 0.5).sum()
                scores[lag].add(gt, at(np.arange(n) * HOP / 16000, np.where(v, midi[lag], 0), t))
            total += n - AHEAD
        print(f'\n{cond} ({len(clips)} clips, {total} frames)\n')
        print('| look-ahead | voicing as final | pitch within 50 c of final | VR | VFA | RPA | OA |')
        print('|---|---|---|---|---|---|---|')
        for lag in range(AHEAD + 1):
            r = scores[lag].row()
            print(f'| {lag} frames ({(lag + 1) * 16} ms) | {agree[lag] / total * 100:.1f}% | '
                  f'{close[lag] / max(1, both[lag]) * 100:.1f}% | {r["VR"]*100:.1f} | {r["VFA"]*100:.1f} | '
                  f'{r["RPA"]*100:.1f} | {r["OA"]*100:.1f} |')
        sys.stdout.flush()


if __name__ == '__main__':
    main()
