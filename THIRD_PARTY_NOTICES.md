# Third-party notices

## Ultimate Vocal Remover GUI (MIT License)

https://github.com/Anjok07/ultimatevocalremovergui

- `lib/src/separation/mdx_separator.dart` and `lib/src/separation/vr_separator.dart`
  port the MDX-Net demixing and VR-architecture pre/post-processing of UVR
  (`separate.py`, `lib_v5/spec_utils.py`).
- `tools/prepare_models.py` re-implements the VR network definitions of
  `lib_v5/vr_network` so that UVR state dicts load unchanged.
- `tools/uvr_model_data.json` contains UVR's model metadata and VR band
  configurations (`models/*/model_data/model_data.json`,
  `lib_v5/vr_network/modelparams/*.json`).
- The models `UVR-MDX-NET-Voc_FT` and `6_HP-Karaoke-UVR` are distributed by
  the UVR project. The UVR authors ask third-party applications using their
  models to credit UVR and its developers.

## miniaudio

https://github.com/mackron/miniaudio — `packages/yintrace_audio/src/miniaudio.h`
(version 0.11.25), available under your choice of the public domain (Unlicense)
or MIT No Attribution. See the license text at the end of the header.

## Flutter packages

The app depends on Flutter packages listed in `pubspec.yaml` (e.g.
`flutter_onnxruntime`, `fftea`, `file_picker`, `path_provider`,
`wakelock_plus`, `ffi`), each under its own license as published on pub.dev.
ONNX Runtime is © Microsoft Corporation (MIT License).
