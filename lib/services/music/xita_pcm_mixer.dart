import 'dart:math' as math;
import 'dart:typed_data';
import '../../mpv/player/music_pcm_capture_source.dart';

/// Bounded 48 kHz WAVE-order PCM. Decoder generations and resampling phases
/// remain independent, including overlapping decoders and layout changes.
class XitaPcmMixer {
  XitaPcmMixer({this.channels = 2}) {
    if (!const [2, 6, 8].contains(channels)) throw ArgumentError.value(channels);
  }
  static const sampleRate = 48000, capacity = sampleRate ~/ 2;
  final int channels;
  int cursor = 0;
  final _lanes = <Object, _PcmLane>{};

  int get bufferedFrames => _lanes.values.fold(0, (maximum, lane) => math.max(maximum, lane.endFrame - cursor));
  void setGain(Object key, double gain) {
    if (!gain.isFinite || gain < 0 || gain > 1000000) throw const FormatException('Unsupported PCM gain');
    _lanes[key]?.gain = gain;
  }

  void clear() => _lanes.clear();
  void remove(Object key) => _lanes.remove(key);

  // Capture bridges canonicalize 5.1/7.1 into FL FR FC LFE RL RR [SL SR].
  // Unrecognized layouts are downmixed by the native bridge before this boundary.
  double _sample(MusicPcmBlock block, int frame, int channel) {
    final input = block.channels, start = frame * input, samples = block.samples;
    if (input == 1) return channel < 2 ? samples[start] : 0;
    if (channels == 2 && input > 2) {
      const surround = .7071067811865476;
      final side = input == 8 ? samples[start + 6 + channel] : 0;
      return (samples[start + channel] + surround * (samples[start + 2] + samples[start + 4 + channel] + side)) /
          (1 + surround * (input == 8 ? 3 : 2));
    }
    if (channels == 6 && input == 8 && channel >= 4) {
      return (samples[start + channel] + samples[start + channel + 2]) * .5;
    }
    return channel < input ? samples[start + channel] : 0;
  }

  void add(Object key, MusicPcmBlock block, {required Duration position, required double gain}) {
    if (!gain.isFinite ||
        gain < 0 ||
        gain > 1000000 ||
        !const [1, 2, 6, 8].contains(block.channels) ||
        block.frames < 1 ||
        block.frames > 512 ||
        block.samples.length % block.channels != 0 ||
        block.sampleRate < 8000 ||
        block.sampleRate > 384000 ||
        block.samples.any((value) => !value.isFinite)) {
      throw const FormatException('Unsupported native music PCM');
    }
    var lane = _lanes[key];
    final discontinuity =
        lane == null ||
        lane.generation != block.generation ||
        lane.rate != block.sampleRate ||
        lane.inputChannels != block.channels ||
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
      lane = _PcmLane(block.generation, block.sampleRate, block.channels, channels, cursor + ahead);
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
      for (var channel = 0; channel < channels; channel++) {
        final a = _sample(block, first, channel), b = _sample(block, second, channel);
        active.samples[slot * channels + channel] = a + (b - a) * fraction;
      }
    }
    active.inputFrames += block.frames;
    active.endFrame = active.origin + end;
  }

  Float32List render(int frames) {
    if (frames < 1 || frames > 4096) throw ArgumentError.value(frames);
    final result = Float32List(frames * channels);
    for (final lane in _lanes.values) {
      for (var offset = 0; offset < frames; offset++) {
        final frame = cursor + offset, slot = frame % capacity;
        if (lane.tags[slot] != frame) continue;
        for (var channel = 0; channel < channels; channel++) {
          result[offset * channels + channel] += lane.samples[slot * channels + channel] * lane.gain;
        }
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
  _PcmLane(this.generation, this.rate, this.inputChannels, int channels, this.origin)
    : samples = Float32List(XitaPcmMixer.capacity * channels);
  final int generation, rate, inputChannels, origin;
  final Float32List samples;
  final tags = List<int>.filled(XitaPcmMixer.capacity, -1);
  int inputFrames = 0, endFrame = 0;
  double gain = 1;
}
