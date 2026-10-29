import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'subtitle_font_store.dart';
import 'subtitle_overlay_service.dart';
import 'subtitle_revision_service.dart';

/// A downloaded edition and opened part, revalidated by the download owner.
/// No raw server ID, path or credential is written to the retained document.
class SubtitleDownloadBinding {
  const SubtitleDownloadBinding({required this.globalKey, required this.profileId,
    required this.version, required this.partOffsetMs, required this.isCurrent});
  final String globalKey, profileId, version;
  final int partOffsetMs;
  final Future<bool> Function() isCurrent;
}

/// Two explicitly selected app lanes per downloaded part. Keeping the font
/// bytes with the document makes removal from the global font picker harmless.
/// Read/restore is explicit: opening media never installs arbitrary fonts.
abstract final class SubtitleDownloadAssets {
  static const maximumFileBytes = 32 * 1024 * 1024;
  static const maximumStoreBytes = 256 * 1024 * 1024;
  static Future<void> _tail = Future.value();
  static String digest(String value) => sha256.convert(utf8.encode(value)).toString();
  static Future<Directory> _root() async => Directory(p.join(
      (await getApplicationSupportDirectory()).path, 'subtitle_download_assets_v1'));
  static Future<Directory> _item(String key) async => Directory(p.join((await _root()).path, digest(key)));
  static Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
  static Future<File> _file(SubtitleDownloadBinding binding, int lane) async {
    if (lane < 0 || lane > 1 || binding.partOffsetMs < 0 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(binding.version)) throw ArgumentError('Invalid download binding');
    return File(p.join((await _item(binding.globalKey)).path,
        digest(binding.profileId), '${binding.version}_${binding.partOffsetMs}_$lane.json'));
  }
  static Future<int> _size(Directory directory) async {
    if (!await directory.exists()) return 0;
    var total = 0, entries = 0;
    await for (final entry in directory.list(recursive: true, followLinks: false)) {
      if (++entries > 12000) throw const FileSystemException('Subtitle download store entry limit');
      if (entry is File) total += await entry.length();
      if (entry is Link) throw const FileSystemException('Unexpected link in subtitle download store');
    }
    return total;
  }
  static Future<int> bytesFor(String globalKey) async => _size(await _item(globalKey));

  static Future<void> save(SubtitleDownloadBinding binding, int lane, SubtitleOverlayTrack track) => _serial(() async {
    if (track.positionToSourceMs != null || track.profileId != binding.profileId ||
        !track.isCurrent() || !await binding.isCurrent()) throw StateError('The downloaded subtitle scope changed');
    final appearance = track.appearance(), delay = track.delayMs;
    final revision = SubtitleRevision(id: '${DateTime.now().microsecondsSinceEpoch}_00',
      createdAt: DateTime.now().toUtc(), operation: track.title.length > 120 ? track.title.substring(0, 120) : track.title,
      languageCode: track.language, cues: track.cues, wordTimings: track.words, onItemTimeline: true);
    final store = SubtitleFontStore.instance;
    await store.initialize();
    final font = store.findFamily(track.fontFamily);
    final fontData = font == null ? null : await store.verifiedBytes(font);
    if (SubtitleFontStore.familyPattern.hasMatch(track.fontFamily) && font == null) {
      throw StateError('Restore or choose an available font before retaining this lane');
    }
    List<double> rect(Rect r) => [r.left, r.top, r.width, r.height];
    final document = <String, Object?>{'schema': 1, 'version': binding.version, 'partOffsetMs': binding.partOffsetMs,
      'lane': lane, 'revision': revision.toJson(), 'appearance': appearance, 'delayMs': delay,
      'regions': {for (final entry in track.regions.entries) entry.key: rect(entry.value)},
      'avoidRegions': {for (final entry in track.avoidRegions.entries) entry.key: entry.value.map(rect).toList()},
      'avoidObjects': track.avoidObjects,
      'font': font == null ? null : {'metadata': font.toJson(), 'data': base64Encode(fontData!)}};
    final bytes = utf8.encode(jsonEncode(document));
    if (bytes.length > maximumFileBytes) throw const FormatException('Retained captions and font exceed 32 MiB');
    final target = await _file(binding, lane);
    final partial = File('${target.path}.partial'), previous = File('${target.path}.previous');
    await target.parent.create(recursive: true);
    if (await partial.exists()) await partial.delete();
    // Include the committed and recovery copies, and reserve the new write.
    if (await _size(await _root()) + bytes.length > maximumStoreBytes) {
      throw StateError('Saved download captions exceed the 256 MiB quota. Remove retained captions first.');
    }
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (!track.isCurrent() || track.delayMs != delay || jsonEncode(track.appearance()) != jsonEncode(appearance) ||
          !await binding.isCurrent()) throw StateError('The subtitle or download changed before saving');
      if (await target.exists()) {
        if (await previous.exists()) await previous.delete();
        await target.rename(previous.path);
      }
      await partial.rename(target.path);
      if (!await binding.isCurrent()) {
        await target.delete();
        throw StateError('The download changed while retaining captions');
      }
    } finally { if (await partial.exists()) await partial.delete(); }
  });

  static Future<Uint8List> _read(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file ||
        await file.length() > maximumFileBytes) throw const FormatException('Invalid saved caption file');
    final data = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (data.length + chunk.length > maximumFileBytes) throw const FormatException('Saved caption size limit');
      data.add(chunk);
    }
    return data.takeBytes();
  }

  static Future<SubtitleOverlayTrack?> restore(SubtitleDownloadBinding binding, int lane,
      {required bool Function() isCurrent}) => _serial(() async {
    if (!isCurrent() || !await binding.isCurrent()) throw StateError('The download changed');
    final file = await _file(binding, lane);
    Map<String, dynamic>? document;
    Object? lastError;
    for (final candidate in [file, File('${file.path}.previous')]) {
      if (!await candidate.exists()) continue;
      try {
        final value = jsonDecode(utf8.decode(await _read(candidate)));
        if (value is! Map<String, dynamic> || value['schema'] != 1 || value['version'] != binding.version ||
            value['partOffsetMs'] != binding.partOffsetMs || value['lane'] != lane ||
            value['appearance'] is! Map<String, dynamic> || value['delayMs'] is! int ||
            (value['delayMs'] as int).abs() > 3600000) throw const FormatException('Invalid retained caption manifest');
        // Validate before accepting this generation so a corrupt current copy
        // can fall back to the previous committed document.
        SubtitleRevision.fromJson(value['revision']);
        document = value; break;
      } catch (error) { lastError = error; }
    }
    if (document == null) { if (lastError != null) throw lastError; return null; }
    final revision = SubtitleRevision.fromJson(document['revision']);
    if (!revision.onItemTimeline) throw const FormatException('Invalid retained caption clock');
    Rect rect(Object? value) {
      if (value is! List || value.length != 4 || value.any((v) => v is! num || !v.isFinite)) {
        throw const FormatException('Invalid retained caption geometry');
      }
      return Rect.fromLTWH((value[0] as num).toDouble(), (value[1] as num).toDouble(),
          (value[2] as num).toDouble(), (value[3] as num).toDouble());
    }
    final rawRegions = document['regions'], rawAvoid = document['avoidRegions'];
    if (rawRegions is! Map || rawAvoid is! Map || rawRegions.length > revision.cues.length ||
        rawAvoid.length > revision.cues.length) throw const FormatException('Invalid retained caption regions');
    final regions = <String, Rect>{}, avoid = <String, List<Rect>>{};
    for (final e in rawRegions.entries) {
      if (e.key is! String) throw const FormatException('Invalid caption region identity');
      regions[e.key as String] = rect(e.value);
    }
    for (final e in rawAvoid.entries) {
      if (e.key is! String || e.value is! List || (e.value as List).length > 12) throw const FormatException('Invalid caption avoidance');
      avoid[e.key as String] = (e.value as List).map(rect).toList();
    }
    final track = SubtitleOverlayTrack(cues: revision.cues, words: revision.wordTimings,
      title: revision.operation, language: revision.languageCode, profileId: binding.profileId,
      regions: regions, avoidRegions: avoid, isCurrent: isCurrent);
    track.applyAppearance(document['appearance'] as Map<String, dynamic>);
    track.delayMs = document['delayMs'] as int;
    track.avoidObjects = document['avoidObjects'] == true;
    final font = document['font'];
    if (font != null) {
      if (font is! Map || font['metadata'] is! Map || font['data'] is! String ||
          (font['data'] as String).length > 4 * ((SubtitleFontStore.maximumFontBytes + 2) ~/ 3)) {
        throw const FormatException('Invalid retained font');
      }
      final meta = font['metadata'] as Map, bytes = base64Decode(font['data'] as String);
      if (meta['bytes'] != bytes.length || meta['sha256'] != sha256.convert(bytes).toString() ||
          meta['label'] is! String || meta['license'] is! String || track.fontFamily != 'PlezyImported-${meta['sha256']}') {
        throw const FormatException('Retained font integrity mismatch');
      }
      if (!isCurrent() || !await binding.isCurrent()) throw StateError('The download changed');
      await SubtitleFontStore.instance.importBytes(bytes, label: meta['label'] as String, license: meta['license'] as String);
    }
    if (!isCurrent() || !await binding.isCurrent()) throw StateError('The download changed');
    return track;
  });

  static Future<void> remove(String globalKey, {String? profileId}) => _serial(() async {
    final item = await _item(globalKey);
    final target = profileId == null ? item : Directory(p.join(item.path, digest(profileId)));
    if (await target.exists()) await target.delete(recursive: true);
  });
}
