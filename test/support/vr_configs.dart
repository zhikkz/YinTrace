import 'package:yintrace/src/separation/model_config.dart';

/// `4band_v2_sn`, a second UVR band configuration. The app's model does not
/// use it; the tests do, to cover four bands and the `stereo_n` channel
/// conversion of the VR pre/post-processing.
const vr4BandV2Sn = VrConfig(
  name: '4band_v2_sn',
  bins: 672,
  sr: 44100,
  preFilterStart: 668,
  preFilterStop: 672,
  isKaraoke: true,
  bands: [
    VrBand(sr: 7350, hl: 80, nFft: 640, cropStart: 0, cropStop: 85, lpfStart: 25, lpfStop: 53),
    VrBand(sr: 7350, hl: 80, nFft: 320, cropStart: 4, cropStop: 87, hpfStart: 25, hpfStop: 12, lpfStart: 31, lpfStop: 62),
    VrBand(sr: 14700, hl: 160, nFft: 512, cropStart: 17, cropStop: 216, hpfStart: 48, hpfStop: 24, lpfStart: 139, lpfStop: 210),
    VrBand(sr: 44100, hl: 480, nFft: 960, cropStart: 78, cropStop: 383, hpfStart: 130, hpfStop: 86, convertChannels: 'stereo_n'),
  ],
);
