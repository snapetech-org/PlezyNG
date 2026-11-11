import 'dart:typed_data';

/// Ordered decoded PCM from the current music core. A source stops capture
/// before disposing its player. The optional bridge never opens another decoder.
abstract interface class MusicPcmCaptureSource {
  Future<bool> musicPcmCaptureAvailable();
  Future<bool> setMusicPcmCaptureEnabled(bool enabled);
  Future<List<MusicPcmBlock>> drainMusicPcmCapture();
}

class MusicPcmBlock {
  const MusicPcmBlock({
    required this.presentationTime,
    required this.sampleRate,
    required this.channels,
    required this.samples,
    required this.droppedFrames,
    required this.generation,
  });
  final Duration presentationTime;
  final int sampleRate, channels, droppedFrames, generation;
  final Float32List samples;
  int get frames => samples.length ~/ channels;
  static MusicPcmBlock? parse(Map<Object?, Object?> value) {
    final pts = value['presentationTimeUs'], rate = value['sampleRate'], channels = value['channels'];
    final dropped = value['droppedFrames'], pcm = value['pcm'], generation = value['generation'];
    if (pts is! int ||
        pts < 0 ||
        rate is! int ||
        rate < 8000 ||
        rate > 384000 ||
        generation is! int ||
        generation < 0 ||
        channels is! int ||
        channels < 1 ||
        channels > 8 ||
        dropped is! int ||
        dropped < 0 ||
        value['encoding'] != 'float32' ||
        pcm is! Uint8List ||
        pcm.isEmpty ||
        pcm.lengthInBytes % (channels * 4) != 0 ||
        pcm.lengthInBytes > 512 * channels * 4) {
      return null;
    }
    final data = ByteData.sublistView(pcm);
    final samples = Float32List(pcm.lengthInBytes ~/ 4);
    for (var i = 0; i < samples.length; i++) {
      final value = data.getFloat32(i * 4, Endian.host);
      if (!value.isFinite) return null;
      samples[i] = value.clamp(-1.0, 1.0);
    }
    return MusicPcmBlock(
      presentationTime: Duration(microseconds: pts),
      sampleRate: rate,
      channels: channels,
      samples: samples,
      droppedFrames: dropped,
      generation: generation,
    );
  }
}
