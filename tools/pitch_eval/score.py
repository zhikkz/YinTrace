#!/usr/bin/env python3
"""Scores the app's YIN and SwiftF0 pitch tracks against the MIR-1K labels.

    python tools/pitch_eval/score.py <rendered dir> <tracks dir> [conditions...]

Reads what `run_app.dart` wrote. The labels are MIDI
notes every 20 ms, the first at 20 ms (0 = unvoiced); every track is read at
the label times (nearest frame). The metrics are the usual ones of melody
extraction (Salamon et al.), with 50 cents for a correct pitch:

- VR: voiced frames (labels) the track has voiced;
- VFA: unvoiced frames the track has voiced;
- RPA: voiced frames with the pitch within 50 cents;
- RCA: the same, an octave off counted as right;
- OA: all frames right (unvoiced where unvoiced, the pitch where voiced).
"""
import json
import os
import sys

import numpy as np

LABEL_T0 = 0.02
LABEL_HOP = 0.02


def at(times, midi, t):
    """The track's value at times [t] (nearest frame; 0 outside it)."""
    idx = np.clip(np.searchsorted(times, t), 1, len(times) - 1)
    idx = np.where(np.abs(t - times[idx - 1]) <= np.abs(times[idx] - t), idx - 1, idx)
    v = midi[idx].copy()
    v[(t < times[0] - 0.02) | (t > times[-1] + 0.02)] = 0
    return v


class Score:
    def __init__(self):
        self.n_v = self.n_u = self.v_on_v = self.v_on_u = self.rp = self.rc = 0
        self.errs = []

    def add(self, gt, est):
        gv, ev = gt > 0, est > 0
        self.n_v += gv.sum()
        self.n_u += (~gv).sum()
        self.v_on_v += (gv & ev).sum()
        self.v_on_u += (~gv & ev).sum()
        both = gv & ev
        d = (est[both] - gt[both]) * 100
        ok = np.abs(d) <= 50
        self.rp += ok.sum()
        self.rc += (np.abs((d + 600) % 1200 - 600) <= 50).sum()
        self.errs.append(np.abs(d[ok]))

    def row(self):
        e = np.concatenate(self.errs) if self.errs else np.zeros(0)
        return dict(VR=self.v_on_v / self.n_v, VFA=self.v_on_u / max(1, self.n_u), RPA=self.rp / self.n_v,
                    RCA=self.rc / self.n_v, OA=((self.n_u - self.v_on_u) + self.rp) / (self.n_v + self.n_u),
                    cents=float(np.median(e)) if e.size else float('nan'))


def fmt(name, r):
    return (f"| {name} | {r['VR']*100:.1f} | {r['VFA']*100:.1f} | {r['RPA']*100:.1f} | {r['RCA']*100:.1f} | "
            f"{r['OA']*100:.1f} | {r['cents']:.1f} |")


def labels(clip):
    lab = np.array(clip['labels'])
    return LABEL_T0 + LABEL_HOP * np.arange(len(lab)), lab


def read(path):
    return np.fromfile(path, '<f4').astype(np.float64)


def main():
    rendered, tracks = sys.argv[1:3]
    meta = json.load(open(os.path.join(rendered, 'meta.json')))
    conds = sys.argv[3:] or meta['conditions']
    kinds = {
        'YIN, import': ('yin_offline', 'grid'),
        'SwiftF0, import': ('model_offline', 'grid'),
        'YIN, practice': ('yin_live', 'pairs'),
    }
    for cond in conds:
        scores = {k: Score() for k in kinds}
        clips = 0
        for clip in meta['clips']:
            paths = {k: os.path.join(tracks, f"{clip['name']}.{cond}.{suffix}.f32") for k, (suffix, _) in kinds.items()}
            if not any(os.path.exists(p) for p in paths.values()):
                continue
            clips += 1
            t, gt = labels(clip)
            for k, (_, layout) in kinds.items():
                if not os.path.exists(paths[k]):
                    continue
                y = read(paths[k])
                if layout == 'grid':  # hop, then midi per frame
                    times, midi = np.arange(len(y) - 1) * y[0], y[1:]
                else:  # song time, midi
                    y = y.reshape(-1, 2)
                    times, midi = y[:, 0], y[:, 1]
                scores[k].add(gt, at(times, midi, t))
        print(f'\n{cond} ({clips} clips)\n')
        print('| | VR | VFA | RPA | RCA | OA | median error (cents) |')
        print('|---|---|---|---|---|---|---|')
        for k, s in scores.items():
            if s.n_v:
                print(fmt(k, s.row()))


if __name__ == '__main__':
    main()
