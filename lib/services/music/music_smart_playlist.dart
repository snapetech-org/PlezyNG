import '../../media/library_query.dart';
import '../../media/media_kind.dart';
import '../library_query_translator.dart';

class MusicSmartPlaylistRules {
  static const _musicKinds = {'8': MediaKind.artist, '9': MediaKind.album, '10': MediaKind.track};
  static const _modifiers = {'type', 'sourceType', 'sort', 'group', 'limit'};
  static const _maxQueryLength = 65536;

  MusicSmartPlaylistRules({required this.libraryId, required List<(String, String)> parameters})
    : parameters = List.unmodifiable(parameters) {
    if (!RegExp(r'^\d+$').hasMatch(libraryId) || parameters.length > 512) {
      throw ArgumentError('Invalid smart playlist library');
    }
    final operands = <bool>[false];
    final modifiers = <String>{};
    for (final (key, value) in parameters) {
      if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9._]*[!<>=]{0,2}$').hasMatch(key) ||
          value.length > 8192 ||
          RegExp(r'[\x00-\x1f]').hasMatch(value) ||
          RegExp(r'token|auth|password|secret|url|uri|container', caseSensitive: false).hasMatch(key)) {
        throw ArgumentError('Invalid smart playlist parameter');
      }
      if (_modifiers.contains(key)) {
        if (!modifiers.add(key) || ((key == 'type' || key == 'sourceType') && !_musicKinds.containsKey(value))) {
          throw ArgumentError('Invalid smart playlist modifier');
        }
        final limit = key == 'limit' ? int.tryParse(value) : null;
        if (key == 'limit' && (limit == null || limit < 1 || limit > 1000000)) {
          throw ArgumentError('Invalid smart playlist limit');
        }
        continue;
      }
      switch (key) {
        case 'push':
          if (value != '1' || operands.length > 16) throw ArgumentError('Invalid filter group');
          operands.add(false);
        case 'pop':
          if (value != '1' || operands.length == 1 || !operands.last) throw ArgumentError('Invalid filter group');
          operands.removeLast();
          operands[operands.length - 1] = true;
        case 'and' || 'or':
          if (value != '1' || !operands.last) throw ArgumentError('Invalid filter conjunction');
          operands[operands.length - 1] = false;
        default:
          operands[operands.length - 1] = true;
      }
    }
    final hasExpression = parameters.any((entry) => !_modifiers.contains(entry.$1));
    if (operands.length != 1 ||
        (hasExpression && !operands.last) ||
        !modifiers.contains('type') ||
        query.length > _maxQueryLength) {
      throw ArgumentError('Invalid smart playlist expression');
    }
  }

  final String libraryId;
  final List<(String, String)> parameters;
  MediaKind get sourceKind =>
      _musicKinds[(parameters.where((entry) => entry.$1 == 'sourceType').firstOrNull ??
              parameters.firstWhere((entry) => entry.$1 == 'type'))
          .$2]!;
  String get query => parameters
      .map((entry) => '${Uri.encodeQueryComponent(entry.$1)}=${Uri.encodeQueryComponent(entry.$2)}')
      .join('&');
  String get searchPath => '/library/sections/$libraryId/all?$query';

  factory MusicSmartPlaylistRules.fromQuery({required String libraryId, required String query}) =>
      MusicSmartPlaylistRules(libraryId: libraryId, parameters: _parseQuery(query));

  static List<(String, String)> _parseQuery(String query) {
    if (query.length > _maxQueryLength) throw const FormatException('Smart playlist query is too large');
    return query.split('&').where((entry) => entry.isNotEmpty).map((entry) {
      var split = entry.indexOf('=');
      if (split < 1) throw const FormatException('Invalid smart playlist query');
      var key = Uri.decodeQueryComponent(entry.substring(0, split));
      if (entry.startsWith('==', split) && RegExp(r'[a-zA-Z0-9._!]$').hasMatch(key)) {
        key += '=';
        split++;
      }
      return (key, Uri.decodeQueryComponent(entry.substring(split + 1)));
    }).toList();
  }

  factory MusicSmartPlaylistRules.fromContent(String content, {String? expectedServer, bool audioPlaylist = false}) {
    if (content.length > _maxQueryLength * 3 + 256) throw const FormatException('Smart playlist URI is too large');
    final outer = Uri.parse(content);
    if (outer.userInfo.isNotEmpty || outer.hasPort || outer.hasFragment) {
      throw const FormatException('Invalid smart playlist content');
    }
    final Uri uri;
    final String path;
    switch (outer.scheme) {
      case 'library':
        final segments = outer.pathSegments;
        if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(outer.host) ||
            outer.hasQuery ||
            segments.length != 2 ||
            segments.first != 'directory') {
          throw const FormatException('Invalid smart playlist directory');
        }
        uri = Uri.parse(segments.last);
        if (uri.hasScheme || uri.hasAuthority || uri.hasFragment) {
          throw const FormatException('Invalid smart playlist directory');
        }
        path = uri.path;
      case 'server':
        if (outer.host.isEmpty || (expectedServer != null && outer.host != expectedServer.toLowerCase())) {
          throw const FormatException('Invalid smart playlist server');
        }
        uri = outer;
        path = uri.path.replaceFirst(RegExp(r'^/com\.plexapp\.plugins\.library(?=/)'), '');
      case '' when !outer.hasAuthority:
        uri = outer;
        path = uri.path;
      default:
        throw const FormatException('Invalid smart playlist content');
    }
    final match = RegExp(r'^/library/sections/(\d+)/all$').firstMatch(path);
    if (match == null) throw const FormatException('Invalid smart playlist section');
    final parameters = _parseQuery(uri.query);
    return MusicSmartPlaylistRules(
      libraryId: match.group(1)!,
      parameters: [if (audioPlaylist && !parameters.any((entry) => entry.$1 == 'type')) ('type', '10'), ...parameters],
    );
  }

  MusicSmartPlaylistRules appendFilters(List<LibraryFilter> filters) {
    final added = MusicSmartPlaylistRules.fromFilters(
      libraryId: libraryId,
      filters: filters,
      kind: sourceKind,
    ).parameters.where((entry) => !_modifiers.contains(entry.$1)).toList();
    if (added.isEmpty) return this;
    final existing = parameters.where((entry) => !_modifiers.contains(entry.$1)).toList();
    return MusicSmartPlaylistRules(
      libraryId: libraryId,
      parameters: [
        ...parameters.where((entry) => _modifiers.contains(entry.$1)),
        if (existing.isNotEmpty) ...[('push', '1'), ...existing, ('pop', '1')],
        ...added,
      ],
    );
  }

  factory MusicSmartPlaylistRules.fromFilters({
    required String libraryId,
    required List<LibraryFilter> filters,
    MediaKind kind = MediaKind.track,
    LibrarySort? sort,
    int? limit,
  }) {
    final params = const PlexLibraryQueryTranslator().toQueryParameters(
      LibraryQuery(kind: kind, filters: filters, sort: sort),
    );
    params.remove('X-Plex-Container-Start');
    params.remove('X-Plex-Container-Size');
    return MusicSmartPlaylistRules(
      libraryId: libraryId,
      parameters: [
        for (final entry in params.entries)
          for (final value in entry.value is List ? entry.value as List : [entry.value]) (entry.key, value.toString()),
        if (limit != null) ('limit', limit.toString()),
      ],
    );
  }
}
