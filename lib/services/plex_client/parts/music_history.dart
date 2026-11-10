part of '../../plex_client.dart';

typedef PlexMusicHistoryEntry = ({String id, MediaItem item, DateTime playedAt});

extension PlexMusicServerHistory on PlexClient {
  static const _pageSize = 50;
  static const _ownerId = 1;
  static final _historyPath = RegExp(r'^/status/sessions/history/(\d+)$');

  void bindMusicHistoryResource({required bool owned}) {
    final user = plexMusicUserIdentifier;
    _musicHistoryOwner =
        owned &&
            user != null &&
            user.isNotEmpty &&
            user != config.clientIdentifier &&
            plexAccountId == 'plex.$user' &&
            config.token?.isNotEmpty == true
        ? (authentication: authenticationSessionId, user: user)
        : null;
  }

  bool get supportsMusicServerHistory {
    final owner = _musicHistoryOwner;
    return owner != null &&
        identical(owner.authentication, authenticationSessionId) &&
        owner.user == plexMusicUserIdentifier &&
        plexAccountId == 'plex.${owner.user}';
  }

  Future<({List<PlexMusicHistoryEntry> entries, int? nextStart})> fetchMusicServerHistory({
    required String libraryId,
    int start = 0,
    AbortController? abort,
  }) async {
    if (start < 0 || start > 10000000 || !RegExp(r'^\d{1,16}$').hasMatch(libraryId)) {
      throw ArgumentError('Invalid music history page');
    }
    final owner = _musicHistoryOwner;
    if (!supportsMusicServerHistory) throw StateError('Music history owner unavailable');
    final response = await _getWithFailover(
      '/status/sessions/history/all',
      queryParameters: {
        'accountID': _ownerId,
        'librarySectionID': libraryId,
        'sort': 'viewedAt:desc',
        ..._buildPaginationParams(start, _pageSize),
      },
      abort: abort,
    );
    if (owner != _musicHistoryOwner || !supportsMusicServerHistory) {
      throw StateError('Music history account changed');
    }
    final container = _getMediaContainer(response);
    final raw = container?['Metadata'] ?? const [];
    final offset = flexibleInt(container?['offset']);
    final size = flexibleInt(container?['size']);
    if (container == null ||
        raw is! List ||
        raw.length > _pageSize ||
        (offset != null && offset != start) ||
        (size != null && size != raw.length)) {
      throw const FormatException('Invalid music history page');
    }
    final total = _responseTotalSize(response, itemCount: raw.length, start: start, requestedSize: _pageSize);
    final end = start + raw.length;
    if (raw.isEmpty && total > end) throw const FormatException('Music history page made no progress');
    final entries = <PlexMusicHistoryEntry>[];
    final seen = <String>{};
    String? label(Object? value) => value is String && value.length <= 1024 ? value : null;
    String? itemId(Object? value) {
      final string = value is int || value is String ? value.toString() : '';
      return RegExp(r'^\d{1,16}$').hasMatch(string) ? string : null;
    }

    for (final row in raw) {
      if (row is! Map ||
          int.tryParse('${row['accountID']}') != _ownerId ||
          itemId(row['librarySectionID']) != libraryId) {
        throw const FormatException('Music history row is outside the requested scope');
      }
      if (row['type'] != 'track') continue;
      final key = _historyPath.firstMatch(label(row['historyKey']) ?? '')?.group(1);
      final id = itemId(row['ratingKey']);
      final playedAt = int.tryParse('${row['viewedAt']}');
      if (key == null ||
          key.length > 16 ||
          id == null ||
          playedAt == null ||
          playedAt <= 0 ||
          playedAt > 253402300799) {
        continue;
      }
      if (!seen.add(key)) continue;
      entries.add((
        id: key,
        item: MediaItem.plex(
          id: id,
          kind: MediaKind.track,
          title: label(row['title']),
          parentId: itemId(row['parentRatingKey']),
          parentTitle: label(row['parentTitle']),
          grandparentId: itemId(row['grandparentRatingKey']),
          grandparentTitle: label(row['grandparentTitle']),
          serverId: serverId.value,
          serverName: serverName,
          libraryId: libraryId,
        ),
        playedAt: DateTime.fromMillisecondsSinceEpoch(playedAt * 1000, isUtc: true),
      ));
    }
    return (entries: entries, nextStart: end < total ? end : null);
  }
}
