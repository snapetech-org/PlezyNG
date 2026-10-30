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
import 'subtitle_analysis_decoder.dart';
import 'subtitle_job_source.dart';
import 'subtitle_job_ownership.dart';
import 'subtitle_job_schedule.dart';
import 'subtitle_inference_scheduler.dart';
import 'subtitle_placement_evidence.dart';
import 'subtitle_retimer.dart';
import 'subtitle_word_timing.dart';
import 'subtitle_playback_transcription_service.dart';

enum SubtitleJobState { queued, running, paused, completed, cancelled, failed }

/// A profile-local transcription task over retained WAV bytes or an explicit
/// owned-source binding. Source descriptors are not full-file content hashes.
/// The service owns all mutation and keeps source capabilities out of storage.
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
    this.sourceBindingKey,
    this.audioOrdinal,
    this.timelineOffsetMs = 0,
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
  final String? sourceBindingKey;
  final int? audioOrdinal;
  final int timelineOffsetMs;
  SubtitleJobSource? _source;
  bool get usesSourceDecoder => sourceBindingKey != null;
  bool _backgroundAllowed = false;
  bool get backgroundAllowed => _backgroundAllowed;
  SubtitleJobState _state = SubtitleJobState.queued;
  String? _message;
  final Set<int> _completed = {};
  int _outputBytes = 0;
  int _cueCount = 0;
  int _wordCount = 0;
  int _generation = 0;
  bool _audioVerified = false;
  DateTime? _resourceRetryAfter;
  String _runtime = '';
  bool _fallback = false;
  String _detectedLanguage = 'unknown';
  int Function()? _playhead;
  bool Function()? _playbackBusy;

  SubtitleJobState get state => _state;
  String? get message => _message;
  bool get backgroundSupported => provider.supportsCooperativeCancellation;
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
    'schema': 3, 'id': id, 'identity': identityKey, 'title': title,
    'durationMs': durationMs, 'provider': provider.name, 'language': language,
    'translate': translateToEnglish, 'chargingOnly': chargingOnly, 'idleOnly': idleOnly,
    'backgroundAllowed': backgroundAllowed,
    'audioDigest': audioDigest, 'audioBytes': audioBytes, 'state': state.name,
    'completed': _completed.toList()..sort(), 'outputBytes': _outputBytes,
    'cueCount': _cueCount, 'wordCount': _wordCount, 'runtime': _runtime,
    'fallback': _fallback, 'detectedLanguage': _detectedLanguage,
    if (_message == 'Install the selected speech model in the foreground first.') 'pausedReason': 'modelMissing',
    if (usesSourceDecoder) 'source': {'binding': sourceBindingKey,
      'audioOrdinal': audioOrdinal, 'timelineOffsetMs': timelineOffsetMs},
  };
}

/// One bounded inference window at a time, with durable per-window checkpoints.
/// Pausing/cancelling never starts another window and discards the active one.
/// Whisper supports cooperative cancellation; other native windows must return.
/// Explicitly enabled retained-WAV jobs can also run through the OS worker.
/// Each engine holds exclusive profile ownership until its last call returns.
final class SubtitleJobService extends ChangeNotifier with WidgetsBindingObserver {
  SubtitleJobService._({bool headless = false}) : _headless = headless;
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
  final bool _headless;
  bool Function()? _workerMayRun;
  SubtitleJobOwnership? _ownership;
  String? _ownershipDirectory;
  Completer<void>? _pumpFinished;
  Completer<void>? _importFinished;
  int _profileEpoch = 0;
  Timer? _retry;
  final _decoder = SubtitleAnalysisDecoder();
  String? _loadError;

  List<SubtitleJob> get jobs => List.unmodifiable(_jobs);
  Future<void> get ready => _ready;
  String? get loadError => _loadError;

  void bindProfile(ActiveProfileProvider profiles) {
    if (identical(_profiles, profiles)) return;
    _profiles?.removeListener(_profileChanged);
    if (_profiles == null) {
      WidgetsBinding.instance.addObserver(this);
      final state = WidgetsBinding.instance.lifecycleState;
      _foreground = state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    }
    _profiles = profiles;
    profiles.addListener(_profileChanged);
    _profileChanged();
  }

  void _profileChanged() {
    final id = _profiles?.activeId;
    final key = id == null ? null : sha256.convert(utf8.encode(id)).toString();
    if (key == _profileKey) return;
    _profileKey = key;
    _transition(changingProfile: true);
  }

  void _transition({bool background = false, bool changingProfile = false}) {
    final epoch = ++_profileEpoch;
    final key = _profileKey;
    final previous = _ready;
    final authorization = SubtitleJobActivity.authorize(key).catchError((Object _) {});
    final schedule = background && _jobs.any((job) => job.backgroundAllowed &&
        (job.state == SubtitleJobState.running || job.state == SubtitleJobState.queued));
    _retry?.cancel();
    _root = null;
    for (final job in _jobs) {
      unawaited(_closeSource(job));
      ++job._generation;
      if (job.state == SubtitleJobState.queued || job.state == SubtitleJobState.running) {
        job._state = !changingProfile && job.backgroundAllowed && !job.usesSourceDecoder
            ? SubtitleJobState.queued : SubtitleJobState.paused;
        unawaited(_persist(job).catchError((Object _) {}));
      }
    }
    _loadError = null;
    _ready = () async {
      try { await previous; } on Object { /* A later open may recover. */ }
      try { await authorization; } on Object { /* No readable authorization means no background work. */ }
      await _pumpFinished?.future;
      await _importFinished?.future;
      await _writes;
      if (schedule) { try { await SubtitleJobSchedule.schedule(); } on Object { /* Existing periodic work can recover. */ } }
      _jobs.clear();
      final ownership = _ownership;
      _ownership = null;
      _ownershipDirectory = null;
      await ownership?.release();
      if (epoch != _profileEpoch || !_foreground || key == null) return;
      await _load(key, epoch);
      if (epoch == _profileEpoch) _wake();
    }();
    notifyListeners();
  }

  Future<void> _load(String? key, int epoch) async {
    if (key == null) return;
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'subtitle_jobs', key));
      await root.create(recursive: true);
      while (_ownership == null && epoch == _profileEpoch && (_foreground || _headless)) {
        final ownership = await SubtitleJobOwnership.acquire(root);
        if (epoch != _profileEpoch || !_foreground && !_headless) {
          await ownership?.release();
          return;
        }
        if (ownership != null) { _ownership = ownership; _ownershipDirectory = root.path; break; }
        if (_headless) return;
        _loadError = 'Waiting for the background subtitle window to release its checkpoint.';
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (_ownership == null || epoch != _profileEpoch) return;
      _loadError = null;
      final revoked = await SubtitleJobActivity.isRevoked(key);
      if (_headless && revoked) return;
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
          final rawSource = json['source'];
          final source = rawSource is Map<String, dynamic> ? rawSource : null;
          if (!const [1, 2, 3].contains(json['schema']) || json['id'] != p.basename(entity.path) ||
              rawSource != null && (!const [2, 3].contains(json['schema']) || source == null) ||
              duration <= 0 || duration > 8 * 3600000 || bytes < (source == null ? 44 : 0) || bytes > _maximumAudioBytes ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['audioDigest'] as String) ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['identity'] as String)) continue;
          if (source != null && (bytes != 0 || source['binding'] is! String ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(source['binding'] as String) ||
              source['audioOrdinal'] is! int || (source['audioOrdinal'] as int) < 0 || (source['audioOrdinal'] as int) > 63 ||
              source['timelineOffsetMs'] is! int || (source['timelineOffsetMs'] as int) < 0 ||
              (source['timelineOffsetMs'] as int) + duration > 24 * 3600000)) continue;
          final title = json['title'] as String;
          if (title.length > 300) continue;
          final job = SubtitleJob._(
            id: json['id'] as String, identityKey: json['identity'] as String,
            title: title, durationMs: duration,
            provider: SubtitleInferenceProvider.values.byName(json['provider'] as String),
            language: json['language'] as String?, translateToEnglish: json['translate'] == true,
            chargingOnly: json['chargingOnly'] == true, idleOnly: json['idleOnly'] == true,
            audioDigest: json['audioDigest'] as String, audioBytes: bytes, directory: entity.path,
            sourceBindingKey: source?['binding'] as String?, audioOrdinal: source?['audioOrdinal'] as int?,
            timelineOffsetMs: source?['timelineOffsetMs'] as int? ?? 0,
          );
          job._backgroundAllowed = !revoked && !job.usesSourceDecoder && !job.idleOnly &&
              job.backgroundSupported && json['backgroundAllowed'] == true;
          job._state = SubtitleJobState.values.byName(json['state'] as String);
          if (job.state == SubtitleJobState.running || job.state == SubtitleJobState.queued) {
            job._state = job.backgroundAllowed ? SubtitleJobState.queued : SubtitleJobState.paused;
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
          if (json['pausedReason'] == 'modelMissing') job._message = 'Install the selected speech model in the foreground first.';
          // Decoded audio is temporary, even if the process exited mid-window.
          final temporary = Directory(p.join(entity.path, 'window'));
          if (await temporary.exists()) await temporary.delete(recursive: true);
          loaded.add(job);
        } catch (_) {
          _loadError = 'A damaged job record was skipped. Other jobs remain available.';
        }
      }
      if (epoch != _profileEpoch) return;
      _root = root.path;
      _jobs.addAll(loaded..sort((a, b) => b.id.compareTo(a.id)));
      if (revoked) { for (final job in loaded) { await _persist(job); } }
      notifyListeners();
    } catch (_) {
      if (epoch == _profileEpoch) {
        _loadError = 'The transcription queue could not be opened.';
        _root = null;
        final ownership = _ownership;
        _ownership = null;
        _ownershipDirectory = null;
        await ownership?.release();
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
    _requireOwnership();
    if (_importing) throw StateError('Another audio file is being staged.');
    if (_root == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(identityKey)) {
      throw StateError('Choose an active profile and a stable media item before queuing transcription.');
    }
    if (_jobs.length >= _maximumJobs) throw StateError('Delete an old job before adding another (12-job limit).');
    _importing = true;
    _importFinished = Completer<void>();
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
      try { if (staging != null && await staging.exists()) await staging.delete(recursive: true); }
      finally { _importing = false; _importFinished?.complete(); _importFinished = null; }
    }
  }

  /// Takes ownership of [source], including on failure. The job stores only
  /// text checkpoints and identity digests; a resume opens a fresh source lease.
  Future<SubtitleJob> enqueueSource({required SubtitleJobSource source,
    required String identityKey, required String title, required SubtitleInferenceProvider provider,
    String? language, bool translateToEnglish = false, bool chargingOnly = false, bool idleOnly = false,
    int Function()? playheadMs, bool Function()? playbackBusy,
  }) async {
    Directory? staging;
    var claimed = false, importing = false;
    final epoch = _profileEpoch;
    try {
      await ready;
      _requireOwnership();
      if (_importing || _root == null || epoch != _profileEpoch ||
          !source.isCurrent || !RegExp(r'^[0-9a-f]{64}$').hasMatch(identityKey)) {
        throw StateError('The source or profile changed, or another job is being created.');
      }
      if (_jobs.length >= _maximumJobs) throw StateError('Delete an old job before adding another (12-job limit).');
      _importing = true; importing = true; _importFinished = Completer<void>();
      final random = math.Random.secure();
      final suffix = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final id = '${DateTime.now().microsecondsSinceEpoch}_$suffix';
      final directory = p.join(_root!, id);
      staging = await Directory('$directory.staging').create();
      final job = SubtitleJob._(id: id, identityKey: identityKey,
        title: title.length > 300 ? title.substring(0, 300) : title,
        durationMs: source.durationMs, provider: provider, language: language,
        translateToEnglish: translateToEnglish, chargingOnly: chargingOnly, idleOnly: idleOnly,
        audioDigest: source.bindingKey, audioBytes: 0, directory: directory,
        sourceBindingKey: source.bindingKey, audioOrdinal: source.audioOrdinal,
        timelineOffsetMs: source.timelineOffsetMs);
      job._source = source;
      job._playhead = playheadMs;
      job._playbackBusy = playbackBusy;
      await File(p.join(staging.path, 'job.json')).writeAsString(jsonEncode(job._json()), flush: true);
      if (!source.isCurrent || epoch != _profileEpoch) throw StateError('Source changed while creating the job.');
      await staging.rename(directory); staging = null;
      if (epoch != _profileEpoch || !source.isCurrent) {
        job._state = SubtitleJobState.paused;
        await _persist(job);
        throw StateError('The saved job is paused; reopen its original source to resume.');
      }
      _jobs.insert(0, job); claimed = true;
      notifyListeners(); _wake();
      return job;
    } finally {
      try {
        if (!claimed) await source.close();
        if (staging != null && await staging.exists()) await staging.delete(recursive: true);
      } finally {
        if (importing) { _importing = false; _importFinished?.complete(); _importFinished = null; }
      }
    }
  }

  Future<void> _closeSource(SubtitleJob job) async {
    final source = job._source; job._source = null;
    try { await source?.close(); } catch (_) {}
  }

  void _requireOwnership() {
    if (_ownership == null || _root == null || !_headless && !_foreground) {
      throw StateError('Wait for the subtitle queue to reopen in the foreground.');
    }
  }

  Future<bool> _scheduleBackgroundWork() async {
    try { return await SubtitleJobSchedule.schedule(); } on Object { return false; }
  }

  Future<void> allowBackground(SubtitleJob job, bool allowed) async {
    await ready;
    _requireOwnership();
    final epoch = _profileEpoch, key = _profileKey!;
    bool current() => epoch == _profileEpoch && _foreground && _root != null && _jobs.contains(job);
    if (!_jobs.contains(job) || job.usesSourceDecoder || job.terminal) {
      throw StateError('Only a retained-WAV job can be scheduled in the background.');
    }
    if (allowed && job.idleOnly) {
      throw StateError('A headless worker cannot confirm that playback is idle.');
    }
    if (allowed && !job.backgroundSupported) {
      throw StateError('This accelerator request cannot be cancelled safely in the background.');
    }
    if (allowed && !await SubtitleAiService.instance.isProviderModelInstalled(job.provider)) {
      throw StateError('Install the selected speech model in the foreground first.');
    }
    if (!current() || job.terminal) throw StateError('The profile changed.');
    if (allowed) await SubtitleJobActivity.reauthorize(key);
    if (!current()) throw StateError('The profile changed.');
    job._backgroundAllowed = allowed;
    await _persist(job);
    if (allowed && !await _scheduleBackgroundWork()) {
      if (!current()) throw StateError('The profile changed.');
      job._backgroundAllowed = false;
      await _persist(job);
      notifyListeners();
      throw StateError('OS subtitle scheduling is unavailable on this device.');
    }
    notifyListeners();
  }

  Future<void> pause(SubtitleJob job) => _setState(job, SubtitleJobState.paused);
  Future<void> cancel(SubtitleJob job) => _setState(job, SubtitleJobState.cancelled);
  Future<void> resume(SubtitleJob job, {int Function()? playheadMs, bool Function()? playbackBusy,
    SubtitleJobSource? source}) async {
    var claimed = false;
    try {
      await ready;
      _requireOwnership();
      if (job.terminal || !_jobs.contains(job)) throw StateError('This job is not available to resume.');
      if (job.usesSourceDecoder && (source == null || !source.isCurrent ||
          source.bindingKey != job.sourceBindingKey || source.durationMs != job.durationMs ||
          source.timelineOffsetMs != job.timelineOffsetMs || source.audioOrdinal != job.audioOrdinal)) {
        throw StateError('Reopen the same file, audio stream and clock before resuming this job.');
      }
      if (!job.usesSourceDecoder && source != null) throw StateError('This job uses its retained WAV.');
      // Retire the old generation before releasing a possibly active decoder.
      final epoch = _profileEpoch;
      ++job._generation;
      await _closeSource(job);
      if (epoch != _profileEpoch || _root == null || !_jobs.contains(job) || source != null && !source.isCurrent) {
        throw StateError('The source changed.');
      }
      job._source = source; claimed = true;
      job._playhead = playheadMs;
      job._playbackBusy = playbackBusy;
      await _setState(job, SubtitleJobState.queued);
      if (job.backgroundAllowed && !await _scheduleBackgroundWork()) {
        if (_jobs.contains(job) && epoch == _profileEpoch) {
          job._backgroundAllowed = false;
          job._message = 'OS subtitle scheduling is unavailable on this device. The job remains available in the app.';
          await _persist(job);
        }
      }
      _wake();
    } finally { if (!claimed) await source?.close(); }
  }

  Future<void> _setState(SubtitleJob job, SubtitleJobState state) async {
    _requireOwnership();
    if (!_jobs.contains(job)) throw StateError('This job belongs to another profile.');
    if (job.terminal) return;
    ++job._generation;
    job._state = state;
    job._message = null;
    final saved = _persist(job);
    notifyListeners();
    await Future.wait<void>([saved, if (state != SubtitleJobState.queued) _closeSource(job)]);
  }

  Future<void> delete(SubtitleJob job) async {
    await ready;
    _requireOwnership();
    if (!_jobs.contains(job)) return;
    ++job._generation;
    job._state = SubtitleJobState.cancelled;
    _jobs.remove(job);
    final deletion = _serialize(() async {
      final directory = Directory(job.directory);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    notifyListeners();
    await Future.wait<void>([deletion, _closeSource(job)]);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final ownership = _ownership;
    final next = _writes.then((_) {
      if (ownership == null || !identical(ownership, _ownership)) {
        throw StateError('Subtitle checkpoint ownership changed.');
      }
      return operation();
    });
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> _persist(SubtitleJob job) {
    if (p.dirname(job.directory) != _ownershipDirectory) {
      return Future.error(StateError('This checkpoint belongs to another profile owner.'));
    }
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
    final foreground = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (_headless || foreground == _foreground) return;
    _foreground = foreground;
    _transition(background: !foreground);
  }

  void _wake() {
    _retry?.cancel();
    if (!_headless && _foreground && _root != null && _ownership != null && !_pumping) unawaited(_pump());
  }

  Future<void> _pump() async {
    _pumping = true;
    final finished = _pumpFinished = Completer<void>();
    try {
      while (_foreground) {
        final live = SubtitlePlaybackTranscriptionService.instance;
        if (live.isStarting || live.isRunning || live.hasActiveSession) break;
        SubtitleJob? selected;
        for (final job in List<SubtitleJob>.of(_jobs)) {
          if (job.state != SubtitleJobState.queued) continue;
          if (job.usesSourceDecoder && job._source?.isCurrent != true) {
            await pause(job);
            job._message = 'Reopen the original file and audio stream to resume this source job.';
            continue;
          }
          if (job._resourceRetryAfter?.isAfter(DateTime.now()) == true) continue;
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
      finished.complete();
      if (identical(_pumpFinished, finished)) _pumpFinished = null;
      notifyListeners();
      if (_jobs.any((job) => job.state == SubtitleJobState.queued)) {
        _retry = Timer(const Duration(seconds: 15), _wake);
      }
    }
  }

  Future<void> _step(SubtitleJob job) async {
    final epoch = _profileEpoch;
    final generation = job._generation;
    bool current() => epoch == _profileEpoch && generation == job._generation && _jobs.contains(job) &&
        _ownership != null && (_headless ? _workerMayRun?.call() == true : _foreground);
    try {
      job._state = SubtitleJobState.running;
      job._message = 'Preparing transcription';
      notifyListeners();
      final audio = File(p.join(job.directory, 'audio.wav'));
      if (!job.usesSourceDecoder && !job._audioVerified) {
        if (await audio.length() != job.audioBytes ||
            (await sha256.bind(audio.openRead()).first).toString() != job.audioDigest) {
          throw const FormatException('The staged audio failed its integrity check. Create a new job.');
        }
        job._audioVerified = true;
      }
      if (!current()) return;
      final position = ((job._playhead?.call() ?? job.timelineOffsetMs) - job.timelineOffsetMs).clamp(0, job.durationMs - 1);
      final priority = position ~/ chunkMs;
      int? chunk;
      for (var offset = 0; offset < job.chunkCount; offset++) {
        final candidate = (priority + offset) % job.chunkCount;
        if (!job._completed.contains(candidate)) { chunk = candidate; break; }
      }
      if (chunk == null) {
        job._state = SubtitleJobState.completed;
        await _closeSource(job);
        await _persist(job);
        return;
      }
      final start = chunk * chunkMs;
      final end = math.min(start + chunkMs, job.durationMs);
      final result = await _transcribeWindow(job, audio, start, end, current);
      if (!current()) return;
      if (job.usesSourceDecoder && job._source?.isCurrent != true) throw StateError('The source changed.');
      // A deterministic midpoint ownership rule removes duplicated overlap
      // windows regardless of processing order after seeks or restarts.
      bool owns(int a, int b) => (a + b) ~/ 2 >= start && (a + b) ~/ 2 < end;
      final cues = result.cues.where((cue) => owns(cue.startMs, cue.endMs)).toList();
      final words = result.wordTimings.where((word) => owns(word.startMs, word.endMs)).toList();
      if (cues.any((cue) => cue.startMs < 0 || cue.endMs <= cue.startMs || cue.endMs > job.durationMs || cue.text.length > 4000) ||
          words.any((word) => word.startMs < 0 || word.endMs <= word.startMs || word.endMs > job.durationMs ||
            word.text.length > 4000 || !word.confidence.isFinite || word.confidence < 0 || word.confidence > 1)) {
        throw const FormatException('The recognizer returned invalid checkpoint values.');
      }
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
      if (job._state == SubtitleJobState.completed) await _closeSource(job);
      await _persist(job);
    } on SubtitleInferenceDeferred catch (error) {
      if (!current()) return;
      job._state = SubtitleJobState.queued;
      job._message = error.reason;
      job._resourceRetryAfter = DateTime.now().add(const Duration(seconds: 15));
      try { await _persist(job); } catch (_) {}
    } catch (_) {
      if (!current()) return;
      job._state = job.usesSourceDecoder && job._source?.isCurrent != true
          ? SubtitleJobState.paused : SubtitleJobState.failed;
      // Native errors can include filesystem paths or media URLs. Keep them out
      // of durable metadata and UI; preserve completed windows for retry/export.
      job._message = 'This window could not finish. Completed windows are saved; resume to retry.';
      await _closeSource(job);
      try { await _persist(job); } catch (_) {}
    }
  }

  Future<SubtitleTranscriptionResult> _transcribeWindow(SubtitleJob job, File audio,
      int start, int end, bool Function() current) async {
    final source = job._source;
    bool valid() => current() && (!job.usesSourceDecoder || source?.isCurrent == true);
    final first = math.max(0, start - _overlapMs), last = math.min(job.durationMs, end + _overlapMs);
    void progress(String phase, int received, int total) {
      if (!valid()) return;
      job._message = '$phase · ${job.completedChunks}/${job.chunkCount} windows saved';
      notifyListeners();
    }
    if (!job.usesSourceDecoder) {
      return SubtitleAiService.instance.transcribeWav(audio.path, provider: job.provider,
        languageCode: job.language, priority: SubtitleWorkPriority.background, isCurrent: valid,
        translateToEnglish: job.translateToEnglish, allowEmpty: true, allowModelDownload: !_headless,
        startMs: first, endMs: last, onProgress: progress);
    }
    if (source == null || !valid()) throw StateError('Reopen this job’s original source.');
    final directory = Directory(p.join(job.directory, 'window'));
    try {
      // Admission happens before decoding as well as inference. Audio is a
      // single bounded window, removed even when inference is deferred.
      await SubtitleInferenceScheduler.instance.run(() async {},
        priority: SubtitleWorkPriority.background, isCurrent: valid);
      if (!valid()) throw StateError('The source changed.');
      await directory.create();
      final wav = File(p.join(directory.path, 'audio.wav'));
      progress('Decoding source audio', 0, 0);
      await _decoder.decode(uri: source.source.uri, startMs: first, endMs: last,
        audioOrdinal: source.audioOrdinal, destination: wav, isCurrent: valid);
      if (!valid()) throw StateError('The source changed.');
      if (await wav.length() > 2100000 ||
          await SubtitleAiService.instance.readWavDurationMs(wav.path) != last - first) {
        throw const FormatException('The decoder did not return the requested source window.');
      }
      final result = await SubtitleAiService.instance.transcribeWav(wav.path,
        provider: job.provider, languageCode: job.language, priority: SubtitleWorkPriority.background,
        isCurrent: valid, translateToEnglish: job.translateToEnglish, allowEmpty: true, onProgress: progress);
      if (!valid()) throw StateError('The source changed.');
      // Checkpoints stay on the opened-file clock. Offset into item time once
      // when presenting the reviewed result, never in the stored windows.
      return SubtitleTranscriptionResult(
        cues: [for (final cue in result.cues) SubtitleCue(index: cue.index,
          startMs: cue.startMs + first, endMs: cue.endMs + first, text: cue.text)],
        wordTimings: [for (final word in result.wordTimings) SubtitleWordTiming(
          startMs: word.startMs + first, endMs: word.endMs + first, text: word.text,
          confidence: word.confidence, unit: word.unit)],
        durationMs: job.durationMs, requestedProvider: result.requestedProvider,
        runtimeProvider: '${_decoder.backend}; ${result.runtimeProvider}',
        fellBackToCpu: result.fellBackToCpu, placementEvidence: result.placementEvidence,
        detectedLanguage: result.detectedLanguage, translatedToEnglish: result.translatedToEnglish);
    } finally {
      await _decoder.cancel();
      try { if (await directory.exists()) await directory.delete(recursive: true); } catch (_) {}
    }
  }

  static Future<bool> runBackgroundProfile(String key, DateTime deadline, bool Function() mayRun) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key) || !mayRun()) return false;
    final service = SubtitleJobService._(headless: true);
    service._profileKey = key;
    service._workerMayRun = () => mayRun() && DateTime.now().isBefore(deadline);
    try {
      await service._load(key, 0);
      if (service._ownership == null || service.loadError != null) return false;
      final queue = service._jobs.where((job) => job.backgroundAllowed && job.backgroundSupported &&
          !job.usesSourceDecoder && !job.idleOnly && job.state == SubtitleJobState.queued).toList();
      while (queue.isNotEmpty && service._workerMayRun!()) {
        final job = queue.removeAt(0);
        // A headless engine cannot establish that every playback owner is idle.
        // Unknown is never treated as idle, including background audio playback.
        if (job.chargingOnly && await PowerSourceService.isConnected().timeout(
            const Duration(seconds: 5), onTimeout: () => null) != true) continue;
        if (!service._workerMayRun!()) break;
        if (!await SubtitleAiService.instance.isProviderModelInstalled(job.provider)) {
          job._state = SubtitleJobState.paused;
          job._message = 'Install the selected speech model in the foreground first.';
          await service._persist(job);
          continue;
        }
        final before = job.completedChunks;
        await service._step(job);
        if (job.state == SubtitleJobState.running) {
          // A foreground request or deadline discarded the unfinished window.
          job._state = SubtitleJobState.queued;
          await service._persist(job);
        }
        if (job.state == SubtitleJobState.queued && job.completedChunks > before) queue.add(job);
      }
      return !service._jobs.any((job) => job.backgroundAllowed && job.state == SubtitleJobState.queued);
    } finally {
      ++service._profileEpoch;
      await service._writes;
      await service._ownership?.release();
      service._ownership = null;
      service.dispose();
    }
  }

  Future<SubtitleTranscriptionResult> readResult(SubtitleJob job) async {
    await ready;
    _requireOwnership();
    return _serialize(() async {
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
    });
  }
}
