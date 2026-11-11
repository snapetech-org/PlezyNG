import 'dart:typed_data';

/// Zita network-audio framing, also used by Caldera's Xita transport.
/// Independently implemented from the published zita-njbridge wire contract.
/// See docs/plezyng/music/NATIVE_GROUP_AUDIO.md for protocol evidence.
sealed class XitaPacket {
  const XitaPacket(this.flags, this.format, this.channels);
  final int flags, format, channels;
  bool get timed => flags & 1 != 0;
  bool get suspended => flags & 2 != 0;
  bool get skipped => flags & 4 != 0;
  bool get terminated => flags & 128 != 0;
  static const maxDatagram = 1472;

  static XitaPacket? decode(Uint8List bytes) {
    if (bytes.length < 8 || bytes.length > maxDatagram) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0) != 0x7a6e6a62 || bytes[5] & ~0x87 != 0) return null;
    final type = bytes[4], flags = bytes[5], format = bytes[6], channels = bytes[7];
    if (type > 1 || format > 2 || channels < 1 || channels > 8) return null;
    if (type == 0) {
      if (bytes.length != 32) return null;
      final mtu = data.getUint32(8), rate = data.getUint32(12), period = data.getUint32(16);
      if (mtu < 32 || mtu > maxDatagram || rate < 8000 || rate > 384000 || period < 1 || period > 8192) return null;
      return XitaDescriptor._(
        flags,
        format,
        channels,
        mtu,
        rate,
        period,
        data.getUint32(20),
        data.getUint32(24),
        data.getUint32(28),
      );
    }
    if (bytes.length < 20) return null;
    final frames = data.getUint32(12), delay = data.getUint32(16);
    if (frames < 1 || frames > 8192 || delay > 1000000) return null;
    final samples = frames * channels;
    final payload = flags & 0x84 != 0 ? 0 : samples * (format + 2);
    if (bytes.length != 20 + payload) return null;
    final pcm = Float32List(payload == 0 ? 0 : samples);
    for (var i = 0; i < pcm.length; i++) {
      final offset = 20 + i * (format + 2);
      double sample;
      if (format == 2) {
        sample = data.getFloat32(offset);
        if (!sample.isFinite) return null;
      } else if (format == 0) {
        sample = data.getInt16(offset) / 32767;
      } else {
        var integer = bytes[offset] << 16 | bytes[offset + 1] << 8 | bytes[offset + 2];
        if (integer & 0x800000 != 0) integer -= 0x1000000;
        sample = integer / 8388607;
      }
      pcm[i] = sample.clamp(-1.0, 1.0);
    }
    return XitaAudio._(flags, format, channels, data.getUint32(8), frames, delay, pcm);
  }

  static ByteData header(int length, int type, int flags, int format, int channels) {
    final data = ByteData(length);
    data.setUint32(0, 0x7a6e6a62);
    data.setUint8(4, type);
    data.setUint8(5, flags);
    data.setUint8(6, format);
    data.setUint8(7, channels);
    return data;
  }
}

final class XitaDescriptor extends XitaPacket {
  const XitaDescriptor._(
    super.flags,
    super.format,
    super.channels,
    this.mtu,
    this.sampleRate,
    this.periodFrames,
    this.frame,
    this.ntpSeconds,
    this.ntpFraction,
  );
  final int mtu, sampleRate, periodFrames, frame, ntpSeconds, ntpFraction;

  static Uint8List encode({
    required int sampleRate,
    required int channels,
    required int periodFrames,
    required int frame,
    required DateTime timestamp,
    int flags = 0,
  }) {
    if (sampleRate < 8000 ||
        sampleRate > 384000 ||
        channels < 1 ||
        channels > 8 ||
        periodFrames < 1 ||
        periodFrames > 8192 ||
        flags & ~0x87 != 0) {
      throw ArgumentError('Unsupported Xita stream');
    }
    final micros = timestamp.toUtc().microsecondsSinceEpoch + 2208988800000000;
    final seconds = micros ~/ 1000000, fraction = micros.remainder(1000000);
    final data = XitaPacket.header(32, 0, flags, 2, channels);
    data.setUint32(8, XitaPacket.maxDatagram);
    data.setUint32(12, sampleRate);
    data.setUint32(16, periodFrames);
    data.setUint32(20, frame & 0xffffffff);
    data.setUint32(24, seconds & 0xffffffff);
    data.setUint32(28, (fraction * 0x100000000) ~/ 1000000);
    return data.buffer.asUint8List();
  }

  /// Resolve the NTP era nearest the supplied wall-clock anchor (2036 safe).
  DateTime timestampNear(DateTime anchor) {
    final anchorSeconds = anchor.toUtc().microsecondsSinceEpoch ~/ 1000000 + 2208988800;
    final era = ((anchorSeconds - ntpSeconds) / 0x100000000).round();
    final seconds = ntpSeconds + era * 0x100000000 - 2208988800;
    return DateTime.fromMicrosecondsSinceEpoch(
      seconds * 1000000 + ((ntpFraction * 1000000) ~/ 0x100000000),
      isUtc: true,
    );
  }
}

final class XitaAudio extends XitaPacket {
  const XitaAudio._(
    super.flags,
    super.format,
    super.channels,
    this.frame,
    this.frames,
    this.transmitDelayMicros,
    this.samples,
  );
  final int frame, frames, transmitDelayMicros;
  final Float32List samples;

  static Uint8List encode({
    required int frame,
    required int channels,
    required Float32List samples,
    int flags = 0,
    int transmitDelayMicros = 0,
    int? skippedFrames,
  }) {
    final frames = skippedFrames ?? (channels == 0 ? 0 : samples.length ~/ channels);
    final token = flags & 0x84 != 0;
    if (channels < 1 ||
        channels > 8 ||
        frames < 1 ||
        frames > 8192 ||
        (!token && samples.length != frames * channels) ||
        (token && samples.isNotEmpty) ||
        flags & ~0x87 != 0 ||
        transmitDelayMicros < 0 ||
        transmitDelayMicros > 1000000) {
      throw ArgumentError('Invalid Xita audio block');
    }
    final length = 20 + (token ? 0 : samples.length * 4);
    if (length > XitaPacket.maxDatagram) throw ArgumentError('Xita packet exceeds MTU');
    final data = XitaPacket.header(length, 1, flags, 2, channels);
    data.setUint32(8, frame & 0xffffffff);
    data.setUint32(12, frames);
    data.setUint32(16, transmitDelayMicros);
    for (var i = 0; i < (token ? 0 : samples.length); i++) {
      if (!samples[i].isFinite) throw ArgumentError('Non-finite PCM');
      data.setFloat32(20 + i * 4, samples[i].clamp(-1.0, 1.0));
    }
    return data.buffer.asUint8List();
  }
}

/// A monotonic receive clock; wall-clock changes never move scheduled audio.
/// Timed packets mark a source period, not a packet sequence number.
class XitaClock {
  XitaClock(this.sampleRate, {this.latencyMicros = 150000}) {
    if (sampleRate < 8000 || sampleRate > 384000 || latencyMicros < 20000 || latencyMicros > 2000000) {
      throw ArgumentError('Unsupported Xita clock');
    }
  }
  final int sampleRate, latencyMicros;
  int? _latestFrame, _originFrame, _originMicros, _lastObservationFrame, _lastObservationMicros;
  double _microsPerFrame = 0;
  bool get ready => _originFrame != null;
  double get rateRatio => _microsPerFrame == 0 ? 1 : 1000000 / sampleRate / _microsPerFrame;

  static int delta(int frame, int reference) => ((frame - reference + 0x80000000) & 0xffffffff) - 0x80000000;

  int unwrap(int frame) => _latestFrame == null ? frame : _latestFrame! + delta(frame, _latestFrame!);

  void observe(XitaAudio packet, int arrivalMicros) {
    final frame = unwrap(packet.frame);
    if (_latestFrame != null && frame <= _latestFrame!) return;
    if (!packet.timed) {
      if (_latestFrame != null && frame - _latestFrame! > sampleRate * 2) return;
      _latestFrame = frame;
      return;
    }
    final sent = arrivalMicros - packet.transmitDelayMicros;
    if (_originFrame == null) {
      _originFrame = frame;
      _originMicros = sent;
      _microsPerFrame = 1000000 / sampleRate;
    } else {
      final predicted = _originMicros! + (frame - _originFrame!) * _microsPerFrame;
      final error = sent - predicted;
      // A discontinuity belongs to a new stream/lease, never a huge clock slew.
      if (error.abs() > 2000000) return;
      _originMicros = (_originMicros! + (error < 0 ? error * .25 : error.clamp(0, 2000) * .001)).round();
      final priorFrame = _lastObservationFrame, priorTime = _lastObservationMicros;
      if (priorFrame != null && priorTime != null && frame - priorFrame >= sampleRate) {
        final nominal = 1000000 / sampleRate;
        final measured = ((sent - priorTime) / (frame - priorFrame)).clamp(nominal * .998, nominal * 1.002);
        final next = _microsPerFrame * .98 + measured * .02;
        // Preserve continuity at this observation when updating slope.
        _originMicros = (_originMicros! + (frame - _originFrame!) * (_microsPerFrame - next)).round();
        _microsPerFrame = next;
        _lastObservationFrame = frame;
        _lastObservationMicros = sent;
      }
    }
    _latestFrame = frame;
    _lastObservationFrame ??= frame;
    _lastObservationMicros ??= sent;
  }

  int presentationMicros(int frame) {
    if (!ready) throw StateError('Xita clock has no timed anchor');
    return (_originMicros! + (unwrap(frame) - _originFrame!) * _microsPerFrame + latencyMicros).round();
  }
}
