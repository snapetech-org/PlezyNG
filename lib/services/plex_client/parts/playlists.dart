part of '../../plex_client.dart';

mixin _PlexPlaylistMethods on _PlexClientInternals implements PlaylistMetadataClient, PlaylistArtworkClient {
  static const int _defaultPlaylistContainerSize = 100;
  @override
  Object get authenticationSessionId;

  /// Playlist fields use the playlist endpoint, not a library-section edit.
  /// Wire shape follows Python PlexAPI Playlist._edit / EditFieldMixin.
  /// https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/playlist.html
  @override
  Future<MediaPlaylist> updatePlaylistMetadata({
    required MediaPlaylist playlist,
    String? title,
    String? summary,
    bool Function()? isCurrent,
  }) async {
    if (playlist.backend != MediaBackend.plex ||
        playlist.serverId != serverId ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(playlist.id) ||
        (title == null && summary == null) ||
        (title != null && (title.trim().isEmpty || title.length > 255 || RegExp(r'[\x00-\x1f]').hasMatch(title))) ||
        (summary != null && (summary.length > 10000 || RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(summary)))) {
      throw ArgumentError('Invalid playlist metadata edit');
    }
    final authentication = authenticationSessionId;
    bool current() =>
        !isOfflineMode && identical(authentication, authenticationSessionId) && (isCurrent?.call() ?? true);
    void requireCurrent() {
      if (!current()) throw StateError('Playlist source changed');
    }

    requireCurrent();
    final fresh = await fetchPlaylistMetadata(playlist.id);
    requireCurrent();
    if (fresh == null ||
        fresh.id != playlist.id ||
        fresh.serverId != playlist.serverId ||
        fresh.backend != playlist.backend ||
        fresh.smart != playlist.smart ||
        fresh.playlistType != playlist.playlistType) {
      throw StateError('Playlist is no longer available');
    }
    // Avoid overwriting edits observed since the form opened. PMS has no
    // atomic compare-and-swap here; only changed fields are submitted.
    if ((title != null && fresh.title != playlist.title) ||
        (summary != null && (fresh.summary ?? '') != (playlist.summary ?? ''))) {
      throw StateError('Playlist metadata changed');
    }
    final response = await _http.put(
      '/playlists/${playlist.id}',
      queryParameters: {
        if (title != null) ...{'title.value': title.trim(), 'title.locked': '1'},
        if (summary != null) ...{'summary.value': summary, 'summary.locked': '1'},
      },
    );
    throwIfHttpError(response);
    requireCurrent();
    final updated = await fetchPlaylistMetadata(playlist.id);
    requireCurrent();
    if (updated == null ||
        updated.id != playlist.id ||
        updated.serverId != playlist.serverId ||
        updated.backend != playlist.backend ||
        updated.smart != playlist.smart ||
        updated.playlistType != playlist.playlistType ||
        (title != null && updated.title != title.trim()) ||
        (summary != null && (updated.summary ?? '') != summary)) {
      throw StateError('Playlist update could not be reloaded');
    }
    return updated;
  }

  // Contracts: Python PlexAPI PosterMixin and BaseResource.select.
  // https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/mixins/resources.html
  // https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/media.html
  void Function() _playlistArtworkLease(MediaPlaylist playlist, bool Function()? isCurrent) {
    if (playlist.backend != MediaBackend.plex ||
        playlist.serverId != serverId ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(playlist.id)) {
      throw ArgumentError('Invalid playlist artwork source');
    }
    final authentication = authenticationSessionId;
    void requireCurrent() {
      if (isOfflineMode || !identical(authentication, authenticationSessionId) || !(isCurrent?.call() ?? true)) {
        throw StateError('Playlist artwork source changed');
      }
    }

    requireCurrent();
    return requireCurrent;
  }

  Future<MediaPlaylist> _reloadArtworkPlaylist(MediaPlaylist playlist, void Function() requireCurrent) async {
    requireCurrent();
    final fresh = await fetchPlaylistMetadata(playlist.id);
    requireCurrent();
    if (fresh == null ||
        fresh.id != playlist.id ||
        fresh.serverId != playlist.serverId ||
        fresh.backend != playlist.backend ||
        fresh.playlistType != playlist.playlistType ||
        fresh.smart != playlist.smart) {
      throw StateError('Playlist is no longer available');
    }
    return fresh;
  }

  Future<List<PlaylistArtworkOption>> _playlistPosters(String id, void Function() requireCurrent) async {
    requireCurrent();
    final response = await _getWithFailover('/library/metadata/$id/posters');
    throwIfHttpError(response);
    requireCurrent();
    final container = _getMediaContainer(response);
    if (container == null) throw const FormatException('Missing playlist artwork container');
    final rows = container['Metadata'] ?? container['Photo'] ?? const [];
    if (rows is! List || rows.length > 512) throw const FormatException('Invalid playlist artwork options');
    final keys = <String>{};
    final options = <PlaylistArtworkOption>[];
    bool valid(String value) => value.isNotEmpty && value.length <= 4096 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
    for (final row in rows) {
      if (row is! Map) throw const FormatException('Invalid playlist artwork option');
      final key = row['ratingKey'];
      final thumb = row['thumb'] ?? row['key'];
      if (key is! String || thumb is! String || !valid(key) || !valid(thumb) || !keys.add(key)) {
        throw const FormatException('Invalid playlist artwork identity');
      }
      final selected = row['selected'];
      options.add(
        PlaylistArtworkOption(
          key: key,
          thumbnailPath: thumb,
          selected: selected == true || selected == 1 || selected == '1' || selected == 'true',
        ),
      );
    }
    return List.unmodifiable(options);
  }

  @override
  Future<List<PlaylistArtworkOption>> fetchPlaylistArtwork(MediaPlaylist playlist, {bool Function()? isCurrent}) async {
    final requireCurrent = _playlistArtworkLease(playlist, isCurrent);
    await _reloadArtworkPlaylist(playlist, requireCurrent);
    return _playlistPosters(playlist.id, requireCurrent);
  }

  @override
  Future<MediaPlaylist> updatePlaylistArtwork({
    required MediaPlaylist playlist,
    String? artworkKey,
    List<int>? bytes,
    bool reset = false,
    bool Function()? isCurrent,
  }) async {
    if ((artworkKey != null ? 1 : 0) + (bytes != null ? 1 : 0) + (reset ? 1 : 0) != 1 ||
        (artworkKey != null &&
            (artworkKey.isEmpty || artworkKey.length > 4096 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(artworkKey))) ||
        (bytes != null &&
            (bytes.isEmpty ||
                bytes.length > PlaylistArtworkClient.maxUploadBytes ||
                bytes.any((value) => value < 0 || value > 255)))) {
      throw ArgumentError('Invalid playlist artwork update');
    }
    final requireCurrent = _playlistArtworkLease(playlist, isCurrent);
    // The caller may retain a mutable buffer across the preflight await.
    final uploadBytes = bytes == null ? null : Uint8List.fromList(bytes);
    await _reloadArtworkPlaylist(playlist, requireCurrent);
    final root = '/library/metadata/${playlist.id}';
    late MediaServerResponse response;
    if (artworkKey != null) {
      final options = await _playlistPosters(playlist.id, requireCurrent);
      if (!options.any((option) => option.key == artworkKey)) throw StateError('Playlist artwork option changed');
      requireCurrent();
      response = await _http.put('$root/poster', queryParameters: {'url': artworkKey});
    } else if (bytes != null) {
      requireCurrent();
      response = await _http.post(
        '$root/posters',
        body: uploadBytes,
        headers: {'Content-Type': 'application/octet-stream'},
      );
    } else {
      requireCurrent();
      response = await _http.delete('$root/thumb');
    }
    throwIfHttpError(response);
    requireCurrent();
    if (artworkKey != null) {
      final selected = await _playlistPosters(playlist.id, requireCurrent);
      if (!selected.any((option) => option.key == artworkKey && option.selected)) {
        throw StateError('Playlist artwork selection was not accepted');
      }
    }
    // PMS can expose playlist posters through "composite", not "thumb".
    // An acknowledged upload/reset plus fresh identity is not byte equivalence.
    return _reloadArtworkPlaylist(playlist, requireCurrent);
  }

  Future<LibraryPage<MediaItem>> previewSmartMusicPlaylist(MusicSmartPlaylistRules rules) async {
    final result = await _fetchPaginatedList(
      rules.searchPath,
      start: 0,
      size: 50,
      librarySectionID: int.parse(rules.libraryId),
    );
    return LibraryPage(items: result.items.map(PlexMappers.mediaItem).toList(), totalCount: result.totalSize);
  }

  Future<MediaPlaylist?> saveSmartMusicPlaylist({
    required String title,
    required MusicSmartPlaylistRules rules,
    MediaPlaylist? playlist,
    bool Function()? isCurrent,
  }) async {
    if (title.trim().isEmpty ||
        title.length > 255 ||
        (playlist != null && (!playlist.smart || playlist.serverId != serverId || playlist.playlistType != 'audio'))) {
      throw ArgumentError('Invalid smart playlist');
    }
    final authentication = authenticationSessionId;
    bool current() => identical(authentication, authenticationSessionId) && (isCurrent?.call() ?? true);
    if (!current()) throw StateError('Smart playlist source changed');
    final root = Uri.parse(await buildMetadataUri(''));
    if (!current()) throw StateError('Smart playlist source changed');
    final uri = root
        .replace(path: '/com.plexapp.plugins.library/library/sections/${rules.libraryId}/all', query: rules.query)
        .toString();
    final response = playlist == null
        ? await _http.post(
            '/playlists',
            queryParameters: {'type': 'audio', 'title': title.trim(), 'smart': '1', 'uri': uri},
          )
        : await _http.put('/playlists/${playlist.id}/items', queryParameters: {'uri': uri});
    throwIfHttpError(response);
    if (!current()) throw StateError('Smart playlist source changed');
    if (playlist != null) {
      final updated = await fetchPlaylistMetadata(playlist.id);
      if (!current()) throw StateError('Smart playlist source changed');
      return updated;
    }
    final metadata = _getMediaContainer(response)?['Metadata'];
    if (metadata is! List || metadata.isEmpty) return null;
    return PlexMappers.mediaPlaylist(
      PlexPlaylistDto.fromJson(
        metadata.first as Map<String, dynamic>,
      ).copyWith(serverId: serverId, serverName: serverName),
    );
  }

  ({List<PlexPlaylistDto> items, int totalSize}) _extractPlaylistListResult(
    MediaServerResponse response, {
    int? start,
    int? size,
  });

  Future<_LibraryContentResult> _getPlaylist(String playlistId, {int? start, int? size, AbortController? abort}) =>
      _fetchPaginatedList('/playlists/$playlistId/items', start: start, size: size, abort: abort);

  Future<({List<PlexPlaylistDto> items, int totalSize})> _getPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final pageSize = size ?? _defaultPlaylistContainerSize;
    final queryParams = <String, dynamic>{
      if (playlistType.isNotEmpty) 'playlistType': playlistType,
      ..._buildPaginationParams(start, pageSize),
    };
    if (smart != null) queryParams['smart'] = smart ? '1' : '0';

    final response = await _getWithFailover('/playlists', queryParameters: queryParams, abort: abort);
    return _extractPlaylistListResult(response, start: start, size: pageSize);
  }

  Future<PlexPlaylistDto?> _getPlaylistMetadata(String playlistId) async {
    try {
      final response = await _getWithFailover('/playlists/$playlistId');
      final container = _getMediaContainer(response);
      final metadata = container?['Metadata'];
      if (metadata is! List || metadata.isEmpty) return null;
      return PlexPlaylistDto.fromJson(
        metadata.first as Map<String, dynamic>,
      ).copyWith(serverId: serverId, serverName: serverName);
    } catch (e) {
      appLogger.e('Failed to get playlist metadata: $e');
      return null;
    }
  }

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final result = await _getPlaylistsPage(
      playlistType: playlistType,
      smart: smart,
      start: start,
      size: size,
      abort: abort,
    );
    return LibraryPage<MediaPlaylist>(
      items: result.items.map(PlexMappers.mediaPlaylist).toList(),
      totalCount: result.totalSize,
      offset: start ?? 0,
    );
  }

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) async {
    final playlist = await _getPlaylistMetadata(id);
    return playlist == null ? null : PlexMappers.mediaPlaylist(playlist);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(
    String playlistId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final result = await _getPlaylist(playlistId, start: start, size: size, abort: abort);
    return LibraryPage<MediaItem>(
      items: result.items.map(PlexMappers.mediaItem).toList(),
      totalCount: result.totalSize,
      offset: start ?? 0,
    );
  }

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) async {
    if (items.isEmpty) return createPlaylistFromUri(title: title);
    final uri = await buildMetadataUri(items.map((item) => item.id).join(','));
    return createPlaylistFromUri(title: title, uri: uri, type: items.first.kind.isMusic ? 'audio' : 'video');
  }

  Future<MediaPlaylist?> createPlaylistFromUri({
    required String title,
    String? uri,
    int? playQueueId,
    String type = 'video',
  }) async {
    final queryParameters = <String, dynamic>{
      'type': type,
      'title': title,
      'smart': '0',
      'uri': ?uri,
      'playQueueID': ?playQueueId?.toString(),
    };
    final response = await _http.post('/playlists', queryParameters: queryParameters);
    throwIfHttpError(response);
    final metadata = _getMediaContainer(response)?['Metadata'];
    if (metadata is! List || metadata.isEmpty) return null;

    final dto = PlexPlaylistDto.fromJson(
      metadata.first as Map<String, dynamic>,
    ).copyWith(serverId: serverId, serverName: serverName);
    return PlexMappers.mediaPlaylist(dto);
  }

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) {
    return _wrapBoolApiCall(() => _http.delete('/playlists/${playlist.id}'), 'Failed to delete playlist');
  }

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) async {
    if (items.isEmpty) return true;
    final uri = await buildMetadataUri(items.map((item) => item.id).join(','));
    return addItemsToPlaylistByUri(playlistId: playlistId, uri: uri);
  }

  Future<bool> addItemsToPlaylistByUri({required String playlistId, required String uri}) async {
    appLogger.d(
      'Adding to playlist $playlistId with URI: '
      '${uri.substring(0, uri.length > 100 ? 100 : uri.length)}'
      '${uri.length > 100 ? "..." : ""}',
    );
    final result = await _wrapBoolApiCall(
      () => _http.put('/playlists/$playlistId/items', queryParameters: {'uri': uri}),
      'Failed to add to playlist',
    );
    if (result) appLogger.d('Add to playlist response status: 200');
    return result;
  }

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) {
    if (item is! PlexMediaItem || item.playlistItemId == null) {
      return Future.value(false);
    }
    return _wrapBoolApiCall(
      () => _http.delete('/playlists/$playlistId/items/${item.playlistItemId}'),
      'Failed to remove from playlist',
    );
  }

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) async {
    if (item is! PlexMediaItem || item.playlistItemId == null) return false;
    final int after;
    if (newIndex == 0) {
      after = 0;
    } else if (afterItem is PlexMediaItem && afterItem.playlistItemId != null) {
      after = afterItem.playlistItemId!;
    } else {
      return false;
    }
    appLogger.d(
      'Moving playlist item ${item.playlistItemId} after $after in playlist '
      '$playlistId',
    );
    return _wrapBoolApiCall(
      () => _http.put('/playlists/$playlistId/items/${item.playlistItemId}/move', queryParameters: {'after': after}),
      'Failed to move playlist item',
    );
  }
}
