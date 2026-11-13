import 'dart:convert';
import 'dart:io';

/// Configuration of an MDX-Net model (e.g. UVR-MDX-NET-Voc_FT).
class MdxConfig {
  const MdxConfig({
    this.name = 'UVR-MDX-NET-Voc_FT',
    this.nFft = 7680,
    this.hop = 1024,
    this.dimF = 3072,
    this.dimT = 256,
    this.compensate = 1.021,
    this.primaryStem = 'Vocals',
    this.overlap = 0.25,
    this.inputName = 'input',
    this.outputName = 'output',
  });

  /// Defaults of UVR-MDX-NET-Voc_FT (UVR model hash 77d07b2667ddf05b9e3175941b4454a0).
  static const vocFt = MdxConfig();

  final String name;
  final int nFft;
  final int hop;
  final int dimF;
  final int dimT;
  final double compensate;
  final String primaryStem;

  /// Fraction of overlap between consecutive chunks (UVR default 0.25).
  final double overlap;
  final String inputName;
  final String outputName;

  int get chunkSize => hop * (dimT - 1);
  int get trim => nFft ~/ 2;
  List<int> get inputShape => [1, 4, dimF, dimT];

  factory MdxConfig.fromJson(Map<String, dynamic> j) => MdxConfig(
        name: j['name'] as String? ?? 'mdx',
        nFft: (j['n_fft'] as num?)?.toInt() ?? 7680,
        hop: (j['hop'] as num?)?.toInt() ?? 1024,
        dimF: (j['dim_f'] as num?)?.toInt() ?? 3072,
        dimT: (j['dim_t'] as num?)?.toInt() ?? 256,
        compensate: (j['compensate'] as num?)?.toDouble() ?? 1.0,
        primaryStem: j['primary_stem'] as String? ?? 'Vocals',
        overlap: (j['overlap'] as num?)?.toDouble() ?? 0.25,
        inputName: j['input_name'] as String? ?? 'input',
        outputName: j['output_name'] as String? ?? 'output',
      );
}

/// One band of a VR multi-band spectrogram configuration
/// (UVR `lib_v5/vr_network/modelparams/*.json`).
class VrBand {
  const VrBand({
    required this.sr,
    required this.hl,
    required this.nFft,
    required this.cropStart,
    required this.cropStop,
    this.hpfStart = 0,
    this.hpfStop = 0,
    this.lpfStart = 0,
    this.lpfStop = 0,
    this.convertChannels,
  });

  final int sr;
  final int hl;
  final int nFft;
  final int cropStart;
  final int cropStop;
  final int hpfStart;
  final int hpfStop;
  final int lpfStart;
  final int lpfStop;
  final String? convertChannels;

  factory VrBand.fromJson(Map<String, dynamic> j) => VrBand(
        sr: (j['sr'] as num).toInt(),
        hl: (j['hl'] as num).toInt(),
        nFft: (j['n_fft'] as num).toInt(),
        cropStart: (j['crop_start'] as num).toInt(),
        cropStop: (j['crop_stop'] as num).toInt(),
        hpfStart: (j['hpf_start'] as num?)?.toInt() ?? 0,
        hpfStop: (j['hpf_stop'] as num?)?.toInt() ?? 0,
        lpfStart: (j['lpf_start'] as num?)?.toInt() ?? 0,
        lpfStop: (j['lpf_stop'] as num?)?.toInt() ?? 0,
        convertChannels: j['convert_channels'] as String?,
      );
}

/// Configuration of a VR-architecture model converted with
/// `tools/prepare_models.py vr` (e.g. 6_HP-Karaoke-UVR).
class VrConfig {
  const VrConfig({
    required this.name,
    required this.bins,
    required this.bands,
    required this.sr,
    required this.preFilterStart,
    required this.preFilterStop,
    this.midSide = false,
    this.midSideB2 = false,
    this.reverse = false,
    this.isV51 = false,
    this.windowSize = 512,
    this.offset = 128,
    this.primaryStem = 'Instrumental',
    this.isKaraoke = false,
    this.aggression = 5,
    this.aggrCorrection,
    this.inputName = 'input',
    this.outputName = 'mask',
  });

  final String name;
  final int bins;
  final List<VrBand> bands;
  final int sr;
  final int preFilterStart;
  final int preFilterStop;
  final bool midSide;
  final bool midSideB2;
  final bool reverse;
  final bool isV51;
  final int windowSize;
  final int offset;
  final String primaryStem;
  final bool isKaraoke;

  /// UVR "aggression setting" (0-100, default 5).
  final int aggression;
  final (double left, double right)? aggrCorrection;
  final String inputName;
  final String outputName;

  List<int> get inputShape => [1, 2, bins + 1, windowSize];

  /// Stems UVR treats as "non accompaniment" (affects aggressiveness).
  bool get primaryIsNonAccompaniment => const {
        'Vocals', 'Other', 'Bass', 'Drums', 'Guitar', 'Piano', 'Synthesizer',
        'Strings', 'Woodwinds', 'Brass', 'Wind Inst',
      }.contains(primaryStem);

  factory VrConfig.fromSidecar(Map<String, dynamic> j) {
    final p = j['params'] as Map<String, dynamic>;
    final bandMap = p['band'] as Map<String, dynamic>;
    final keys = bandMap.keys.map(int.parse).toList()..sort();
    final corr = p['aggr_correction'] as Map<String, dynamic>?;
    return VrConfig(
      name: j['name'] as String? ?? 'vr',
      bins: (p['bins'] as num).toInt(),
      bands: [
        for (final k in keys)
          VrBand.fromJson(bandMap['$k'] as Map<String, dynamic>)
      ],
      sr: (p['sr'] as num?)?.toInt() ?? 44100,
      preFilterStart: (p['pre_filter_start'] as num).toInt(),
      preFilterStop: (p['pre_filter_stop'] as num).toInt(),
      midSide: p['mid_side'] == true,
      midSideB2: p['mid_side_b2'] == true,
      reverse: p['reverse'] == true,
      isV51: j['is_v51'] == true,
      windowSize: (j['window_size'] as num?)?.toInt() ?? 512,
      offset: (j['offset'] as num?)?.toInt() ?? 128,
      primaryStem: j['primary_stem'] as String? ?? 'Instrumental',
      isKaraoke: j['is_karaoke'] == true,
      aggression: (j['aggression'] as num?)?.toInt() ?? 5,
      aggrCorrection: corr == null
          ? null
          : ((corr['left'] as num).toDouble(), (corr['right'] as num).toDouble()),
      inputName: j['input_name'] as String? ?? 'input',
      outputName: j['output_name'] as String? ?? 'mask',
    );
  }

  /// 4band_v2_sn (one of the two UVR karaoke VR configurations).
  static VrConfig karaoke4BandV2Sn({String name = '6_HP-Karaoke-UVR'}) => VrConfig(
        name: name,
        bins: 672,
        sr: 44100,
        preFilterStart: 668,
        preFilterStop: 672,
        isKaraoke: true,
        bands: const [
          VrBand(sr: 7350, hl: 80, nFft: 640, cropStart: 0, cropStop: 85, lpfStart: 25, lpfStop: 53),
          VrBand(sr: 7350, hl: 80, nFft: 320, cropStart: 4, cropStop: 87, hpfStart: 25, hpfStop: 12, lpfStart: 31, lpfStop: 62),
          VrBand(sr: 14700, hl: 160, nFft: 512, cropStart: 17, cropStop: 216, hpfStart: 48, hpfStop: 24, lpfStart: 139, lpfStop: 210),
          VrBand(sr: 44100, hl: 480, nFft: 960, cropStart: 78, cropStop: 383, hpfStart: 130, hpfStop: 86, convertChannels: 'stereo_n'),
        ],
      );

  /// 3band_44100_msb2 (the other UVR karaoke VR configuration).
  static VrConfig karaoke3BandMsb2({String name = '5_HP-Karaoke-UVR'}) => VrConfig(
        name: name,
        bins: 640,
        sr: 44100,
        preFilterStart: 639,
        preFilterStop: 640,
        midSideB2: true,
        isKaraoke: true,
        bands: const [
          VrBand(sr: 11025, hl: 108, nFft: 1024, cropStart: 0, cropStop: 187, lpfStart: 92, lpfStop: 186),
          VrBand(sr: 22050, hl: 216, nFft: 768, cropStart: 0, cropStop: 212, hpfStart: 68, hpfStop: 34, lpfStart: 174, lpfStop: 209),
          VrBand(sr: 44100, hl: 432, nFft: 640, cropStart: 66, cropStop: 307, hpfStart: 86, hpfStop: 72),
        ],
      );
}

/// Reads `<model>.json` next to `<model>.onnx` if it exists.
Map<String, dynamic>? readSidecar(String onnxPath) {
  final base = onnxPath.endsWith('.onnx')
      ? onnxPath.substring(0, onnxPath.length - 5)
      : onnxPath;
  final f = File('$base.json');
  if (!f.existsSync()) return null;
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}
