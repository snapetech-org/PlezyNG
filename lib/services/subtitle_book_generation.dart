import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../profiles/active_profile_provider.dart';
import 'subtitle_ai_service.dart';
import 'subtitle_book_timeline.dart';
import 'subtitle_job_service.dart';
import 'subtitle_job_source.dart';
import 'subtitle_revision_service.dart';

/// A book batch feeds one ordinary checkpointed job at a time. Completed files
/// are retained as unaccepted results outside reviewed revision history. It
/// never seeks playback, selects captions, or guesses that files share a dub.
final class SubtitleBookGeneration extends ChangeNotifier with WidgetsBindingObserver {
  SubtitleBookGeneration._() { WidgetsBinding.instance.addObserver(this); }
  static final instance = SubtitleBookGeneration._();
  static const _maximumBytes = 64 * 1024 * 1024;
  SubtitleBookTimeline? _timeline;
  ActiveProfileProvider? _profiles;
  String? _profile, _key, _directory, _jobId;
  final Map<int, ({String digest, int bytes, bool empty})> _results = {};
  List<int> _ordinals = [];
  SubtitleInferenceProvider _provider = SubtitleInferenceProvider.cpu;
  String? _language;
  bool _charging = false, _idle = false, _running = false, _busy = false, _foreground = true;
  int _generation = 0;
  bool _resumeFile = false;
  Completer<void>? _operationDone;
  Future<void> _writes = Future.value();
  Timer? _timer;
  String? message;

  bool get running => _running;
  bool get busy => _busy;
  bool get exists => _directory != null && _ordinals.isNotEmpty;
  bool get hasStoredBatch => _directory != null;
  bool get complete => exists && _results.length == _ordinals.length;
  int get completedFiles => _results.length;
  Set<int> get completedIndices => Set.unmodifiable(_results.keys);
  SubtitleJob? get activeJob {
    for (final job in SubtitleJobService.instance.jobs) { if (job.id == _jobId) return job; }
    return null;
  }

  static String keyFor(SubtitleBookTimeline timeline) => sha256.convert(utf8.encode(jsonEncode([
    'book-source-batch-v1', for (final part in timeline.parts)
      [part.identity.storageKey, part.fileIndex, part.startMs, part.durationMs],
  ]))).toString();

  bool _current(int generation) {
    try { return generation == _generation && _profiles?.activeId == _profile && _timeline?.isCurrent() == true; }
    catch (_) { return false; }
  }

  Future<void> open(SubtitleBookTimeline timeline, ActiveProfileProvider profiles) async {
    final key = keyFor(timeline);
    if (_key == key && identical(_profiles, profiles) && _current(_generation)) return;
    await pause();
    await _operationDone?.future;
    final generation = ++_generation;
    _profiles?.removeListener(_ownerChanged); _timeline?.changes.removeListener(_ownerChanged);
    _profiles = profiles; _profile = profiles.activeId; _timeline = timeline; _key = key;
    profiles.addListener(_ownerChanged); timeline.changes.addListener(_ownerChanged);
    _results.clear(); _ordinals = []; _directory = null; _jobId = null; message = null;
    final jobs = SubtitleJobService.instance..bindProfile(profiles);
    await jobs.ready;
    if (!_current(generation) || _profile == null) throw StateError('The book or profile changed.');
    final root = await _root();
    final directory = Directory(p.join(root.path, key));
    if (!await directory.exists()) { notifyListeners(); return; }
    try {
      Map<String, dynamic>? data;
      for (final suffix in ['', '.bak']) {
        final file = File(p.join(directory.path, 'batch.json$suffix'));
        if (!await file.exists() || await file.length() > 65536) continue;
        try { data = jsonDecode(await file.readAsString()) as Map<String, dynamic>; break; } catch (_) {}
      }
      if (data == null || data['schema'] != 1 || data['key'] != key) throw const FormatException('Invalid batch record');
      final ordinals = (data['ordinals'] as List).cast<int>();
      if (ordinals.length != timeline.parts.length || ordinals.any((value) => value < 0 || value > 63)) {
        throw const FormatException('Invalid batch audio selection');
      }
      final results = <int, ({String digest, int bytes, bool empty})>{};
      var bytes = 0;
      for (final raw in data['results'] as List) {
        final value = raw as Map<String, dynamic>, index = value['index'] as int;
        final digest = value['digest'] as String, length = value['bytes'] as int;
        if (index < 0 || index >= ordinals.length || results.containsKey(index) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) || length < 2 || length > SubtitleRevisionService.maximumRevisionBytes ||
            (bytes += length) > _maximumBytes || value['empty'] is! bool) throw const FormatException('Invalid batch result');
        results[index] = (digest: digest, bytes: length, empty: value['empty'] as bool);
      }
      final jobId = data['jobId'] as String?;
      if (jobId != null && !RegExp(r'^\d+_[0-9a-f]{16}$').hasMatch(jobId)) throw const FormatException('Invalid batch job');
      final language = data['language'] as String?;
      if (language != null && !RegExp(r'^[a-z]{2,3}$').hasMatch(language)) throw const FormatException('Invalid language');
      final provider = SubtitleInferenceProvider.values.byName(data['provider'] as String);
      if (!_current(generation)) return;
      _directory = directory.path; _ordinals = ordinals; _results.addAll(results); _jobId = jobId;
      _provider = provider;
      _language = language; _charging = data['charging'] == true; _idle = data['idle'] == true;
      message = complete ? 'All selected files have saved results. Review before use.' : 'Saved batch paused. Resume explicitly with this book open.';
    } catch (_) {
      if (!_current(generation)) return;
      _results.clear(); _ordinals = []; _jobId = null;
      _directory = directory.path;
      message = 'This batch record could not be opened. Delete this batch before creating another; reviewed history is separate.';
    }
    notifyListeners();
  }

  Future<Directory> _root() async {
    if (_profile == null) throw StateError('Choose a profile.');
    final key = sha256.convert(utf8.encode(_profile!)).toString();
    return Directory(p.join((await getApplicationSupportDirectory()).path, 'subtitle_book_jobs', key)).create(recursive: true);
  }

  Future<void> create({required List<int> ordinals, required SubtitleInferenceProvider provider,
    String? language, required bool chargingOnly, required bool idleOnly}) async {
    if (_busy || _directory != null || !_current(_generation)) throw StateError('Reopen this book or delete its existing batch first.');
    final timeline = _timeline!, generation = _generation;
    if (timeline.openAnalysisSource == null || ordinals.length != timeline.parts.length ||
        ordinals.any((value) => value < 0 || value > 63) || timeline.parts.any((part) => part.durationMs > 8 * 3600000) ||
        language != null && !RegExp(r'^[a-z]{2,3}$').hasMatch(language)) {
      throw const FormatException('Each source file requires a known duration up to eight hours and an audio ordinal.');
    }
    _busy = true;
    final done = _operationDone = Completer<void>();
    try {
      final root = await _root();
      var count = 0;
      await for (final entity in root.list(followLinks: false)) { if (entity is Directory) count++; }
      if (count >= 4) throw StateError('Four book batches are already retained in this profile. Delete an earlier batch first.');
      if (!_current(generation)) throw StateError('The book changed.');
      final directory = await Directory(p.join(root.path, _key!)).create();
      if (!_current(generation)) throw StateError('The book changed.');
      _directory = directory.path; _ordinals = List.of(ordinals); _provider = provider;
      _language = language; _charging = chargingOnly; _idle = idleOnly;
      await _persist();
    } finally { _busy = false; done.complete(); _operationDone = null; notifyListeners(); }
    await resume();
  }

  Future<void> resume() async {
    if (_busy || !exists || complete || !_current(_generation) || !_foreground) return;
    _running = true; _resumeFile = true; message = 'Preparing the next incomplete file.';
    _timer?.cancel(); _timer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_tick()));
    notifyListeners(); unawaited(_tick());
  }

  Future<void> pause() async {
    _running = false; _timer?.cancel(); _timer = null;
    final job = activeJob;
    if (job != null && !job.terminal) {
      try { await SubtitleJobService.instance.pause(job); } catch (_) {}
    }
    notifyListeners();
  }

  void _ownerChanged() {
    if (!_current(_generation)) {
      message = 'Book, order, edition or profile changed. Reopen the original book to resume.';
      unawaited(pause());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) { message = 'Paused outside the foreground. Resume explicitly.'; unawaited(pause()); }
  }

  Future<void> _persist() {
    final directory = _directory;
    if (directory == null) return Future.value();
    final text = jsonEncode({'schema': 1, 'key': _key, 'ordinals': _ordinals,
      'provider': _provider.name, 'language': _language, 'charging': _charging, 'idle': _idle, 'jobId': _jobId,
      'results': [for (final entry in _results.entries) {'index': entry.key,
        'digest': entry.value.digest, 'bytes': entry.value.bytes, 'empty': entry.value.empty}]});
    final next = _writes.then((_) async {
      final file = File(p.join(directory, 'batch.json')), backup = File(p.join(directory, 'batch.json.bak'));
      final temporary = File(p.join(directory, 'batch.json.tmp'));
      await temporary.writeAsString(text, flush: true);
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      await temporary.rename(file.path);
    });
    _writes = next.catchError((Object _) {}); return next;
  }

  Future<void> _tick() async {
    if (_busy || !_running) return;
    final generation = _generation, timeline = _timeline!, jobs = SubtitleJobService.instance;
    bool current() => _running && _foreground && _current(generation);
    if (!current()) { await pause(); return; }
    _busy = true;
    final done = _operationDone = Completer<void>();
    try {
      int? index;
      for (var i = 0; i < timeline.parts.length; i++) { if (!_results.containsKey(i)) { index = i; break; } }
      if (index == null) { message = 'All files have saved results. Review before use.'; await pause(); return; }
      final part = timeline.parts[index];
      var job = activeJob;
      if (_jobId != null && job == null) {
        // A deleted job cannot be silently replaced, losing the explanation of
        // its partial result. A second explicit resume authorizes a fresh job.
        _jobId = null; await _persist();
        throw StateError('The active file job was removed. Resume again to create a new job for that file.');
      }
      Future<SubtitleJobSource> openSource() => SubtitleJobSource.open(
        openSource: () => timeline.openAnalysisSource!(part), audioOrdinal: _ordinals[index],
        audioDescriptor: 'Explicit book audio ordinal ${_ordinals[index]}',
        fallbackDurationMs: part.durationMs, isCurrent: current);
      if (job == null) {
        final source = await openSource();
        job = await jobs.enqueueSource(source: source, identityKey: part.identity.storageKey,
          title: '${timeline.title} · ${part.title}', provider: _provider, language: _language,
          chargingOnly: _charging, idleOnly: _idle,
          playbackBusy: () => !current() || timeline.playbackBusy?.call() != false);
        _resumeFile = false;
        _jobId = job.id; await _persist();
        if (!current()) { await jobs.pause(job); return; }
      } else if (job.identityKey != part.identity.storageKey || !job.usesSourceDecoder ||
          job.audioOrdinal != _ordinals[index] || job.durationMs != part.durationMs) {
        throw StateError('This saved file job does not match the book.');
      } else if (job.state == SubtitleJobState.paused || job.state == SubtitleJobState.failed) {
        if (!_resumeFile) throw StateError('The file job paused or failed. Resume explicitly to retry its incomplete window.');
        _resumeFile = false;
        await jobs.resume(job, source: await openSource(), playbackBusy: () => !current() || timeline.playbackBusy?.call() != false);
      } else if (job.state == SubtitleJobState.cancelled) {
        throw StateError('The file job was cancelled. Delete it in Transcription jobs, then resume this batch to retry.');
      } else if (job.state == SubtitleJobState.queued || job.state == SubtitleJobState.running) {
        _resumeFile = false;
      } else if (job.state == SubtitleJobState.completed) {
        final result = await jobs.readResult(job);
        if (!current()) return;
        final revision = SubtitleRevision(id: '0_0', createdAt: DateTime.now().toUtc(),
          operation: 'Unreviewed book transcription', languageCode: result.detectedLanguage,
          cues: result.cues, wordTimings: result.wordTimings);
        final bytes = utf8.encode(jsonEncode(result.cues.isEmpty ? {'empty': true} : revision.toJson()));
        if (bytes.length > SubtitleRevisionService.maximumRevisionBytes ||
            _results.values.fold<int>(0, (sum, value) => sum + value.bytes) + bytes.length > _maximumBytes) {
          throw StateError('This batch reached its 64 MiB result limit. The completed file job is retained for review.');
        }
        final file = File(p.join(_directory!, 'result_$index.json'));
        await File('${file.path}.tmp').writeAsBytes(bytes, flush: true);
        if (!current()) return;
        // A crash can leave an uncommitted result. Its completed job remains
        // authoritative until the manifest commits this index.
        if (await file.exists()) await file.delete();
        await File('${file.path}.tmp').rename(file.path);
        if (!current()) return;
        _results[index] = (digest: sha256.convert(bytes).toString(), bytes: bytes.length, empty: result.cues.isEmpty);
        // Durable result and cursor precede deletion of its window checkpoints.
        _jobId = null; await _persist();
        await jobs.delete(job);
      }
      message = '${_results.length}/${timeline.parts.length} files saved · ${part.title}';
    } catch (_) {
      await pause();
      message = 'The batch paused. Completed files and windows are retained; check Transcription jobs, reopen the source and resume. '
          'Cancelled jobs must be deleted before retry; a full queue or result store must be cleared first.';
    } finally { _busy = false; done.complete(); _operationDone = null; notifyListeners(); }
  }

  Future<SubtitleRevision?> result(int index) async {
    final record = _results[index], generation = _generation;
    if (record == null || !_current(generation)) throw StateError('No result for the current book file.');
    final file = File(p.join(_directory!, 'result_$index.json'));
    if (await file.length() != record.bytes) throw const FormatException('Result size changed');
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != record.digest || !_current(generation)) throw const FormatException('Result identity changed');
    return record.empty ? null : SubtitleRevision.fromJson(jsonDecode(utf8.decode(bytes)));
  }

  Future<void> delete() async {
    if (_busy) throw StateError('Wait for the current batch operation to finish.');
    _busy = true;
    final done = _operationDone = Completer<void>();
    try {
      await pause();
      final job = activeJob;
      if (job != null) await SubtitleJobService.instance.delete(job);
      await _writes;
      final directory = _directory;
      if (directory != null && await Directory(directory).exists()) await Directory(directory).delete(recursive: true);
      _results.clear(); _ordinals = []; _jobId = null; _directory = null;
      message = 'Batch results deleted. Reviewed revision history is unchanged.';
    } finally { _busy = false; done.complete(); _operationDone = null; notifyListeners(); }
  }
}
