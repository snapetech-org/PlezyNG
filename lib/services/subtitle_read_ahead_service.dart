import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../mpv/mpv.dart';
import '../mpv/player/player_media_session_identity.dart';
import '../mpv/player/subtitle_pcm_capture_source.dart';
import 'subtitle_analysis_source.dart';
import 'subtitle_analysis_decoder.dart';
import 'subtitle_hls_analysis.dart';
import 'subtitle_ai_service.dart';
import 'subtitle_inference_scheduler.dart';
import 'subtitle_overlay_service.dart';
import 'subtitle_playback_transcription_service.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';

/// Separate bounded native/FFmpeg VOD decoder. Never touches audible output, native playback
/// speed, or audio passthrough. User start/stop owns this single worker.
class SubtitleReadAheadService extends ChangeNotifier {
  SubtitleReadAheadService._();
  static final instance = SubtitleReadAheadService._();
  static bool get available => SubtitleAnalysisDecoder.available;
  Player? _player;
  SubtitleAnalysisSource? _source;
  Timer? _timer;
  final _decoder = SubtitleAnalysisDecoder();
  int _generation = 0;
  int? _mediaGeneration;
  String? _audio;
  bool Function()? _valid;
  bool _busy = false;
  int _audioOrdinal = 0;
  String? _language;
  String? _profileId;
  SubtitleInferenceProvider _provider = SubtitleInferenceProvider.cpu;
  final Map<int, List<SubtitleCue>> _windows = {};
  final Map<int, List<SubtitleWordTiming>> _words = {};
  SubtitleOverlayTrack? _published;
  SubtitleHlsAnalysis? _hls;
  final Map<String, int> _completedSegments = {};
  DateTime _lastLivePoll = DateTime.fromMillisecondsSinceEpoch(0);
  String status = 'Stopped';
  bool get running => _player != null;
  bool get busy => _busy;
  bool _current(int epoch) {
    try { return epoch == _generation && _player != null && !_player!.disposed &&
        _source?.isCurrent() == true && _valid?.call() == true &&
        (_mediaGeneration == null || (_player as PlayerMediaSessionIdentity).mediaSessionGeneration == _mediaGeneration) &&
        _player!.state.track.audio?.id == _audio; }
    catch (_) { return false; }
  }

  Future<void> start(Player player, {required Future<SubtitleAnalysisSource> Function() open,
    required bool Function() isCurrent, required int audioOrdinal, String? language, String? profileId,
    SubtitleInferenceProvider provider = SubtitleInferenceProvider.cpu, int hlsRendition = 0}) async {
    if (!available) throw UnsupportedError('A separate local analysis decoder is not installed on this platform.');
    if (running || _busy) throw StateError('Stop the current read-ahead job first.');
    final live = player is SubtitlePcmCaptureSource && player.isLivePlayback;
    if ((!live && !player.state.seekable) || audioOrdinal < 0 || audioOrdinal > 63 || hlsRendition < 0 || hlsRendition > 63) {
      throw ArgumentError('A seekable VOD or program-timestamped live source and audio stream are required.');
    }
    final epoch = ++_generation;
    _player = player;
    _mediaGeneration = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
    _audio = player.state.track.audio?.id;
    _valid = isCurrent;
    _audioOrdinal = audioOrdinal;
    _language = language;
    _profileId = profileId;
    _provider = provider;
    _windows.clear(); _words.clear(); _published = SubtitleOverlayService.forPlayer(player).lanes[0];
    _completedSegments.clear(); _lastLivePoll = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final source = await open();
      if (epoch != _generation) { await source.close(); return; }
      _source = source;
      if (!_current(epoch)) throw StateError('Playback changed before analysis started.');
      final uri = source.uri;
      if (uri.scheme != 'file' && !(uri.scheme == 'http' && uri.host == '127.0.0.1')) {
        throw UnsupportedError('Decoder access must be through the owning local transport.');
      }
      if (source.liveEpochForPosition != null) {
        if (!SubtitleAnalysisDecoder.hlsAvailable) throw UnsupportedError('Live HLS analysis requires a separate local audio decoder');
        _hls = SubtitleHlsAnalysis(uri, () => _current(epoch), rendition: hlsRendition);
      } else if (live) { throw UnsupportedError('This live source does not provide program-clock analysis access'); }
      status = 'Preparing captions ahead of the playhead. Initial speech may finish late.';
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_tick(epoch)));
      notifyListeners();
      unawaited(_tick(epoch));
    } catch (_) { await stop(); rethrow; }
  }

  Future<void> stop() async {
    ++_generation;
    _timer?.cancel(); _timer = null;
    _hls?.close(); _hls = null;
    await _decoder.cancel();
    final source = _source; _source = null;
    _player = null; _valid = null;
    await source?.close();
    // The final overlay stays on this exact media/audio/profile until removed.
    status = 'Stopped; completed caption windows remain in the app overlay.';
    notifyListeners();
  }

  Future<void> _tick(int epoch) async {
    if (_busy) return;
    if (!_current(epoch)) { if (epoch == _generation) await stop(); return; }
    if (SubtitlePlaybackTranscriptionService.instance.hasActiveSession) {
      status = 'Waiting while playback PCM recognition owns the local model.'; notifyListeners(); return;
    }
    final player = _player!;
    final overlay = SubtitleOverlayService.forPlayer(player);
    if (!identical(overlay.lanes[0], _published)) { await stop(); return; }
    if (_hls != null) { await _tickLive(epoch); return; }
    final offset = _source!.timelineOffsetMs;
    final now = (player.currentPosition.inMilliseconds - offset).clamp(0, 28800000).toInt();
    final duration = _source!.durationMs ?? player.state.duration.inMilliseconds - offset;
    if (duration <= 0) return;
    final first = now ~/ 30000;
    int? index;
    for (var i = first; i <= first + 3 && i * 30000 < duration; i++) {
      if (!_windows.containsKey(i)) { index = i; break; }
    }
    if (index == null) return;
    final start = index * 30000;
    final decodeStart = (start - 2000).clamp(0, duration).toInt();
    final end = (start + 32000).clamp(0, duration).toInt();
    final seek = player is SubtitlePcmCaptureSource ? player.playbackTimelineGeneration : null;
    _busy = true;
    Directory? temporary;
    try {
      await SubtitleInferenceScheduler.instance.run(() async {}, priority: SubtitleWorkPriority.readAhead,
        isCurrent: () => _current(epoch) && (seek == null || (player as SubtitlePcmCaptureSource).playbackTimelineGeneration == seek));
      temporary = await (await getTemporaryDirectory()).createTemp('subtitle_analysis_');
      final wav = File('${temporary.path}/window.wav');
      status = 'Decoding ${start ~/ 1000}–${end ~/ 1000}s through the source transport'; notifyListeners();
      final uri = _source!.uri;
      await _decoder.decode(uri: uri, startMs: decodeStart, endMs: end,
        audioOrdinal: _audioOrdinal, destination: wav, isCurrent: () => _current(epoch) &&
          (seek == null || (player as SubtitlePcmCaptureSource).playbackTimelineGeneration == seek));
      if (!_current(epoch)) return;
      if (seek != null && (player as SubtitlePcmCaptureSource).playbackTimelineGeneration != seek) return;
      status = 'Recognizing source audio ${start ~/ 1000}s via ${_decoder.backend}'; notifyListeners();
      final result = await SubtitleAiService.instance.transcribeWav(wav.path,
          provider: _provider, languageCode: _language, allowEmpty: true, numThreads: 2,
          priority: SubtitleWorkPriority.readAhead, isCurrent: () => _current(epoch) &&
            (seek == null || (player as SubtitlePcmCaptureSource).playbackTimelineGeneration == seek));
      if (!_current(epoch) || seek != null && (player as SubtitlePcmCaptureSource).playbackTimelineGeneration != seek) return;
      final cues = <SubtitleCue>[];
      for (final cue in result.cues) {
        final a = cue.startMs + decodeStart, b = cue.endMs + decodeStart;
        final midpoint = (a + b) ~/ 2;
        if (midpoint < start || midpoint >= start + 30000) continue;
        cues.add(SubtitleCue(index: cue.index, startMs: a + offset, endMs: b + offset, text: cue.text));
      }
      _windows[index] = cues;
      _words[index] = [for (final word in result.wordTimings) SubtitleWordTiming(
        startMs: word.startMs + decodeStart + offset, endMs: word.endMs + decodeStart + offset,
        text: word.text, confidence: word.confidence, unit: word.unit)];
      await _publish(epoch, first, result.detectedLanguage);
      status = 'Prepared ${_windows.length} windows; ${result.runtimeProvider}. Placement remains unverified.';
    } on SubtitleInferenceDeferred catch (error) {
      if (_current(epoch)) status = error.reason;
    } catch (error) {
      if (epoch == _generation) {
        await stop();
        status = error is ProcessException ? 'Read-ahead stopped. Install FFmpeg or configure PLEZY_FFMPEG.'
            : 'Read-ahead stopped. The decoder, model, or current source could not complete the window.';
      }
    } finally {
      await _decoder.cancel();
      if (temporary != null) { try { await temporary.delete(recursive: true); } catch (_) {} }
      _busy = false; notifyListeners();
    }
  }

  Future<void> _tickLive(int epoch) async {
    if (DateTime.now().difference(_lastLivePoll).inSeconds < 3) return;
    _lastLivePoll = DateTime.now();
    final player = _player!, source = _source!, hls = _hls!;
    final now = source.liveEpochForPosition!(player.currentPosition.inMilliseconds);
    if (now == null) { status = 'Waiting for an active live playback clock'; notifyListeners(); return; }
    final seek = player is SubtitlePcmCaptureSource ? player.playbackTimelineGeneration : null;
    bool current() => _current(epoch) && (seek == null || (player as SubtitlePcmCaptureSource).playbackTimelineGeneration == seek);
    _busy = true;
    Directory? temporary;
    try {
      final segments = await hls.segments();
      if (!current()) return;
      final first = segments.indexWhere((segment) => !segment.gap && segment.endMs > now - 10000 &&
          segment.startMs < now + 120000 && !_completedSegments.containsKey(segment.key));
      if (first < 0) {
        status = 'Waiting for complete HLS audio near or ahead of playback. Program-clock alignment is estimated.';
        return;
      }
      final selected = <SubtitleHlsSegment>[];
      var duration = 0;
      for (final segment in segments.skip(first)) {
        if (selected.length >= 32 || duration >= 30000 || duration + segment.durationMs > 64000 ||
            segment.gap || segment.discontinuity != segments[first].discontinuity ||
            segment.initialization != segments[first].initialization || segment.initializationRange != segments[first].initializationRange ||
            segment.startMs >= now + 120000 || _completedSegments.containsKey(segment.key) ||
            selected.isNotEmpty && (segment.startMs - selected.last.endMs).abs() > 250) break;
        selected.add(segment); duration += segment.durationMs;
      }
      if (selected.isEmpty || duration < 1000) return;
      await SubtitleInferenceScheduler.instance.run(() async {}, priority: SubtitleWorkPriority.readAhead, isCurrent: current);
      temporary = await (await getTemporaryDirectory()).createTemp('subtitle_live_analysis_');
      status = 'Reading ${selected.length} completed live segments through the source transport'; notifyListeners();
      final native = SubtitleAnalysisDecoder.nativeHlsSnapshot;
      final manifest = native ? await hls.stageNative(selected, temporary) : await hls.stage(selected, temporary);
      if (!current()) return;
      final wav = File('${temporary.path}/window.wav');
      await _decoder.decode(uri: manifest.uri, startMs: 0, endMs: duration, audioOrdinal: _audioOrdinal,
        destination: wav, isCurrent: current, localHlsSnapshot: !native, localSegmentSnapshot: native);
      if (!current()) return;
      status = 'Recognizing completed live audio; the audible player is unchanged'; notifyListeners();
      final result = await SubtitleAiService.instance.transcribeWav(wav.path,
        provider: _provider, languageCode: _language, allowEmpty: true, numThreads: 2,
        priority: SubtitleWorkPriority.readAhead, isCurrent: current);
      if (!current()) return;
      final anchor = selected.first.startMs;
      _windows[anchor] = [for (final cue in result.cues)
        if (cue.startMs < duration && cue.endMs > cue.startMs) SubtitleCue(index: cue.index,
          startMs: anchor + cue.startMs, endMs: anchor + cue.endMs.clamp(0, duration).toInt(), text: cue.text)];
      _words[anchor] = [for (final word in result.wordTimings)
        if (word.startMs < duration && word.endMs > word.startMs) SubtitleWordTiming(startMs: anchor + word.startMs,
          endMs: anchor + word.endMs.clamp(0, duration).toInt(), text: word.text, confidence: word.confidence, unit: word.unit)];
      for (final segment in selected) { _completedSegments[segment.key] = anchor; }
      await _publish(epoch, now, result.detectedLanguage);
      status = 'Prepared live/DVR captions from complete HLS segments; ${result.runtimeProvider}. '
          'Program-clock alignment remains estimated; protected or untimestamped streams are refused.';
    } on SubtitleInferenceDeferred catch (error) {
      if (_current(epoch)) status = error.reason;
    } catch (error) {
      if (_current(epoch)) {
        await stop();
        status = error is UnsupportedError ? error.message?.toString() ?? 'This live source cannot be analyzed'
            : error is FormatException ? error.message : 'Live analysis stopped: a segment, decoder or model was unavailable.';
      }
    } finally {
      await _decoder.cancel();
      if (temporary != null) { try { await temporary.delete(recursive: true); } catch (_) {} }
      _busy = false; notifyListeners();
    }
  }

  Future<void> _publish(int epoch, int center, String? language) async {
    if (!_current(epoch)) return;
    final player = _player!, source = _source!, validity = _valid!;
    final overlay = SubtitleOverlayService.forPlayer(player);
    // Includes an initially empty lane: a user selection during inference wins.
    if (!identical(overlay.lanes[0], _published)) { await stop(); return; }
    while (_windows.length > 240 ||
        _windows.values.fold<int>(0, (n, cues) => n + cues.length) > 49000 ||
        _words.values.fold<int>(0, (n, words) => n + words.length) > 240000 ||
        _windows.values.expand((v) => v).fold<int>(0, (n, c) => n + c.text.length) > 2 * 1024 * 1024) {
      final farthest = _windows.keys.reduce((a, b) => (a - center).abs() > (b - center).abs() ? a : b);
      _windows.remove(farthest); _words.remove(farthest);
      _completedSegments.removeWhere((_, window) => window == farthest);
    }
    final sorted = _windows.values.expand((v) => v).toList()..sort((a, b) => a.startMs.compareTo(b.startMs));
    final all = [for (var i = 0; i < sorted.length; i++) SubtitleCue(index: i + 1, startMs: sorted[i].startMs,
      endMs: sorted[i].endMs, text: sorted[i].text, cueId: sorted[i].stableId)];
    final words = _words.values.expand((v) => v).toList()..sort((a, b) => a.startMs.compareTo(b.startMs));
    final track = SubtitleOverlayTrack(cues: all, words: SubtitleWordTimingBuilder.attachCueIndices(words, all),
      title: source.liveEpochForPosition == null ? 'Prepared playback captions' : 'Live program-clock captions (estimated)',
      profileId: _profileId, language: language, positionToSourceMs: source.liveEpochForPosition,
      isCurrent: () => validity() && source.isCurrent());
    final previous = _published;
    if (previous != null) {
      track.applyAppearance(previous.appearance()); track.delayMs = previous.delayMs; track.avoidObjects = previous.avoidObjects;
    }
    _published = track;
    SubtitleOverlayService.attach(player, 0, track, restoreAppearance: previous == null);
  }
}
