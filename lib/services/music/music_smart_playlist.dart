import '../../media/library_query.dart';
import '../../media/media_kind.dart';
import '../library_query_translator.dart';

class MusicSmartPlaylistRules {
  MusicSmartPlaylistRules({required this.libraryId, required List<(String, String)> parameters})
    : parameters = List.unmodifiable(parameters) {
    if (!RegExp(r'^\d+$').hasMatch(libraryId) || parameters.length > 512) {
      throw ArgumentError('Invalid smart playlist library');
    }
    var depth = 0;
    var types = 0;
    for (final (key, value) in parameters) {
      if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9._]*[!<>=]{0,2}$').hasMatch(key) ||
          value.length > 8192 ||
          RegExp(r'[\x00-\x1f]').hasMatch(value) ||
          RegExp(r'token|auth|password|secret|url|uri|container', caseSensitive: false).hasMatch(key)) {
        throw ArgumentError('Invalid smart playlist parameter');
      }
      if (key == 'type') {
        types++;
        if (value != '10') throw ArgumentError('Smart music playlists require tracks');
      }
      if (key == 'push') {
        depth++;
        if (value != '1' || depth > 16) throw ArgumentError('Invalid filter group');
      }
      if (key == 'pop') {
        depth--;
        if (value != '1' || depth < 0) throw ArgumentError('Invalid filter group');
      }
      if ((key == 'and' || key == 'or') && value != '1') throw ArgumentError('Invalid filter conjunction');
      if (key == 'limit' && (int.tryParse(value) == null || int.parse(value) < 1 || int.parse(value) > 1000000)) {
        throw ArgumentError('Invalid smart playlist limit');
      }
    }
    if (depth != 0 || types != 1 || query.length > 65536) throw ArgumentError('Invalid smart playlist expression');
  }

  final String libraryId;
  final List<(String, String)> parameters;
  String get query => parameters
      .map((entry) => '${Uri.encodeQueryComponent(entry.$1)}=${Uri.encodeQueryComponent(entry.$2)}')
      .join('&');
  String get searchPath => '/library/sections/$libraryId/all?$query';

  factory MusicSmartPlaylistRules.fromQuery({required String libraryId, required String query}) =>
      MusicSmartPlaylistRules(
        libraryId: libraryId,
        parameters: query.split('&').where((entry) => entry.isNotEmpty).map((entry) {
          final split = entry.indexOf('=');
          if (split < 1) throw const FormatException('Invalid smart playlist query');
          return (
            Uri.decodeQueryComponent(entry.substring(0, split)),
            Uri.decodeQueryComponent(entry.substring(split + 1)),
          );
        }).toList(),
      );

  factory MusicSmartPlaylistRules.fromContent(String content) {
    final uri = Uri.parse(content);
    final match = RegExp(
      r'^/library/sections/(\d+)/all$',
    ).firstMatch(uri.path.replaceFirst(RegExp(r'^/com\.plexapp\.plugins\.library'), ''));
    if ((uri.scheme.isNotEmpty && uri.scheme != 'server') ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        match == null) {
      throw const FormatException('Invalid smart playlist content');
    }
    return MusicSmartPlaylistRules.fromQuery(libraryId: match.group(1)!, query: uri.query);
  }

  factory MusicSmartPlaylistRules.fromFilters({
    required String libraryId,
    required List<LibraryFilter> filters,
    LibrarySort? sort,
    int? limit,
  }) {
    final params = const PlexLibraryQueryTranslator().toQueryParameters(
      LibraryQuery(kind: MediaKind.track, filters: filters, sort: sort),
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
