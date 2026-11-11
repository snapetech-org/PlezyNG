import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'caldera_audio_output.dart';
import 'xita_packet.dart';
import 'xita_jitter_buffer.dart';
import 'xita_output_clock.dart';

/// Bounded Xita PCM rendering shared by remote sinks and the source speaker.
/// The owning session keeps queue, focus, controls and reporting authority.
class XitaAudioRenderer {
  XitaAudioRenderer({
    required this.descriptor,
    required this.output,
    required this.owner,
    required this.current,
    required this.silent,
    required this.title,
    required this.monotonicMicros,
    this.onClosed,
  }) : _audio = XitaJitterBuffer(descriptor);
  final XitaDescriptor descriptor;
  final CalderaAudioOutput output;
  final Object owner;
  final bool Function() current, silent;
  final int Function() monotonicMicros;
  final String title;
  final void Function()? onClosed;
  XitaJitterBuffer _audio;
  HttpServer? _http;
  // The owned server aborts pending flushes during retirement.
  // ignore: close_sinks
  HttpResponse? _response;
  Timer? _pump;
  XitaOutputClock? _waveClock;
  int _lastPumpMicros = 0, _waveFrames = 0, _waveStartedMicros = 0;
  int _lastTimingPoll = 0, _lastTiming = 0, _lastFlush = 0;
  double _waveLeadFrames = 0;
  bool _timingPending = false, _writing = false, _opened = false, _starting = false, _closed = false;
  Future<void>? _closing;
  bool get active => _opened && _valid;
  bool get _valid => !_closed && current() && (!_opened || output.ownsCalderaAudio(owner));
  void reset() => _audio = XitaJitterBuffer(descriptor);
  bool? _wasSilent;
  bool get _silent {
    final value = silent();
    if (_wasSilent != null && _wasSilent != value) reset();
    _wasSilent = value;
    return value;
  }

  bool add(XitaAudio packet, {int? arrivalMicros}) =>
      _valid && !_silent && _audio.add(packet, arrivalMicros ?? monotonicMicros());

  Future<void> _observeOutput(CalderaAudioClockOutput output, XitaOutputClock clock) async {
    if (_timingPending) return;
    _timingPending = true;
    final started = _lastTimingPoll = monotonicMicros();
    try {
      final position = await output.readCalderaAudioClock(owner);
      final now = monotonicMicros();
      if (!_valid || position == null || now - started > 50000) return;
      final initial = !clock.ready;
      if (clock.observe(position, (started + now) ~/ 2)) {
        _lastTiming = now;
        if (initial) {
          _waveLeadFrames = (_waveFrames - position.inMicroseconds * clock.sampleRate / 1000000).clamp(
            clock.sampleRate * .02,
            clock.sampleRate * .1,
          );
        }
      }
    } on Object {
      // Opening and device warm-up can temporarily leave audio-PTS unavailable.
      // The bounded heartbeat below retires a renderer that never supplies it.
    } finally {
      _timingPending = false;
    }
  }

  Future<void> start() async {
    if (_closed || _starting || _opened || !current()) throw StateError('Native renderer unavailable');
    _starting = true;
    try {
      _waveClock = XitaOutputClock(descriptor.sampleRate);
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (!_valid) {
        await http.close(force: true);
        throw StateError('Native renderer retired during bind');
      }
      _http = http;
      final path = '/${const Uuid().v4()}.wav';
      _http!.listen((request) {
        if (!_valid ||
            _response != null ||
            request.method != 'GET' ||
            request.uri.path != path ||
            request.uri.hasQuery) {
          request.response.statusCode = 404;
          unawaited(request.response.close());
          return;
        }
        _response = request.response;
        _waveStartedMicros = _lastTiming = monotonicMicros();
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.headers.set('Cache-Control', 'no-store');
        request.response.bufferOutput = false;
        request.response.add(wavHeader(descriptor.sampleRate, descriptor.channels));
        unawaited(request.response.done.then<void>((_) => close(), onError: (Object _) => close()));
      });
      _lastPumpMicros = monotonicMicros();
      _pump = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (!_valid) {
          unawaited(close());
          return;
        }
        final nowMicros = monotonicMicros();
        final elapsed = (nowMicros - _lastPumpMicros).clamp(0, 50000);
        _lastPumpMicros = nowMicros;
        final response = _response;
        if (response == null) return;
        if (_writing) {
          if ((monotonicMicros() ~/ 1000) - _lastFlush > 500) unawaited(close());
          return;
        }
        final timing =
            output is CalderaAudioClockOutput && (output as CalderaAudioClockOutput).hasCalderaAudioClock(owner)
            ? output as CalderaAudioClockOutput
            : null;
        final waveClock = _waveClock!;
        Uint8List? bytes;
        if (timing != null) {
          if (nowMicros - _lastTimingPoll >= 20000) unawaited(_observeOutput(timing, waveClock));
          if (nowMicros - _lastTiming > 5000000) {
            unawaited(close());
            return;
          }
          final desired = waveClock.ready
              ? (waveClock.frameAtMicros(nowMicros) + _waveLeadFrames).round()
              : ((nowMicros - _waveStartedMicros) * descriptor.sampleRate / 1000000).floor().clamp(
                  0,
                  descriptor.sampleRate ~/ 10,
                );
          final frames = desired - _waveFrames;
          if (frames > 4096) {
            unawaited(close());
            return;
          }
          if (frames > 0) {
            bytes = _silent || !waveClock.ready
                ? Uint8List(frames * descriptor.channels * 4)
                : _audio.renderScheduled(
                    frames,
                    presentationMicros: waveClock.presentationMicros(_waveFrames),
                    microsPerFrame: waveClock.microsPerFrame,
                  );
          }
        } else {
          final frames = (elapsed * descriptor.sampleRate / 1000000).floor().clamp(0, 4096);
          bytes = _silent ? Uint8List(frames * descriptor.channels * 4) : _audio.render(nowMicros);
        }
        if (bytes != null && bytes.isNotEmpty) {
          _waveFrames += bytes.length ~/ (descriptor.channels * 4);
          _writing = true;
          _lastFlush = (monotonicMicros() ~/ 1000);
          response.add(bytes);
          unawaited(
            response.flush().then<void>(
              (_) {
                _writing = false;
              },
              onError: (Object _) {
                _writing = false;
                unawaited(close());
              },
            ),
          );
        }
      });
      final opened = await output.openCalderaAudio(
        owner,
        Uri.parse('http://127.0.0.1:${_http!.port}$path'),
        title,
        () => _valid,
      );
      if (!opened || !_valid || !output.ownsCalderaAudio(owner)) {
        // A late accepted open can finish after close has already completed.
        await output.closeCalderaAudio(owner);
        throw StateError('Native audio output unavailable');
      }
      _opened = true;
    } catch (_) {
      await close();
      rethrow;
    } finally {
      _starting = false;
    }
  }

  static Uint8List wavHeader(int rate, int channels) {
    final data = ByteData(44);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        data.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 0xffffffff, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 3, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * channels * 4, Endian.little);
    data.setUint16(32, channels * 4, Endian.little);
    data.setUint16(34, 32, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, 0xffffffff, Endian.little);
    return data.buffer.asUint8List();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _pump?.cancel();
    _response = null;
    await _http?.close(force: true);
    _http = null;
    try {
      await output.closeCalderaAudio(owner);
    } finally {
      onClosed?.call();
    }
  }
}
