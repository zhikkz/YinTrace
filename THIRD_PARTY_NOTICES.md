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

## ONNX Runtime 1.28.0 (MIT License and third-party notices)

https://github.com/microsoft/onnxruntime — linked through the
`flutter_onnxruntime` plugin (MIT License, © MASIC AI). The iOS and macOS
CocoaPods dependency and the Android Maven dependency are pinned to 1.28.0.
YinTrace ships the [Microsoft MIT text](assets/licenses/onnxruntime-1.28.0-LICENSE.txt)
and the [complete 1.28.0 third-party notices](assets/licenses/onnxruntime-1.28.0-ThirdPartyNotices.txt),
including the KleidiAI Apache 2.0 text. The two files were copied verbatim from
Microsoft's [ONNX Runtime 1.28.0 macOS arm64 wheel](https://pypi.org/project/onnxruntime/1.28.0/#files).
The iOS CI reads the Podfile lock and checks both files inside the IPA.

The iOS podspecs use the device and simulator XCFramework from Microsoft's
SHA-256-pinned NuGet package. Its manifest identifies ONNX Runtime commit
`da9b5e364c465de65c49d91e696cd6485270757f`. The Objective-C binding is
fetched at a fixed commit of the plugin maintainer's source mirror. Its
entire `objectivec` tree matches that Microsoft commit (Git tree
`4f2470ea4b95f32b759534719040b7a5bd35c7bb`).
[Microsoft NuGet package](https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime/1.28.0)
· [Objective-C source](https://github.com/masicai/onnxruntime-swift-package-manager/tree/3fb68950a5967c8c120f9f99a1a850a43985a4c9/objectivec)

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

## Mandarin pronunciation data

**Unicode Unihan 17.0.0.** [Unihan.zip](https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip)
supplies `kMandarin` and `kSimplifiedVariant` for [single-character readings](assets/mandarin/unihan-readings.tsv)
and the GB2312 onset table. Copyright Unicode, Inc. The [Unicode License v3](assets/licenses/Unicode-3.0.txt)
is bundled. Source ZIP SHA-256 `f7a48b2b545acfaa77b2d607ae28747404ce02baefee16396c5d2d7a8ef34b5e`.

**CC-CEDICT.** CC-CEDICT contributors, published by MDBG. The source credits
CEDICT (Copyright (C) 1997, 1998 Paul Andrew Denisowski). YinTrace uses the
[MDBG 1.0 UTF-8 snapshot](https://www.mdbg.net/chinese/dictionary?page=cedict)
dated 2026-11-24T00:04:08Z. Source ZIP SHA-256
`f26840577f87708bc8aec11fddacd8a5d85a1defcced19865d158d320d05e10c`.

**Changes.** YinTrace extracted Chinese headwords and pronunciations, removed
definitions and tones, omitted non-Mandarin placeholders, and converted the
erhua suffix `r` to `er` for independently timed 儿/兒. The
[readings table](assets/mandarin/cc-cedict-readings.tsv) contains supplementary
single-character readings and agreed non-default syllables within phrases.
The [segmentation table](assets/mandarin/cc-cedict-words.tsv) contains headwords
with no agreed non-default syllables, including multiply pronounced words.
It omits redundant spellings already covered by Unihan simplification. Both
tables are available separately under [CC BY-SA 4.0 International](assets/licenses/CC-BY-SA-4.0.txt).
Rebuild the Mandarin tables with [build_mandarin_readings.py](tools/reference/build_mandarin_readings.py).
The [original lyric rules and exceptions](lib/src/analysis/mandarin_lyric_rules.dart)
are written for YinTrace.

**Earlier distributions.** `pinyin` 3.3.0 (BSD 2-Clause for the Dart package) shipped
the phrase table produced by its [generation script](https://github.com/sun-jiao/dart-pinyin/blob/cda5704260dba7df639a1756de78c24f0632414d/dev/data/phrase_generator.dart)
from [phrase-pinyin-data](https://github.com/mozillazg/phrase-pinyin-data)'s
`large_pinyin.txt`, which combines CC-CEDICT readings and readings from other
sources. The [phrase-pinyin-data MIT notice](assets/licenses/phrase-pinyin-data-LICENSE.txt)
applies to its MIT-licensed material. The scope of CC-CEDICT's share-alike
terms for that mixed artifact needs separate assessment. YinTrace replaced
that package and the earlier pypinyin-derived onset table with the sources above.

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

## HuBERTFA v0.0.7 code, model, and dictionaries

YinTrace ports the HuBERTFA AlignmentDecoder to Dart and bundles the upstream
[Apache 2.0 code license](assets/models/hubertfa-LICENSE.txt). YinTrace retrieves
the original [v0.0.7 release ZIP](https://github.com/wolfgitpr/HubertFA/releases/tag/v0.0.7)
on demand and verifies SHA-256 `48bd6dbcc293e47cc6cbcc556baf575e3d91d61d0ac88ddeccd6098f8f346fa2`.
The ZIP contains the following files with no accompanying license text.

| File or component | Provenance and license evidence |
| --- | --- |
| `model.onnx` | Neither the verified ZIP nor the release notes specifies terms for the trained weights or ONNX export. |
| Chinese HuBERT base encoder | The ZIP's `config.json` names `cn_hubert` and `dependencies/chinese-hubert-base`. The [TencentGameMate model card](https://huggingface.co/TencentGameMate/chinese-hubert-base) labels the published base model MIT. The exact base checkpoint and terms for the combined export remain to be confirmed. |
| `ds_cmudict-07b.txt` | Converted English dictionary based on the [Carnegie Mellon Pronouncing Dictionary](https://github.com/cmusphinx/cmudict). The [CMUdict notice](assets/licenses/cmudict-LICENSE.txt) ships with YinTrace. The terms on upstream conversion changes remain to be confirmed. |
| `ds-zh-pinyin-lite.txt` | Chinese phoneme table also present in the [v0.0.7 source tag](https://github.com/wolfgitpr/HubertFA/tree/v0.0.7/dictionaries). Its file-specific terms and upstream source are unconfirmed. |
| `japanese_dict_full.txt` | Japanese phoneme table also present in the same source tag. Its file-specific terms and upstream source are unconfirmed. |

The app exposes this [provenance notice](assets/licenses/hubertfa-v0.0.7-provenance.txt)
alongside the decoder and CMUdict licenses.

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
| `file_picker`, `archive`, `kana_kit` | MIT |
| `fftea` | Apache 2.0 |
| `crypto`, `ffi`, `path_provider` | BSD 3-Clause |
| `wakelock_plus` (and `package_info_plus`) | BSD 3-Clause |
| `cupertino_icons` | MIT |

`archive` 4.7.1 also ships code derived from Zstandard 1.5.7 (including xxHash)
and other projects. The verbatim [LICENSE-other.md](assets/licenses/archive-4.7.1-LICENSE-other.md)
is taken from the [versioned pub.dev archive](https://pub.dev/api/archives/archive-4.7.1.tar.gz)
and shipped alongside the main package license that Flutter collects.

## Development-only tools

Development dependencies include CairoSVG and Pillow (icon rendering),
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
