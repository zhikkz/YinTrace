#!/usr/bin/env python3
"""Builds the on-device recipe for the harmony-removal model.

YinTrace uses exactly two UVR models:

  * ``UVR-MDX-NET-Voc_FT.onnx``  - ONNX; patched to a dynamic time axis at install.
  * ``6_HP-Karaoke-UVR.pth``     - PyTorch weights of UVR's VR architecture.

ONNX Runtime on a phone cannot read a ``.pth``. Instead of shipping converted
weights (the weights belong to the UVR authors and are 120 MB), the app
bundles only the *graph* of the network and a recipe that says where every
weight tensor sits inside the official ``.pth`` (a zip of raw little-endian
tensors). After downloading the official file the app assembles the ONNX
model by plain byte copying - no PyTorch needed, and the result is
bit-identical to the export made here.

    pip install torch onnx onnxruntime numpy
    python tools/build_karaoke_graph.py build  ~/Downloads/6_HP-Karaoke-UVR.pth
    python tools/build_karaoke_graph.py verify ~/Downloads/6_HP-Karaoke-UVR.pth
    python tools/build_karaoke_graph.py selftest

``build`` writes ``assets/models/karaoke_graph.bin`` (every byte of the ONNX
file that is not weight data) and ``assets/models/karaoke_graph.json`` (the
copy recipe and the SHA-256 of the source and of the result). ``verify``
assembles the model from the committed assets the same way the app does,
checks the hash and compares ONNX Runtime with PyTorch. ``selftest`` runs the
whole round trip with random weights (no download needed).

The network below re-implements ``lib_v5/vr_network/nets.py`` and
``layers.py`` of Ultimate Vocal Remover GUI (MIT License,
https://github.com/Anjok07/ultimatevocalremovergui), which derive from
tsurumeso's vocal-remover (MIT License). Module names are kept identical so
that the UVR state dict loads unchanged. Only the variant used by
6_HP-Karaoke-UVR is kept (VR v5, "123821KB" capacity, band configuration
``3band_44100_msb2``).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
os.environ["ORT_DISABLE_TELEMETRY"] = "1"
import pickle
import struct
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "assets", "models")

SOURCE_NAME = "6_HP-Karaoke-UVR.pth"
OUTPUT_NAME = "6_HP-Karaoke-UVR-dynamic.onnx"
# 3band_44100_msb2: 640 bins (+1), processed in windows of 512 frames.
BINS = 640
WINDOW = 512
OPSET = 17
FORMAT_VERSION = 1


# ---------------------------------------------------------------------------
# Network (UVR VR v5, CascadedASPPNet with the 123821KB capacity)
# ---------------------------------------------------------------------------

def build_network():
    import torch
    from torch import nn
    import torch.nn.functional as F

    def crop_center(h1, h2):
        # The deployed windows (320 and 512) are divisible by 32, so every
        # encoder/decoder skip has equal time extent. Keep the no-op crop out
        # of ONNX to avoid extra activation copies. Both shapes are verified.
        if h1.size()[3] == h2.size()[3]:
            return h1
        s_time = (h1.size()[3] - h2.size()[3]) // 2
        return h1[:, :, :, s_time:s_time + h2.size()[3]]

    class MeanOverFreq(nn.Module):
        """nn.AdaptiveAvgPool2d((1, None)) written so that it exports cleanly."""

        def forward(self, x):
            return x.mean(dim=2, keepdim=True)

    class Conv2DBNActiv(nn.Module):
        def __init__(self, nin, nout, ksize=3, stride=1, pad=1, dilation=1, activ=nn.ReLU):
            super().__init__()
            self.conv = nn.Sequential(
                nn.Conv2d(nin, nout, kernel_size=ksize, stride=stride, padding=pad,
                          dilation=dilation, bias=False),
                nn.BatchNorm2d(nout),
                activ())

        def forward(self, x):
            return self.conv(x)

    class SeperableConv2DBNActiv(nn.Module):
        def __init__(self, nin, nout, ksize=3, stride=1, pad=1, dilation=1, activ=nn.ReLU):
            super().__init__()
            self.conv = nn.Sequential(
                nn.Conv2d(nin, nin, kernel_size=ksize, stride=stride, padding=pad,
                          dilation=dilation, groups=nin, bias=False),
                nn.Conv2d(nin, nout, kernel_size=1, bias=False),
                nn.BatchNorm2d(nout),
                activ())

        def forward(self, x):
            return self.conv(x)

    class Encoder(nn.Module):
        def __init__(self, nin, nout, ksize=3, stride=1, pad=1, activ=nn.LeakyReLU):
            super().__init__()
            self.conv1 = Conv2DBNActiv(nin, nout, ksize, 1, pad, activ=activ)
            self.conv2 = Conv2DBNActiv(nout, nout, ksize, stride, pad, activ=activ)

        def forward(self, x):
            skip = self.conv1(x)
            return self.conv2(skip), skip

    class Decoder(nn.Module):
        def __init__(self, nin, nout, ksize=3, stride=1, pad=1, activ=nn.ReLU):
            super().__init__()
            self.conv = Conv2DBNActiv(nin, nout, ksize, 1, pad, activ=activ)

        def forward(self, x, skip=None):
            x = F.interpolate(x, scale_factor=2, mode="bilinear", align_corners=True)
            if skip is not None:
                x = torch.cat([x, crop_center(skip, x)], dim=1)
            return self.conv(x)

    class ASPPModule(nn.Module):
        def __init__(self, nin, nout, dilations=(4, 8, 16), activ=nn.ReLU):
            super().__init__()
            self.conv1 = nn.Sequential(MeanOverFreq(), Conv2DBNActiv(nin, nin, 1, 1, 0, activ=activ))
            self.conv2 = Conv2DBNActiv(nin, nin, 1, 1, 0, activ=activ)
            self.conv3 = SeperableConv2DBNActiv(nin, nin, 3, 1, dilations[0], dilations[0], activ=activ)
            self.conv4 = SeperableConv2DBNActiv(nin, nin, 3, 1, dilations[1], dilations[1], activ=activ)
            self.conv5 = SeperableConv2DBNActiv(nin, nin, 3, 1, dilations[2], dilations[2], activ=activ)
            self.bottleneck = nn.Sequential(Conv2DBNActiv(nin * 5, nout, 1, 1, 0, activ=activ),
                                            nn.Dropout2d(0.1))

        def forward(self, x):
            _, _, h, w = x.size()
            feat1 = F.interpolate(self.conv1(x), size=(h, w), mode="bilinear", align_corners=True)
            feats = [feat1, self.conv2(x), self.conv3(x), self.conv4(x), self.conv5(x)]
            return self.bottleneck(torch.cat(feats, dim=1))

    class BaseASPPNet(nn.Module):
        def __init__(self, nin, ch, dilations=(4, 8, 16)):
            super().__init__()
            self.enc1 = Encoder(nin, ch, 3, 2, 1)
            self.enc2 = Encoder(ch, ch * 2, 3, 2, 1)
            self.enc3 = Encoder(ch * 2, ch * 4, 3, 2, 1)
            self.enc4 = Encoder(ch * 4, ch * 8, 3, 2, 1)
            self.aspp = ASPPModule(ch * 8, ch * 16, dilations)
            self.dec4 = Decoder(ch * (8 + 16), ch * 8, 3, 1, 1)
            self.dec3 = Decoder(ch * (4 + 8), ch * 4, 3, 1, 1)
            self.dec2 = Decoder(ch * (2 + 4), ch * 2, 3, 1, 1)
            self.dec1 = Decoder(ch * (1 + 2), ch, 3, 1, 1)

        def forward(self, x):
            h, e1 = self.enc1(x)
            h, e2 = self.enc2(h)
            h, e3 = self.enc3(h)
            h, e4 = self.enc4(h)
            h = self.aspp(h)
            h = self.dec4(h, e4)
            h = self.dec3(h, e3)
            h = self.dec2(h, e2)
            return self.dec1(h, e1)

    class CascadedASPPNet(nn.Module):
        def __init__(self, n_fft):
            super().__init__()
            self.stg1_low_band_net = BaseASPPNet(2, 32)
            self.stg1_high_band_net = BaseASPPNet(2, 32)
            self.stg2_bridge = Conv2DBNActiv(34, 16, 1, 1, 0)
            self.stg2_full_band_net = BaseASPPNet(16, 32)
            self.stg3_bridge = Conv2DBNActiv(66, 32, 1, 1, 0)
            self.stg3_full_band_net = BaseASPPNet(32, 64)
            self.out = nn.Conv2d(64, 2, 1, bias=False)
            # Auxiliary training heads; present in the state dict, unused here.
            self.aux1_out = nn.Conv2d(32, 2, 1, bias=False)
            self.aux2_out = nn.Conv2d(32, 2, 1, bias=False)
            self.max_bin = n_fft // 2
            self.output_bin = n_fft // 2 + 1

        def forward(self, x):
            x = x[:, :, :self.max_bin]
            bandw = x.size()[2] // 2
            aux1 = torch.cat([self.stg1_low_band_net(x[:, :, :bandw]),
                              self.stg1_high_band_net(x[:, :, bandw:])], dim=2)
            h = torch.cat([x, aux1], dim=1)
            aux2 = self.stg2_full_band_net(self.stg2_bridge(h))
            h = torch.cat([x, aux1, aux2], dim=1)
            h = self.stg3_full_band_net(self.stg3_bridge(h))
            mask = torch.sigmoid(self.out(h))
            return F.pad(input=mask, pad=(0, 0, 0, self.output_bin - mask.size()[2]), mode="replicate")

    return torch, CascadedASPPNet(BINS * 2)


def load_model(pth_path):
    torch, model = build_network()
    state = torch.load(pth_path, map_location="cpu", weights_only=True)
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing or unexpected:
        sys.exit(f"state dict mismatch\n  missing: {missing[:8]}\n  unexpected: {unexpected[:8]}")
    model.eval()
    return torch, model, state


def export_onnx(torch, model, out_path):
    """Exports with BatchNorm kept separate and without constant folding, so
    that every initializer is a verbatim copy of a state dict tensor."""
    shape = (1, 2, BINS + 1, WINDOW)
    with torch.no_grad():
        torch.onnx.export(model, (torch.rand(*shape),), out_path, dynamo=False,
                          input_names=["input"], output_names=["mask"], opset_version=OPSET,
                          training=torch.onnx.TrainingMode.PRESERVE, do_constant_folding=False,
                          dynamic_axes={"input": {3: "T"}, "mask": {3: "T"}})
    return shape


# ---------------------------------------------------------------------------
# Where the tensors are: inside the .pth and inside the .onnx
# ---------------------------------------------------------------------------

def pth_tensor_locations(pth_path):
    """Maps state dict names to (file offset, byte length, shape, dtype)."""
    sizes = {"FloatStorage": ("float32", 4), "LongStorage": ("int64", 8), "DoubleStorage": ("float64", 8),
             "HalfStorage": ("float16", 2), "IntStorage": ("int32", 4)}

    class StorageType:
        def __init__(self, name):
            self.name = name

    class Unpickler(pickle.Unpickler):
        def find_class(self, module, name):
            if module == "collections" and name == "OrderedDict":
                import collections
                return collections.OrderedDict
            if module == "torch._utils" and name == "_rebuild_tensor_v2":
                def rebuild(storage, storage_offset, size, stride, *_):
                    return ("tensor", storage, storage_offset, tuple(size), tuple(stride))
                return rebuild
            if module == "torch" and name.endswith("Storage"):
                return StorageType(name)
            raise pickle.UnpicklingError(f"unexpected global {module}.{name}")

        def persistent_load(self, pid):
            # ('storage', storage_type, key, location, numel)
            return (pid[1].name, pid[2], int(pid[4]))

    with zipfile.ZipFile(pth_path) as z:
        names = z.namelist()
        pkl = next(n for n in names if n.endswith("data.pkl"))
        prefix = pkl[: -len("data.pkl")]
        state = Unpickler(z.open(pkl)).load()
        with open(pth_path, "rb") as f:
            def data_offset(info):
                if info.compress_type != zipfile.ZIP_STORED:
                    sys.exit(f"{info.filename} is compressed; expected a stored entry")
                f.seek(info.header_offset)
                hdr = f.read(30)
                if hdr[:4] != b"PK\x03\x04":
                    sys.exit("bad zip local header")
                name_len, extra_len = struct.unpack("<HH", hdr[26:30])
                return info.header_offset + 30 + name_len + extra_len

            out = {}
            for name, (_, (storage_type, key, numel), storage_offset, size, stride) in state.items():
                dtype, width = sizes[storage_type]
                info = z.getinfo(f"{prefix}data/{key}")
                count = 1
                for d in size:
                    count *= d
                expect_stride = []
                acc = 1
                for d in reversed(size):
                    expect_stride.insert(0, acc)
                    acc *= d
                if tuple(expect_stride) != stride:
                    sys.exit(f"{name}: non-contiguous tensor")
                out[name] = (data_offset(info) + storage_offset * width, count * width, size, dtype)
            return out


def _varint(buf, pos):
    result = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


def _fields(buf, start, end):
    """Yields (field number, wire type, value start, value end) of a message."""
    pos = start
    while pos < end:
        key, pos = _varint(buf, pos)
        field, wire = key >> 3, key & 7
        if wire == 0:
            _, nxt = _varint(buf, pos)
        elif wire == 1:
            nxt = pos + 8
        elif wire == 2:
            length, pos = _varint(buf, pos)
            nxt = pos + length
        elif wire == 5:
            nxt = pos + 4
        else:
            raise ValueError(f"unsupported wire type {wire}")
        yield field, wire, pos, nxt
        pos = nxt


def onnx_initializer_locations(buf):
    """Maps initializer names to (offset, length) of their raw_data."""
    out = {}
    for field, wire, s, e in _fields(buf, 0, len(buf)):
        if field != 7 or wire != 2:  # ModelProto.graph
            continue
        for gfield, gwire, gs, ge in _fields(buf, s, e):
            if gfield != 5 or gwire != 2:  # GraphProto.initializer
                continue
            name = None
            raw = None
            for tfield, twire, ts, te in _fields(buf, gs, ge):
                if tfield == 8 and twire == 2:  # TensorProto.name
                    name = bytes(buf[ts:te]).decode()
                elif tfield == 9 and twire == 2:  # TensorProto.raw_data
                    raw = (ts, te - ts)
                elif tfield in (4, 5, 6, 7, 10, 11, 13):
                    sys.exit(f"initializer {name} does not use raw_data")
            if raw is None:
                sys.exit(f"initializer {name} has no raw_data")
            out[name] = raw
    return out


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def make_recipe(pth_path, onnx_path):
    """Returns (skeleton bytes, recipe dict)."""
    with open(onnx_path, "rb") as f:
        onnx_bytes = f.read()
    in_onnx = onnx_initializer_locations(memoryview(onnx_bytes))
    in_pth = pth_tensor_locations(pth_path)
    skeleton = bytearray()
    segments = []
    cursor = 0
    copied = 0
    with open(pth_path, "rb") as src:
        for name, (off, length) in sorted(in_onnx.items(), key=lambda kv: kv[1][0]):
            if name not in in_pth:
                sys.exit(f"initializer {name} is not a state dict tensor")
            src_off, src_len, _, dtype = in_pth[name]
            if dtype != "float32" or src_len != length:
                sys.exit(f"{name}: unexpected dtype/size")
            src.seek(src_off)
            if src.read(length) != onnx_bytes[off:off + length]:
                sys.exit(f"{name}: ONNX data differs from the .pth (was the weight folded?)")
            skeleton += onnx_bytes[cursor:off]
            segments.append([off - cursor, src_off, length])
            cursor = off + length
            copied += length
    skeleton += onnx_bytes[cursor:]
    segments.append([len(onnx_bytes) - cursor, 0, 0])
    recipe = {
        "format": "yintrace-model-recipe",
        "version": FORMAT_VERSION,
        "about": "Copy recipe that turns the official UVR file into an ONNX model. "
                 "Each segment is [literal bytes taken from karaoke_graph.bin, offset in the source file, "
                 "bytes copied from the source file]. Generated by tools/build_karaoke_graph.py.",
        "source": {"name": SOURCE_NAME, "bytes": os.path.getsize(pth_path), "sha256": sha256_file(pth_path)},
        "output": {"name": OUTPUT_NAME, "bytes": len(onnx_bytes), "sha256": hashlib.sha256(onnx_bytes).hexdigest()},
        "graph": {"bytes": len(skeleton), "sha256": hashlib.sha256(bytes(skeleton)).hexdigest()},
        "input": {"name": "input", "shape": [1, 2, BINS + 1, WINDOW]},
        "dynamicAxes": {"input": {"3": "T"}, "mask": {"3": "T"}},
        "outputName": "mask",
        "segments": segments,
    }
    print(f"  {len(segments) - 1} tensors, {copied} weight bytes copied from the .pth, "
          f"{len(skeleton)} graph bytes")
    return bytes(skeleton), recipe


def assemble(recipe, skeleton, pth_path, out_path):
    """What the app does on the device."""
    pos = 0
    with open(pth_path, "rb") as src, open(out_path, "wb") as out:
        for literal, src_off, length in recipe["segments"]:
            out.write(skeleton[pos:pos + literal])
            pos += literal
            if length:
                src.seek(src_off)
                out.write(src.read(length))
    if pos != len(skeleton):
        sys.exit("recipe does not consume the whole graph file")


def compare_with_torch(torch, model, onnx_path, shape):
    import numpy as np
    import onnxruntime as ort
    ort.disable_telemetry_events()

    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    sess = ort.InferenceSession(onnx_path, options, providers=["CPUExecutionProvider"])
    errors = []
    for window in (320, 512):
        x = np.random.default_rng(0).random((*shape[:3], window), dtype=np.float32)
        with torch.no_grad():
            ref = model(torch.from_numpy(x)).numpy()
        out = sess.run(None, {sess.get_inputs()[0].name: x})[0]
        if out.shape != ref.shape:
            sys.exit(f"shape mismatch {out.shape} vs {ref.shape}")
        errors.append(float(np.max(np.abs(out - ref))))
    return max(errors)


def write_assets(out_dir, skeleton, recipe):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "karaoke_graph.bin"), "wb") as f:
        f.write(skeleton)
    with open(os.path.join(out_dir, "karaoke_graph.json"), "w", encoding="utf-8") as f:
        json.dump(recipe, f, separators=(",", ":"))
        f.write("\n")


def read_assets(assets_dir):
    with open(os.path.join(assets_dir, "karaoke_graph.json"), encoding="utf-8") as f:
        recipe = json.load(f)
    with open(os.path.join(assets_dir, "karaoke_graph.bin"), "rb") as f:
        skeleton = f.read()
    if hashlib.sha256(skeleton).hexdigest() != recipe["graph"]["sha256"]:
        sys.exit("karaoke_graph.bin does not match karaoke_graph.json")
    return recipe, skeleton


def cmd_build(args):
    torch, model, _ = load_model(args.pth)
    with tempfile.TemporaryDirectory() as tmp:
        onnx_path = os.path.join(tmp, OUTPUT_NAME)
        shape = export_onnx(torch, model, onnx_path)
        skeleton, recipe = make_recipe(args.pth, onnx_path)
        assembled = os.path.join(tmp, "assembled.onnx")
        assemble(recipe, skeleton, args.pth, assembled)
        if sha256_file(assembled) != recipe["output"]["sha256"]:
            sys.exit("assembled model differs from the export")
        err = compare_with_torch(torch, model, assembled, shape)
        print(f"  max |onnx - torch| = {err:.2e}")
        if err > 1e-3:
            sys.exit("verification failed: ONNX output differs from PyTorch")
    write_assets(args.out_dir, skeleton, recipe)
    print(f"wrote {os.path.join(args.out_dir, 'karaoke_graph.bin')} and karaoke_graph.json")
    print(f"  source sha256 {recipe['source']['sha256']}\n  output sha256 {recipe['output']['sha256']}")


def cmd_verify(args):
    recipe, skeleton = read_assets(args.assets)
    if os.path.getsize(args.pth) != recipe["source"]["bytes"] or sha256_file(args.pth) != recipe["source"]["sha256"]:
        sys.exit("the .pth is not the file the recipe was made for")
    with tempfile.TemporaryDirectory() as tmp:
        out = args.out or os.path.join(tmp, OUTPUT_NAME)
        assemble(recipe, skeleton, args.pth, out)
        digest = sha256_file(out)
        if digest != recipe["output"]["sha256"]:
            sys.exit(f"assembled model has sha256 {digest}, expected {recipe['output']['sha256']}")
        print(f"assembled {recipe['output']['name']}: sha256 OK ({recipe['output']['bytes']} bytes)")
        if not args.no_run:
            torch, model, _ = load_model(args.pth)
            err = compare_with_torch(torch, model, out, tuple(recipe["input"]["shape"]))
            print(f"  ONNX Runtime vs PyTorch: max difference {err:.2e}")
            if err > 1e-3:
                sys.exit("verification failed: ONNX output differs from PyTorch")
    print("verify OK")


def cmd_selftest(args):
    """Round trip with random weights saved the way UVR saves its models."""
    torch, model = build_network()
    torch.manual_seed(0)
    for m in model.modules():
        if hasattr(m, "running_mean"):
            torch.nn.init.normal_(m.running_mean, 0, 0.1)
            torch.nn.init.uniform_(m.running_var, 0.5, 1.5)
    with tempfile.TemporaryDirectory() as tmp:
        pth = os.path.join(tmp, SOURCE_NAME)
        torch.save(model.state_dict(), pth)
        torch, model, _ = load_model(pth)
        onnx_path = os.path.join(tmp, "export.onnx")
        shape = export_onnx(torch, model, onnx_path)
        skeleton, recipe = make_recipe(pth, onnx_path)
        write_assets(os.path.join(tmp, "assets"), skeleton, recipe)
        recipe, skeleton = read_assets(os.path.join(tmp, "assets"))
        out = os.path.join(tmp, "assembled.onnx")
        assemble(recipe, skeleton, pth, out)
        if sha256_file(out) != recipe["output"]["sha256"]:
            sys.exit("assembled model differs from the export")
        err = compare_with_torch(torch, model, out, shape)
        print(f"  max |onnx - torch| = {err:.2e}")
        if err > 1e-3:
            sys.exit("selftest failed")
    print("selftest OK")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="write the graph and recipe assets from the official .pth")
    b.add_argument("pth")
    b.add_argument("--out-dir", default=ASSETS)
    b.set_defaults(func=cmd_build)
    v = sub.add_parser("verify", help="assemble the model from the committed assets and check it")
    v.add_argument("pth")
    v.add_argument("--assets", default=ASSETS)
    v.add_argument("--out", help="keep the assembled .onnx here")
    v.add_argument("--no-run", action="store_true", help="only check the hash (no torch/onnxruntime needed)")
    v.set_defaults(func=cmd_verify)
    s = sub.add_parser("selftest", help="round trip with random weights")
    s.set_defaults(func=cmd_selftest)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
