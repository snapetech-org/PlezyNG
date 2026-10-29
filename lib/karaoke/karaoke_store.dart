import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Profile isolation and serialized, recoverable snapshots. No provider tokens.
class KaraokeStore {
  KaraokeStore(this.profileId);
  final String profileId;
  Future<Directory>? _directory;
  Future<void> _writes = Future.value();
  Future<Directory> get directory => _directory ??= _open();
  Future<Directory> _open() async {
    final root = await getApplicationSupportDirectory();
    final key = sha256.convert(utf8.encode(profileId)).toString();
    return Directory(p.join(root.path, 'karaoke', key)).create(recursive: true);
  }
  Future<Map<String, dynamic>?> read(String name) async {
    _validateName(name);
    final dir = await directory;
    for (final suffix in ['', '.previous']) {
      final file = File(p.join(dir.path, '$name.json$suffix'));
      if (!await file.exists()) continue;
      try {
        if (await file.length() > 32 * 1024 * 1024) continue;
        final value = jsonDecode(await file.readAsString());
        if (value is Map<String, dynamic>) return value;
      } on FormatException { continue; }
    }
    return null;
  }
  Future<void> write(String name, Map<String, dynamic> value) {
    _validateName(name);
    final encoded = jsonEncode(value);
    if (encoded.length > 32 * 1024 * 1024) throw const FormatException('Karaoke state limit exceeded');
    final result = _writes.then((_) async {
      final dir = await directory;
      final file = File(p.join(dir.path, '$name.json'));
      final temp = File('${file.path}.pending');
      final backup = File('${file.path}.previous');
      await temp.writeAsString(encoded, flush: true);
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      await temp.rename(file.path);
    });
    _writes = result.catchError((Object _) {});
    return result;
  }
  static void _validateName(String name) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(name)) throw const FormatException('Invalid state name');
  }
  Future<File> asset(String id, String relative) async {
    _validateName(id);
    final base = p.join((await directory).path, 'packages', id);
    final target = p.normalize(p.join(base, relative));
    if (!p.isWithin(base, target) || relative.contains('\\') || p.isAbsolute(relative)) {
      throw const FormatException('Invalid asset path');
    }
    // Imports materialize regular files. Never follow links supplied by a package.
    var probe = target;
    while (probe != base) {
      if (await FileSystemEntity.type(probe, followLinks: false) == FileSystemEntityType.link) {
        throw const FormatException('Karaoke asset is a symbolic link');
      }
      probe = p.dirname(probe);
    }
    return File(target);
  }
}
