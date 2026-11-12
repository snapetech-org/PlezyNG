/// Credential-free playlist grants returned by Plex item sharing.
/// Contract: Plex Web 4.163.0 shared_sources + sharedItems, owner/invited.
class PlexPlaylistAccessGrant {
  const PlexPlaylistAccessGrant({
    required this.itemId,
    required this.sourceId,
    required this.userId,
    required this.userName,
    required this.uri,
    required this.received,
  });
  final int itemId, sourceId, userId;
  final String userName, uri;
  final bool received;

  static bool isPlaylistUri(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'server' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasPort &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        RegExp(r'^/com\.plexapp\.plugins\.library/playlists/[a-zA-Z0-9_-]+/items$').hasMatch(uri.path);
  }

  static int? _id(Object? value) {
    final id = value is int
        ? value
        : value is String
        ? int.tryParse(value)
        : null;
    return id != null && id > 0 ? id : null;
  }

  static List<PlexPlaylistAccessGrant> parseSources(Object? data, {required bool received, String? playlistUri}) {
    if (data is! List || data.length > 512) throw const FormatException('Invalid Plex shared sources');
    final grants = <PlexPlaylistAccessGrant>[];
    final seen = <int>{};
    var itemCount = 0;
    for (final source in data) {
      if (source is! Map) throw const FormatException('Invalid Plex shared source');
      if (received && source['status'] != 'accepted') continue;
      final id = _id(source['id']);
      final user = source[received ? 'owner' : 'invited'];
      final items = source['sharedItems'];
      if (items is! List) throw const FormatException('Missing Plex shared items');
      itemCount += items.length;
      if (itemCount > 8192) throw const FormatException('Too many Plex shared items');
      if (id == null || user is! Map || _id(user['id']) == null) continue;
      final name = [
        user['title'],
        user['username'],
        user['email'],
      ].whereType<String>().where((s) => s.trim().isNotEmpty && s.length <= 320).firstOrNull;
      if (name == null) continue;
      for (final item in items) {
        if (item is! Map || item['uri'] is! String) continue;
        final itemId = _id(item['id']), uri = item['uri'] as String;
        if (itemId == null || !isPlaylistUri(uri) || playlistUri != null && uri != playlistUri) continue;
        if (!seen.add(itemId)) throw const FormatException('Ambiguous Plex shared item');
        grants.add(
          PlexPlaylistAccessGrant(
            itemId: itemId,
            sourceId: id,
            userId: _id(user['id'])!,
            userName: name,
            uri: uri,
            received: received,
          ),
        );
      }
    }
    return List.unmodifiable(grants);
  }
}
