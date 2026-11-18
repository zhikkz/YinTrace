# Third-party notices

YinTrace is free software released under the GNU Affero General Public
License, version 3 (see `LICENSE`). It is built on the work listed here. Those
parts were published under permissive terms (MIT, BSD, Apache 2.0, public
domain) that are compatible with the AGPL; their copyright notices and license
texts are kept below, as those licenses require. The app shows the same credits
under 设置 → 致谢与开源许可, together with the licenses of every Flutter
package it links.

What this repository does **not** contain: no weights of the separation
models, no audio, and no lyrics of published songs (the lyrics in the tests
and examples were written for this project). The one model it does contain
is the small pitch model SwiftF0 (MIT, see below).

## Models: UVR-MDX-NET-Voc_FT and 6_HP-Karaoke-UVR

Trained and published by the developers of Ultimate Vocal Remover,
[Anjok07](https://github.com/anjok07) and [aufr33](https://github.com/aufr33).

- The models are **not redistributed** by this project. The app downloads the
  original files and checks their SHA-256: from a copy of UVR's public models
  on Hugging Face (`Blane187/all_public_uvr_models`, through hf-mirror.com)
  or, when that does not work, from UVR's official model repository
  (`https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/`).
- UVR's README says: "For all third-party application developers who wish to
  use our models, please honor the MIT license by providing credit to UVR and
  its developers." YinTrace credits them in the app, in the model download
  dialog and here.
- `assets/models/karaoke_graph.bin` / `.json` hold the *graph* of the
  6_HP-Karaoke-UVR network (its layer structure, exported from the network
  definition below) and the byte offsets of the weight tensors inside the
  official `.pth`. They contain no weight data. `mdx_graph.bin` / `.json`
  contain only six literal bytes and a copy recipe for the dynamic MDX time axis.

## Ultimate Vocal Remover GUI (MIT License)

https://github.com/Anjok07/ultimatevocalremovergui

- `lib/src/separation/mdx_separator.dart` and
  `lib/src/separation/vr_separator.dart` port UVR's MDX-Net demixing and
  VR-architecture pre/post-processing (`separate.py`, `lib_v5/spec_utils.py`).
- `tools/build_karaoke_graph.py` re-implements the VR network definition
  (`lib_v5/vr_network/nets.py`, `layers.py`) so that UVR's state dict loads
  unchanged.
- `lib/src/separation/model_config.dart` and
  `tools/reference/vr_band_params.json` contain UVR's band configurations
  (`lib_v5/vr_network/modelparams/`) and model parameters
  (`models/*/model_data/model_data.json`).

UVR's README states that its code is MIT-licensed. The license file last
present in that repository reads:

    MIT License

    Copyright (c) 2022 Anjok07, Aufr33

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## vocal-remover by tsurumeso (MIT License)

https://github.com/tsurumeso/vocal-remover — the origin of UVR's VR
architecture (network layers and multi-band spectrogram processing).

    MIT License

    Copyright (c) 2019 tsurumeso

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## MDX-Net by Kuielab / Woosung Choi (MIT License)

https://github.com/kuielab/mdx-net — the origin of the MDX-Net architecture
and of the chunked STFT demixing procedure.

    MIT License

    Copyright (c) 2020 KINoAI

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## miniaudio

https://github.com/mackron/miniaudio — `packages/yintrace_audio/src/miniaudio.h`
(version 0.11.25), by David Reid. Available under the public domain
(Unlicense) or MIT No Attribution, at your choice; the full text is at the end
of the header. YinTrace uses it under MIT No Attribution.

## ONNX Runtime (MIT License)

https://github.com/microsoft/onnxruntime — linked through the
`flutter_onnxruntime` plugin (MIT License, © MASIC AI). ONNX Runtime itself
bundles further open-source components; their notices are in
`ThirdPartyNotices.txt` of the ONNX Runtime repository.

    MIT License

    Copyright (c) Microsoft Corporation

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## pypinyin and pinyin-data (MIT License)

https://github.com/mozillazg/python-pinyin and
https://github.com/mozillazg/pinyin-data — `lib/src/analysis/pinyin_initials.dart`
(the onset class of each GB2312 character) is generated from their data by
`tools/reference/make_pinyin_table.py`.

    The MIT License (MIT)

    Copyright (c) 2016 mozillazg, 闲耘 <hotoo.cn@gmail.com>

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in
    the Software without restriction, including without limitation the rights to
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
    the Software, and to permit persons to whom the Software is furnished to do so,
    subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
    FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
    COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
    IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    The MIT License (MIT)

    Copyright (c) 2016 mozillazg

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## Model: SwiftF0 (MIT License)

https://github.com/lars76/swift-f0 — L. Nieradzik, "SwiftF0: Fast and
Accurate Monophonic Pitch Detection", arXiv:2508.18440, 2025. The app uses it
to measure the original singer's pitch when a song is imported.

- `assets/models/swift_f0.onnx` is the model of the official swift-f0 0.3.0
  release on PyPI (`swift_f0/model.onnx`, SHA-256
  `6385e8c2ebc3872e82c9ff5946228de44cd3be77a750ea53698b7dbfe94b0a22`) with its
  interface adapted for the app by `tools/build_pitch_model.py`: the inputs
  `fmin` and `fmax` became constants (60 and 1400 Hz), the `pitch` output is
  cast to float32, and `pitch` and `confidence` are joined into one output.
  The weights and all other nodes are unchanged; the script checks that the
  result computes the same pitch and confidence as the original.
- `lib/src/dsp/swift_f0.dart` follows the package's own use of the model
  (`swift_f0/core.py`): 30 s runs with 11 frames of history and 10 of
  look-ahead, and frames of digital silence treated as unvoiced.

The license file of the release reads:

    MIT License

    Copyright (c) 2025-2026 Lars Nieradzik

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## YIN

The singer's own pitch, live in practice and free practice, is measured with
the algorithm published in A. de Cheveigné and H. Kawahara, "YIN, a
fundamental frequency estimator for speech and music", J. Acoust. Soc. Am. 111
(4), 2002; imports use it too when the pitch model cannot run. The
implementation in `lib/src/dsp/yin.dart` was written for this project from the
paper.

## Flutter packages

Linked into the app, each under the license published with the package:

| Package | License |
|---|---|
| Flutter SDK, `flutter_localizations` | BSD 3-Clause |
| `flutter_onnxruntime` | MIT |
| `file_picker` | MIT |
| `fftea` | Apache 2.0 |
| `crypto`, `ffi`, `path_provider` | BSD 3-Clause |
| `wakelock_plus` (and `package_info_plus`) | BSD 3-Clause |
| `cupertino_icons` | MIT |

## Development-only tools

Not part of the app: CairoSVG (LGPL-3.0-or-later, icon rendering only),
PyTorch, ONNX, NumPy, SciPy, librosa and pYIN (used by
`tools/` to export the network graph and to produce reference values for the
tests).

## flutter_onnxruntime local patch (MIT License)

`packages/flutter_onnxruntime/` preserves version 1.9.0 from pub.dev,
https://github.com/masicai/flutter_onnxruntime. YinTrace adds an Apple
`SessionOptionsHelper` to honor `useArena: false`. The added internal header
`ort_session_internal.h` comes from microsoft/onnxruntime v1.28.0 (MIT,
Copyright (c) Microsoft Corporation). Both original LICENSE and copyright
headers are preserved. YinTrace additions are AGPL-3.0-only.

    MIT License

    Copyright (c) 2025 MASIC AI

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
