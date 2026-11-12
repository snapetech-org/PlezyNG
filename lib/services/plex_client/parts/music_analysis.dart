part of '../../plex_client.dart';

enum PlexMusicAnalysisStatus { ready, missing, requested, forbidden, unsupported, unavailable }

extension PlexMusicAnalysis on PlexClient {
  static final _numericId = RegExp(r'^[0-9]{1,16}$');
  static final _version = RegExp(r'^(\d{1,4})\.(\d{1,4})\.(\d{1,4})(?:[.-]|$)');

  bool _trackAnalysisMatches(MediaItem item) =>
      item.backend == MediaBackend.plex &&
      item.kind == MediaKind.track &&
      item.serverId == serverId.value &&
      _numericId.hasMatch(item.id);

  Future<PlexMusicAnalysisStatus> checkMusicAnalysis(MediaItem item, {required bool Function() current}) async {
    final authentication = authenticationSessionId;
    bool authorized() => current() && !isOfflineMode && identical(authentication, authenticationSessionId);
    if (!authorized() || !_trackAnalysisMatches(item)) return PlexMusicAnalysisStatus.unavailable;
    final part = item.mediaVersions?.firstOrNull?.parts.firstOrNull;
    final streams = part?.streams.where((stream) => stream.kind == MediaStreamKind.audio);
    final stream = streams?.where((stream) => stream.selected).firstOrNull ?? streams?.firstOrNull;
    final id = int.tryParse(stream?.id ?? '');
    if (id == null || id <= 0) return PlexMusicAnalysisStatus.unavailable;
    try {
      final profile = await _readAudioLoudnessProfile(id);
      if (!authorized()) return PlexMusicAnalysisStatus.unavailable;
      return profile == null ? PlexMusicAnalysisStatus.missing : PlexMusicAnalysisStatus.ready;
    } on MediaServerHttpException catch (error) {
      if (!authorized()) return PlexMusicAnalysisStatus.unavailable;
      return switch (error.statusCode) {
        401 || 403 => PlexMusicAnalysisStatus.forbidden,
        404 => PlexMusicAnalysisStatus.missing,
        _ => PlexMusicAnalysisStatus.unavailable,
      };
    } catch (_) {
      return PlexMusicAnalysisStatus.unavailable;
    }
  }

  Future<PlexMusicAnalysisStatus> requestMusicAnalysis(MediaItem item, {required bool Function() current}) async {
    final owner = _musicHistoryOwner;
    bool authorized() => current() && !isOfflineMode && owner == _musicHistoryOwner && hasVerifiedMusicServerOwner;
    if (!authorized()) return PlexMusicAnalysisStatus.forbidden;
    final library = item.libraryId;
    if (!_trackAnalysisMatches(item) || library == null || !_numericId.hasMatch(library)) {
      return PlexMusicAnalysisStatus.unavailable;
    }
    try {
      final root = await _getWithFailover('/', timeout: const Duration(seconds: 8));
      if (!authorized()) return PlexMusicAnalysisStatus.forbidden;
      final version = _getMediaContainer(root)?['version'];
      final match = version is String ? _version.firstMatch(version) : null;
      if (match == null) return PlexMusicAnalysisStatus.unavailable;
      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);
      final patch = int.parse(match.group(3)!);
      if (major < 1 || major == 1 && (minor < 43 || minor == 43 && patch < 4)) {
        return PlexMusicAnalysisStatus.unsupported;
      }
      final path = '/library/metadata/${item.id}';
      final response = await _getWithFailover(path, timeout: const Duration(seconds: 8));
      if (!authorized()) return PlexMusicAnalysisStatus.forbidden;
      final confirmed = _extractMetadataList(response).map(PlexMappers.mediaItem).singleOrNull;
      if (confirmed == null ||
          !_trackAnalysisMatches(confirmed) ||
          confirmed.id != item.id ||
          confirmed.libraryId != library) {
        return PlexMusicAnalysisStatus.unavailable;
      }
      final analysis = await _http.put(
        '$path/analyzeLoudness',
        queryParameters: const {'force': 0, 'manual': 1},
        timeout: const Duration(seconds: 8),
      );
      if (!authorized()) return PlexMusicAnalysisStatus.forbidden;
      throwIfHttpError(analysis);
      return PlexMusicAnalysisStatus.requested;
    } on MediaServerHttpException catch (error) {
      if (!authorized() || error.statusCode == 401 || error.statusCode == 403) return PlexMusicAnalysisStatus.forbidden;
      return PlexMusicAnalysisStatus.unavailable;
    } catch (_) {
      return PlexMusicAnalysisStatus.unavailable;
    }
  }
}

/// Official named Butler tasks; never accepts an arbitrary task or all-task path.
enum PlexMusicServerTask {
  sonic('MusicAnalysis'),
  loudness('LoudnessAnalysis');

  const PlexMusicServerTask(this.serverName);
  final String serverName;
}

enum PlexMusicServerTaskRequest { started, alreadyRunning, stopped }

class PlexMusicServerAnalysisSnapshot {
  PlexMusicServerAnalysisSnapshot({required Set<PlexMusicServerTask> tasks, required List<PlexActivity> activities})
    : tasks = Set.unmodifiable(tasks),
      activities = List.unmodifiable(activities);

  final Set<PlexMusicServerTask> tasks;

  /// Server activities, not a fabricated Sonic-only progress aggregate.
  /// A negative progress value is indeterminate.
  final List<PlexActivity> activities;
}

extension PlexMusicServerAnalysis on PlexClient {
  static const _musicTaskTimeout = Duration(seconds: 8);

  void _requireMusicTaskOwner(bool Function() current, [AbortController? abort]) {
    abort?.throwIfAborted();
    if (!current() || isOfflineMode || !hasVerifiedMusicServerOwner) {
      throw StateError('Music server owner unavailable');
    }
  }

  Future<Set<PlexMusicServerTask>> _readMusicButlerTasks({
    required bool Function() current,
    AbortController? abort,
  }) async {
    _requireMusicTaskOwner(current, abort);
    final response = await _getWithFailover('/butler', timeout: _musicTaskTimeout, abort: abort);
    _requireMusicTaskOwner(current, abort);
    throwIfHttpError(response);
    final body = response.data;
    final root = body is Map ? body['ButlerTasks'] : null;
    final rows = root is Map ? root['ButlerTask'] : null;
    if (response.statusCode != 200 || rows is! List || rows.length > 256) {
      throw const FormatException('Invalid music task advertisement');
    }
    final tasks = <PlexMusicServerTask>{};
    for (final row in rows) {
      final name = row is Map ? row['name'] : null;
      final task = PlexMusicServerTask.values.where((task) => task.serverName == name).singleOrNull;
      if (task != null && !tasks.add(task)) throw const FormatException('Duplicate music task advertisement');
    }
    return tasks;
  }

  Future<PlexMusicServerAnalysisSnapshot> readMusicServerAnalysis({
    required bool Function() current,
    AbortController? abort,
  }) async {
    final owner = _musicHistoryOwner, route = config.baseUrl;
    bool authorized() => current() && owner != null && owner == _musicHistoryOwner && route == config.baseUrl;
    final tasks = await _readMusicButlerTasks(current: authorized, abort: abort);
    _requireMusicTaskOwner(authorized, abort);
    final response = await _getWithFailover('/activities', timeout: _musicTaskTimeout, abort: abort);
    _requireMusicTaskOwner(authorized, abort);
    throwIfHttpError(response);
    final container = _getMediaContainer(response);
    final rows = container?['Activity'] ?? const [];
    if (response.statusCode != 200 || container == null || rows is! List || rows.length > 512) {
      throw const FormatException('Invalid server activities');
    }
    final activities = <PlexActivity>[];
    final seen = <String>{};
    for (final row in rows) {
      if (row is! Map<String, dynamic>) throw const FormatException('Invalid server activity');
      for (final field in ['uuid', 'title', 'subtitle', 'type']) {
        final value = row[field];
        if (value != null && (value is! String || value.length > 1024)) {
          throw const FormatException('Invalid server activity text');
        }
      }
      final rawProgress = row['progress'];
      final num? progress = rawProgress == null
          ? -1
          : rawProgress is num
          ? rawProgress
          : rawProgress is String
          ? num.tryParse(rawProgress)
          : null;
      if (progress == null || !progress.isFinite || (progress != -1 && progress < 0) || progress > 100) {
        throw const FormatException('Invalid server activity progress');
      }
      final activity = PlexActivity.fromJson({...row, 'progress': progress.toInt()});
      if (activity.uuid.isEmpty || activity.uuid.length > 128 || !seen.add(activity.uuid)) {
        throw const FormatException('Invalid server activity identity');
      }
      activities.add(activity);
    }
    return PlexMusicServerAnalysisSnapshot(tasks: tasks, activities: activities);
  }

  Future<PlexMusicServerTaskRequest> changeMusicServerAnalysis(
    PlexMusicServerTask task, {
    required bool start,
    required bool Function() current,
  }) {
    final owner = _musicHistoryOwner, route = config.baseUrl;
    bool authorized() => current() && owner != null && owner == _musicHistoryOwner && route == config.baseUrl;
    return _musicServerAnalysisChanges.run(() async {
      final tasks = await _readMusicButlerTasks(current: authorized);
      _requireMusicTaskOwner(authorized);
      if (!tasks.contains(task)) throw UnsupportedError('Music task not advertised');
      // enabled is a scheduling preference, not authorization for a named
      // manual request. No server/library preferences are modified here.
      final path = '/butler/${task.serverName}';
      final response = start
          ? await _http.post(path, timeout: _musicTaskTimeout)
          : await _http.delete(path, timeout: _musicTaskTimeout);
      _requireMusicTaskOwner(authorized);
      throwIfHttpError(response);
      if (response.statusCode == 200) {
        return start ? PlexMusicServerTaskRequest.started : PlexMusicServerTaskRequest.stopped;
      }
      if (start && response.statusCode == 202) return PlexMusicServerTaskRequest.alreadyRunning;
      throw const FormatException('Unconfirmed music task request');
    });
  }
}
