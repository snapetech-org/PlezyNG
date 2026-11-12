part of '../../jellyfin_client.dart';

/// Music browsing + playback-adjacent reads: artist discography, album track
/// listings, instant mix, and lyrics. Endpoint conventions follow the
/// Jellyfin web client's music surface (cross-checked against the Kotlin
/// SDK), mirroring the style notes at the top of `browse.dart`.
mixin _JellyfinMusicMethods on _JellyfinClientInternals {
  /// Albums credited to [artist], newest first. Queries `AlbumArtistIds`
  /// rather than `ParentId` because Jellyfin links albums to artists via
  /// tags — an artist's albums are usually not its folder children.
  @override
  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist) async {
    final response = await _http.get(
      '/Items',
      queryParameters: {
        'userId': connection.userId,
        'AlbumArtistIds': artist.id,
        'IncludeItemTypes': 'MusicAlbum',
        'Recursive': 'true',
        'SortBy': 'PremiereDate,ProductionYear,SortName',
        'SortOrder': 'Descending',
        'Fields': _musicAlbumRowFields,
        'EnableUserData': 'false',
        ...jellyfinImageQueryParameters,
      },
    );
    throwIfHttpError(response);
    return _mapItems(_itemsArray(response.data));
  }

  @override
  Future<LibraryPage<MediaItem>> fetchArtistAlbumsPage(
    MediaItem artist, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final offset = start ?? 0, pageSize = size ?? 100;
    if (offset < 0 || pageSize < 1 || pageSize > 1000) throw ArgumentError('Invalid artist album page bounds');
    if (isOfflineMode) {
      final albums = await fetchArtistAlbums(artist);
      final safeOffset = offset.clamp(0, albums.length).toInt();
      final end = (safeOffset + pageSize).clamp(0, albums.length).toInt();
      return LibraryPage(items: albums.sublist(safeOffset, end), totalCount: albums.length, offset: offset);
    }
    final response = await _http.get(
      '/Items',
      queryParameters: {
        'userId': connection.userId,
        'AlbumArtistIds': artist.id,
        'IncludeItemTypes': 'MusicAlbum',
        'Recursive': 'true',
        'SortBy': 'PremiereDate,ProductionYear,SortName',
        'SortOrder': 'Descending',
        'Fields': _musicAlbumRowFields,
        'EnableUserData': 'false',
        'StartIndex': offset.toString(),
        'Limit': pageSize.toString(),
        ...jellyfinImageQueryParameters,
      },
      abort: abort,
    );
    throwIfHttpError(response);
    return _pagedItems(response.data, offset: offset, requestedSize: pageSize, map: _mapItems);
  }

  /// MediaBrowser `BaseItemDto`s carry no single/EP/live/compilation
  /// taxonomy, so the discography is a single albums group — the neutral
  /// contract's MediaBrowser-family shape.
  @override
  Future<List<ArtistDiscographyGroup>> fetchArtistDiscography(MediaItem artist) async {
    final albums = await fetchArtistAlbums(artist);
    if (albums.isEmpty) return const <ArtistDiscographyGroup>[];
    return [ArtistDiscographyGroup(kind: DiscographyGroupKind.albums, items: albums)];
  }

  /// Tracks of [albumId] in disc/track order. `AlbumIds` (not `ParentId`) so
  /// tag-based albums whose files share one physical folder still resolve;
  /// `ParentIndexNumber,IndexNumber` yields correct multi-disc ordering.
  @override
  Future<List<MediaItem>> fetchAlbumTracks(String albumId) async {
    final response = await _http.get(
      '/Items',
      queryParameters: {
        'userId': connection.userId,
        'AlbumIds': albumId,
        'IncludeItemTypes': 'Audio',
        'Recursive': 'true',
        'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
        'SortOrder': 'Ascending',
        'Fields': _musicTrackRowFields,
        ...jellyfinImageQueryParameters,
      },
    );
    throwIfHttpError(response);
    return _mapItems(_itemsArray(response.data));
  }

  @override
  Future<LibraryPage<MediaItem>> fetchMusicTracksPage(
    String parentId, {
    required MediaKind kind,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    if (kind != MediaKind.album && kind != MediaKind.artist) {
      throw ArgumentError.value(kind, 'kind', 'Expected an album or artist');
    }
    final offset = start ?? 0, pageSize = size ?? 200;
    final response = await _http.get(
      '/Items',
      queryParameters: {
        'userId': connection.userId,
        if (kind == MediaKind.album) 'AlbumIds': parentId else 'AlbumArtistIds': parentId,
        'IncludeItemTypes': 'Audio',
        'Recursive': 'true',
        'SortBy': kind == MediaKind.album
            ? 'ParentIndexNumber,IndexNumber,SortName'
            : 'Album,ParentIndexNumber,IndexNumber,SortName',
        'SortOrder': 'Ascending',
        'Fields': _musicTrackRowFields,
        'StartIndex': offset.toString(),
        'Limit': pageSize.toString(),
        ..._excludeVirtualItemsQuery,
        ...jellyfinImageQueryParameters,
      },
      abort: abort,
    );
    throwIfHttpError(response);
    return _pagedItems(response.data, offset: offset, requestedSize: pageSize, map: _mapItems);
  }

  /// Server-built radio seeded from a track/album/artist/playlist id.
  @override
  Future<List<MediaItem>> fetchInstantMix(String itemId, {int limit = 100}) async {
    final response = await _http.get(
      '/Items/${_segment(itemId)}/InstantMix',
      queryParameters: {
        'userId': connection.userId,
        'Limit': limit.toString(),
        'Fields': _browseFields,
        ...jellyfinImageQueryParameters,
      },
    );
    throwIfHttpError(response);
    return _mapItems(_itemsArray(response.data));
  }

  /// Lyrics for [track] from Jellyfin's `/Audio/{id}/Lyrics`. `LyricDto`
  /// carries per-line `Start` offsets in ticks when the source is an LRC /
  /// synced provider; `IsSynced` is absent on some server versions, so
  /// synced-ness is inferred from any line carrying a `Start`. A Jellyfin 404
  /// means the track has no lyrics → `null`; Emby is rejected before the request.
  @override
  Future<Lyrics?> fetchLyrics(MediaItem track) async {
    if (!dialect.supportsLyrics) {
      // Emby 4.9.5 binds `Lyrics` as an audio container and starts a failing ffmpeg transcode, so this call is harmful.
      return null;
    }
    try {
      final response = await _http.get('/Audio/${_segment(track.id)}/Lyrics');
      throwIfHttpError(response);
      final data = response.data;
      if (data is! Map<String, dynamic>) return null;
      final rawLines = data['Lyrics'];
      if (rawLines is! List) return null;
      final lines = <LyricLine>[];
      var synced = false;
      for (final raw in rawLines) {
        if (raw is! Map<String, dynamic>) continue;
        final startMs = jellyfinTicksToMs(raw['Start']);
        if (startMs != null) synced = true;
        lines.add(LyricLine(text: raw['Text'] as String? ?? '', startMs: startMs));
      }
      if (lines.isEmpty) return null;
      return Lyrics(synced: synced, lines: lines);
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }
}
