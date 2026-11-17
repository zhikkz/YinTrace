#!/usr/bin/env python3
"""Builds the pitch model YinTrace bundles (assets/models/swift_f0.onnx).

The model is SwiftF0 0.3.0 by Lars Nieradzik (MIT,
https://github.com/lars76/swift-f0), taken unchanged from the official
release on PyPI. Only its interface changes, so that the app's ONNX Runtime
plugin and `TensorModel` can run it:

- `fmin` and `fmax` (scalar inputs) become constants: the pitch range the app
  searches, FMIN to FMAX below;
- `pitch` (float64) is cast to float32, which the Apple plugin can read
  (it has no float64 tensors); the rounding is below 1e-4 cent;
- `pitch` and `confidence` are joined into one output `pitch_confidence`
  of shape [2, frames]: row 0 the pitch in Hz, row 1 the confidence.

The weights and every other node stay as they are. `verify` checks that the
result gives the same pitch (to float32 rounding) and exactly the same
confidence as the original model.

    python tools/build_pitch_model.py build [--wheel swift_f0-0.3.0-py3-none-any.whl]
    python tools/build_pitch_model.py verify [--wheel ...]

Without --wheel the wheel is downloaded from PyPI. Needs onnx, onnxruntime
and numpy.
"""
import argparse
import hashlib
import io
import os
import sys
import urllib.request
import zipfile

import numpy as np

WHEEL_URL = ('https://files.pythonhosted.org/packages/07/21/'
             'ac6c76119a776e4281da61e22828f992bb2e34b74edfcd3987dca97a6180/swift_f0-0.3.0-py3-none-any.whl')
WHEEL_SHA256 = 'd7240c7c94b1d3e8f0e0cd2701b79be89a0f23a19cd5f944895a6518ecad72f3'
MODEL_MEMBER = 'swift_f0/model.onnx'
MODEL_SHA256 = '6385e8c2ebc3872e82c9ff5946228de44cd3be77a750ea53698b7dbfe94b0a22'
LICENSE_MEMBER = 'swift_f0-0.3.0.dist-info/licenses/LICENSE'

# The pitch range searched: C2 (65.4 Hz) is lower than the lowest note of
# almost any pop song, and the top is above the highest soprano notes of
# pop and musical theatre (C6 is 1047 Hz). The model covers 46.875 Hz to
# 2093.75 Hz; frames whose best pitch lies outside the range are unvoiced.
FMIN = 60.0
FMAX = 1400.0

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'assets', 'models', 'swift_f0.onnx')


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def official_model(wheel_path):
    if wheel_path:
        wheel = open(wheel_path, 'rb').read()
    else:
        with urllib.request.urlopen(WHEEL_URL, timeout=60) as r:
            wheel = r.read()
    if sha256(wheel) != WHEEL_SHA256:
        sys.exit('the wheel is not the official swift-f0 0.3.0 release')
    with zipfile.ZipFile(io.BytesIO(wheel)) as z:
        model = z.read(MODEL_MEMBER)
        license_text = z.read(LICENSE_MEMBER).decode()
    if sha256(model) != MODEL_SHA256:
        sys.exit('model.onnx in the wheel has an unexpected SHA-256')
    return model, license_text


def convert(model_bytes):
    import onnx
    from onnx import TensorProto, helper, numpy_helper

    m = onnx.load_from_string(model_bytes)
    g = m.graph
    names = [i.name for i in g.input]
    if names != ['audio', 'fmin', 'fmax'] or [o.name for o in g.output] != ['pitch', 'confidence']:
        sys.exit(f'unexpected model interface: {names} -> {[o.name for o in g.output]}')
    for name, value in (('fmin', FMIN), ('fmax', FMAX)):
        g.input.remove(next(i for i in g.input if i.name == name))
        g.initializer.append(numpy_helper.from_array(np.array(value, dtype=np.float32), name))
    g.node.extend([
        helper.make_node('Cast', ['pitch'], ['pitch_float'], to=TensorProto.FLOAT, name='yintrace_cast_pitch'),
        helper.make_node('Concat', ['pitch_float', 'confidence'], ['pitch_confidence'], axis=0,
                         name='yintrace_join_outputs'),
    ])
    del g.output[:]
    g.output.append(helper.make_tensor_value_info('pitch_confidence', TensorProto.FLOAT, [2, 'frames']))
    for key, value in (
        ('yintrace_source', f'swift-f0 0.3.0 model.onnx sha256 {MODEL_SHA256}'),
        ('yintrace_change', f'fmin={FMIN:g} and fmax={FMAX:g} fixed; pitch cast to float32; '
                            'output pitch_confidence [2, frames] = (pitch Hz, confidence)'),
    ):
        entry = m.metadata_props.add()
        entry.key, entry.value = key, value
    onnx.checker.check_model(m)
    return m.SerializeToString()


def test_audio():
    """Silence, noise, tones, a glide and a vowel-like signal at 16 kHz."""
    rng = np.random.default_rng(0)
    sr = 16000
    t = np.arange(4 * sr) / sr
    f0 = np.where(t < 1, 110, np.where(t < 2, 220 * 2 ** (t - 1), np.where(t < 3, 523.25, 880)))
    phase = 2 * np.pi * np.cumsum(f0) / sr
    voice = sum(np.sin(h * phase) / h for h in range(1, 12)) * 0.2
    voice[(t > 0.45) & (t < 0.55)] = 0
    out = [voice + 0.003 * rng.standard_normal(len(t)), 0.1 * rng.standard_normal(sr), np.zeros(sr // 2),
           voice[: 3333]]
    return [x.astype(np.float32) for x in out]


def verify(original, converted):
    import onnxruntime as ort

    a = ort.InferenceSession(original, providers=['CPUExecutionProvider'])
    b = ort.InferenceSession(converted, providers=['CPUExecutionProvider'])
    assert [i.name for i in b.get_inputs()] == ['audio']
    assert [o.name for o in b.get_outputs()] == ['pitch_confidence']
    for x in test_audio():
        pitch, conf = a.run(['pitch', 'confidence'], {'audio': x[None], 'fmin': np.array(FMIN, np.float32),
                                                     'fmax': np.array(FMAX, np.float32)})
        (joined,) = b.run(None, {'audio': x[None]})
        assert joined.dtype == np.float32 and joined.shape == (2, conf.shape[1]), joined.shape
        assert np.array_equal(joined[0], pitch[0].astype(np.float32)), 'pitch differs'
        assert np.array_equal(joined[1], conf[0]), 'confidence differs'
    print(f'verified: same pitch and confidence as the original on {len(test_audio())} test signals')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['build', 'verify'])
    p.add_argument('--wheel')
    p.add_argument('--out', default=OUT)
    args = p.parse_args()
    original, _ = official_model(args.wheel)
    converted = convert(original)
    if args.command == 'build':
        with open(args.out, 'wb') as f:
            f.write(converted)
        print(f'wrote {args.out} ({len(converted)} bytes, sha256 {sha256(converted)})')
        verify(original, converted)
        return
    bundled = open(args.out, 'rb').read()
    if bundled == converted:
        print(f'{args.out} is what this script builds (sha256 {sha256(bundled)})')
    else:
        # Another version of the onnx package may lay out the same model
        # differently: compare the models as this version writes them.
        import onnx
        if onnx.load_from_string(bundled).SerializeToString() != onnx.load_from_string(converted).SerializeToString():
            sys.exit(f'{args.out} is not what this script builds from the official model')
        print(f'{args.out} is the model this script builds (written by another version of onnx)')
    verify(original, bundled)


if __name__ == '__main__':
    main()
