#!/usr/bin/env python3
"""Runs an ONNX model for the Dart tests.

`flutter test` cannot load the ONNX Runtime plugin, so
`test/support/python_ort_model.dart` starts this script and exchanges tensors
with it over stdin/stdout: int32 rank, int32 dims, float32 data (little
endian) in both directions.

    python tools/reference/ort_server.py model.onnx
"""
import struct
import sys

import numpy as np
import onnxruntime as ort


def main():
    sess = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name
    inp, out = sys.stdin.buffer, sys.stdout.buffer
    while True:
        head = inp.read(4)
        if len(head) < 4:
            break
        rank, = struct.unpack("<i", head)
        dims = struct.unpack(f"<{rank}i", inp.read(4 * rank))
        count = int(np.prod(dims))
        x = np.frombuffer(inp.read(4 * count), dtype="<f4").reshape(dims)
        y = np.ascontiguousarray(sess.run(None, {name: x})[0], dtype="<f4")
        out.write(struct.pack("<i", y.ndim))
        out.write(struct.pack(f"<{y.ndim}i", *y.shape))
        out.write(y.tobytes())
        out.flush()


if __name__ == "__main__":
    main()
