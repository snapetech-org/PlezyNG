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
