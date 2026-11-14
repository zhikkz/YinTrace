#!/usr/bin/env python3
"""Benchmark one ONNX session in a fresh process (no PyTorch in RSS).

python tools/benchmark_inference.py model.onnx --shape 1 4 3072 128
RSS includes session creation and three runs; input is deterministic float32.
Linux ru_maxrss is KiB, macOS bytes. These numbers are NOT iPhone footprints.
"""
import argparse
import json
import resource
import sys
import time

import os
os.environ["ORT_DISABLE_TELEMETRY"] = "1"

import numpy as np
import onnxruntime as ort
ort.disable_telemetry_events()

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('model')
ap.add_argument('--shape', nargs=4, type=int, required=True)
ap.add_argument('--threads', type=int, default=4)
ap.add_argument('--no-arena', action='store_true')
args = ap.parse_args()
options = ort.SessionOptions()
options.intra_op_num_threads = args.threads
options.enable_cpu_mem_arena = not args.no_arena
started = time.perf_counter()
sess = ort.InferenceSession(args.model, options, providers=['CPUExecutionProvider'])
load_seconds = time.perf_counter() - started
x = np.random.default_rng(0).random(args.shape, dtype=np.float32)
seconds = []
for _ in range(3):
    started = time.perf_counter()
    out = sess.run(None, {sess.get_inputs()[0].name: x})
    seconds.append(time.perf_counter() - started)
    assert list(out[0].shape) == args.shape and np.isfinite(out[0]).all()
    del out
rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
rss_bytes = rss if sys.platform == 'darwin' else rss * 1024
print(json.dumps(dict(model=args.model, ort=ort.__version__, shape=args.shape,
                      threads=args.threads, arena=not args.no_arena,
                      load_seconds=load_seconds, seconds=seconds, peak_rss_mb=rss_bytes / 1e6)))
