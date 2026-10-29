import 'romm_models.dart';

/// A portable handoff identifies a server and exact copy, never an API token,
/// local connection UUID, executable command or arbitrary download URL.
class RommLink {
  const RommLink(this.server, this.romId, this.identity, {this.platform = '', this.igdbId = 0});
  final Uri server;
  final int romId, igdbId;
  final String identity, platform;
  factory RommLink.game(RommConnection source, RommGame game) => RommLink(source.base, game.id,
    game.sha1.isNotEmpty ? 'sha1:${game.sha1}' : game.md5.isNotEmpty ? 'md5:${game.md5}' : '', platform: game.platform, igdbId: game.igdbId);
  Uri get uri => Uri(scheme: 'plezy', host: 'game', queryParameters: {'source': 'romm', 'server': server.toString(),
    if (romId > 0) 'rom': '$romId', if (identity.isNotEmpty) 'copy': identity,
    if (platform.isNotEmpty) 'platform': platform, if (igdbId > 0) 'igdb': '$igdbId'});
  static RommLink? parse(Uri uri) {
    if (!{'plezy', 'plezyng', 'plezxyng'}.contains(uri.scheme) || uri.host != 'game' || uri.path.isNotEmpty ||
        uri.userInfo.isNotEmpty || uri.hasPort || uri.hasFragment || uri.toString().length > 4096) return null;
    final q = uri.queryParameters;
    if (q['source'] != 'romm' || q.keys.any((key) => !{'source', 'server', 'rom', 'copy', 'platform', 'igdb'}.contains(key)) ||
        uri.queryParametersAll.values.any((values) => values.length != 1)) return null;
    try {
      if (['rom', 'igdb'].any((key) => q.containsKey(key) && !RegExp(r'^[0-9]{1,10}$').hasMatch(q[key]!))) return null;
      final server = rommBaseUri(q['server'] ?? '');
      final id = int.tryParse(q['rom'] ?? '') ?? 0, igdb = int.tryParse(q['igdb'] ?? '') ?? 0;
      final copy = q['copy'] ?? '', platform = q['platform'] ?? '';
      if (id < 0 || id > 0x7fffffff || igdb < 0 || igdb > 0x7fffffff || (id == 0 && igdb == 0) ||
          copy.isNotEmpty && !RegExp(r'^(sha1:[0-9a-fA-F]{40}|md5:[0-9a-fA-F]{32})$').hasMatch(copy) ||
          platform.length > 100 || platform.isNotEmpty && !RegExp(r'^[a-z0-9_-]+$').hasMatch(platform)) return null;
      return RommLink(server, id, copy.toLowerCase(), platform: platform, igdbId: igdb);
    } catch (_) { return null; }
  }
  bool matches(RommGame game) => (romId == 0 || game.id == romId) && (identity.isEmpty || game.identity.toLowerCase() == identity) &&
      (platform.isEmpty || game.platform == platform) && (igdbId == 0 || game.igdbId == igdbId);
}
