import 'dart:io';
import 'dart:typed_data';

/// Minimal RIFF/WAVE reader & writer (PCM 16/24/32 bit and float32).
class WavData {
  WavData(this.samples, this.channels, this.sampleRate);

  /// Interleaved samples in [-1, 1].
  final Float32List samples;
  final int channels;
  final int sampleRate;

  int get frames => samples.length ~/ channels;
}

WavData decodeWav(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('not a WAV file');
  }
  var pos = 12;
  int? format, channels, rate, bits;
  Uint8List? data;
  while (pos + 8 <= bytes.length) {
    final id = tag(pos);
    final size = bd.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      format = bd.getUint16(body, Endian.little);
      channels = bd.getUint16(body + 2, Endian.little);
      rate = bd.getUint32(body + 4, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE && size >= 26) {
        format = bd.getUint16(body + 24, Endian.little); // extensible sub format
      }
    } else if (id == 'data') {
      final end = (body + size).clamp(0, bytes.length);
      data = Uint8List.sublistView(bytes, body, end);
    }
    pos = body + size + (size.isOdd ? 1 : 0);
  }
  if (format == null || data == null || channels == null || rate == null || bits == null) {
    throw const FormatException('incomplete WAV file');
  }
  final db = ByteData.sublistView(data);
  final bytesPer = bits ~/ 8;
  final n = data.length ~/ bytesPer;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final o = i * bytesPer;
    if (format == 3 && bits == 32) {
      out[i] = db.getFloat32(o, Endian.little);
    } else if (format == 1 && bits == 16) {
      out[i] = db.getInt16(o, Endian.little) / 32768.0;
    } else if (format == 1 && bits == 24) {
      var v = data[o] | (data[o + 1] << 8) | (data[o + 2] << 16);
      if (v & 0x800000 != 0) v -= 0x1000000;
      out[i] = v / 8388608.0;
    } else if (format == 1 && bits == 32) {
      out[i] = db.getInt32(o, Endian.little) / 2147483648.0;
    } else if (format == 1 && bits == 8) {
      out[i] = (data[o] - 128) / 128.0;
    } else {
      throw FormatException('unsupported WAV encoding (format $format, $bits bit)');
    }
  }
  return WavData(out, channels, rate);
}

/// Encodes interleaved float samples as 16-bit PCM WAV.
Uint8List encodeWav16(Float32List samples, int channels, int sampleRate) {
  final dataBytes = samples.length * 2;
  final b = BytesBuilder(copy: false);
  final header = ByteData(44);
  void str(int o, String s) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  header.setUint32(4, 36 + dataBytes, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * channels * 2, Endian.little);
  header.setUint16(32, channels * 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  str(36, 'data');
  header.setUint32(40, dataBytes, Endian.little);
  b.add(header.buffer.asUint8List());
  final pcm = Int16List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i] * 32767).round();
    pcm[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
  }
  b.add(pcm.buffer.asUint8List());
  return b.takeBytes();
}

WavData readWavFile(String path) => decodeWav(File(path).readAsBytesSync());

void writeWavFile(String path, Float32List samples, int channels, int sampleRate) =>
    File(path).writeAsBytesSync(encodeWav16(samples, channels, sampleRate));
