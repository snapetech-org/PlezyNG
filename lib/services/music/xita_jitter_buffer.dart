import 'dart:collection';
import 'dart:typed_data';
import 'xita_packet.dart';

/// A bounded reorder window. Rendering advances the source clock even when a
/// packet is missing, replacing only the missing frames with silence.
class XitaJitterBuffer {
  XitaJitterBuffer(this.descriptor) : clock = XitaClock(descriptor.sampleRate);
  final XitaDescriptor descriptor;
  final XitaClock clock;
  final _packets = SplayTreeMap<int, XitaAudio>();
  int? _cursor;
  int _queuedFrames = 0;
  int missingFrames = 0;
  int droppedPackets = 0;

  bool add(XitaAudio packet, int arrivalMicros) {
    if (packet.format != descriptor.format ||
        packet.channels != descriptor.channels ||
        packet.terminated ||
        packet.suspended) {
      return false;
    }
    final frame = clock.unwrap(packet.frame);
    if (_cursor != null && (frame + packet.frames <= _cursor! || frame - _cursor! > descriptor.sampleRate ~/ 2)) {
      droppedPackets++;
      return false;
    }
    if (_packets.containsKey(frame) ||
        _packets.length >= 1024 ||
        _queuedFrames + packet.frames > descriptor.sampleRate ~/ 2) {
      droppedPackets++;
      return false;
    }
    // Reject overlap, including a replay with a different starting counter.
    final before = _packets.lastKeyBefore(frame + 1);
    final after = _packets.firstKeyAfter(frame - 1);
    if (before != null && before + _packets[before]!.frames > frame || after != null && after < frame + packet.frames) {
      droppedPackets++;
      return false;
    }
    clock.observe(packet, arrivalMicros);
    if (!clock.ready) return false;
    _cursor ??= frame;
    _packets[frame] = packet;
    _queuedFrames += packet.frames;
    return true;
  }

  XitaAudio? _packetAt(int sample) {
    final key = _packets.lastKeyBefore(sample + 1);
    final packet = key == null ? null : _packets[key];
    return packet != null && !packet.skipped && sample < key! + packet.frames ? packet : null;
  }

  /// Render for the actual audible WAV timeline, not the time at which bytes
  /// enter HTTP. Fractional source positions reconcile independent audio clocks.
  Uint8List renderScheduled(int frames, {required double presentationMicros, required double microsPerFrame}) {
    if (frames < 0 ||
        frames > 4096 ||
        !presentationMicros.isFinite ||
        !microsPerFrame.isFinite ||
        microsPerFrame <= 0) {
      throw ArgumentError('Invalid scheduled audio window');
    }
    final bytes = ByteData(frames * descriptor.channels * 4);
    if (!clock.ready || frames == 0) return bytes.buffer.asUint8List();
    var last = 0;
    for (var index = 0; index < frames; index++) {
      final source = clock.frameAtMicros(presentationMicros + index * microsPerFrame);
      final frame = source.floor(), fraction = source - source.floor();
      last = frame;

      final first = _packetAt(frame), second = fraction < .000001 ? first : _packetAt(frame + 1);
      if (first == null || second == null) {
        missingFrames++;
        continue;
      }
      final firstFrame = frame - clock.unwrap(first.frame);
      final secondFrame = frame + (identical(first, second) && fraction < .000001 ? 0 : 1) - clock.unwrap(second.frame);
      for (var channel = 0; channel < descriptor.channels; channel++) {
        final a = first.samples[firstFrame * descriptor.channels + channel];
        final b = second.samples[secondFrame * descriptor.channels + channel];
        bytes.setFloat32((index * descriptor.channels + channel) * 4, a + (b - a) * fraction, Endian.little);
      }
    }
    if (_cursor == null || last > _cursor!) _cursor = last;
    final expired = _packets.keys.where((key) => key + _packets[key]!.frames < last).toList();
    for (final key in expired) {
      _queuedFrames -= _packets.remove(key)!.frames;
    }
    return bytes.buffer.asUint8List();
  }

  /// Float32 little-endian WAV payload, at most one output tick.
  Uint8List render(int nowMicros, {int maximumFrames = 4096}) {
    if (_cursor == null || !clock.ready) return Uint8List(0);
    final available = ((nowMicros - clock.presentationMicros(_cursor!)) * descriptor.sampleRate / 1000000).floor();
    final frames = available.clamp(0, maximumFrames);
    if (frames == 0) return Uint8List(0);
    final bytes = ByteData(frames * descriptor.channels * 4);
    for (var index = 0; index < frames; index++) {
      final frame = _cursor! + index;
      final key = _packets.lastKeyBefore(frame + 1);
      final packet = key == null ? null : _packets[key];
      if (packet == null || frame >= key! + packet.frames || packet.skipped) {
        missingFrames++;
        continue;
      }
      for (var channel = 0; channel < descriptor.channels; channel++) {
        bytes.setFloat32(
          (index * descriptor.channels + channel) * 4,
          packet.samples[(frame - key) * descriptor.channels + channel],
          Endian.little,
        );
      }
    }
    _cursor = _cursor! + frames;
    final expired = _packets.keys.where((key) => key + _packets[key]!.frames <= _cursor!).toList();
    for (final key in expired) {
      _queuedFrames -= _packets.remove(key)!.frames;
    }
    return bytes.buffer.asUint8List();
  }
}
