import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../sources/source_database.dart';
import '../sources/source_models.dart';
import '../sources/sync/sync_document.dart';
import '../sources/sync/sync_store.dart';
import 'subtitle_revision_service.dart';
import 'subtitle_portable_defaults.dart';

class SubtitleSyncChoice {
  SubtitleSyncChoice(this.version, this.digest, this.bytes, this.parts);
  final SyncVersion version;
  final String digest;
  final int bytes;
  final List<String> parts;
  String get device => version.actor?.substring(0, 8) ?? 'combined';
}

/// Explicit, profile/item-paired synchronization of reviewed subtitles and
/// portable caption defaults.
/// Reuses the existing AES-GCM envelope, causal register and source transports.
/// Server IDs, source URLs, account credentials and media bytes are never sent.
/// There is no background selection, playback mutation, or wall-clock winner.
class SubtitleCloudSync {
  SubtitleCloudSync({required this.repository, required this.identity,
    required this.store, required String code, required this.check, this.defaults = false})
      : cipher = _cipher(code, defaults);
  final SourceRepository repository;
  final SubtitleRevisionIdentity identity;
  final SyncStore store;
  final SyncCipher cipher;
  final void Function() check;
  final bool defaults;
  static SyncCipher _cipher(String code, bool defaults) {
    if (!defaults) return SyncCipher(code);
    // A purpose-derived key keeps profile presets in a separate encrypted
    // namespace even if a viewer accidentally reuses a revision pairing code.
    final key = Hmac(sha256, SyncCipher.decodeCode(code)).convert(utf8.encode('plezyng.subtitle-defaults.v1')).bytes;
    return SyncCipher(base64UrlEncode(key));
  }
  static SubtitleRevisionIdentity defaultsIdentity(String profileId) => SubtitleRevisionIdentity(
    profileId: profileId, serverId: 'plezyng.subtitle-defaults.v1', ratingKey: 'profile-defaults', mediaIndex: 0);
  static final _active = <String>{};
  String get _choiceType => defaults ? 'plezyng.subtitle-defaults-choice.v1' : 'plezyng.subtitle-choice.v1';
  String get _partType => defaults ? 'plezyng.subtitle-defaults-part.v1' : 'plezyng.subtitle-part.v1';
  String get _record => sourceDigest(_choiceType);
  int get _maximumBytes => defaults ? SubtitlePortableDefaults.maximumBytes : SubtitleRevisionService.maximumRevisionBytes;
  static const _chunkBytes = 1024 * 1024;
  static final _hex = RegExp(r'^[0-9a-f]{64}$');
  String get _cacheKey => 'subtitle-sync-cache.v1:${identity.storageKey}:${cipher.namespace}';
  static String _pairKey(SubtitleRevisionIdentity identity) => 'subtitle-sync-pair.v1:${identity.storageKey}';
  static Future<String?> pairedCode(SourceRepository repository, SubtitleRevisionIdentity identity) async {
    final value = (await repository.privatePreference(identity.profileId, _pairKey(identity)))['code'];
    if (value is! String) return null;
    SyncCipher(value); return value;
  }
  static Future<void> pair(SourceRepository repository, SubtitleRevisionIdentity identity, String? code) async {
    if (code == null) { await repository.forgetPreference(identity.profileId, _pairKey(identity)); return; }
    SyncCipher(code);
    await repository.savePrivatePreference(identity.profileId, _pairKey(identity), {'code': code.trim()});
  }

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    final key = '${identity.profileId}:$_cacheKey';
    check();
    if (!_active.add(key)) throw StateError('Subtitle synchronization is already running for this item');
    try { return await body(); } finally { _active.remove(key); }
  }
  Future<_SubtitleSyncCache> _load() async {
    final cache = _SubtitleSyncCache(await repository.preference(identity.profileId, _cacheKey));
    _choices(cache.document); check(); return cache;
  }
  Future<void> _save(_SubtitleSyncCache cache) async {
    check();
    SyncDocument.fromJson(cache.document.toJson());
    if (utf8.encode(canonicalSyncJson(cache.document.toJson())).length > SyncDocument.maxBytes) throw const FormatException('Subtitle sync metadata limit');
    await repository.savePreference(identity.profileId, _cacheKey, cache.toJson()); check();
  }
  Future<String> _device() async {
    final saved = await repository.preference(identity.profileId, 'subtitle-sync-device.v1');
    final id = saved['id'] as String? ?? const Uuid().v4().replaceAll('-', '');
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) throw const FormatException('Invalid subtitle sync device');
    check(); await repository.savePreference(identity.profileId, 'subtitle-sync-device.v1', {'id': id}); check(); return id;
  }

  List<SubtitleSyncChoice> _choices(SyncDocument document) {
    if (document.records.keys.any((key) => key != _record)) throw const FormatException('Not a subtitle synchronization document');
    return [for (final version in document.records[_record] ?? <SyncVersion>[]) _choice(version)];
  }
  SubtitleSyncChoice _choice(SyncVersion version) {
    final value = version.value, bytes = version.value['bytes'], digest = version.value['digest'], parts = version.value['parts'];
    if (value['type'] != _choiceType || digest is! String || !_hex.hasMatch(digest) ||
        bytes is! int || bytes < 1 || bytes > _maximumBytes || parts is! List ||
        parts.length != (bytes + _chunkBytes - 1) ~/ _chunkBytes ||
        parts.any((part) => part is! String || !_hex.hasMatch(part))) throw const FormatException('Invalid subtitle sync asset descriptor');
    return SubtitleSyncChoice(version, digest, bytes, parts.cast<String>());
  }
  static Uint8List _content(SubtitleRevision revision) {
    // Device-local creation IDs and wall clocks are not subtitle semantics.
    // Equivalent reviewed text/timing from two devices converges by content.
    final normalized = {...revision.toJson(), 'id': '0_0', 'createdAt': '2000-01-01T00:00:00.000Z', 'operation': 'Shared reviewed subtitle'};
    final canonical = SubtitleRevision.fromJson(normalized).toJson();
    final bytes = Uint8List.fromList(utf8.encode(canonicalSyncJson(canonical)));
    if (bytes.length > SubtitleRevisionService.maximumRevisionBytes) throw const FormatException('Subtitle sync asset exceeds 8 MiB');
    return bytes;
  }
  String _blobNamespace(String digest) => sourceDigest('${cipher.namespace}:subtitle-blob:$digest').substring(0, 24);
  String _blobName(String digest, int index) => SyncFile.filename(_blobNamespace(digest), digest.substring(0, 32), index + 1);

  Future<Map<String, dynamic>> _upload(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > _maximumBytes) throw const FormatException('Subtitle sync asset size limit');
    final digest = sha256.convert(bytes).toString();
    final parts = <String>[];
    final files = await store.list(_blobNamespace(digest)); check();
    if (files.length > 256) throw const FormatException('Too many duplicate subtitle asset chunks');
    for (var offset = 0; offset < bytes.length; offset += _chunkBytes) {
      check();
      final index = parts.length, end = offset + _chunkBytes < bytes.length ? offset + _chunkBytes : bytes.length;
      final chunk = Uint8List.sublistView(bytes, offset, end), hash = sha256.convert(Uint8List.sublistView(bytes, offset, end)).toString();
      parts.add(hash);
      final name = _blobName(digest, index);
      final existing = files.where((file) => file.name == name).firstOrNull;
      if (existing != null) {
        await _readChunk(existing, digest, index, hash, chunk.length);
        continue;
      }
      final payload = SyncDocument({_record: [SyncVersion({digest.substring(0, 32): index + 1}, {
        'type': _partType, 'digest': digest, 'index': index, 'sha256': hash, 'data': base64Encode(chunk),
      })]});
      final encrypted = await cipher.seal(payload, name); check();
      await store.create(name, encrypted); check();
    }
    return {'type': _choiceType, 'digest': digest, 'bytes': bytes.length, 'parts': parts};
  }
  Future<Uint8List> _readChunk(SyncFile file, String digest, int index, String expectedHash, int expectedBytes) async {
    check();
    final document = await cipher.open(await store.read(file), file.name); check();
    if (document.records.length != 1 || document.records[_record]?.length != 1) throw const FormatException('Invalid subtitle asset chunk');
    final value = document.records[_record]!.single.value;
    if (file.name != _blobName(digest, index) || value['type'] != _partType || value['digest'] != digest ||
        value['index'] != index || value['sha256'] != expectedHash || value['data'] is! String ||
        (value['data'] as String).length > ((expectedBytes + 2) ~/ 3) * 4) throw const FormatException('Subtitle asset chunk identity mismatch');
    final bytes = base64Decode(value['data'] as String);
    if (bytes.length != expectedBytes || sha256.convert(bytes).toString() != expectedHash) throw const FormatException('Subtitle asset chunk is corrupt');
    return bytes;
  }

  /// Publish only a user-selected reviewed revision. Pull alone can propagate
  /// already known causal metadata but never imports or selects a caption.
  Future<List<SubtitleSyncChoice>> synchronize({SubtitleRevision? publish, SubtitlePortableDefaults? publishDefaults}) => _exclusive(() async {
    if ((defaults && publish != null) || (!defaults && publishDefaults != null)) {
      throw ArgumentError('The content does not match this subtitle synchronization channel');
    }
    final cache = await _load(), device = await _device();
    if (publish != null || publishDefaults != null) {
      // Complete immutable blobs first. A failed upload does not leave a
      // durable register pointing to missing chunks or claim offline success.
      final bytes = publish != null ? _content(publish) : Uint8List.fromList(utf8.encode(
        canonicalSyncJson(jsonDecode(utf8.decode(publishDefaults!.encode())))));
      final descriptor = await _upload(bytes);
      if (cache.observed != descriptor['digest']) {
        final version = cache.document.edit(_record, device, descriptor, cache.basis);
        cache.basis = version.clock; cache.observed = descriptor['digest'] as String;
        await _save(cache);
      }
    }
    final listed = await store.list(cipher.namespace); check();
    if (listed.length > 4096) throw const FormatException('Subtitle sync generation limit');
    final latest = <String, int>{};
    for (final file in listed) {
      if (file.sequence > (latest[file.device] ?? -1)) latest[file.device] = file.sequence;
      if (file.device == device && file.sequence > cache.sequence) cache.sequence = file.sequence;
    }
    if (latest.length > 128) throw const FormatException('Subtitle sync device limit');
    var metadataBytes = 0;
    final duplicates = <String, int>{};
    for (final file in listed.where((file) => file.sequence == latest[file.device])) {
      check();
      duplicates[file.name] = (duplicates[file.name] ?? 0) + 1;
      if (duplicates[file.name]! > 4) throw const FormatException('Duplicate subtitle sync metadata limit');
      final text = await store.read(file);
      final length = utf8.encode(text).length;
      metadataBytes += length;
      if (length > 512 * 1024 || metadataBytes > 16 * 1024 * 1024) throw const FormatException('Subtitle sync metadata exceeds the transfer bound');
      final incoming = await cipher.open(text, file.name);
      _choices(incoming); check(); cache.document.merge(incoming);
    }
    final choices = _choices(cache.document);
    if (choices.length == 1 && choices.single.digest == cache.observed) {
      cache.basis = Map.of(choices.single.version.clock);
    }
    await _save(cache);
    final digest = sourceDigest(canonicalSyncJson(cache.document.toJson()));
    if (cache.document.records.isNotEmpty && (cache.published != digest || !latest.containsKey(device))) {
      cache.sequence++;
      if (cache.sequence > 9007199254740991) throw const FormatException('Subtitle sync sequence exhausted');
      await _save(cache);
      final name = SyncFile.filename(cipher.namespace, device, cache.sequence);
      final encrypted = await cipher.seal(cache.document, name); check();
      await store.create(name, encrypted); check();
      cache.published = digest; await _save(cache);
      final owned = listed.where((file) => file.device == device).toList()..sort((a, b) => b.sequence.compareTo(a.sequence));
      for (final file in owned.skip(1)) {
        check(); try { await store.delete(file); } catch (_) { check(); }
      }
    }
    return _choices(cache.document);
  });

  Future<Uint8List> _download(SubtitleSyncChoice choice) => _exclusive(() async {
    final cache = await _load(); _requireChoice(cache, choice);
    final listed = await store.list(_blobNamespace(choice.digest)); check();
    if (listed.length > 256) throw const FormatException('Subtitle chunk generation limit');
    final bytes = BytesBuilder(copy: false);
    for (var i = 0; i < choice.parts.length; i++) {
      final file = listed.where((file) => file.name == _blobName(choice.digest, i)).firstOrNull;
      if (file == null) throw StateError('A subtitle chunk is missing; the publishing device must retry');
      final remaining = choice.bytes - i * _chunkBytes;
      bytes.add(await _readChunk(file, choice.digest, i, choice.parts[i], remaining < _chunkBytes ? remaining : _chunkBytes));
    }
    final content = bytes.takeBytes();
    if (content.length != choice.bytes || sha256.convert(content).toString() != choice.digest) throw const FormatException('Subtitle asset digest mismatch');
    check(); return content;
  });
  Future<SubtitleRevision> download(SubtitleSyncChoice choice) async {
    if (defaults) throw StateError('This channel contains caption defaults');
    final content = await _download(choice);
    final revision = SubtitleRevision.fromJson(jsonDecode(utf8.decode(content, allowMalformed: false))); check(); return revision;
  }
  Future<SubtitlePortableDefaults> downloadDefaults(SubtitleSyncChoice choice) async {
    if (!defaults) throw StateError('This channel contains subtitle revisions');
    final content = await _download(choice);
    final result = SubtitlePortableDefaults.decode(content); check(); return result;
  }
  void _requireChoice(_SubtitleSyncCache cache, SubtitleSyncChoice choice) {
    if (!_choices(cache.document).any((value) => value.digest == choice.digest &&
        canonicalSyncJson(value.version.clock) == canonicalSyncJson(choice.version.clock))) {
      throw StateError('The subtitle choices changed; pull again before choosing');
    }
  }

  /// Import adds history under its existing retention limit and never changes playback.
  Future<void> importRevision(SubtitleSyncChoice choice, SubtitleRevision revision) => _exclusive(() async {
    if (defaults) throw StateError('This channel contains caption defaults');
    final cache = await _load(); _requireChoice(cache, choice);
    if (sha256.convert(_content(revision)).toString() != choice.digest) throw const FormatException('Reviewed sync content changed');
    check();
    await SubtitleRevisionService.saveRevision(identity: identity, operation: 'Imported encrypted subtitle sync',
      languageCode: revision.languageCode, cues: revision.cues, wordTimings: revision.wordTimings, onItemTimeline: revision.onItemTimeline);
    check(); cache.basis = Map.of(choice.version.clock); cache.observed = choice.digest; await _save(cache);
  });

  /// Resolve precisely the conflicts the user saw. A later unseen remote edit
  /// remains concurrent when it arrives; no timestamp or device is preferred.
  Future<List<SubtitleSyncChoice>> resolve(SubtitleSyncChoice choice, {required List<SubtitleSyncChoice> observedChoices}) async {
    await _exclusive(() async {
      final cache = await _load(); _requireChoice(cache, choice);
      List<String> snapshot(List<SubtitleSyncChoice> choices) => choices.map((choice) =>
          canonicalSyncJson(choice.version.toJson())).toList()..sort();
      if (canonicalSyncJson(snapshot(_choices(cache.document))) != canonicalSyncJson(snapshot(observedChoices))) {
        throw StateError('New subtitle choices arrived; pull and review them before resolving');
      }
      final version = cache.document.edit(_record, await _device(), choice.version.value,
          joinedClock(cache.document.records[_record] ?? []));
      cache.basis = version.clock; cache.observed = choice.digest; await _save(cache);
    });
    return synchronize();
  }
}

class _SubtitleSyncCache {
  _SubtitleSyncCache(Map<String, dynamic> value)
      : document = value['document'] == null ? SyncDocument() : SyncDocument.fromJson(sourceMap(value['document'])),
        basis = sourceMap(value['basis']).map((key, value) => MapEntry(key, value as int)),
        observed = value['observed'] as String? ?? '', published = value['published'] as String? ?? '',
        sequence = value['sequence'] as int? ?? 0;
  final SyncDocument document;
  Map<String, int> basis;
  String observed, published;
  int sequence;
  Map<String, dynamic> toJson() => {'document': document.toJson(), 'basis': basis,
    'observed': observed, 'published': published, 'sequence': sequence};
}
