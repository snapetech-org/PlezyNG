import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

import '../sources/source_models.dart';
import '../sources/source_transport.dart';

/// A self-contained HLS recording. Keeping complete segments and local
/// playlists preserves separate audio, initialization maps and discontinuities
/// without requiring an external remuxer on phones or TVs. No remote URL or
/// encryption key is persisted in the archive.
class IptvHlsArchive {
  IptvHlsArchive({
    required this.uri,
    required this.allowHttp,
    required this.headers,
    required this.output,
    required this.directory,
    required this.endsAt,
    this.maximumBytes = 64 * 1024 * 1024 * 1024,
  });

  final Uri uri;
  final bool allowHttp;
  final Map<String, String> headers;
  final File output;
  final Directory directory;
  final DateTime endsAt;
  final int maximumBytes;
  SourceTransport? _transport;
  bool _stopped = false;
  int mediaBytes = 0;
  final Map<String, Uint8List> _keys = {};

  Future<void> stop() async {
    _stopped = true;
    _transport?.close();
  }

  Map<String, String> _headers(Uri target) => sameSourceOrigin(uri, target) ? headers : const {};

  Future<({Uri base, String text})> _playlist(SourceTransport transport, Uri address) async {
    final response = await transport.send('GET', address, headers: _headers(address), redirects: true);
    SourceTransport.check(response.statusCode);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const SourceException(SourceFailure.invalidData);
      }
      bytes.add(chunk);
    }
    final text = utf8.decode(bytes.takeBytes());
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      throw const SourceException(SourceFailure.invalidData);
    }
    return (base: response.request?.url ?? address, text: text);
  }

  Future<void> record() async {
    final transport = SourceTransport(allowHttp: allowHttp);
    _transport = transport;
    final tracks = <_ArchiveTrack>[];
    var succeeded = false;
    await directory.create(recursive: true);
    try {
      final initial = await _playlist(transport, uri);
      final variant = _variant(initial.text, initial.base);
      tracks.add(_ArchiveTrack(variant?.uri ?? uri, 'video'));
      if (variant?.audio case final audio?) {
        tracks.add(_ArchiveTrack(audio, 'audio'));
      }
      await _writeMaster(tracks, variant?.bandwidth ?? 1000000);
      var failures = 0;
      while (!_stopped && DateTime.now().isBefore(endsAt)) {
        _keys.clear(); // A publisher may rotate a key behind the same URI.
        try {
          await Future.wait(tracks.map((track) => _captureTrack(transport, track)));
          failures = 0;
          await _checkpoint(tracks, complete: false);
          if (tracks.every((track) => track.ended)) {
            break;
          }
          final delay = tracks.map((track) => track.targetDuration).reduce((a, b) => a < b ? a : b);
          final remaining = endsAt.difference(DateTime.now());
          if (remaining > Duration.zero) {
            final wait = Duration(milliseconds: (delay * 500).clamp(250, 4000).toInt());
            await Future<void>.delayed(wait < remaining ? wait : remaining);
          }
        } on Object {
          if (_stopped || !DateTime.now().isBefore(endsAt)) {
            break;
          }
          if (++failures > 3) {
            rethrow;
          }
          await Future<void>.delayed(Duration(seconds: failures));
        }
      }
      if (tracks.any((track) => track.segments.isEmpty)) {
        throw const FileSystemException('No media received for an HLS recording track');
      }
      succeeded = true;
    } finally {
      _keys.clear();
      transport.close();
      _transport = null;
      // Every published playlist describes only fully written/decrypted files.
      // Even a failed capture remains a valid finite archive of retained data.
      for (final track in tracks) {
        await _writeTrack(track, complete: true);
      }
      await _checkpoint(tracks, complete: succeeded && !_stopped);
    }
  }

  Future<void> _captureTrack(SourceTransport transport, _ArchiveTrack track) async {
    final page = await _playlist(transport, track.uri);
    final parsed = _parse(page.text, page.base);
    track.targetDuration = parsed.targetDuration;
    track.ended = parsed.ended;
    for (final segment in parsed.segments) {
      if (_stopped || !DateTime.now().isBefore(endsAt)) {
        break;
      }
      final identity =
          '${segment.continuity}:${segment.sequence}:${segment.uri}:${segment.range?.offset}:${segment.range?.length}';
      if (track.seen.contains(identity)) {
        continue;
      }
      if (track.segments.length >= 50000) {
        throw const SourceException(SourceFailure.invalidData);
      }
      String? mapName;
      final map = segment.map;
      if (map != null) {
        final mapIdentity =
            '${segment.continuity}:${map.uri}:${map.range?.offset}:${map.range?.length}:${map.key?.uri}:'
            '${map.key?.iv == null ? '' : base64Encode(map.key!.iv!)}';
        mapName = track.maps[mapIdentity];
        if (mapName == null) {
          final bytes = await _resource(transport, map.uri, map.range);
          final decoded = map.key == null
              ? bytes
              : _decrypt(
                  bytes,
                  await _key(transport, map.key!.uri),
                  map.key!.iv ?? (throw UnsupportedError('Encrypted HLS maps require an explicit IV')),
                );
          mapName = '${track.name}-map-${track.maps.length}.bin';
          await _writeMedia(mapName, decoded);
          track.maps[mapIdentity] = mapName;
        }
      }
      final bytes = await _resource(transport, segment.uri, segment.range);
      final decoded = segment.key == null
          ? bytes
          : _decrypt(bytes, await _key(transport, segment.key!.uri), segment.key!.iv ?? _sequenceIv(segment.sequence));
      final filename = '${track.name}-segment-${track.segments.length}.bin';
      await _writeMedia(filename, decoded);
      track.segments.add((
        name: filename,
        duration: segment.duration,
        startsAt: segment.startsAt,
        map: mapName,
        discontinuity:
            segment.discontinuity || (track.lastSequence != null && track.lastSequence! + 1 != segment.sequence),
      ));
      track.lastSequence = segment.sequence;
      if (segment.duration.ceil() > track.targetDuration) {
        track.targetDuration = segment.duration.ceil();
      }
      track.seen.add(identity);
      if (track.segments.length == 1 ||
          DateTime.now().difference(track.lastPublishedAt) >= const Duration(seconds: 2)) {
        await _writeTrack(track, complete: false);
      }
    }
    await _writeTrack(track, complete: false);
  }

  Future<Uint8List> _resource(
    SourceTransport transport,
    Uri address,
    _Range? range, {
    int limit = 64 * 1024 * 1024,
  }) async {
    final abort = Completer<void>();
    final deadline = Timer(const Duration(seconds: 45), () => abort.complete());
    try {
      final response = await transport.send(
        'GET',
        address,
        headers: {
          ..._headers(address),
          if (range != null) 'Range': 'bytes=${range.offset}-${range.offset + range.length - 1}',
        },
        redirects: true,
        abort: abort.future,
      );
      SourceTransport.check(response.statusCode);
      if (range != null) {
        final expected = 'bytes ${range.offset}-${range.offset + range.length - 1}/';
        if (response.statusCode != 206 || !(response.headers['content-range'] ?? '').startsWith(expected)) {
          throw const FileSystemException('HLS server did not honor the byte range');
        }
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > limit) {
          throw const FileSystemException('HLS resource exceeds the capture bound');
        }
        bytes.add(chunk);
      }
      final value = bytes.takeBytes();
      if (value.isEmpty || (range != null && value.length != range.length)) {
        throw const FileSystemException('Incomplete HLS resource');
      }
      return value;
    } finally {
      deadline.cancel();
    }
  }

  Future<Uint8List> _key(SourceTransport transport, Uri address) async {
    final cached = _keys[address.toString()];
    if (cached != null) {
      return cached;
    }
    final bytes = await _resource(transport, address, null, limit: 16);
    if (bytes.length != 16) {
      throw const FileSystemException('Invalid HLS encryption key');
    }
    if (_keys.length >= 16) {
      _keys.remove(_keys.keys.first);
    }
    _keys[address.toString()] = bytes;
    return bytes;
  }

  Future<void> _writeMedia(String name, Uint8List bytes) async {
    if (bytes.isEmpty || mediaBytes + bytes.length > maximumBytes) {
      throw const FileSystemException('Recording storage budget exceeded');
    }
    final target = File(p.join(directory.path, name));
    final partial = File('${target.path}.partial');
    mediaBytes += bytes.length;
    try {
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(target.path);
    } catch (_) {
      mediaBytes -= bytes.length;
      rethrow;
    }
  }

  Future<void> _atomicText(File file, String text) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(file.path);
  }

  Future<void> _writeMaster(List<_ArchiveTrack> tracks, int bandwidth) async {
    final folder = p.basename(directory.path);
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(folder)) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final audio = tracks.length > 1;
    await _atomicText(
      output,
      '#EXTM3U\n#EXT-X-VERSION:7\n#PLEZY-ARCHIVE:$folder\n'
      '${audio ? '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="$folder/audio.m3u8"\n' : ''}'
      '#EXT-X-STREAM-INF:BANDWIDTH=$bandwidth${audio ? ',AUDIO="audio"' : ''}\n$folder/video.m3u8\n',
    );
  }

  Future<void> _writeTrack(_ArchiveTrack track, {required bool complete}) async {
    final text = StringBuffer(
      '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:${track.targetDuration}\n'
      '#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:${complete ? 'VOD' : 'EVENT'}\n',
    );
    String? previousMap;
    for (final segment in track.segments) {
      if (segment.discontinuity) {
        text.writeln('#EXT-X-DISCONTINUITY');
      }
      if (segment.map != previousMap && segment.map != null) {
        text.writeln('#EXT-X-MAP:URI="${segment.map}"');
      }
      previousMap = segment.map;
      if (segment.startsAt != null) {
        text.writeln('#EXT-X-PROGRAM-DATE-TIME:${segment.startsAt!.toUtc().toIso8601String()}');
      }
      text.writeln('#EXTINF:${segment.duration.toStringAsFixed(6)},');
      text.writeln(segment.name);
    }
    if (complete) {
      text.writeln('#EXT-X-ENDLIST');
    }
    await _atomicText(File(p.join(directory.path, '${track.name}.m3u8')), text.toString());
    track.lastPublishedAt = DateTime.now();
  }

  Future<void> _checkpoint(List<_ArchiveTrack> tracks, {required bool complete}) => _atomicText(
    File(p.join(directory.path, 'recording.json')),
    jsonEncode({
      'version': 1,
      'mediaBytes': mediaBytes,
      'complete': complete,
      'tracks': {for (final track in tracks) track.name: track.segments.length},
    }),
  );

  /// Only an archive explicitly created beside this recording can be removed
  /// with it. A marker cannot name a parent, absolute path or symbolic link.
  static Future<Directory?> mediaDirectory(File manifest) async {
    if (!await manifest.exists()) {
      return null;
    }
    final input = await manifest.open();
    final String prefix;
    try {
      prefix = utf8.decode(await input.read(8192), allowMalformed: true);
    } finally {
      await input.close();
    }
    final match = RegExp(r'^#PLEZY-ARCHIVE:([A-Za-z0-9_.-]+\.media)$', multiLine: true).firstMatch(prefix);
    if (match == null || match.group(1)!.length > 160) {
      return null;
    }
    final folder = Directory(p.join(manifest.parent.path, match.group(1)!));
    return await FileSystemEntity.type(folder.path, followLinks: false) == FileSystemEntityType.directory
        ? folder
        : null;
  }

  static Future<int> retainedBytes(File manifest) async {
    final folder = await mediaDirectory(manifest);
    if (folder == null) {
      if (!await manifest.exists()) {
        return 0;
      }
      final input = await manifest.open();
      final String prefix;
      try {
        prefix = utf8.decode(await input.read(8192), allowMalformed: true);
      } finally {
        await input.close();
      }
      // An archive's master playlist contains no media. Missing or linked
      // payload directories must not turn those metadata bytes into a capture.
      if (prefix.startsWith('#EXTM3U') && RegExp(r'^#PLEZY-ARCHIVE:', multiLine: true).hasMatch(prefix)) {
        return 0;
      }
      return manifest.length();
    }
    final video = File(p.join(folder.path, 'video.m3u8'));
    if (!await video.exists() ||
        await video.length() > 16 * 1024 * 1024 ||
        !(await video.readAsString()).contains('#EXTINF:')) {
      return 0;
    }
    var bytes = 0, entries = 0;
    await for (final file in folder.list(followLinks: false)) {
      if (++entries > 100100) {
        throw const FileSystemException('Recording archive contains too many files');
      }
      if (file is File && p.extension(file.path) == '.bin') {
        bytes += await file.length();
      }
    }
    return bytes;
  }

  static Future<void> finalizeInterrupted(File manifest) async {
    final folder = await mediaDirectory(manifest);
    if (folder == null) {
      return;
    }
    for (final name in const ['video', 'audio']) {
      final playlist = File(p.join(folder.path, '$name.m3u8'));
      if (!await playlist.exists() || await playlist.length() > 16 * 1024 * 1024) {
        continue;
      }
      var text = await playlist.readAsString();
      if (!text.startsWith('#EXTM3U')) {
        continue;
      }
      text = text.replaceAll('#EXT-X-PLAYLIST-TYPE:EVENT', '#EXT-X-PLAYLIST-TYPE:VOD');
      if (!text.contains('#EXT-X-ENDLIST')) {
        text = '${text.trimRight()}\n#EXT-X-ENDLIST\n';
      }
      final temporary = File('${playlist.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(playlist.path);
    }
  }

  static Map<String, String> _attributes(String value) => {
    for (final match in RegExp(r'([A-Za-z0-9-]+)=((?:"[^"]*")|[^,]*)').allMatches(value))
      match.group(1)!.toUpperCase(): match.group(2)!.startsWith('"')
          ? match.group(2)!.substring(1, match.group(2)!.length - 1)
          : match.group(2)!.trim(),
  };

  static ({Uri uri, Uri? audio, int bandwidth})? _variant(String text, Uri base) {
    final audio = <String, Uri>{};
    final variants = <({Uri uri, String? group, int bandwidth})>[];
    Map<String, String>? pending;
    for (final line in const LineSplitter().convert(text).map((line) => line.trim())) {
      if (line.startsWith('#EXT-X-MEDIA:')) {
        final values = _attributes(line.substring(13));
        final group = values['GROUP-ID'], path = values['URI'];
        if (values['TYPE'] == 'AUDIO' &&
            group != null &&
            path != null &&
            (!audio.containsKey(group) || values['DEFAULT'] == 'YES')) {
          audio[group] = base.resolve(path);
        }
      } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pending = _attributes(line.substring(18));
      } else if (pending != null && line.isNotEmpty && !line.startsWith('#')) {
        variants.add((
          uri: base.resolve(line),
          group: pending['AUDIO'],
          bandwidth: int.tryParse(pending['BANDWIDTH'] ?? '') ?? 1000000,
        ));
        pending = null;
      }
    }
    if (variants.isEmpty) {
      return null;
    }
    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    final selected = variants.first;
    if (selected.group != null && !audio.containsKey(selected.group)) {
      // An AUDIO group without a URI denotes in-band audio and needs no
      // second playlist; absent groups are handled by the normal video path.
      return (uri: selected.uri, audio: null, bandwidth: selected.bandwidth);
    }
    return (uri: selected.uri, audio: audio[selected.group], bandwidth: selected.bandwidth);
  }

  static ({List<_Segment> segments, int targetDuration, bool ended}) _parse(String text, Uri base) {
    var sequence = 0, target = 4, continuity = 0;
    DateTime? startsAt;
    var ended = false, discontinuity = false;
    var duration = 0.0;
    _Encryption? key;
    _MapResource? map;
    String? byteRange;
    final offsets = <String, int>{};
    final segments = <_Segment>[];
    for (final line in const LineSplitter().convert(text).map((line) => line.trim())) {
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = int.tryParse(line.substring(22)) ?? 0;
      } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        target = (int.tryParse(line.substring(22)) ?? 4).clamp(1, 120).toInt();
      } else if (line.startsWith('#EXTINF:')) {
        duration = double.tryParse(line.substring(8).split(',').first) ?? 0;
      } else if (line == '#EXT-X-DISCONTINUITY') {
        discontinuity = true;
        continuity++;
      } else if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')) {
        continuity = int.tryParse(line.substring('#EXT-X-DISCONTINUITY-SEQUENCE:'.length)) ?? 0;
      } else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
        startsAt = DateTime.tryParse(line.substring('#EXT-X-PROGRAM-DATE-TIME:'.length));
      } else if (line.startsWith('#EXT-X-KEY:')) {
        final values = _attributes(line.substring(11));
        if (values['METHOD'] == 'NONE') {
          key = null;
        } else if (values['METHOD'] == 'AES-128' &&
            values['URI'] != null &&
            (values['KEYFORMAT'] == null || values['KEYFORMAT'] == 'identity')) {
          key = _Encryption(base.resolve(values['URI']!), _iv(values['IV']));
        } else {
          throw UnsupportedError('Unsupported HLS encryption method');
        }
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final values = _attributes(line.substring(11));
        final path = values['URI'];
        if (path == null) {
          throw const SourceException(SourceFailure.invalidData);
        }
        final address = base.resolve(path);
        map = _MapResource(address, _range(values['BYTERANGE'], address, offsets), key);
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        byteRange = line.substring(17);
      } else if (line == '#EXT-X-ENDLIST') {
        ended = true;
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        if (!duration.isFinite || duration <= 0 || duration > 120 || segments.length >= 50000) {
          throw const SourceException(SourceFailure.invalidData);
        }
        final address = base.resolve(line);
        segments.add(
          _Segment(
            address,
            sequence + segments.length,
            duration,
            _range(byteRange, address, offsets),
            key,
            map,
            discontinuity,
            continuity,
            startsAt,
          ),
        );
        if (startsAt != null) {
          startsAt = startsAt.add(Duration(microseconds: (duration * 1000000).round()));
        }
        byteRange = null;
        discontinuity = false;
        duration = 0;
      }
    }
    return (segments: segments, targetDuration: target, ended: ended);
  }

  static _Range? _range(String? value, Uri address, Map<String, int> offsets) {
    if (value == null) {
      return null;
    }
    final match = RegExp(r'^(\d+)(?:@(\d+))?$').firstMatch(value.trim());
    final length = int.tryParse(match?.group(1) ?? '');
    final offset = match?.group(2) == null ? offsets[address.toString()] : int.tryParse(match!.group(2)!);
    if (length == null || length <= 0 || offset == null || offset < 0) {
      throw const FileSystemException('Invalid HLS byte range');
    }
    offsets[address.toString()] = offset + length;
    return _Range(offset, length);
  }

  static Uint8List? _iv(String? raw) {
    if (raw == null) {
      return null;
    }
    final value = raw.toLowerCase().replaceFirst(RegExp(r'^0x'), '');
    if (!RegExp(r'^[a-f0-9]{1,32}$').hasMatch(value)) {
      throw const FormatException('Invalid HLS IV');
    }
    final padded = value.padLeft(32, '0');
    return Uint8List.fromList([for (var i = 0; i < 32; i += 2) int.parse(padded.substring(i, i + 2), radix: 16)]);
  }

  static Uint8List _sequenceIv(int sequence) {
    if (sequence < 0) {
      throw const FormatException('Invalid HLS sequence');
    }
    final value = Uint8List(16);
    for (var i = 15; i >= 0 && sequence > 0; i--, sequence >>= 8) {
      value[i] = sequence & 255;
    }
    return value;
  }

  static Uint8List _decrypt(Uint8List bytes, Uint8List key, Uint8List iv) {
    if (bytes.isEmpty || bytes.length % 16 != 0 || key.length != 16 || iv.length != 16) {
      throw const FormatException('Invalid AES-128 HLS resource');
    }
    final cipher = CBCBlockCipher(AESEngine())..init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
    final output = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i += 16) {
      cipher.processBlock(bytes, i, output, i);
    }
    final padding = output.last;
    if (padding < 1 || padding > 16 || !output.sublist(output.length - padding).every((b) => b == padding)) {
      throw const FormatException('Invalid AES-128 HLS padding');
    }
    return Uint8List.sublistView(output, 0, output.length - padding);
  }
}

class _ArchiveTrack {
  _ArchiveTrack(this.uri, this.name);
  final Uri uri;
  final String name;
  int targetDuration = 4;
  bool ended = false;
  int? lastSequence;
  DateTime lastPublishedAt = DateTime.fromMillisecondsSinceEpoch(0);
  final seen = <String>{};
  final maps = <String, String>{};
  final segments = <({String name, double duration, String? map, bool discontinuity, DateTime? startsAt})>[];
}

class _Range {
  const _Range(this.offset, this.length);
  final int offset, length;
}

class _Encryption {
  const _Encryption(this.uri, this.iv);
  final Uri uri;
  final Uint8List? iv;
}

class _MapResource {
  const _MapResource(this.uri, this.range, this.key);
  final Uri uri;
  final _Range? range;
  final _Encryption? key;
}

class _Segment {
  const _Segment(
    this.uri,
    this.sequence,
    this.duration,
    this.range,
    this.key,
    this.map,
    this.discontinuity,
    this.continuity,
    this.startsAt,
  );
  final Uri uri;
  final int sequence;
  final double duration;
  final _Range? range;
  final _Encryption? key;
  final _MapResource? map;
  final bool discontinuity;
  final int continuity;
  final DateTime? startsAt;
}
