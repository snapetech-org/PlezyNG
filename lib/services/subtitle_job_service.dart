import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../profiles/active_profile_provider.dart';
import 'power_source_service.dart';
import 'subtitle_ai_service.dart';
import 'subtitle_inference_scheduler.dart';
import 'subtitle_placement_evidence.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';
import 'subtitle_playback_transcription_service.dart';

enum SubtitleJobState { queued, running, paused, completed, cancelled, failed }

/// A profile-local, immutable-input transcription task. The service owns all
/// mutation; callers can inspect progress but cannot change persisted state.
final class SubtitleJob {
  SubtitleJob._({
    required this.id,
    required this.identityKey,
    required this.title,
    required this.durationMs,
    required this.provider,
    required this.language,
    required this.translateToEnglish,
    required this.chargingOnly,
    required this.idleOnly,
    required this.audioDigest,
    required this.audioBytes,
    required this.directory,
  });

  final String id;
  final String identityKey;
  final String title;
  final int durationMs;
  final SubtitleInferenceProvider provider;
  final String? language;
  final bool translateToEnglish;
  final bool chargingOnly;
  final bool idleOnly;
  final String audioDigest;
  final int audioBytes;
  final String directory;
  SubtitleJobState _state = SubtitleJobState.queued;
  String? _message;
  final Set<int> _completed = {};
  int _outputBytes = 0;
  int _cueCount = 0;
  int _wordCount = 0;
  int _generation = 0;
  bool _audioVerified = false;
  String _runtime = '';
  bool _fallback = false;
  String _detectedLanguage = 'unknown';
  int Function()? _playhead;
  bool Function()? _playbackBusy;

  SubtitleJobState get state => _state;
  String? get message => _message;
  int get chunkCount => (durationMs / SubtitleJobService.chunkMs).ceil();
  int get completedChunks => _completed.length;
  double get progress => completedChunks / chunkCount;
  bool get hasResult => _completed.isNotEmpty && _cueCount > 0;
  bool get terminal => state == SubtitleJobState.completed || state == SubtitleJobState.cancelled;
  List<(int, int)> get completedRanges => List.unmodifiable(
    (_completed.toList()..sort()).map((i) => (i * SubtitleJobService.chunkMs,
        math.min((i + 1) * SubtitleJobService.chunkMs, durationMs))),
  );

  Map<String, Object?> _json() => {
    'schema': 1, 'id': id, 'identity': identityKey, 'title': title,
    'durationMs': durationMs, 'provider': provider.name, 'language': language,
    'translate': translateToEnglish, 'chargingOnly': chargingOnly, 'idleOnly': idleOnly,
    'audioDigest': audioDigest, 'audioBytes': audioBytes, 'state': state.name,
    'completed': _completed.toList()..sort(), 'outputBytes': _outputBytes,
    'cueCount': _cueCount, 'wordCount': _wordCount, 'runtime': _runtime,
    'fallback': _fallback, 'detectedLanguage': _detectedLanguage,
  };
}

/// One bounded inference window at a time, with durable per-window checkpoints.
/// Pausing/cancelling never starts another window and discards the active one.
/// Native inference itself is not interruptible; its current window must return.
/// This is an in-app worker, not an OS background-execution entitlement.
final class SubtitleJobService extends ChangeNotifier with WidgetsBindingObserver {
  SubtitleJobService._();
  static final instance = SubtitleJobService._();
  static const chunkMs = 30000;
  static const _overlapMs = 2000;
  static const _maximumJobs = 12;
  static const _maximumAudioBytes = 1024 * 1024 * 1024;
  static const _maximumTotalAudioBytes = 2 * 1024 * 1024 * 1024;
  static const _maximumOutputBytes = 24 * 1024 * 1024;
  final List<SubtitleJob> _jobs = [];
  ActiveProfileProvider? _profiles;
  String? _profileKey;
  String? _root;
  Future<void> _ready = Future.value();
  Future<void> _writes = Future.value();
  bool _pumping = false;
  bool _importing = false;
  bool _foreground = true;
  int _profileEpoch = 0;
  Timer? _retry;
  String? _loadError;

  List<SubtitleJob> get jobs => List.unmodifiable(_jobs);
  Future<void> get ready => _ready;
  String? get loadError => _loadError;

  void bindProfile(ActiveProfileProvider profiles) {
    if (identical(_profiles, profiles)) return;
    _profiles?.removeListener(_profileChanged);
    if (_profiles == null) WidgetsBinding.instance.addObserver(this);
    _profiles = profiles;
    profiles.addListener(_profileChanged);
    _profileChanged();
  }

  void _profileChanged() {
    final id = _profiles?.activeId;
    final key = id == null ? null : sha256.convert(utf8.encode(id)).toString();
    if (key == _profileKey) return;
    _profileKey = key;
    final epoch = ++_profileEpoch;
    _retry?.cancel();
    for (final job in _jobs) {
      if (job.state == SubtitleJobState.queued || job.state == SubtitleJobState.running) {
        ++job._generation;
        job._state = SubtitleJobState.paused;
        unawaited(_persist(job).catchError((Object _) {}));
      }
    }
    _jobs.clear();
    _root = null;
    _loadError = null;
    _ready = _load(key, epoch);
    notifyListeners();
  }

  Future<void> _load(String? key, int epoch) async {
    if (key == null) return;
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'subtitle_jobs', key));
      await root.create(recursive: true);
      final loaded = <SubtitleJob>[];
      await for (final entity in root.list(followLinks: false)) {
        if (epoch != _profileEpoch) return;
        if (entity is Directory && RegExp(r'^\d+_[0-9a-f]{16}\.staging$').hasMatch(p.basename(entity.path))) {
          // A process exit during copying leaves no resumable job. Never retain
          // its audio indefinitely or charge it against an invisible quota.
          await entity.delete(recursive: true);
          continue;
        }
        if (entity is! Directory || !RegExp(r'^\d+_[0-9a-f]{16}$').hasMatch(p.basename(entity.path))) continue;
        if (loaded.length >= _maximumJobs) break;
        try {
          final file = File(p.join(entity.path, 'job.json'));
          Map<String, dynamic>? json;
          for (final candidate in [file, File('${file.path}.bak')]) {
            if (!await candidate.exists() || await candidate.length() > 65536) continue;
            try { json = jsonDecode(await candidate.readAsString()) as Map<String, dynamic>; break; } catch (_) {}
          }
          if (json == null) continue;
          final duration = json['durationMs'] as int;
          final bytes = json['audioBytes'] as int;
          if (json['schema'] != 1 || json['id'] != p.basename(entity.path) ||
              duration <= 0 || duration > 8 * 3600000 || bytes < 44 || bytes > _maximumAudioBytes ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['audioDigest'] as String) ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['identity'] as String)) continue;
          final title = json['title'] as String;
          if (title.length > 300) continue;
          final job = SubtitleJob._(
            id: json['id'] as String, identityKey: json['identity'] as String,
            title: title, durationMs: duration,
            provider: SubtitleInferenceProvider.values.byName(json['provider'] as String),
            language: json['language'] as String?, translateToEnglish: json['translate'] == true,
            chargingOnly: json['chargingOnly'] == true, idleOnly: json['idleOnly'] == true,
            audioDigest: json['audioDigest'] as String, audioBytes: bytes, directory: entity.path,
          );
          job._state = SubtitleJobState.values.byName(json['state'] as String);
          if (job.state == SubtitleJobState.running || job.state == SubtitleJobState.queued) {
            job._state = SubtitleJobState.paused;
          }
          final chunks = (json['completed'] as List).cast<int>();
          if (chunks.length > job.chunkCount || chunks.any((i) => i < 0 || i >= job.chunkCount)) continue;
          job._completed.addAll(chunks);
          job._outputBytes = json['outputBytes'] as int;
          job._cueCount = json['cueCount'] as int;
          job._wordCount = json['wordCount'] as int;
          if (job._outputBytes < 0 || job._outputBytes > _maximumOutputBytes || job._cueCount < 0 ||
              job._cueCount > 50000 || job._wordCount < 0 || job._wordCount > 250000) continue;
          job._runtime = json['runtime'] as String;
          job._fallback = json['fallback'] == true;
          job._detectedLanguage = json['detectedLanguage'] as String;
          loaded.add(job);
        } catch (_) {
          _loadError = 'A damaged job record was skipped. Other jobs remain available.';
        }
      }
      if (epoch != _profileEpoch) return;
      _root = root.path;
      _jobs.addAll(loaded..sort((a, b) => b.id.compareTo(a.id)));
      notifyListeners();
    } catch (_) {
      if (epoch == _profileEpoch) {
        _loadError = 'The transcription queue could not be opened.';
        notifyListeners();
      }
    }
  }

  Future<SubtitleJob> enqueue({
    required String wavPath, required String identityKey, required String title,
    required SubtitleInferenceProvider provider, String? language,
    bool translateToEnglish = false, bool chargingOnly = false, bool idleOnly = false,
    int Function()? playheadMs, bool Function()? playbackBusy,
  }) async {
    await ready;
    if (_importing) throw StateError('Another audio file is being staged.');
    if (_root == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(identityKey)) {
      throw StateError('Choose an active profile and a stable media item before queuing transcription.');
    }
    if (_jobs.length >= _maximumJobs) throw StateError('Delete an old job before adding another (12-job limit).');
    _importing = true;
    final epoch = _profileEpoch;
    Directory? staging;
    try {
      final input = File(wavPath);
      final length = await input.length();
      final total = _jobs.fold<int>(0, (sum, job) => sum + job.audioBytes);
      if (length < 44 || length > _maximumAudioBytes || total + length > _maximumTotalAudioBytes) {
        throw const FormatException('Jobs allow 1 GiB per WAV and 2 GiB of queued audio per profile.');
      }
      final duration = await SubtitleAiService.instance.readWavDurationMs(wavPath);
      if (duration <= 0 || duration > 8 * 3600000) throw const FormatException('Choose up to eight hours of audio.');
      final random = math.Random.secure();
      final suffix = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final id = '${DateTime.now().microsecondsSinceEpoch}_$suffix';
      final directory = p.join(_root!, id);
      staging = await Directory('$directory.staging').create();
      final copied = File(p.join(staging.path, 'audio.wav'));
      final sink = copied.openWrite();
      var copiedBytes = 0;
      try {
        await for (final bytes in input.openRead()) {
          if (epoch != _profileEpoch) throw StateError('Profile changed while staging audio.');
          copiedBytes += bytes.length;
          if (copiedBytes > length) throw const FormatException('Audio changed during import.');
          sink.add(bytes);
        }
        await sink.flush();
      } finally { await sink.close(); }
      if (copiedBytes != length) throw const FormatException('Audio changed during import.');
      final digest = (await sha256.bind(copied.openRead()).first).toString();
      // Re-parse the owned copy, not the file whose permissions may have expired.
      if (await SubtitleAiService.instance.readWavDurationMs(copied.path) != duration || epoch != _profileEpoch) {
        throw StateError('Audio or profile changed during import.');
      }
      final job = SubtitleJob._(
        id: id, identityKey: identityKey, title: title.length > 300 ? title.substring(0, 300) : title,
        durationMs: duration, provider: provider, language: language,
        translateToEnglish: translateToEnglish, chargingOnly: chargingOnly, idleOnly: idleOnly,
        audioDigest: digest, audioBytes: length, directory: directory,
      ).._audioVerified = true;
      job._playhead = playheadMs;
      job._playbackBusy = playbackBusy;
      await File(p.join(staging.path, 'job.json')).writeAsString(jsonEncode(job._json()), flush: true);
      await staging.rename(directory);
      staging = null;
      if (epoch != _profileEpoch) {
        job._state = SubtitleJobState.paused;
        await _persist(job);
        throw StateError('The job was saved under its original profile; switch back to resume it.');
      }
      _jobs.insert(0, job);
      notifyListeners();
      _wake();
      return job;
    } finally {
      _importing = false;
      if (staging != null && await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> pause(SubtitleJob job) => _setState(job, SubtitleJobState.paused);
  Future<void> cancel(SubtitleJob job) => _setState(job, SubtitleJobState.cancelled);
  Future<void> resume(SubtitleJob job, {int Function()? playheadMs, bool Function()? playbackBusy}) async {
    if (job.terminal) return;
    job._playhead = playheadMs;
    job._playbackBusy = playbackBusy;
    await _setState(job, SubtitleJobState.queued);
    _wake();
  }

  Future<void> _setState(SubtitleJob job, SubtitleJobState state) async {
    if (!_jobs.contains(job)) throw StateError('This job belongs to another profile.');
    if (job.terminal) return;
    ++job._generation;
    job._state = state;
    job._message = null;
    notifyListeners();
    await _persist(job);
  }

  Future<void> delete(SubtitleJob job) async {
    if (!_jobs.contains(job)) return;
    ++job._generation;
    job._state = SubtitleJobState.cancelled;
    _jobs.remove(job);
    notifyListeners();
    await _serialize(() async {
      final directory = Directory(job.directory);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _writes.then((_) => operation());
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> _persist(SubtitleJob job) {
    final data = jsonEncode(job._json());
    return _serialize(() => _atomicWrite(File(p.join(job.directory, 'job.json')), data));
  }

  static Future<void> _atomicWrite(File file, String data) async {
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temp.writeAsString(data, flush: true);
    if (await file.exists()) {
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
    }
    await temp.rename(file.path);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _wake();
  }

  void _wake() {
    _retry?.cancel();
    if (!_pumping) unawaited(_pump());
  }

  Future<void> _pump() async {
    _pumping = true;
    try {
      while (_foreground) {
        final live = SubtitlePlaybackTranscriptionService.instance;
        if (live.isStarting || live.isRunning || live.hasActiveSession) break;
        SubtitleJob? selected;
        for (final job in List<SubtitleJob>.of(_jobs)) {
          if (job.state != SubtitleJobState.queued) continue;
          if (job.idleOnly && (job._playbackBusy?.call() ?? true)) {
            job._message = 'Waiting for playback to stop (reopen this item to report playback state).';
            continue;
          }
          if (job.chargingOnly && await PowerSourceService.isConnected() != true) {
            job._message = 'Waiting for confirmed external power.';
            continue;
          }
          if (!_jobs.contains(job) || job.state != SubtitleJobState.queued) continue;
          selected = job;
          break;
        }
        if (selected == null) break;
        await _step(selected);
      }
    } finally {
      _pumping = false;
      notifyListeners();
      if (_jobs.any((job) => job.state == SubtitleJobState.queued)) {
        _retry = Timer(const Duration(seconds: 15), _wake);
      }
    }
  }

  Future<void> _step(SubtitleJob job) async {
    final epoch = _profileEpoch;
    final generation = job._generation;
    bool current() => epoch == _profileEpoch && generation == job._generation && _jobs.contains(job);
    try {
      job._state = SubtitleJobState.running;
      job._message = 'Preparing transcription';
      notifyListeners();
      final audio = File(p.join(job.directory, 'audio.wav'));
      if (!job._audioVerified) {
        if (await audio.length() != job.audioBytes ||
            (await sha256.bind(audio.openRead()).first).toString() != job.audioDigest) {
          throw const FormatException('The staged audio failed its integrity check. Create a new job.');
        }
        job._audioVerified = true;
      }
      if (!current()) return;
      final position = (job._playhead?.call() ?? 0).clamp(0, job.durationMs - 1);
      final priority = position ~/ chunkMs;
      int? chunk;
      for (var offset = 0; offset < job.chunkCount; offset++) {
        final candidate = (priority + offset) % job.chunkCount;
        if (!job._completed.contains(candidate)) { chunk = candidate; break; }
      }
      if (chunk == null) {
        job._state = SubtitleJobState.completed;
        await _persist(job);
        return;
      }
      final start = chunk * chunkMs;
      final end = math.min(start + chunkMs, job.durationMs);
      final result = await SubtitleAiService.instance.transcribeWav(
        audio.path, provider: job.provider, languageCode: job.language,
        priority: SubtitleWorkPriority.background, isCurrent: current,
        translateToEnglish: job.translateToEnglish, allowEmpty: true,
        startMs: math.max(0, start - _overlapMs), endMs: math.min(job.durationMs, end + _overlapMs),
        onProgress: (phase, received, total) {
          if (!current()) return;
          job._message = '$phase · ${job.completedChunks}/${job.chunkCount} windows saved';
          notifyListeners();
        },
      );
      if (!current()) return;
      // A deterministic midpoint ownership rule removes duplicated overlap
      // windows regardless of processing order after seeks or restarts.
      bool owns(int a, int b) => (a + b) ~/ 2 >= start && (a + b) ~/ 2 < end;
      final cues = result.cues.where((cue) => owns(cue.startMs, cue.endMs)).toList();
      final words = result.wordTimings.where((word) => owns(word.startMs, word.endMs)).toList();
      final data = jsonEncode({
        'cues': cues.map((c) => [c.startMs, c.endMs, c.text]).toList(),
        'words': words.map((w) => [w.startMs, w.endMs, w.text, w.confidence, w.unit.name]).toList(),
      });
      final bytes = utf8.encode(data).length;
      if (job._outputBytes + bytes > _maximumOutputBytes || job._cueCount + cues.length > 50000 ||
          job._wordCount + words.length > 250000) {
        throw const FormatException('The job reached its caption storage limit. Review its saved partial result.');
      }
      await _serialize(() async {
        if (!current()) return;
        await _atomicWrite(File(p.join(job.directory, 'chunk_$chunk.json')), data);
      });
      if (!current()) return;
      job._completed.add(chunk);
      job._outputBytes += bytes;
      job._cueCount += cues.length;
      job._wordCount += words.length;
      job._runtime = result.runtimeProvider;
      job._fallback |= result.fellBackToCpu;
      if (result.cues.isNotEmpty && job._detectedLanguage == 'unknown') {
        job._detectedLanguage = result.detectedLanguage;
      } else if (result.cues.isNotEmpty && job._detectedLanguage != result.detectedLanguage) {
        job._detectedLanguage = 'mixed';
      }
      job._state = job.completedChunks == job.chunkCount ? SubtitleJobState.completed : SubtitleJobState.queued;
      job._message = job._state == SubtitleJobState.completed ? 'All audio windows saved; review before attachment.' : null;
      await _persist(job);
    } catch (_) {
      if (!current()) return;
      job._state = SubtitleJobState.failed;
      // Native errors can include filesystem paths or media URLs. Keep them out
      // of durable metadata and UI; preserve completed windows for retry/export.
      job._message = 'This window could not finish. Completed windows are saved; resume to retry.';
      try { await _persist(job); } catch (_) {}
    }
  }

  Future<SubtitleTranscriptionResult> readResult(SubtitleJob job) async {
    if (!_jobs.contains(job)) throw StateError('The active profile changed.');
    final epoch = _profileEpoch;
    final cues = <SubtitleCue>[];
    final words = <SubtitleWordTiming>[];
    var bytes = 0;
    for (final chunk in job._completed.toList()..sort()) {
      final file = File(p.join(job.directory, 'chunk_$chunk.json'));
      bytes += await file.length();
      if (bytes > _maximumOutputBytes) throw const FormatException('Job output exceeds its storage limit.');
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final raw in json['cues'] as List) {
        final c = raw as List;
        final start = c[0] as int, end = c[1] as int;
        final text = c[2] as String;
        if (start < 0 || end <= start || end > job.durationMs || text.length > 4000 || cues.length >= 50000) {
          throw const FormatException('A job checkpoint contains invalid cues.');
        }
        cues.add(SubtitleCue(index: cues.length + 1, startMs: start, endMs: end, text: text));
      }
      for (final raw in json['words'] as List) {
        final w = raw as List;
        final start = w[0] as int, end = w[1] as int;
        final text = w[2] as String;
        final probability = (w[3] as num).toDouble();
        if (start < 0 || end <= start || end > job.durationMs || text.length > 4000 ||
            !probability.isFinite || probability < 0 || probability > 1 || words.length >= 250000) {
          throw const FormatException('A job checkpoint contains invalid word timings.');
        }
        words.add(SubtitleWordTiming(startMs: start, endMs: end, text: text,
            confidence: probability, unit: SubtitleWordTimingUnit.values.byName(w[4] as String)));
      }
    }
    if (epoch != _profileEpoch) throw StateError('The active profile changed.');
    cues.sort((a, b) => a.startMs.compareTo(b.startMs));
    words.sort((a, b) => a.startMs.compareTo(b.startMs));
    final merged = <SubtitleCue>[];
    for (final cue in cues) {
      if (merged.isNotEmpty && cue.startMs < merged.last.endMs &&
          cue.text.trim().toLowerCase() == merged.last.text.trim().toLowerCase()) {
        final previous = merged.removeLast();
        merged.add(SubtitleCue(index: merged.length + 1, startMs: previous.startMs,
            endMs: math.max(previous.endMs, cue.endMs), text: previous.text));
      } else {
        merged.add(SubtitleCue(index: merged.length + 1, startMs: cue.startMs, endMs: cue.endMs, text: cue.text));
      }
    }
    return SubtitleTranscriptionResult(
      cues: List.unmodifiable(merged), wordTimings: SubtitleWordTimingBuilder.attachCueIndices(words, merged),
      durationMs: job.durationMs, requestedProvider: job.provider, runtimeProvider: job._runtime,
      fellBackToCpu: job._fallback,
      placementEvidence: job._fallback ? SubtitlePlacementEvidence.cpuFallbackAfterAcceleratorUnavailable
          : job.provider == SubtitleInferenceProvider.cpu ? SubtitlePlacementEvidence.cpuOnlyConfigured
          : SubtitlePlacementEvidence.acceleratorRequestSucceededButUnverified,
      detectedLanguage: job.translateToEnglish ? 'en' : job._detectedLanguage,
      translatedToEnglish: job.translateToEnglish,
    );
  }
}
