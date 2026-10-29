import 'dart:convert';

/// RomM 5.4.1's public API boundary. Filesystem paths and arbitrary executable
/// addresses are deliberately not retained in the client catalog.
Map<String, dynamic> rommMap(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};
List<dynamic> rommList(Object? value) => value is List ? value : const [];
String rommString(Object? value, [int limit = 4096]) {
  final text = value is String ? value.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '') : '';
  return text.length <= limit ? text : text.substring(0, limit);
}
int rommInt(Object? value, [int fallback = 0]) => value is int && value >= 0 && value <= 0x1fffffffffffff
    ? value : fallback;
List<String> rommStrings(Object? value) => rommList(value).take(100).map((e) => rommString(e, 256)).where((s) => s.isNotEmpty).toList();
String rommHash(Object? value, int length) => value is String && RegExp('^[0-9a-fA-F]{$length}\$').hasMatch(value) ? value.toLowerCase() : '';

Uri rommBaseUri(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || !{'https', 'http'}.contains(uri.scheme) || uri.host.isEmpty ||
      uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
      uri.pathSegments.any((p) => p == '..' || p == '.' || p.contains('\\')) ||
      input.length > 2048) {
    throw const FormatException('romm.invalidAddress');
  }
  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (path.endsWith('/api')) path = path.substring(0, path.length - 4);
  return uri.replace(path: '$path/');
}

class RommConnection {
  const RommConnection({required this.id, required this.name, required this.baseUrl,
    required this.userId, required this.username, required this.deviceId,
    this.credential = '', this.version = '', this.scopes = const []});
  final String id, name, baseUrl, username, deviceId, credential, version;
  final int userId;
  final List<String> scopes;
  Uri get base => rommBaseUri(baseUrl);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'baseUrl': baseUrl,
    'userId': userId, 'username': username, 'deviceId': deviceId,
    'credential': credential, 'version': version, 'scopes': scopes};
  factory RommConnection.fromJson(Map<String, dynamic> j) {
    final id = rommString(j['id'], 128);
    if (!RegExp(r'^[a-zA-Z0-9_-]{8,128}$').hasMatch(id) || rommInt(j['userId']) == 0) throw const FormatException('romm.invalidConnection');
    return RommConnection(id: id, name: rommString(j['name'], 128),
      baseUrl: rommBaseUri(rommString(j['baseUrl'], 2048)).toString(),
      userId: rommInt(j['userId']), username: rommString(j['username'], 128),
      deviceId: rommString(j['deviceId'], 128), credential: rommString(j['credential'], 16384),
      version: rommString(j['version'], 64), scopes: rommStrings(j['scopes']));
  }
}

class RommFile {
  const RommFile({required this.id, required this.name, required this.size,
    this.sha1 = '', this.md5 = '', this.category = ''});
  final int id, size;
  final String name, sha1, md5, category;
  factory RommFile.fromJson(Map<String, dynamic> j) => RommFile(id: rommInt(j['id']),
    name: rommString(j['file_name'], 1024), size: rommInt(j['file_size_bytes']),
    sha1: rommHash(j['sha1_hash'], 40), md5: rommHash(j['md5_hash'], 32),
    category: rommString(j['category'], 64));
  Map<String, dynamic> toJson() => {'id': id, 'file_name': name, 'file_size_bytes': size,
    'sha1_hash': sha1, 'md5_hash': md5, 'category': category};
}

class RommGame {
  RommGame({required this.connectionId, required this.id, required this.platformId,
    required this.name, required this.platform, required this.platformName,
    required this.fileName, required this.extension, required this.size,
    this.summary = '', this.cover = '', this.revision = '', this.sha1 = '', this.md5 = '',
    this.regions = const [], this.languages = const [], this.tags = const [],
    this.files = const [], this.siblingIds = const [], this.screenshots = const [],
    this.missing = false, this.physical = false, this.easyRpg = false,
    this.lastPlayed, this.igdbId = 0, this.achievementId = 0,
    this.userData = const {}, this.achievements = const {}, this.manual = '',
    this.saves = const [], this.states = const []});
  final String connectionId, name, platform, platformName, fileName, extension, summary,
      cover, revision, sha1, md5, manual;
  final int id, platformId, size, igdbId, achievementId;
  final List<String> regions, languages, tags, screenshots;
  final List<RommFile> files;
  final List<int> siblingIds;
  final bool missing, physical, easyRpg;
  final DateTime? lastPlayed;
  final Map<String, dynamic> userData, achievements;
  final List<RommSave> saves, states;
  String get key => 'romm:$connectionId:$id';
  String get variant => [platformName, ...regions, ...languages, revision].where((s) => s.isNotEmpty).join(' · ');
  bool get hasBytes => !missing && !physical;
  /// Keep disc controls aligned with RomM's utils.m3u.playlist_files: the
  /// playlist and a descriptor's raw/audio companions are not swappable discs.
  List<RommFile> get discFiles {
    String extension(RommFile file) => file.name.split('.').last.toLowerCase();
    const descriptors = {'cue', 'gdi', 'ccd', 'mds'};
    const companions = {'bin', 'raw', 'img', 'sub', 'mdf', 'wav', 'ogg', 'flac', 'mp3'};
    final discs = files.where((file) => file.id > 0 && extension(file) != 'm3u').toList();
    if (discs.any((file) => descriptors.contains(extension(file)))) {
      discs.removeWhere((file) => companions.contains(extension(file)));
    }
    final tag = RegExp(r'\((?:disc|disk|cd|disque)(?:\s*([0-9]+)[a-z]?|\s+([a-z]))(?:\s+of\s+[0-9]+)?\)', caseSensitive: false);
    int? number(RommFile file) {
      final match = tag.firstMatch(file.name);
      if (match == null) return null;
      return match.group(1) != null ? int.tryParse(match.group(1)!) : match.group(2)!.toLowerCase().codeUnitAt(0) - 96;
    }
    discs.sort((a, b) {
      final x = number(a), y = number(b);
      if (x == null && y != null) return 1;
      if (x != null && y == null) return -1;
      final order = (x ?? 0).compareTo(y ?? 0);
      return order != 0 ? order : a.name.compareTo(b.name);
    });
    return discs;
  }
  String get identity => sha1.isNotEmpty ? 'sha1:$sha1' : md5.isNotEmpty ? 'md5:$md5' : '$key:$size:$fileName';
  factory RommGame.fromJson(String connectionId, Map<String, dynamic> j) {
    final user = rommMap(j['rom_user']);
    return RommGame(connectionId: connectionId, id: rommInt(j['id']),
      platformId: rommInt(j['platform_id']), name: rommString(j['name'], 512).trim().isNotEmpty ? rommString(j['name'], 512) : rommString(j['fs_name'], 512),
      platform: rommString(j['platform_slug'], 128),
      platformName: rommString(j['platform_display_name'] ?? j['platform_slug'], 256),
      fileName: rommString(j['fs_name'], 1024), extension: rommString(j['fs_extension'], 32).toLowerCase(),
      size: rommInt(j['fs_size_bytes']), summary: rommString(j['summary'], 16384),
      cover: rommString(j['path_cover_large'], 2048).isNotEmpty ? rommString(j['path_cover_large'], 2048) : rommString(j['path_cover_small'], 2048),
      revision: rommString(j['revision'], 128), sha1: rommHash(j['sha1_hash'], 40), md5: rommHash(j['md5_hash'], 32),
      regions: rommStrings(j['regions']), languages: rommStrings(j['languages']), tags: rommStrings(j['tags']),
      files: rommList(j['files']).take(8192).map((e) => RommFile.fromJson(rommMap(e))).where((e) => e.id > 0).toList(),
      siblingIds: rommList(j['sibling_roms']).take(200).map((e) => rommInt(rommMap(e)['id'])).where((id) => id > 0).toList(),
      screenshots: rommStrings(j['merged_screenshots']),
      missing: j['missing_from_fs'] == true || j['has_file_on_disk'] == false,
      physical: j['is_physical'] == true, easyRpg: j['is_easyrpg_game'] == true,
      lastPlayed: DateTime.tryParse(rommString(user['last_played'], 64)),
      igdbId: rommInt(j['igdb_id']), achievementId: rommInt(j['ra_id']), userData: user,
      achievements: rommMap(j['merged_ra_metadata']), manual: rommString(j['path_manual'], 2048),
      saves: rommList(j['user_saves']).take(500).map((e) => RommSave.fromJson(rommMap(e))).toList(),
      states: rommList(j['user_states']).take(500).map((e) => RommSave.fromJson(rommMap(e), state: true)).toList());
  }
  Map<String, dynamic> toJson() => {'id': id, 'platform_id': platformId, 'name': name,
    'platform_slug': platform, 'platform_display_name': platformName, 'fs_name': fileName,
    'fs_extension': extension, 'fs_size_bytes': size, 'summary': summary,
    'path_cover_large': cover, 'revision': revision, 'sha1_hash': sha1, 'md5_hash': md5,
    'regions': regions, 'languages': languages, 'tags': tags, 'files': files.map((e) => e.toJson()).toList(),
    'sibling_roms': siblingIds.map((id) => {'id': id}).toList(), 'merged_screenshots': screenshots,
    'missing_from_fs': missing, 'is_physical': physical, 'is_easyrpg_game': easyRpg,
    'igdb_id': igdbId, 'ra_id': achievementId, 'rom_user': userData,
    'merged_ra_metadata': achievements, 'path_manual': manual};
}

class RommSave {
  const RommSave({required this.id, required this.romId, required this.userId,
    required this.name, required this.size, required this.emulator, required this.core,
    required this.slot, required this.hash, required this.updatedAt, required this.state,
    this.missing = false, this.screenshot = ''});
  final int id, romId, userId, size;
  final String name, emulator, core, slot, hash, screenshot;
  final DateTime? updatedAt;
  final bool state, missing;
  factory RommSave.fromJson(Map<String, dynamic> j, {bool state = false}) => RommSave(
    id: rommInt(j['id']), romId: rommInt(j['rom_id']), userId: rommInt(j['user_id']),
    name: rommString(j['file_name'], 255), size: rommInt(j['file_size_bytes']),
    emulator: rommString(j['emulator'], 128), core: rommString(j['core'], 128).isNotEmpty ? rommString(j['core'], 128)
      : rommList(j['labels']).whereType<String>().where((label) => label.startsWith('Plezy core: ')).firstOrNull?.substring(12) ?? '',
    slot: rommString(j['slot'], 255), hash: rommHash(j['content_hash'], 32),
    updatedAt: DateTime.tryParse(rommString(j['updated_at'], 64)), state: state,
    missing: j['missing_from_fs'] == true,
    screenshot: rommString(rommMap(j['screenshot'])['download_path'], 2048));
}

class RommCollection {
  const RommCollection(this.id, this.name, this.kind, this.count, {this.favorite = false, this.userId = 0, this.romIds = const {}});
  final String id, name, kind;
  final int count, userId;
  final bool favorite;
  final Set<int> romIds;
  factory RommCollection.fromJson(Map<String, dynamic> j, String kind) => RommCollection(
    j['id'].toString(), rommString(j['name'], 400), kind, rommInt(j['rom_count']),
    favorite: j['is_favorite'] == true, userId: rommInt(j['user_id']),
    romIds: rommList(j['rom_ids']).take(100000).map((v) => rommInt(v)).where((v) => v > 0).toSet());
}

class RommPage {
  const RommPage(this.games, this.total, this.nextOffset);
  final List<RommGame> games;
  final int total;
  final int? nextOffset;
}

enum RommEngine { emulatorJs, ruffle, jsDos, pico8, easyRpg, stream, native }
extension RommEnginePath on RommEngine {
  String get path => switch (this) { RommEngine.emulatorJs => 'ejs', RommEngine.jsDos => 'jsdos',
    RommEngine.pico8 => 'pico8', RommEngine.easyRpg => 'easyrpg', RommEngine.ruffle => 'ruffle',
    RommEngine.stream => 'stream', RommEngine.native => 'native' };
}

class RommRoute {
  const RommRoute(this.engine, {this.core = '', this.reason = '', this.available = true});
  final RommEngine engine;
  final String core, reason;
  final bool available;
}

class RommFailure implements Exception {
  const RommFailure(this.code, {this.status = 0});
  final String code;
  final int status;
  @override String toString() => code; // Never expose response bodies, tokens or URLs.
}

String rommSafeFileName(String value) {
  if (value.isEmpty || value.length > 255 || value == '.' || value == '..' ||
      RegExp(r'[/\\\x00-\x1f]').hasMatch(value)) throw const RommFailure('romm.invalidFile');
  return value;
}

String rommOpaqueKey(String value) => base64Url.encode(utf8.encode(value)).replaceAll('=', '');
