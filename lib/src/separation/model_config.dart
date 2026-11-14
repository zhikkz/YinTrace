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
  // UVR segment size 128: lower activation memory with a modest context
  // tradeoff. The constructor keeps UVR's original 256 for reference tests.
  static const vocFt = MdxConfig(dimT: 128, overlap: 0.5);

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
}

/// Configuration of a VR-architecture model (UVR `lib_v5/vr_network`).
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
    'Vocals',
    'Other',
    'Bass',
    'Drums',
    'Guitar',
    'Piano',
    'Synthesizer',
    'Strings',
    'Woodwinds',
    'Brass',
    'Wind Inst',
  }.contains(primaryStem);

  /// 6_HP-Karaoke-UVR (UVR model hash 6b5916069a49be3fe29d4397ecfd73fa):
  /// VR v5 network with the band configuration `3band_44100_msb2`. Its
  /// primary stem is the instrumental plus backing vocals; the secondary
  /// stem is the lead vocal.
  static const karaoke6Hp = VrConfig(
    name: '6_HP-Karaoke-UVR',
    windowSize: 320,
    bins: 640,
    sr: 44100,
    preFilterStart: 639,
    preFilterStop: 640,
    midSideB2: true,
    isKaraoke: true,
    bands: [
      VrBand(sr: 11025, hl: 108, nFft: 1024, cropStart: 0, cropStop: 187, lpfStart: 92, lpfStop: 186),
      VrBand(
        sr: 22050,
        hl: 216,
        nFft: 768,
        cropStart: 0,
        cropStop: 212,
        hpfStart: 68,
        hpfStop: 34,
        lpfStart: 174,
        lpfStop: 209,
      ),
      VrBand(sr: 44100, hl: 432, nFft: 640, cropStart: 66, cropStop: 307, hpfStart: 86, hpfStop: 72),
    ],
  );
}
