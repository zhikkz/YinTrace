#!/usr/bin/env python3
"""Prepares Ultimate Vocal Remover (UVR) models for the YinTrace app.

The app runs separation on the device with ONNX Runtime, so every model has
to be an ``.onnx`` file accompanied by a small JSON "sidecar" that describes
how the audio has to be pre/post-processed.

  * MDX-Net models (e.g. ``UVR-MDX-NET-Voc_FT.onnx``) already are ONNX; this
    script only identifies them and writes the sidecar.
  * VR-architecture models (e.g. ``6_HP-Karaoke-UVR.pth``) are PyTorch state
    dicts. This script rebuilds the network exactly like UVR does, loads the
    weights, exports ONNX and verifies the export against PyTorch.

Usage::

    pip install torch onnx onnxruntime numpy
    python tools/prepare_models.py mdx ~/Downloads/UVR-MDX-NET-Voc_FT.onnx --out-dir build/models
    python tools/prepare_models.py vr  ~/Downloads/6_HP-Karaoke-UVR.pth   --out-dir build/models

Copy the resulting ``*.onnx`` + ``*.json`` pairs into the app (see README).

Model metadata (band configurations, model hashes) comes from UVR
(MIT License, https://github.com/Anjok07/ultimatevocalremovergui) and is
stored in ``tools/uvr_model_data.json``. The network definitions below are
re-implementations of UVR's ``lib_v5/vr_network`` modules (same MIT license)
with module names kept identical so that UVR state dicts load unchanged.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_PATH = os.path.join(HERE, "uvr_model_data.json")

SIDE_CAR_VERSION = 1

# UVR picks the VR network variant from the file size (KiB).
NN_ARCH_SIZES = [31191, 33966, 56817, 123821, 123812, 129605, 218409, 537238, 537227]
VR_51_ARCH_SIZES = [56817, 218409]


def load_uvr_data():
    with open(DATA_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def uvr_model_hash(path: str) -> str:
    """UVR's model hash: md5 of the last 10 MB (or of the whole file)."""
    with open(path, "rb") as f:
        try:
            f.seek(-10000 * 1024, 2)
            return hashlib.md5(f.read()).hexdigest()
        except OSError:
            f.seek(0)
            return hashlib.md5(f.read()).hexdigest()


def normalize_vr_params(param: dict) -> dict:
    """Applies the defaults of UVR's ModelParameters."""
    p = json.loads(json.dumps(param))
    for k in ["mid_side", "mid_side_b", "mid_side_b2", "stereo_w", "stereo_n", "reverse"]:
        p.setdefault(k, False)
    if "n_bins" in p:
        p["bins"] = p["n_bins"]
    bands = p["band"]
    for key in list(bands.keys()):
        b = bands[key]
        b.setdefault("hpf_start", 0)
        b.setdefault("hpf_stop", 0)
        b.setdefault("lpf_start", 0)
        b.setdefault("lpf_stop", 0)
    return p


def write_json(path: str, obj: dict):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")


# ---------------------------------------------------------------------------
# VR networks (UVR lib_v5/vr_network) — imported lazily so `mdx` works
# without PyTorch.
# ---------------------------------------------------------------------------

def build_vr_modules():
    import torch
    from torch import nn
    import torch.nn.functional as F

    def crop_center(h1, h2):
        if h1.size()[3] == h2.size()[3]:
            return h1
        s_time = (h1.size()[3] - h2.size()[3]) // 2
        return h1[:, :, :, s_time:s_time + h2.size()[3]]

    class MeanOverFreq(nn.Module):
        """Export-friendly replacement for nn.AdaptiveAvgPool2d((1, None))."""

        def forward(self, x):
            return x.mean(dim=2, keepdim=True)

    # ---- v5 (layers.py / nets.py) ----
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
            h = self.conv2(skip)
            return h, skip

    class Decoder(nn.Module):
        def __init__(self, nin, nout, ksize=3, stride=1, pad=1, activ=nn.ReLU, dropout=False):
            super().__init__()
            self.conv = Conv2DBNActiv(nin, nout, ksize, 1, pad, activ=activ)
            self.dropout = nn.Dropout2d(0.1) if dropout else None

        def forward(self, x, skip=None):
            x = F.interpolate(x, scale_factor=2, mode="bilinear", align_corners=True)
            if skip is not None:
                skip = crop_center(skip, x)
                x = torch.cat([x, skip], dim=1)
            h = self.conv(x)
            if self.dropout is not None:
                h = self.dropout(h)
            return h

    class ASPPModule(nn.Module):
        def __init__(self, nn_architecture, nin, nout, dilations=(4, 8, 16), activ=nn.ReLU):
            super().__init__()
            self.conv1 = nn.Sequential(nn.AdaptiveAvgPool2d((1, None)),
                                       Conv2DBNActiv(nin, nin, 1, 1, 0, activ=activ))
            self.nn_architecture = nn_architecture
            self.six_layer = [129605]
            self.seven_layer = [537238, 537227, 33966]
            extra_conv = SeperableConv2DBNActiv(nin, nin, 3, 1, dilations[2], dilations[2], activ=activ)
            self.conv2 = Conv2DBNActiv(nin, nin, 1, 1, 0, activ=activ)
            self.conv3 = SeperableConv2DBNActiv(nin, nin, 3, 1, dilations[0], dilations[0], activ=activ)
            self.conv4 = SeperableConv2DBNActiv(nin, nin, 3, 1, dilations[1], dilations[1], activ=activ)
            self.conv5 = SeperableConv2DBNActiv(nin, nin, 3, 1, dilations[2], dilations[2], activ=activ)
            if self.nn_architecture in self.six_layer:
                self.conv6 = extra_conv
                nin_x = 6
            elif self.nn_architecture in self.seven_layer:
                self.conv6 = extra_conv
                self.conv7 = extra_conv
                nin_x = 7
            else:
                nin_x = 5
            self.bottleneck = nn.Sequential(Conv2DBNActiv(nin * nin_x, nout, 1, 1, 0, activ=activ),
                                            nn.Dropout2d(0.1))

        def forward(self, x):
            _, _, h, w = x.size()
            feat1 = F.interpolate(self.conv1(x), size=(h, w), mode="bilinear", align_corners=True)
            feats = [feat1, self.conv2(x), self.conv3(x), self.conv4(x), self.conv5(x)]
            if self.nn_architecture in self.six_layer:
                feats.append(self.conv6(x))
            elif self.nn_architecture in self.seven_layer:
                feats.append(self.conv6(x))
                feats.append(self.conv7(x))
            return self.bottleneck(torch.cat(feats, dim=1))

    class BaseASPPNet(nn.Module):
        def __init__(self, nn_architecture, nin, ch, dilations=(4, 8, 16)):
            super().__init__()
            self.nn_architecture = nn_architecture
            self.enc1 = Encoder(nin, ch, 3, 2, 1)
            self.enc2 = Encoder(ch, ch * 2, 3, 2, 1)
            self.enc3 = Encoder(ch * 2, ch * 4, 3, 2, 1)
            self.enc4 = Encoder(ch * 4, ch * 8, 3, 2, 1)
            if self.nn_architecture == 129605:
                self.enc5 = Encoder(ch * 8, ch * 16, 3, 2, 1)
                self.aspp = ASPPModule(nn_architecture, ch * 16, ch * 32, dilations)
                self.dec5 = Decoder(ch * (16 + 32), ch * 16, 3, 1, 1)
            else:
                self.aspp = ASPPModule(nn_architecture, ch * 8, ch * 16, dilations)
            self.dec4 = Decoder(ch * (8 + 16), ch * 8, 3, 1, 1)
            self.dec3 = Decoder(ch * (4 + 8), ch * 4, 3, 1, 1)
            self.dec2 = Decoder(ch * (2 + 4), ch * 2, 3, 1, 1)
            self.dec1 = Decoder(ch * (1 + 2), ch, 3, 1, 1)

        def forward(self, x):
            h, e1 = self.enc1(x)
            h, e2 = self.enc2(h)
            h, e3 = self.enc3(h)
            h, e4 = self.enc4(h)
            if self.nn_architecture == 129605:
                h, e5 = self.enc5(h)
                h = self.aspp(h)
                h = self.dec5(h, e5)
            else:
                h = self.aspp(h)
            h = self.dec4(h, e4)
            h = self.dec3(h, e3)
            h = self.dec2(h, e2)
            h = self.dec1(h, e1)
            return h

    def model_capacity(nn_architecture):
        if nn_architecture in [31191, 33966, 129605]:
            return [(2, 16), (2, 16), (18, 8, 1, 1, 0), (8, 16), (34, 16, 1, 1, 0), (16, 32),
                    (32, 2, 1), (16, 2, 1), (16, 2, 1)]
        if nn_architecture in [123821, 123812]:
            return [(2, 32), (2, 32), (34, 16, 1, 1, 0), (16, 32), (66, 32, 1, 1, 0), (32, 64),
                    (64, 2, 1), (32, 2, 1), (32, 2, 1)]
        if nn_architecture in [537238, 537227]:
            return [(2, 64), (2, 64), (66, 32, 1, 1, 0), (32, 64), (130, 64, 1, 1, 0), (64, 128),
                    (128, 2, 1), (64, 2, 1), (64, 2, 1)]
        raise ValueError(f"unsupported VR v5 architecture {nn_architecture}")

    class CascadedASPPNet(nn.Module):
        def __init__(self, n_fft, nn_architecture):
            super().__init__()
            cap = model_capacity(nn_architecture)
            self.stg1_low_band_net = BaseASPPNet(nn_architecture, *cap[0])
            self.stg1_high_band_net = BaseASPPNet(nn_architecture, *cap[1])
            self.stg2_bridge = Conv2DBNActiv(*cap[2])
            self.stg2_full_band_net = BaseASPPNet(nn_architecture, *cap[3])
            self.stg3_bridge = Conv2DBNActiv(*cap[4])
            self.stg3_full_band_net = BaseASPPNet(nn_architecture, *cap[5])
            self.out = nn.Conv2d(*cap[6], bias=False)
            self.aux1_out = nn.Conv2d(*cap[7], bias=False)
            self.aux2_out = nn.Conv2d(*cap[8], bias=False)
            self.max_bin = n_fft // 2
            self.output_bin = n_fft // 2 + 1
            self.offset = 128

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
            mask = F.pad(input=mask, pad=(0, 0, 0, self.output_bin - mask.size()[2]), mode="replicate")
            return mask

    # ---- v5.1 (layers_new.py / nets_new.py) ----
    class EncoderNew(nn.Module):
        def __init__(self, nin, nout, ksize=3, stride=1, pad=1, activ=nn.LeakyReLU):
            super().__init__()
            self.conv1 = Conv2DBNActiv(nin, nout, ksize, stride, pad, activ=activ)
            self.conv2 = Conv2DBNActiv(nout, nout, ksize, 1, pad, activ=activ)

        def forward(self, x):
            return self.conv2(self.conv1(x))

    class DecoderNew(nn.Module):
        def __init__(self, nin, nout, ksize=3, stride=1, pad=1, activ=nn.ReLU, dropout=False):
            super().__init__()
            self.conv1 = Conv2DBNActiv(nin, nout, ksize, 1, pad, activ=activ)
            self.dropout = nn.Dropout2d(0.1) if dropout else None

        def forward(self, x, skip=None):
            x = F.interpolate(x, scale_factor=2, mode="bilinear", align_corners=True)
            if skip is not None:
                skip = crop_center(skip, x)
                x = torch.cat([x, skip], dim=1)
            h = self.conv1(x)
            if self.dropout is not None:
                h = self.dropout(h)
            return h

    class ASPPModuleNew(nn.Module):
        def __init__(self, nin, nout, dilations=(4, 8, 12), activ=nn.ReLU, dropout=False):
            super().__init__()
            self.conv1 = nn.Sequential(nn.AdaptiveAvgPool2d((1, None)),
                                       Conv2DBNActiv(nin, nout, 1, 1, 0, activ=activ))
            self.conv2 = Conv2DBNActiv(nin, nout, 1, 1, 0, activ=activ)
            self.conv3 = Conv2DBNActiv(nin, nout, 3, 1, dilations[0], dilations[0], activ=activ)
            self.conv4 = Conv2DBNActiv(nin, nout, 3, 1, dilations[1], dilations[1], activ=activ)
            self.conv5 = Conv2DBNActiv(nin, nout, 3, 1, dilations[2], dilations[2], activ=activ)
            self.bottleneck = Conv2DBNActiv(nout * 5, nout, 1, 1, 0, activ=activ)
            self.dropout = nn.Dropout2d(0.1) if dropout else None

        def forward(self, x):
            _, _, h, w = x.size()
            feat1 = F.interpolate(self.conv1(x), size=(h, w), mode="bilinear", align_corners=True)
            out = torch.cat((feat1, self.conv2(x), self.conv3(x), self.conv4(x), self.conv5(x)), dim=1)
            out = self.bottleneck(out)
            if self.dropout is not None:
                out = self.dropout(out)
            return out

    class LSTMModule(nn.Module):
        def __init__(self, nin_conv, nin_lstm, nout_lstm):
            super().__init__()
            self.conv = Conv2DBNActiv(nin_conv, 1, 1, 1, 0)
            self.lstm = nn.LSTM(input_size=nin_lstm, hidden_size=nout_lstm // 2, bidirectional=True)
            self.dense = nn.Sequential(nn.Linear(nout_lstm, nin_lstm), nn.BatchNorm1d(nin_lstm), nn.ReLU())

        def forward(self, x):
            n, _, nbins, nframes = x.size()
            h = self.conv(x)[:, 0]
            h = h.permute(2, 0, 1)
            h, _ = self.lstm(h)
            h = self.dense(h.reshape(-1, h.size()[-1]))
            h = h.reshape(nframes, n, 1, nbins)
            return h.permute(1, 2, 3, 0)

    class BaseNet(nn.Module):
        def __init__(self, nin, nout, nin_lstm, nout_lstm, dilations=((4, 2), (8, 4), (12, 6))):
            super().__init__()
            self.enc1 = Conv2DBNActiv(nin, nout, 3, 1, 1)
            self.enc2 = EncoderNew(nout, nout * 2, 3, 2, 1)
            self.enc3 = EncoderNew(nout * 2, nout * 4, 3, 2, 1)
            self.enc4 = EncoderNew(nout * 4, nout * 6, 3, 2, 1)
            self.enc5 = EncoderNew(nout * 6, nout * 8, 3, 2, 1)
            self.aspp = ASPPModuleNew(nout * 8, nout * 8, dilations, dropout=True)
            self.dec4 = DecoderNew(nout * (6 + 8), nout * 6, 3, 1, 1)
            self.dec3 = DecoderNew(nout * (4 + 6), nout * 4, 3, 1, 1)
            self.dec2 = DecoderNew(nout * (2 + 4), nout * 2, 3, 1, 1)
            self.lstm_dec2 = LSTMModule(nout * 2, nin_lstm, nout_lstm)
            self.dec1 = DecoderNew(nout * (1 + 2) + 1, nout * 1, 3, 1, 1)

        def forward(self, x):
            e1 = self.enc1(x)
            e2 = self.enc2(e1)
            e3 = self.enc3(e2)
            e4 = self.enc4(e3)
            e5 = self.enc5(e4)
            h = self.aspp(e5)
            h = self.dec4(h, e4)
            h = self.dec3(h, e3)
            h = self.dec2(h, e2)
            h = torch.cat([h, self.lstm_dec2(h)], dim=1)
            return self.dec1(h, e1)

    class CascadedNet(nn.Module):
        def __init__(self, n_fft, nn_arch_size=51000, nout=32, nout_lstm=128):
            super().__init__()
            self.max_bin = n_fft // 2
            self.output_bin = n_fft // 2 + 1
            self.nin_lstm = self.max_bin // 2
            self.offset = 64
            nout = 64 if nn_arch_size == 218409 else nout
            self.stg1_low_band_net = nn.Sequential(BaseNet(2, nout // 2, self.nin_lstm // 2, nout_lstm),
                                                   Conv2DBNActiv(nout // 2, nout // 4, 1, 1, 0))
            self.stg1_high_band_net = BaseNet(2, nout // 4, self.nin_lstm // 2, nout_lstm // 2)
            self.stg2_low_band_net = nn.Sequential(BaseNet(nout // 4 + 2, nout, self.nin_lstm // 2, nout_lstm),
                                                   Conv2DBNActiv(nout, nout // 2, 1, 1, 0))
            self.stg2_high_band_net = BaseNet(nout // 4 + 2, nout // 2, self.nin_lstm // 2, nout_lstm // 2)
            self.stg3_full_band_net = BaseNet(3 * nout // 4 + 2, nout, self.nin_lstm, nout_lstm)
            self.out = nn.Conv2d(nout, 2, 1, bias=False)
            self.aux_out = nn.Conv2d(3 * nout // 4, 2, 1, bias=False)

        def forward(self, x):
            x = x[:, :, :self.max_bin]
            bandw = x.size()[2] // 2
            l1_in = x[:, :, :bandw]
            h1_in = x[:, :, bandw:]
            l1 = self.stg1_low_band_net(l1_in)
            h1 = self.stg1_high_band_net(h1_in)
            aux1 = torch.cat([l1, h1], dim=2)
            l2 = self.stg2_low_band_net(torch.cat([l1_in, l1], dim=1))
            h2 = self.stg2_high_band_net(torch.cat([h1_in, h1], dim=1))
            aux2 = torch.cat([l2, h2], dim=2)
            f3 = self.stg3_full_band_net(torch.cat([x, aux1, aux2], dim=1))
            mask = torch.sigmoid(self.out(f3))
            mask = F.pad(input=mask, pad=(0, 0, 0, self.output_bin - mask.size()[2]), mode="replicate")
            return mask

    def make_export_friendly(model):
        """Replaces AdaptiveAvgPool2d((1, None)) by an explicit mean."""
        for module in model.modules():
            if isinstance(module, nn.Sequential) and len(module) > 0 and isinstance(module[0], nn.AdaptiveAvgPool2d):
                module[0] = MeanOverFreq()
        return model

    return {
        "torch": torch,
        "CascadedASPPNet": CascadedASPPNet,
        "CascadedNet": CascadedNet,
        "make_export_friendly": make_export_friendly,
    }


def build_vr_model(mods, bins: int, nn_arch_size: int, is_v51: bool, nout: int, nout_lstm: int):
    if is_v51:
        return mods["CascadedNet"](bins * 2, nn_arch_size, nout=nout, nout_lstm=nout_lstm)
    return mods["CascadedASPPNet"](bins * 2, nn_arch_size)


def export_onnx(torch, model, dummy, out_path: str, opset: int):
    kwargs = dict(input_names=["input"], output_names=["mask"], opset_version=opset)
    errors = []
    for dynamo in (False, True):
        try:
            torch.onnx.export(model, (dummy,), out_path, dynamo=dynamo, **kwargs)
            return
        except TypeError:
            # Old torch without the `dynamo` argument.
            torch.onnx.export(model, (dummy,), out_path, **kwargs)
            return
        except Exception as e:  # noqa: BLE001 - try the other exporter
            errors.append(f"dynamo={dynamo}: {e}")
    raise RuntimeError("ONNX export failed:\n" + "\n".join(errors))


def verify_onnx(torch, model, onnx_path: str, input_shape, seed=0):
    import numpy as np
    import onnxruntime as ort

    rng = np.random.default_rng(seed)
    x = rng.random(input_shape, dtype=np.float32)
    with torch.no_grad():
        ref = model(torch.from_numpy(x)).numpy()
    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    out = sess.run(None, {sess.get_inputs()[0].name: x})[0]
    if out.shape != ref.shape:
        raise RuntimeError(f"shape mismatch {out.shape} vs {ref.shape}")
    return float(np.max(np.abs(out - ref)))


def cmd_vr(args):
    data = load_uvr_data()
    path = args.model
    name = os.path.splitext(os.path.basename(path))[0]
    model_hash = uvr_model_hash(path)
    info = dict(data["vr_model_data"].get(model_hash, {}))
    if args.param:
        info["vr_model_param"] = args.param
    if "vr_model_param" not in info:
        known = ", ".join(sorted(data["vr_params"].keys()))
        sys.exit(f"unknown model hash {model_hash}; pass --param <name> (one of: {known})")
    param_name = info["vr_model_param"]
    params = normalize_vr_params(data["vr_params"][param_name])
    bins = int(params["bins"])

    model_size_kib = math.ceil(os.stat(path).st_size / 1024)
    nn_arch_size = min(NN_ARCH_SIZES, key=lambda x: abs(x - model_size_kib))
    is_v51 = nn_arch_size in VR_51_ARCH_SIZES or "nout" in info
    nout = int(info.get("nout", 32))
    nout_lstm = int(info.get("nout_lstm", 128))
    print(f"model: {name}\n  hash: {model_hash}\n  params: {param_name} (bins={bins})\n"
          f"  arch: {'v5.1' if is_v51 else 'v5'} size class {nn_arch_size} KiB (file {model_size_kib} KiB)")

    mods = build_vr_modules()
    torch = mods["torch"]
    model = build_vr_model(mods, bins, nn_arch_size, is_v51, nout, nout_lstm)
    state = torch.load(path, map_location="cpu", weights_only=True)
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing or unexpected:
        sys.exit(f"state dict mismatch\n  missing: {missing[:8]}\n  unexpected: {unexpected[:8]}")
    model.eval()
    mods["make_export_friendly"](model)

    window = args.window_size
    offset = 64 if is_v51 else 128
    if window - 2 * offset <= 0 or window % 32 != 0:
        sys.exit("window size must be a multiple of 32 and larger than 2*offset")
    os.makedirs(args.out_dir, exist_ok=True)
    onnx_path = os.path.join(args.out_dir, name + ".onnx")
    shape = (1, 2, bins + 1, window)
    with torch.no_grad():
        export_onnx(torch, model, torch.rand(*shape), onnx_path, args.opset)
    err = verify_onnx(torch, model, onnx_path, shape)
    print(f"  exported {onnx_path} (max |onnx - torch| = {err:.2e})")
    if err > 1e-3:
        sys.exit("verification failed: ONNX output differs from PyTorch")

    primary = info.get("primary_stem", "Instrumental")
    sidecar = {
        "format": "yintrace-model",
        "version": SIDE_CAR_VERSION,
        "type": "vr",
        "name": name,
        "model_hash": model_hash,
        "primary_stem": primary,
        "is_karaoke": bool(info.get("is_karaoke", False)),
        "is_v51": is_v51,
        "window_size": window,
        "offset": offset,
        "input_name": "input",
        "output_name": "mask",
        "input_shape": list(shape),
        "aggression": args.aggression,
        "param_name": param_name,
        "params": params,
    }
    write_json(os.path.join(args.out_dir, name + ".json"), sidecar)
    print(f"  wrote {os.path.join(args.out_dir, name + '.json')}")


def cmd_mdx(args):
    data = load_uvr_data()
    path = args.model
    name = os.path.splitext(os.path.basename(path))[0]
    model_hash = uvr_model_hash(path)
    info = dict(data["mdx_model_data"].get(model_hash, {}))
    if not info:
        print(f"warning: unknown MDX model hash {model_hash}; using UVR-MDX-NET-Voc_FT defaults")
        info = {"compensate": 1.021, "mdx_dim_f_set": 3072, "mdx_dim_t_set": 8,
                "mdx_n_fft_scale_set": 7680, "primary_stem": "Vocals"}
    dim_t = 2 ** int(info["mdx_dim_t_set"])
    sidecar = {
        "format": "yintrace-model",
        "version": SIDE_CAR_VERSION,
        "type": "mdx",
        "name": name,
        "model_hash": model_hash,
        "primary_stem": info.get("primary_stem", "Vocals"),
        "n_fft": int(info["mdx_n_fft_scale_set"]),
        "hop": 1024,
        "dim_f": int(info["mdx_dim_f_set"]),
        "dim_t": dim_t,
        "compensate": float(info.get("compensate", 1.0)),
        "input_name": "input",
        "output_name": "output",
        "overlap": args.overlap,
    }
    try:
        import onnxruntime as ort
        sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        inp = sess.get_inputs()[0]
        sidecar["input_name"] = inp.name
        sidecar["output_name"] = sess.get_outputs()[0].name
        shape = inp.shape
        print(f"  onnx input {inp.name} {shape}")
        if isinstance(shape[2], int) and shape[2] != sidecar["dim_f"]:
            sys.exit(f"model dim_f {shape[2]} does not match metadata {sidecar['dim_f']}")
        if isinstance(shape[3], int) and shape[3] != dim_t:
            sys.exit(f"model dim_t {shape[3]} does not match metadata {dim_t}")
    except ImportError:
        print("  (onnxruntime not installed: skipping shape check)")
    os.makedirs(args.out_dir, exist_ok=True)
    dst = os.path.join(args.out_dir, name + ".onnx")
    if os.path.abspath(dst) != os.path.abspath(path):
        shutil.copyfile(path, dst)
    write_json(os.path.join(args.out_dir, name + ".json"), sidecar)
    print(f"model: {name}\n  hash: {model_hash}\n  wrote {dst} and {name}.json")


def cmd_selftest(args):
    """Builds random-weight networks, saves them like UVR files and converts."""
    data = load_uvr_data()
    mods = build_vr_modules()
    torch = mods["torch"]
    cases = [("4band_v2_sn", 123821, False), ("3band_44100_msb2", 123821, False)]
    if args.full:
        cases += [("4band_v3", 56817, True)]
    with tempfile.TemporaryDirectory() as tmp:
        for param_name, arch, v51 in cases:
            bins = int(data["vr_params"][param_name]["bins"])
            torch.manual_seed(0)
            model = build_vr_model(mods, bins, arch, v51, 32, 128)
            pth = os.path.join(tmp, f"selftest_{param_name}.pth")
            torch.save(model.state_dict(), pth)
            size_kib = math.ceil(os.stat(pth).st_size / 1024)
            nearest = min(NN_ARCH_SIZES, key=lambda x: abs(x - size_kib))
            print(f"[{param_name}] random weights: {size_kib} KiB -> size class {nearest} (expected {arch})")
            families = [{31191, 33966, 129605}, {123821, 123812}, {537238, 537227}, {56817}, {218409}]
            if not any(nearest in f and arch in f for f in families):
                sys.exit("architecture size check failed")
            ns = argparse.Namespace(model=pth, out_dir=args.out_dir or tmp, param=param_name,
                                    window_size=512, opset=args.opset, aggression=5)
            cmd_vr(ns)
    print("selftest OK")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    vr = sub.add_parser("vr", help="convert a UVR VR-architecture .pth model to ONNX")
    vr.add_argument("model")
    vr.add_argument("--out-dir", default="build/models")
    vr.add_argument("--param", help="override the band configuration (e.g. 4band_v2_sn)")
    vr.add_argument("--window-size", type=int, default=512)
    vr.add_argument("--opset", type=int, default=17)
    vr.add_argument("--aggression", type=int, default=5, help="UVR aggression setting (0-100), default 5")
    vr.set_defaults(func=cmd_vr)

    mdx = sub.add_parser("mdx", help="identify an MDX-Net ONNX model and write its sidecar")
    mdx.add_argument("model")
    mdx.add_argument("--out-dir", default="build/models")
    mdx.add_argument("--overlap", type=float, default=0.25)
    mdx.set_defaults(func=cmd_mdx)

    st = sub.add_parser("selftest", help="convert random-weight networks to check the toolchain")
    st.add_argument("--out-dir")
    st.add_argument("--opset", type=int, default=17)
    st.add_argument("--full", action="store_true", help="also test a v5.1 (LSTM) network")
    st.set_defaults(func=cmd_selftest)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
