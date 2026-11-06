/// Replace only Plex's playback identity, preserving signed/repeated query
/// parameters and their original escaping. External players cannot supply
/// the headers used by our embedded player.
String plexDirectPlayIdentity(String url, {required String clientId, required String sessionId}) {
  final fragmentAt = url.indexOf('#');
  final fragment = fragmentAt < 0 ? '' : url.substring(fragmentAt);
  final resource = fragmentAt < 0 ? url : url.substring(0, fragmentAt);
  final queryAt = resource.indexOf('?');
  final base = queryAt < 0 ? resource : resource.substring(0, queryAt);
  final parts = queryAt < 0 ? <String>[] : resource.substring(queryAt + 1).split('&');
  parts.removeWhere((part) {
    if (part.isEmpty) return true;
    final key = part.split('=').first;
    try {
      final decoded = Uri.decodeQueryComponent(key).toLowerCase();
      return decoded == 'x-plex-session-identifier' || decoded == 'x-plex-client-identifier';
    } on FormatException {
      return false;
    }
  });
  parts.add('X-Plex-Client-Identifier=${Uri.encodeComponent(clientId)}');
  parts.add('X-Plex-Session-Identifier=${Uri.encodeComponent(sessionId)}');
  return '$base?${parts.join('&')}$fragment';
}
