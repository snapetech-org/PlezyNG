import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_whisper_ggml/flutter_whisper.dart' as whisper;

import '../mpv/player/subtitle_pcm_capture_source.dart';
import 'subtitle_ai_service.dart';
import 'subtitle_inference_scheduler.dart';
import 'subtitle_placement_evidence.dart';
import 'subtitle_retimer.dart';
import 'subtitle_whisper_cpp_service.dart';
import 'subtitle_word_timing.dart';
import 'subtitle_stream_stabilizer.dart';

@immutable
final class SubtitleLiveCaption {
  const SubtitleLiveCaption({required this.startMs, required this.endMs, required this.text, this.provisional = false});
  final int startMs;
  final int endMs;
  final String text;
  final bool provisional;
}

/// Opt-in player-owned caption capture. PCM remains in a bounded queue and is
/// transcribed locally; no recording file is created.
final class SubtitlePlaybackTranscriptionService extends ChangeNotifier {
  SubtitlePlaybackTranscriptionService._();
  static final SubtitlePlaybackTranscriptionService instance = SubtitlePlaybackTranscriptionService._();

  static const int _sampleRate = 16000;
  static const int _windowSamples = _sampleRate * 5;
  static const int _strideSamples = _sampleRate * 4;
  static const int _maximumQueuedSamples = _sampleRate * 24;
  static const int _minimumFinalSamples = _sampleRate;
  static const int _streamWindowSamples = _sampleRate * 12;
  static const int _maximumCueCount = 50000;

  final ValueNotifier<SubtitleLiveCaption?> liveCaption = ValueNotifier<SubtitleLiveCaption?>(null);
  final List<double> _samples = <double>[];
  final List<SubtitleCue> _cues = <SubtitleCue>[];
  final List<SubtitleWordTiming> _wordTimings = <SubtitleWordTiming>[];

  SubtitlePcmCaptureSource? _player;
  int? _playerGeneration;
  int? _playerTimelineGeneration;
  String? _audioTrackId;
  bool Function()? _isProfileIdentityCurrent;
  whisper.FlutterWhisper? _session;
  SubtitleModelLease? _modelLease;
  String? _resourceStopReason;
  Future<SubtitleTranscriptionResult?>? _stopping;
  Completer<void>? _startDone;
  bool _startCancelled = false;
  Timer? _timer;
  Future<void>? _inferenceFuture;
  bool _running = false;
  bool _starting = false;
  bool _polling = false;
  String? _status;
  Object? _lastError;
  String _detectedLanguage = 'auto';
  String _languageCode = 'auto';
  SubtitleInferenceProvider _requestedProvider = SubtitleInferenceProvider.cpu;
  String _runtimeProvider = 'CPU';
  bool _fellBackToCpu = false;
  double? _streamStartMs;
  int? _nextExpectedPtsUs;
  int? _clockOriginUs;
  int? _lastSampleRate;
  int? _lastChannels;
  String? _lastEncoding;
  int _packetsReceived = 0;
  int _audioGeneration = 0;
  DateTime? _startedAt;
  DateTime? _lastPacketAt;
  SubtitleCue? _arrivalCue;
  DateTime? _arrivalExpires;
  int _discontinuities = 0;
  int _droppedAudioMs = 0;
  bool _showDelayedText = true;
  bool _stableStreaming = true;
  final _stabilizer = SubtitleStreamStabilizer();
  int? _lastStreamingEndMs;
  SubtitleLiveCaption? _partialCaption;
  DateTime? _partialExpires;
  int _singlePassTails = 0;
  bool get stableStreaming => _stableStreaming;
  int get singlePassTails => _singlePassTails;
  void setStableStreaming(bool value) {
    if (_starting || _running || _session != null) return;
    _stableStreaming = value; notifyListeners();
  }
  void _resetPartial() {
    _stabilizer.reset(); _lastStreamingEndMs = null;
    _partialCaption = null; _partialExpires = null;
  }

  /// A live caption can arrive after its media interval has passed. This is
  /// presentation policy only: exported cue times always remain source times.
  bool get showDelayedText => _showDelayedText;
  void setShowDelayedText(bool value) {
    _showDelayedText = value;
    liveCaption.value = null;
    notifyListeners();
  }
  int get discontinuities => _discontinuities;
  int get droppedAudioMs => _droppedAudioMs;
  bool isForPlayer(Object player) => identical(player, _player) &&
      _invalidCaptureSessionReason(_player) == null;

  SubtitleTranscriptionResult? _recentTranscript;

  bool get isRunning => _running;
  bool get isStarting => _starting;
  bool get hasActiveSession => _session != null;
  String? get status => _status;
  SubtitleTranscriptionResult? get recentTranscript => _recentTranscript;
  bool get hasRecentTranscript => _recentTranscript?.cues.isNotEmpty == true;
  SubtitleInferenceProvider get requestedProvider => _requestedProvider;
  String get runtimeProvider => _runtimeProvider;
  bool get fellBackToCpu => _fellBackToCpu;

  Future<void> start(
    SubtitlePcmCaptureSource player, {
    String? languageCode,
    SubtitleInferenceProvider provider = SubtitleInferenceProvider.cpu,
    bool Function()? isProfileIdentityCurrent,
    void Function(String phase, int received, int total)? onProgress,
  }) async {
    if (provider != SubtitleInferenceProvider.cpu && provider != SubtitleInferenceProvider.desktopGpu) {
      throw UnsupportedError('Playback Whisper captions support CPU or a compiled desktop GPU request.');
    }
    final requestedLanguage = languageCode?.trim().toLowerCase().split(RegExp(r'[-_]')).first ?? '';
    final selectedLanguage = requestedLanguage.isEmpty ? 'auto' : requestedLanguage;
    if (selectedLanguage != 'auto' && !RegExp(r'^[a-z]{2,3}$').hasMatch(selectedLanguage)) {
      throw ArgumentError.value(languageCode, 'languageCode', 'Use a two or three letter language code or auto.');
    }
    if (_starting || _running || _session != null || _stopping != null) {
      throw StateError('A live subtitle capture session is already active.');
    }
    if (!await player.subtitlePcmCaptureAvailable()) {
      throw UnsupportedError('This player build does not expose decoded PCM to live subtitles.');
    }
    if (_starting || _running || _session != null || _stopping != null) {
      throw StateError('A live subtitle capture session is already active.');
    }

    _starting = true;
    _startDone = Completer<void>();
    _startCancelled = false;
    final startGeneration = player.mediaSessionGeneration;
    final startTimelineGeneration = player.playbackTimelineGeneration;
    final startAudioTrackId = player.subtitlePcmAudioTrackId;
    SubtitleLiveWhisperRuntime? loadedRuntime;
    var captureEnabled = false;
    try {
      _resourceStopReason = null;
      bool current() => !_startCancelled && !player.disposed && player.mediaSessionGeneration == startGeneration &&
          player.playbackTimelineGeneration == startTimelineGeneration &&
          player.subtitlePcmAudioTrackId == startAudioTrackId && _profileIsCurrent(isProfileIdentityCurrent);
      _modelLease = await SubtitleInferenceScheduler.instance.reserveModel(this,
        isCurrent: current, onReleaseRequested: _releaseForResources);
      _setStatus('Loading the local Whisper model…');
      _lastError = null;
      _languageCode = selectedLanguage;
      _detectedLanguage = selectedLanguage;
      _requestedProvider = provider;
      _runtimeProvider = 'Loading Whisper';
      _fellBackToCpu = false;
      _samples.clear();
      _resetPartial(); _singlePassTails = 0;
      _cues.clear();
      _wordTimings.clear();
      _streamStartMs = null;
      _nextExpectedPtsUs = null;
      _clockOriginUs = null;
      _lastSampleRate = null;
      _lastChannels = null;
      _lastEncoding = null;
      _packetsReceived = 0;
      _discontinuities = 0;
      _droppedAudioMs = 0;
      _arrivalCue = null;
      _arrivalExpires = null;
      _recentTranscript = null;
      liveCaption.value = null;

      loadedRuntime = await SubtitleInferenceScheduler.instance.run(() => SubtitleWhisperCppService.instance.loadLiveSession(
        requestGpu: provider == SubtitleInferenceProvider.desktopGpu,
        onProgress: (phase, received, total) {
          onProgress?.call(phase, received, total);
          _setStatus(phase);
        },
      ), priority: SubtitleWorkPriority.playback, modelOwner: this, isCurrent: current);
      if (_startCancelled) throw StateError('Live subtitle startup was cancelled.');
      if (_modelLease?.revoked == true) throw SubtitleInferenceDeferred(_resourceStopReason ?? 'Model loading was stopped to release resources.');
      if (player.disposed ||
          player.mediaSessionGeneration != startGeneration ||
          player.playbackTimelineGeneration != startTimelineGeneration ||
          player.subtitlePcmAudioTrackId != startAudioTrackId) {
        throw StateError('Playback changed while Whisper was loading. Start live captions again.');
      }
      if (!_profileIsCurrent(isProfileIdentityCurrent)) {
        throw StateError('The active profile changed while Whisper was loading. Start live captions again.');
      }
      captureEnabled = await player.setSubtitlePcmCaptureEnabled(true);
      if (!captureEnabled) {
        throw UnsupportedError('This player session cannot capture decoded PCM.');
      }
      if (player.disposed ||
          player.mediaSessionGeneration != startGeneration ||
          player.playbackTimelineGeneration != startTimelineGeneration ||
          player.subtitlePcmAudioTrackId != startAudioTrackId) {
        throw StateError('Playback changed while live capture was starting. Start again on the current audio track.');
      }
      if (!_profileIsCurrent(isProfileIdentityCurrent)) {
        throw StateError('The active profile changed while live capture was starting. Start again.');
      }

      if (_startCancelled) throw StateError('Live subtitle startup was cancelled.');
      if (_modelLease?.revoked == true) throw SubtitleInferenceDeferred(_resourceStopReason ?? 'Live captions were stopped to release resources.');
      _session = loadedRuntime.session;
      _runtimeProvider = loadedRuntime.runtimeProvider;
      _fellBackToCpu = loadedRuntime.fellBackToCpu;
      loadedRuntime = null;
      _player = player;
      _playerGeneration = startGeneration;
      _playerTimelineGeneration = startTimelineGeneration;
      _audioTrackId = startAudioTrackId;
      _isProfileIdentityCurrent = isProfileIdentityCurrent;
      _running = true;
      _startedAt = DateTime.now();
      _lastPacketAt = null;
      _setStatus('Capturing decoded audio locally with $_runtimeProvider; captions appear after a few seconds.');
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        _publishCurrentCaption();
        unawaited(_poll());
      });
    } catch (error) {
      if (captureEnabled) {
        try {
          await player.setSubtitlePcmCaptureEnabled(false);
        } catch (_) {}
      }
      try { await loadedRuntime?.session.dispose(); } finally { _modelLease?.release(); _modelLease = null; }
      _setStatus('Could not start live captions: $error');
      rethrow;
    } finally {
      _starting = false;
      _startDone?.complete(); _startDone = null;
    }
  }

  void _releaseForResources(String reason) {
    _resourceStopReason = reason;
    if (_starting) return; // The loader checks revocation before enabling PCM.
    unawaited(stop().then<void>((_) {}, onError: (Object error, StackTrace stack) { _setStatus(reason); }));
  }

  Future<SubtitleTranscriptionResult?> stop() => _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<SubtitleTranscriptionResult?> _stop() async {
    if (_starting) {
      _startCancelled = true;
      await _startDone?.future;
    }
    _timer?.cancel();
    _timer = null;
    final player = _player;
    _running = false;

    var invalidReason = _invalidCaptureSessionReason(player);
    if (player != null && player.playbackTimelineGeneration != _playerTimelineGeneration) {
      _audioGeneration++;
      _samples.clear();
      _streamStartMs = null;
      _playerTimelineGeneration = player.playbackTimelineGeneration;
      await player.drainSubtitlePcmCapture();
    }
    if (invalidReason != null) _discardCapturedTimeline();

    if (player != null) {
      try {
        await player.setSubtitlePcmCaptureEnabled(false);
      } catch (_) {}
    }
    while (_polling) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    invalidReason ??= _invalidCaptureSessionReason(player);
    if (invalidReason == null && player != null) {
      try {
        _appendPackets(await player.drainSubtitlePcmCapture());
      } catch (_) {}
    } else {
      _discardCapturedTimeline();
    }

    while (_inferenceFuture != null) {
      await _inferenceFuture;
    }
    invalidReason ??= _invalidCaptureSessionReason(player);
    if (invalidReason != null) _discardCapturedTimeline();

    while (invalidReason == null &&
        _resourceStopReason == null &&
        _lastError == null &&
        _samples.length >= _windowSamples &&
        _invalidCaptureSessionReason(player) == null) {
      _startInference(finalChunk: false);
      final inference = _inferenceFuture;
      if (inference == null) break;
      await inference;
      invalidReason ??= _invalidCaptureSessionReason(player);
      if (invalidReason != null) _discardCapturedTimeline();
    }
    if (invalidReason == null &&
        _resourceStopReason == null &&
        _lastError == null &&
        _samples.length >= _minimumFinalSamples &&
        _invalidCaptureSessionReason(player) == null) {
      _startInference(finalChunk: true);
      final inference = _inferenceFuture;
      if (inference != null) await inference;
    }
    invalidReason ??= _invalidCaptureSessionReason(player);
    if (invalidReason != null) _discardCapturedTimeline();

    if (invalidReason == null) _publishTranscript();
    final session = _session;
    _session = null;
    try { if (session != null) await session.dispose(); } finally { _modelLease?.release(); _modelLease = null; }
    _player = null;
    _playerGeneration = null;
    _playerTimelineGeneration = null;
    _audioTrackId = null;
    _isProfileIdentityCurrent = null;
    liveCaption.value = null;
    _resetPartial();

    if (_resourceStopReason != null) {
      _setStatus('$_resourceStopReason Completed cues remain available for review.');
      return _recentTranscript;
    }
    if (_lastError != null) {
      _setStatus('Capture ended with an inference error: $_lastError');
      throw StateError('Live subtitle transcription failed: $_lastError');
    }
    if (invalidReason != null) {
      _setStatus(invalidReason);
    } else if (_recentTranscript == null || _recentTranscript!.cues.isEmpty) {
      _setStatus('No speech captions were produced. Check the audio track and try again.');
    } else {
      _setStatus('Captured ${_recentTranscript!.cues.length} speech cues from the watched portion.');
    }
    return _recentTranscript;
  }

  String? _invalidCaptureSessionReason(SubtitlePcmCaptureSource? player) {
    if (player == null) return 'Playback session ended; captured transcript was discarded.';
    if (player.disposed || player.mediaSessionGeneration != _playerGeneration) {
      return 'Playback session changed; captured transcript was discarded.';
    }
    if (!_profileIsCurrent(_isProfileIdentityCurrent)) {
      return 'Active profile changed during capture; the partial transcript was discarded. Start again.';
    }
    if (player.subtitlePcmAudioTrackId != _audioTrackId) {
      return 'Selected audio track changed; captured transcript was discarded. Start capture again on the new track.';
    }
    return null;
  }

  static bool _profileIsCurrent(bool Function()? isCurrent) {
    try {
      return isCurrent?.call() != false;
    } catch (_) {
      return false;
    }
  }

  bool _isCurrentInference(int generation) =>
      _modelLease?.revoked != true &&
      generation == _audioGeneration &&
      _player?.playbackTimelineGeneration == _playerTimelineGeneration &&
      _invalidCaptureSessionReason(_player) == null;

  void _discardCapturedTimeline() {
    _audioGeneration++;
    _resetPartial();
    _samples.clear();
    _cues.clear();
    _wordTimings.clear();
    _streamStartMs = null;
    _nextExpectedPtsUs = null;
    _clockOriginUs = null;
    _lastSampleRate = null;
    _lastChannels = null;
    _lastEncoding = null;
    _recentTranscript = null;
    _arrivalCue = null;
    _arrivalExpires = null;
    liveCaption.value = null;
  }

  Future<void> _poll() async {
    if (!_running || _polling || _starting) return;
    final player = _player;
    if (player == null) return;
    final invalidReason = _invalidCaptureSessionReason(player);
    if (invalidReason != null) {
      _running = false;
      _timer?.cancel();
      _timer = null;
      _discardCapturedTimeline();
      _setStatus(invalidReason);
      unawaited(stop());
      return;
    }
    _polling = true;
    try {
      if (player.playbackTimelineGeneration != _playerTimelineGeneration) {
        // Retire the native/inference window before any await. Finalized cues
        // remain reusable on a seek within this media/audio session.
        final timeline = player.playbackTimelineGeneration;
        _resetAudioWindow(player.currentPosition.inMicroseconds);
        _streamStartMs = null;
        _arrivalCue = null;
        _arrivalExpires = null;
        liveCaption.value = null;
        await player.setSubtitlePcmCaptureEnabled(false);
        await player.drainSubtitlePcmCapture();
        if (!_running || _invalidCaptureSessionReason(player) != null) return;
        if (!await player.setSubtitlePcmCaptureEnabled(true)) {
          throw StateError('The new playback route cannot expose PCM.');
        }
        _playerTimelineGeneration = timeline;
        if (player.playbackTimelineGeneration != timeline) return;
        _setStatus('Capture resumed at the new playhead; finalized cues retained.');
      }
      final timeline = player.playbackTimelineGeneration;
      final packets = await player.drainSubtitlePcmCapture();
      if (player.playbackTimelineGeneration != timeline) return;
      if (packets.isNotEmpty) {
        _appendPackets(packets);
        _packetsReceived += packets.length;
        _lastPacketAt = DateTime.now();
        _setStatus('Listening locally with $_runtimeProvider; captured $_packetsReceived audio packets.');
      } else {
        final started = _startedAt;
        final lastPacket = _lastPacketAt;
        if (started != null && lastPacket == null && DateTime.now().difference(started) > const Duration(seconds: 8)) {
          _setStatus(
            'No decoded PCM is reaching the capture tap. Tunneling/offload or this audio route may prevent capture.',
          );
        } else if (lastPacket != null && DateTime.now().difference(lastPacket) > const Duration(seconds: 8)) {
          _setStatus('No recent PCM packets. Playback may be paused or the route may not expose decoded audio.');
        }
      }
      final postDrainInvalidReason = _invalidCaptureSessionReason(player);
      if (postDrainInvalidReason != null) {
        _running = false;
        _timer?.cancel();
        _timer = null;
        _discardCapturedTimeline();
        _setStatus(postDrainInvalidReason);
        unawaited(stop());
        return;
      }
      _startInference(finalChunk: false);
      // Flush a trailing utterance on pause/end-of-stream without repeatedly
      // submitting the same overlap. Packet age is not a source timestamp.
      if (_lastPacketAt != null &&
          DateTime.now().difference(_lastPacketAt!) > const Duration(seconds: 2) &&
          _samples.length >= _minimumFinalSamples && (_stableStreaming || _samples.length < _windowSamples)) {
        _startInference(finalChunk: true);
      }
    } catch (error) {
      _lastError = error;
      _running = false;
      _timer?.cancel();
      _timer = null;
      try {
        await player.setSubtitlePcmCaptureEnabled(false);
      } catch (_) {}
      _setStatus('Live capture stopped: $error');
    } finally {
      _polling = false;
    }
  }

  int _originShiftMs(int? origin) => origin == null || _clockOriginUs == null ? 0 : ((origin - _clockOriginUs!) / 1000).round();

  void _rebaseLiveWindow(int origin) {
    final previous = _clockOriginUs;
    _clockOriginUs = origin;
    if (previous == null || previous == origin) return;
    final delta = ((previous - origin) / 1000).round();
    _stabilizer.rebase(delta);
    if (_lastStreamingEndMs != null) _lastStreamingEndMs = _lastStreamingEndMs! + delta;
    _partialCaption = null; _partialExpires = null;
    // A sliding DVR window changes the zero point, not the underlying audio.
    // Preserve stable cue IDs while retiring content outside the new window.
    final shifted = <SubtitleCue>[];
    for (final cue in _cues) {
      if (cue.endMs + delta <= 0) continue;
      shifted.add(SubtitleCue(index: cue.index, startMs: math.max(0, cue.startMs + delta),
        endMs: cue.endMs + delta, text: cue.text, cueId: cue.stableId));
    }
    _cues..clear()..addAll(shifted);
    final words = <SubtitleWordTiming>[];
    for (final word in _wordTimings) {
      if (word.endMs + delta <= 0) continue;
      words.add(SubtitleWordTiming(startMs: math.max(0, word.startMs + delta), endMs: word.endMs + delta,
        text: word.text, confidence: word.confidence, unit: word.unit, cueId: word.cueId, cueIndex: word.cueIndex));
    }
    _wordTimings..clear()..addAll(words);
    if (_streamStartMs != null) _streamStartMs = _streamStartMs! + delta;
    if (_nextExpectedPtsUs != null) _nextExpectedPtsUs = _nextExpectedPtsUs! + previous - origin;
    _arrivalCue = null; _arrivalExpires = null; _recentTranscript = null;
    liveCaption.value = null;
    _publishTranscript();
  }

  void _appendPackets(List<Map<String, Object?>> packets) {
    for (final packet in packets) {
      final origin = packet['clockOriginUs'];
      if (origin is num && origin.isFinite) _rebaseLiveWindow(origin.toInt());
      final raw = packet['pcm'];
      if (raw is! Uint8List) continue;
      final ptsUs = (packet['presentationTimeUs'] as num?)?.toInt();
      final sampleRate = (packet['sampleRate'] as num?)?.toInt();
      final channels = (packet['channels'] as num?)?.toInt();
      final encoding = packet['encoding']?.toString();
      if (ptsUs == null ||
          sampleRate == null ||
          sampleRate < 8000 ||
          sampleRate > 192000 ||
          channels == null ||
          channels < 1 ||
          channels > 8 ||
          (encoding != 'pcm16' && encoding != 'float32')) {
        continue;
      }
      final bytesPerSample = encoding == 'pcm16' ? 2 : 4;
      final bytesPerFrame = bytesPerSample * channels;
      final frames = raw.length ~/ bytesPerFrame;
      if (frames <= 0) continue;

      final changedFormat =
          (_lastSampleRate != null && _lastSampleRate != sampleRate) ||
          (_lastChannels != null && _lastChannels != channels) ||
          (_lastEncoding != null && _lastEncoding != encoding);
      final expected = _nextExpectedPtsUs;
      final gapUs = expected == null ? 0 : ptsUs - expected;
      if (changedFormat || (expected != null && (gapUs < -150000 || gapUs > 250000))) {
        // A raw PTS reset without an explicit seek can reuse old timestamps
        // for different live content. Retire the old clock namespace.
        _discontinuities++;
        _cues.clear();
        _wordTimings.clear();
        _recentTranscript = null;
        _arrivalCue = null;
        _arrivalExpires = null;
        liveCaption.value = null;
        _resetAudioWindow(ptsUs);
      } else if (_streamStartMs == null) {
        _streamStartMs = ptsUs / 1000.0;
      } else if (gapUs > 40000 && gapUs <= 250000) {
        final silenceSamples = (gapUs * _sampleRate / 1000000).round();
        if (silenceSamples > 0 && silenceSamples <= _sampleRate ~/ 4) {
          _samples.addAll(List<double>.filled(silenceSamples, 0));
        }
      }

      _lastSampleRate = sampleRate;
      _lastChannels = channels;
      _lastEncoding = encoding;
      _nextExpectedPtsUs = ptsUs + (frames * 1000000 / sampleRate).round();
      final data = ByteData.sublistView(raw);
      final mono = Float32List(frames);
      for (var frame = 0; frame < frames; frame++) {
        var total = 0.0;
        for (var channel = 0; channel < channels; channel++) {
          final offset = frame * bytesPerFrame + channel * bytesPerSample;
          final value = encoding == 'pcm16'
              ? data.getInt16(offset, Endian.little) / 32768.0
              : data.getFloat32(offset, Endian.little);
          total += value.isFinite ? value.clamp(-1.0, 1.0) : 0.0;
        }
        mono[frame] = (total / channels).clamp(-1.0, 1.0);
      }

      final outputLength = (frames * _sampleRate / sampleRate).round();
      for (var index = 0; index < outputLength; index++) {
        final sourcePosition = index * sampleRate / _sampleRate;
        final left = sourcePosition.floor().clamp(0, frames - 1).toInt();
        final right = (left + 1).clamp(0, frames - 1).toInt();
        final fraction = sourcePosition - left;
        _samples.add((mono[left] * (1.0 - fraction) + mono[right] * fraction).clamp(-1.0, 1.0));
      }
      _streamStartMs ??= ptsUs / 1000.0;
      _trimOldSamples();
    }
  }

  void _trimOldSamples() {
    if (_samples.length <= _maximumQueuedSamples) return;
    final trim = _samples.length - _maximumQueuedSamples;
    _droppedAudioMs += (trim * 1000 / _sampleRate).round();
    _resetPartial(); _audioGeneration++;
    _samples.removeRange(0, trim);
    _streamStartMs = (_streamStartMs ?? 0) + trim * 1000.0 / _sampleRate;
  }

  void _resetAudioWindow(int ptsUs) {
    _audioGeneration++;
    _resetPartial();
    _samples.clear();
    _streamStartMs = ptsUs / 1000.0;
    _nextExpectedPtsUs = null;
    _lastSampleRate = null;
    _lastChannels = null;
    _lastEncoding = null;
  }

  void _startInference({required bool finalChunk}) {
    if (_inferenceFuture != null || _session == null || _streamStartMs == null) return;
    final minimum = _stableStreaming ? _sampleRate * 2 : _windowSamples;
    if (_samples.length < minimum && !(finalChunk && _samples.length >= _minimumFinalSamples)) return;
    final count = math.min(_stableStreaming ? _streamWindowSamples : _windowSamples, _samples.length).toInt();
    final inputEndMs = _streamStartMs!.round() + (count * 1000 / _sampleRate).round();
    if (_stableStreaming && !finalChunk && _lastStreamingEndMs != null && inputEndMs - _lastStreamingEndMs! < 800) return;
    if (_stableStreaming) _lastStreamingEndMs = inputEndMs;
    final flush = finalChunk || _stableStreaming && count == _streamWindowSamples;
    final samples = Float32List.fromList(_samples.take(count).toList(growable: false));
    final startMs = _streamStartMs!.round();
    final consume = finalChunk ? count : math.min(_strideSamples, count).toInt();
    final generation = _audioGeneration;
    final session = _session!;
    final origin = _clockOriginUs;
    _inferenceFuture = _transcribeWindow(session, samples, startMs, generation, origin, flush: flush)
        .then<void>((_) {
          if (generation != _audioGeneration) return;
          // The bounded queue may trim samples while native inference is
          // running. Advance to this window's intended stride by media time,
          // not by blindly removing [consume] from the now-shifted queue.
          final desiredNextStartMs = _stableStreaming
              ? (flush ? inputEndMs + _originShiftMs(origin) : math.max(startMs + _originShiftMs(origin), _stabilizer.committedThroughMs - 500)).toDouble()
              : startMs + _originShiftMs(origin) + consume * 1000.0 / _sampleRate;
          final queuedStartMs = _streamStartMs ?? startMs.toDouble();
          final samplesToDrop = ((desiredNextStartMs - queuedStartMs) * _sampleRate / 1000.0)
              .round()
              .clamp(0, _samples.length)
              .toInt();
          if (samplesToDrop > 0) {
            _samples.removeRange(0, samplesToDrop);
            _streamStartMs = queuedStartMs + samplesToDrop * 1000.0 / _sampleRate;
          }
        })
        .catchError((Object error) {
          if (error is SubtitleInferenceDeferred) {
            _releaseForResources(error.reason);
            return;
          }
          _lastError = error;
          _running = false;
          _timer?.cancel();
          _timer = null;
          final player = _player;
          if (player != null) unawaited(player.setSubtitlePcmCaptureEnabled(false));
          _setStatus('Whisper inference failed: $error');
          unawaited(stop().then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
        })
        .whenComplete(() {
          _inferenceFuture = null;
          _publishTranscript();
          if (_running && _isCurrentInference(generation)) _startInference(finalChunk: false);
        });
  }

  Future<void> _transcribeWindow(
    whisper.FlutterWhisper session,
    Float32List samples,
    int startMs,
    int generation,
    int? origin, {
    required bool flush,
  }) async {
    if (samples.length < _minimumFinalSamples) return;
    dynamic result;
    try {
      result = await _transcribeWindowResult(session, samples, generation);
    } on Object catch (error) {
      if (!_isCurrentInference(generation)) return;
      if (error is SubtitleInferenceDeferred) rethrow;
      if (_requestedProvider != SubtitleInferenceProvider.desktopGpu ||
          _fellBackToCpu ||
          !identical(session, _session)) {
        rethrow;
      }
      await _switchLiveInferenceToCpu(error);
      final fallbackSession = _session;
      if (fallbackSession == null || !_isCurrentInference(generation)) return;
      result = await _transcribeWindowResult(fallbackSession, samples, generation);
    }
    if (result == null) return;
    if (!_isCurrentInference(generation)) return;
    startMs += _originShiftMs(origin);
    final language = result.language.trim();
    if (language.isNotEmpty && language.toLowerCase() != 'auto') _detectedLanguage = language;
    final words = SubtitleWordTimingBuilder.fromWhisperSegments(result.segments,
      durationMs: SubtitleRetimer.maximumTimeMs, offsetMs: startMs);
    final cues = <SubtitleCue>[];
    final windowEnd = startMs + (samples.length * 1000 / _sampleRate).round();
    for (final segment in result.segments) {
      final text = segment.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (text.isEmpty || text.length > 600) continue;
      final start = startMs + segment.start.inMilliseconds;
      final end = startMs + segment.end.inMilliseconds;
      if (start < 0 || end <= start || end > windowEnd || end > SubtitleRetimer.maximumTimeMs) continue;
      cues.add(SubtitleCue(index: 0, startMs: start, endMs: end, text: text));
    }
    if (_stableStreaming) {
      final update = _stabilizer.add(cues: cues, words: words, windowEndMs: windowEnd, flush: flush);
      for (final word in update.words) { _mergeWordTiming(word); }
      for (final cue in update.cues) { _mergeCue(cue); }
      if (update.boundaryFinalized) _singlePassTails++;
      _partialCaption = update.preview == null ? null : SubtitleLiveCaption(startMs: math.max(startMs, _stabilizer.committedThroughMs),
        endMs: windowEnd, text: update.preview!, provisional: true);
      _partialExpires = DateTime.now().add(const Duration(seconds: 4));
      _publishCurrentCaption();
    } else {
      for (final word in words) { _mergeWordTiming(word); }
      for (final cue in cues) { _mergeCue(cue); }
    }
  }

  Future<void> _switchLiveInferenceToCpu(Object error) async {
    final failedSession = _session;
    _session = null;
    await failedSession?.dispose();
    final fallback = await SubtitleInferenceScheduler.instance.run(() => SubtitleWhisperCppService.instance.loadLiveSession(),
      priority: SubtitleWorkPriority.playback, modelOwner: this,
      isCurrent: () => _resourceStopReason == null && _invalidCaptureSessionReason(_player) == null);
    if (_invalidCaptureSessionReason(_player) != null) {
      await fallback.session.dispose();
      return;
    }
    _session = fallback.session;
    _runtimeProvider = 'CPU (live GPU inference fallback)';
    _fellBackToCpu = true;
    _setStatus('GPU live inference failed; continuing with CPU Whisper: $error');
  }

  Future<dynamic> _transcribeWindowResult(whisper.FlutterWhisper session, Float32List samples, int generation) => SubtitleInferenceScheduler.instance.run(() => session.transcribe(
    samples,
    config: whisper.WhisperTranscribeConfig(
      language: _languageCode,
      threads: 2,
      tokenTimestamps: true,
      splitOnWord: true,
      noSpeechThreshold: 0.6,
    ),
  ), priority: SubtitleWorkPriority.playback, modelOwner: this,
    isCurrent: () => identical(_session, session) && _isCurrentInference(generation));

  void _mergeWordTiming(SubtitleWordTiming timing) {
    if (timing.text.isEmpty || timing.endMs <= timing.startMs) return;
    final normalized = _normalize(timing.text);
    for (var index = _wordTimings.length - 1; index >= 0; index--) {
      final previous = _wordTimings[index];
      if (previous.endMs < timing.startMs - 1200) break;
      final overlap = math.max(0, math.min(previous.endMs, timing.endMs) - math.max(previous.startMs, timing.startMs));
      final shorterDuration = math.max(1, math.min(previous.endMs - previous.startMs, timing.endMs - timing.startMs));
      if (overlap / shorterDuration < 0.45 || _normalize(previous.text) != normalized) continue;
      if (timing.confidence > previous.confidence) _wordTimings[index] = timing;
      return;
    }
    if (_wordTimings.length < 250000) _wordTimings.add(timing);
  }

  void _mergeCue(SubtitleCue cue) {
    final normalized = _normalize(cue.text);
    final existingIndex = _cues.indexWhere((existing) {
      final overlap = math.max(0, math.min(existing.endMs, cue.endMs) - math.max(existing.startMs, cue.startMs));
      final shorterDuration = math.max(1, math.min(existing.endMs - existing.startMs, cue.endMs - cue.startMs));
      if (overlap / shorterDuration < 0.35) return false;
      final left = _normalize(existing.text);
      if (left == normalized) return true;
      final leftWords = left.split(' ').where((word) => word.isNotEmpty).toSet();
      final rightWords = normalized.split(' ').where((word) => word.isNotEmpty).toSet();
      if (leftWords.isEmpty || rightWords.isEmpty) return false;
      final similarity = leftWords.intersection(rightWords).length / leftWords.union(rightWords).length;
      return similarity >= 0.68;
    });
    if (existingIndex >= 0) {
      // A finalized cue must not change while a viewer is reading it.
      return;
    } else if (_cues.length < _maximumCueCount) {
      _cues.add(cue);
      _arrivalCue = cue;
      _arrivalExpires = DateTime.now().add(Duration(
        milliseconds: (cue.text.runes.length * 65).clamp(1800, 6000).toInt()));
    }
    _cues.sort((left, right) => left.startMs.compareTo(right.startMs));
    if (_player?.isLivePlayback == true && _cues.isNotEmpty) {
      // Two hours/4000 cues, whichever is smaller. Bound live sessions even
      // when the station runs indefinitely or its DVR window is very large.
      final cutoff = _cues.last.endMs - const Duration(hours: 2).inMilliseconds;
      _cues.removeWhere((value) => value.endMs < cutoff);
      if (_cues.length > 4000) _cues.removeRange(0, _cues.length - 4000);
      final first = _cues.first.startMs;
      _wordTimings.removeWhere((value) => value.endMs < first);
      if (_wordTimings.length > 32000) _wordTimings.removeRange(0, _wordTimings.length - 32000);
    }
    for (var index = 0; index < _cues.length; index++) {
      final cue = _cues[index];
      _cues[index] = SubtitleCue(
        index: index + 1,
        startMs: cue.startMs,
        endMs: cue.endMs,
        text: cue.text,
        cueId: cue.stableId,
      );
    }
    _publishTranscript();
  }

  void _publishTranscript() {
    final player = _player;
    if (_cues.isEmpty) return;
    final cueEnd = _cues.map((cue) => cue.endMs).reduce((left, right) => left > right ? left : right);
    final playerDuration = player?.state.duration.inMilliseconds ?? 0;
    final duration = math.max(cueEnd, playerDuration);
    _recentTranscript = SubtitleTranscriptionResult(
      cues: List.unmodifiable(_cues),
      durationMs: duration.clamp(1, SubtitleRetimer.maximumTimeMs).toInt(),
      requestedProvider: _requestedProvider,
      runtimeProvider: 'Player decoded PCM; whisper.cpp $_runtimeProvider',
      fellBackToCpu: _fellBackToCpu,
      placementEvidence: _fellBackToCpu
          ? SubtitlePlacementEvidence.cpuFallbackAfterAcceleratorUnavailable
          : (_requestedProvider == SubtitleInferenceProvider.cpu
                ? SubtitlePlacementEvidence.cpuOnlyConfigured
                : SubtitlePlacementEvidence.acceleratorRequestSucceededButUnverified),
      detectedLanguage: _detectedLanguage,
      translatedToEnglish: false,
      wordTimings: SubtitleWordTimingBuilder.attachCueIndices(_wordTimings, _cues),
    );
    notifyListeners();
  }

  void _publishCurrentCaption() {
    final player = _player;
    if (!_running || player == null) {
      if (liveCaption.value != null) liveCaption.value = null;
      return;
    }
    if (!_isCurrentInference(_audioGeneration)) {
      liveCaption.value = null;
      return;
    }
    final position = player.currentPosition.inMilliseconds;
    SubtitleCue? current;
    for (final cue in _cues.reversed) {
      if (position >= cue.startMs && position < cue.endMs) {
        current = cue;
        break;
      }
      if (cue.startMs < position - 5000) break;
    }
    if (current == null && _showDelayedText && player.state.playing &&
        _arrivalExpires?.isAfter(DateTime.now()) == true &&
        _arrivalCue != null && position >= _arrivalCue!.endMs &&
        position - _arrivalCue!.endMs < 30000) {
      current = _arrivalCue;
    }
    final partial = _partialExpires?.isAfter(DateTime.now()) == true && player.state.playing &&
        (_showDelayedText || _partialCaption != null && position >= _partialCaption!.startMs && position < _partialCaption!.endMs)
        ? _partialCaption : null;
    final next = current == null
        ? partial
        : SubtitleLiveCaption(startMs: current.startMs, endMs: current.endMs, text: current.text);
    final previous = liveCaption.value;
    if (previous?.startMs != next?.startMs || previous?.endMs != next?.endMs || previous?.text != next?.text || previous?.provisional != next?.provisional) {
      liveCaption.value = next;
    }
  }

  String _normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), ' ')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  void _setStatus(String status) {
    if (_status == status) return;
    _status = status;
    notifyListeners();
  }
}
