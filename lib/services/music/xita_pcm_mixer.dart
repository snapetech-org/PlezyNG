import 'dart:math' as math;
import 'dart:typed_data';
import '../../mpv/player/music_pcm_capture_source.dart';

/// A bounded, continuous 48 kHz stereo source clock. Each decoder has an
/// independent generation and resampling phase, including overlap decoders.
class XitaPcmMixer {
  static const sampleRate = 48000, channels = 2, capacity = sampleRate ~/ 2;
  int cursor = 0;
  final _lanes = <Object, _PcmLane>{};

  int get bufferedFrames => _lanes.values.fold(0, (maximum, lane) => math.max(maximum, lane.endFrame - cursor));
  void setGain(Object key, double gain) {
    if (!gain.isFinite || gain < 0 || gain > 1000000) {
      throw const FormatException('Unsupported PCM gain');
    }
    _lanes[key]?.gain = gain;
  }

  void clear() => _lanes.clear();
  void remove(Object key) => _lanes.remove(key);

  void add(Object key, MusicPcmBlock block, {required Duration position, required double gain}) {
    if (!gain.isFinite ||
        gain < 0 ||
        gain > 1000000 ||
        block.channels > 2 ||
        block.channels < 1 ||
        block.frames < 1 ||
        block.frames > 512 ||
        block.sampleRate < 8000 ||
        block.sampleRate > 384000) {
      throw const FormatException('Unsupported native music PCM');
    }
    var lane = _lanes[key];
    final discontinuity =
        lane == null ||
        lane.generation != block.generation ||
        lane.rate != block.sampleRate ||
        block.droppedFrames > 0 ||
        lane.endFrame < cursor - 1024;
    if (discontinuity) {
      if (lane == null && _lanes.length >= 4) {
        _lanes.remove(_lanes.keys.first);
      }
      final ahead = ((block.presentationTime - position).inMicroseconds * sampleRate / 1000000).round().clamp(
        0,
        capacity ~/ 2,
      );
      lane = _PcmLane(block.generation, block.sampleRate, cursor + ahead);
      _lanes[key] = lane;
    }
    final active = lane;
    final start = (active.inputFrames * sampleRate / block.sampleRate).ceil();
    final end = ((active.inputFrames + block.frames) * sampleRate / block.sampleRate).ceil();
    active.gain = gain;
    for (var output = start; output < end; output++) {
      final frame = active.origin + output;
      if (frame < cursor || frame >= cursor + capacity) continue;
      final input = output * block.sampleRate / sampleRate - active.inputFrames;
      final first = input.floor().clamp(0, block.frames - 1);
      final second = math.min(first + 1, block.frames - 1);
      final fraction = (input - first).clamp(0.0, 1.0);
      final slot = frame % capacity;
      active.tags[slot] = frame;
      for (var channel = 0; channel < 2; channel++) {
        final source = block.channels == 1 ? 0 : channel;
        final a = block.samples[first * block.channels + source];
        final b = block.samples[second * block.channels + source];
        if (!a.isFinite || !b.isFinite) throw const FormatException('Non-finite native music PCM');
        active.samples[slot * 2 + channel] = (a + (b - a) * fraction);
      }
    }
    active.inputFrames += block.frames;
    active.endFrame = active.origin + end;
  }

  Float32List render(int frames) {
    if (frames < 1 || frames > 4096) throw ArgumentError.value(frames);
    final result = Float32List(frames * 2);
    for (final lane in _lanes.values) {
      for (var offset = 0; offset < frames; offset++) {
        final frame = cursor + offset, slot = frame % capacity;
        if (lane.tags[slot] != frame) continue;
        result[offset * 2] += lane.samples[slot * 2] * lane.gain;
        result[offset * 2 + 1] += lane.samples[slot * 2 + 1] * lane.gain;
        lane.tags[slot] = -1;
      }
    }
    for (var i = 0; i < result.length; i++) {
      result[i] = result[i].clamp(-1.0, 1.0);
    }
    cursor += frames;
    _lanes.removeWhere((_, lane) => lane.endFrame < cursor - capacity);
    return result;
  }
}

class _PcmLane {
  _PcmLane(this.generation, this.rate, this.origin);
  final int generation, rate, origin;
  final samples = Float32List(XitaPcmMixer.capacity * 2);
  final tags = List<int>.filled(XitaPcmMixer.capacity, -1);
  int inputFrames = 0, endFrame = 0;
  double gain = 1;
}
