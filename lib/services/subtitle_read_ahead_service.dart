import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../mpv/mpv.dart';
import '../mpv/player/player_media_session_identity.dart';
import '../mpv/player/subtitle_pcm_capture_source.dart';
import 'subtitle_analysis_source.dart';
import 'subtitle_ai_service.dart';
import 'subtitle_inference_scheduler.dart';
import 'subtitle_overlay_service.dart';
import 'subtitle_playback_transcription_service.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';

/// Separate bounded VOD decoder. Never touches audible output, native playback
/// speed, or audio passthrough. User start/stop owns this single worker.
class SubtitleReadAheadService extends ChangeNotifier {
  SubtitleReadAheadService._();
  static final instance = SubtitleReadAheadService._();
  static bool get available => (Platform.isLinux || Platform.isMacOS || Platform.isWindows) &&
      !const bool.fromEnvironment('PLEZY_TIZEN') && !const bool.fromEnvironment('PLEZY_WEBOS');
  Player? _player;
  SubtitleAnalysisSource? _source;
  Timer? _timer;
  Process? _decoder;
  int _generation = 0;
  int? _mediaGeneration;
  String? _audio;
  bool Function()? _valid;
  bool _busy = false;
  int _audioOrdinal = 0;
  String? _language;
  SubtitleInferenceProvider _provider = SubtitleInferenceProvider.cpu;
  final Map<int, List<SubtitleCue>> _windows = {};
  final Map<int, List<SubtitleWordTiming>> _words = {};
  SubtitleOverlayTrack? _published;
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
    required bool Function() isCurrent, required int audioOrdinal, String? language,
    SubtitleInferenceProvider provider = SubtitleInferenceProvider.cpu}) async {
    if (!available) throw UnsupportedError('Separate FFmpeg analysis is available on desktop builds.');
    if (running || _busy) throw StateError('Stop the current read-ahead job first.');
    if (player is SubtitlePcmCaptureSource && player.isLivePlayback) throw UnsupportedError('This decoder requires seekable VOD.');
    if (!player.state.seekable || audioOrdinal < 0 || audioOrdinal > 63) throw ArgumentError('A seekable source and audio stream are required.');
    final epoch = ++_generation;
    _player = player;
    _mediaGeneration = player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
    _audio = player.state.track.audio?.id;
    _valid = isCurrent;
    _audioOrdinal = audioOrdinal;
    _language = language;
    _provider = provider;
    _windows.clear(); _words.clear(); _published = SubtitleOverlayService.forPlayer(player).lanes[0];
    try {
      final source = await open();
      if (epoch != _generation) { await source.close(); return; }
      _source = source;
      if (!_current(epoch)) throw StateError('Playback changed before analysis started.');
      final uri = source.uri;
      if (uri.scheme != 'file' && !(uri.scheme == 'http' && uri.host == '127.0.0.1')) {
        throw UnsupportedError('Decoder access must be through the owning local transport.');
      }
      status = 'Preparing captions ahead of the playhead. Initial speech may finish late.';
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_tick(epoch)));
      notifyListeners();
      unawaited(_tick(epoch));
    } catch (_) { await stop(); rethrow; }
  }

  Future<void> stop() async {
    ++_generation;
    _timer?.cancel(); _timer = null;
    _decoder?.kill(ProcessSignal.sigkill);
    _decoder = null;
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
    if (_published != null && !identical(overlay.lanes[0], _published)) { await stop(); return; }
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
      temporary = await (await getTemporaryDirectory()).createTemp('subtitle_analysis_');
      final wav = File('${temporary.path}/window.wav');
      status = 'Decoding ${start ~/ 1000}–${end ~/ 1000}s through the source transport'; notifyListeners();
      final uri = _source!.uri;
      final process = await Process.start(Platform.environment['PLEZY_FFMPEG'] ?? 'ffmpeg', [
        '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-rw_timeout', '20000000',
        '-protocol_whitelist', uri.scheme == 'file' ? 'file,pipe' : 'http,tcp,pipe',
        '-format_whitelist', 'matroska,webm,mov,avi,mp3,wav,flac,ogg,aac,ac3,eac3,mpegts,mpeg',
        '-ss', (decodeStart / 1000).toStringAsFixed(3), '-i', uri.scheme == 'file' ? uri.toFilePath() : uri.toString(),
        '-map', '0:a:$_audioOrdinal', '-vn', '-sn', '-t', ((end - decodeStart) / 1000).toStringAsFixed(3),
        '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', '-f', 'wav', '-fs', '2300000', wav.path,
      ], runInShell: false);
      _decoder = process;
      final outputs = [process.stdout.drain<void>(), process.stderr.drain<void>()];
      final code = await process.exitCode.timeout(const Duration(seconds: 90), onTimeout: () {
        process.kill(ProcessSignal.sigkill); throw TimeoutException('Analysis decoder timed out');
      });
      await Future.wait(outputs);
      _decoder = null;
      if (!_current(epoch)) return;
      if (code != 0) throw StateError('Decoder failed; check installed FFmpeg and selected audio stream.');
      if (seek != null && (player as SubtitlePcmCaptureSource).playbackTimelineGeneration != seek) return;
      status = 'Recognizing source audio ${start ~/ 1000}s'; notifyListeners();
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
      // Keep up to 240 windows (2 hours) around current playhead, 8 MiB text.
      while (_windows.length > 240 || _windows.values.expand((v) => v).fold<int>(0, (n, c) => n + c.text.length) > 2 * 1024 * 1024) {
        final farthest = _windows.keys.reduce((a, b) => (a - first).abs() > (b - first).abs() ? a : b);
        _windows.remove(farthest); _words.remove(farthest);
      }
      final all = _windows.values.expand((v) => v).toList()..sort((a, b) => a.startMs.compareTo(b.startMs));
      final validity = _valid!, source = _source!;
      final track = SubtitleOverlayTrack(cues: all,
        words: SubtitleWordTimingBuilder.attachCueIndices(_words.values.expand((v) => v).toList(), all),
        title: 'Prepared playback captions', language: result.detectedLanguage, isCurrent: () => validity() && source.isCurrent());
      final previous = _published;
      if (previous != null) {
        track.fontSize = previous.fontSize; track.position = previous.position; track.color = previous.color;
        track.outline = previous.outline; track.outlineWidth = previous.outlineWidth;
        track.backgroundOpacity = previous.backgroundOpacity; track.margin = previous.margin;
        track.delayMs = previous.delayMs; track.karaoke = previous.karaoke; track.bold = previous.bold; track.italic = previous.italic;
      }
      // Refuse to overwrite a lane the user edited/replaced during inference.
      if (_published != null && !identical(overlay.lanes[0], _published)) { await stop(); return; }
      _published = track;
      SubtitleOverlayService.attach(player, 0, track);
      status = 'Prepared ${_windows.length} windows; ${result.runtimeProvider}. Placement remains unverified.';
    } catch (error) {
      if (epoch == _generation) {
        await stop();
        status = error is ProcessException ? 'Read-ahead stopped. Install FFmpeg or configure PLEZY_FFMPEG.'
            : 'Read-ahead stopped. The decoder, model, or current source could not complete the window.';
      }
    } finally {
      _decoder?.kill(ProcessSignal.sigkill); _decoder = null;
      if (temporary != null) { try { await temporary.delete(recursive: true); } catch (_) {} }
      _busy = false; notifyListeners();
    }
  }
}
