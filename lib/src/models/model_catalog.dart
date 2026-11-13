/// The two separation models YinTrace uses. Both come from the Ultimate
/// Vocal Remover project and are downloaded from its official model
/// repository on first use; they are not part of the app or of this
/// repository.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.title,
    required this.purpose,
    required this.fileName,
    required this.url,
    required this.bytes,
    required this.sha256,
    required this.installedName,
    required this.installedBytes,
  });

  final String id;

  /// Short name shown in the UI.
  final String title;
  final String purpose;

  /// Name of the file as published by UVR.
  final String fileName;
  final String url;
  final int bytes;
  final String sha256;

  /// Name of the file the app loads (the ONNX model).
  final String installedName;
  final int installedBytes;

  /// The download has to be turned into an ONNX model on the device.
  bool get needsAssembly => installedName != fileName;
}

const _releases = 'https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models';

/// MDX-Net "Voc FT": separates the vocals from the accompaniment.
const vocalModel = ModelSpec(
  id: 'vocals',
  title: '人声分离',
  purpose: '把人声从伴奏里分出来',
  fileName: 'UVR-MDX-NET-Voc_FT.onnx',
  url: '$_releases/UVR-MDX-NET-Voc_FT.onnx',
  bytes: 66762490,
  sha256: '534b2070fcc7df514b13ef660dc8cbb328679c2374d04354a5c42bb14ecce111',
  installedName: 'UVR-MDX-NET-Voc_FT.onnx',
  installedBytes: 66762490,
);

/// VR architecture "6_HP-Karaoke": removes backing vocals from the vocals.
/// Published as PyTorch weights; assembled into ONNX on the device with the
/// recipe in `assets/models/karaoke_graph.json`.
const karaokeModel = ModelSpec(
  id: 'karaoke',
  title: '去和声',
  purpose: '从人声里去掉和声，只留主唱',
  fileName: '6_HP-Karaoke-UVR.pth',
  url: '$_releases/6_HP-Karaoke-UVR.pth',
  bytes: 126782699,
  sha256: '4ce7eaaa9e56f09366b788aebf6d3a72aec8145692c56f1e090e4e7e2d7ce65f',
  installedName: '6_HP-Karaoke-UVR.onnx',
  installedBytes: 126737731,
);

const separationModels = [vocalModel, karaokeModel];

String formatMegabytes(int bytes) => '${(bytes / 1e6).round()} MB';
