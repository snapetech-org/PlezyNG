import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import 'music_account_scope.dart';
import 'music_library_store.dart';

/// A small navigation reference, never a stream, credential or serialized server
/// response. Cached presentation belongs to one exact profile/account scope.
class MusicHomePin {
  const MusicHomePin({required this.id, required this.account, required this.item, required this.order});
  final String id, account;
  final MediaItem item;
  final int order;
  static const kinds = [MediaKind.artist, MediaKind.album, MediaKind.track];
  static bool _identifier(String value, int maximum) =>
      value.isNotEmpty && value.length <= maximum && !RegExp(r'[\x00-\x20?&#]|://').hasMatch(value);
  static String key(String account, MediaItem item) =>
      sha256.convert(utf8.encode(jsonEncode([account, item.serverId, item.kind.name, item.id]))).toString();
  static void validate(String account, MediaItem item, int order) {
    if (account.isEmpty ||
        account.length > 4096 ||
        !kinds.contains(item.kind) ||
        !_identifier(item.id, 1024) ||
        !_identifier(item.serverId ?? '', 1024) ||
        !_identifier(item.libraryId ?? '', 1024) ||
        item.displayTitle.length > 512 ||
        order < 0 ||
        order > 1000000) {
      throw const FormatException('Invalid music home pin');
    }
  }

  factory MusicHomePin.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1 ||
        value['id'] is! String ||
        value['account'] is! String ||
        value['mediaId'] is! String ||
        value['server'] is! String ||
        value['library'] is! String ||
        value['title'] is! String ||
        value['order'] is! int) {
      throw const FormatException('Invalid music home pin');
    }
    final kind = MediaKind.values.where((kind) => kind.name == value['kind']).firstOrNull;
    final backend = MediaBackend.values.where((backend) => backend.name == value['backend']).firstOrNull;
    if (kind == null || backend == null) throw const FormatException('Invalid music home pin');
    final item = MediaItem(
      id: value['mediaId'],
      backend: backend,
      kind: kind,
      serverId: value['server'],
      libraryId: value['library'],
      title: value['title'],
    );
    final account = value['account'] as String, order = value['order'] as int;
    validate(account, item, order);
    if (key(account, item) != value['id']) throw const FormatException('Invalid music home pin identity');
    return MusicHomePin(id: value['id'], account: account, item: item, order: order);
  }
  Map<String, Object> toJson() {
    validate(account, item, order);
    if (id != key(account, item)) throw const FormatException("Invalid music pin identity");
    return {
      'version': 1,
      'id': id,
      'account': account,
      'mediaId': item.id,
      'server': item.serverId!,
      'library': item.libraryId!,
      'backend': item.backend.name,
      'kind': item.kind.name,
      'title': item.displayTitle,
      'order': order,
    };
  }
}

/// Profile-owned bounded pins, with serialized mutations and fresh authorized
/// metadata before creation. Display references never grant playback authority.
class MusicHomePins extends ChangeNotifier {
  MusicHomePins({required this.store, required this.clientFor, this.visible, this.ready});
  final MusicLibraryStore store;
  final MediaServerClient? Function(MediaItem) clientFor;
  final bool Function(MediaItem)? visible;
  final Future<void> Function()? ready;
  static const limit = 100, profileLimit = 500;
  bool _closed = false;
  int _queued = 0;
  Future<void> _tail = Future.value();
  bool get _active => !_closed && store.active;
  bool _authorized(MusicHomePin pin) {
    final client = clientFor(pin.item);
    return _active &&
        pin.id == MusicHomePin.key(pin.account, pin.item) &&
        client != null &&
        client.serverId == pin.item.serverId &&
        musicAccountScope(client) == pin.account &&
        visible?.call(pin.item) != false;
  }

  void refresh() {
    if (_active) notifyListeners();
  }

  Future<List<MusicHomePin>> _all() async {
    final rows = await store.documents('homePin', limit: profileLimit);
    final result = <MusicHomePin>[];
    for (final row in rows) {
      try {
        result.add(MusicHomePin.fromJson(row));
      } on FormatException {
        continue;
      }
    }
    result.sort((a, b) {
      final order = a.order.compareTo(b.order);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return result;
  }

  Future<List<MusicHomePin>> load() async {
    if (!_active) return const [];
    await ready?.call();
    final pins = await _all();
    return _active ? pins.where(_authorized).take(limit).toList(growable: false) : const [];
  }

  Future<T> _change<T>(Future<T> Function() action) {
    if (_queued >= 32) return Future.error(StateError('Music home pin queue full'));
    _queued++;
    final operation = _tail.then((_) async {
      if (!_active) throw StateError('Music profile unavailable');
      return action();
    });
    final settled = operation.whenComplete(() => _queued--);
    _tail = settled.then<void>((_) {}, onError: (Object _) {});
    return settled;
  }

  Future<MusicHomePin> save(MediaItem seed) {
    final client = clientFor(seed);
    final authentication = client?.authenticationSessionId;
    final account = client == null ? null : musicAccountScope(client);
    bool current() =>
        _active &&
        client != null &&
        identical(client, clientFor(seed)) &&
        identical(authentication, client.authenticationSessionId) &&
        account == musicAccountScope(client);
    if (!current() || client!.isOfflineMode || !MusicHomePin.kinds.contains(seed.kind)) {
      throw StateError('Authorized music metadata unavailable');
    }
    return _change(() async {
      await ready?.call();
      if (!current()) throw StateError('Music account changed');
      final item = await client.fetchItem(seed.id);
      if (!current() ||
          item == null ||
          item.id != seed.id ||
          item.kind != seed.kind ||
          item.backend != seed.backend ||
          item.serverId != client.serverId ||
          visible?.call(item) == false) {
        throw StateError('Music metadata unavailable');
      }
      final all = await _all();
      if (!current()) throw StateError('Music account changed');
      final count = await store.database
          .customSelect(
            'SELECT COUNT(*) AS n FROM music_documents WHERE profile_id=? AND kind=?',
            variables: [Variable(store.profileId), Variable('homePin')],
          )
          .getSingle();
      if (!current()) throw StateError('Music account changed');
      final id = MusicHomePin.key(account!, item), previous = all.where((pin) => pin.id == id).firstOrNull;
      if (previous == null &&
          (count.read<int>('n') >= profileLimit || all.where((pin) => pin.account == account).length >= limit)) {
        throw StateError('Music home pin limit reached');
      }
      final order =
          previous?.order ?? (all.isEmpty ? 0 : all.map((pin) => pin.order).reduce((a, b) => a > b ? a : b) + 1);
      final pin = MusicHomePin(id: id, account: account, item: item, order: order);
      await store.database.transaction(() async {
        if (!current()) throw StateError('Music account changed');
        await store.saveDocument('homePin', id, pin.toJson());
        if (!current()) throw StateError('Music account changed');
      });
      if (current()) notifyListeners();
      return pin;
    });
  }

  Future<void> remove(MusicHomePin pin) {
    final client = clientFor(pin.item);
    final authentication = client?.authenticationSessionId;
    bool current() =>
        _authorized(pin) &&
        identical(client, clientFor(pin.item)) &&
        identical(authentication, client?.authenticationSessionId);
    return _change(() async {
      if (!current()) throw StateError('Music pin account changed');
      await store.database.transaction(() async {
        await store.deleteDocument('homePin', pin.id);
        if (!current()) throw StateError('Music pin account changed');
      });
      if (current()) notifyListeners();
    });
  }

  ({MediaServerClient? client, Object? authentication}) _binding(MusicHomePin pin) {
    final client = clientFor(pin.item);
    return (client: client, authentication: client?.authenticationSessionId);
  }

  /// Re-authorize a navigation reference before using an existing detail route.
  Future<MediaItem> resolve(MusicHomePin pin) async {
    final binding = _binding(pin);
    bool current() =>
        _authorized(pin) &&
        identical(binding.client, clientFor(pin.item)) &&
        identical(binding.authentication, binding.client?.authenticationSessionId);
    await ready?.call();
    if (!current() || binding.client!.isOfflineMode) throw StateError('Music pin unavailable');
    final item = await binding.client!.fetchItem(pin.item.id);
    if (!current() ||
        item == null ||
        item.id != pin.item.id ||
        item.serverId != pin.item.serverId ||
        item.kind != pin.item.kind ||
        item.backend != pin.item.backend ||
        item.libraryId != pin.item.libraryId ||
        visible?.call(item) == false) {
      throw StateError('Music pin unavailable');
    }
    return item;
  }

  Future<void> reorder(List<MusicHomePin> pins) {
    final copy = List<MusicHomePin>.unmodifiable(pins);
    final bindings = [for (final pin in copy) _binding(pin)];
    bool current() =>
        _active &&
        copy.indexed.every((entry) {
          final binding = bindings[entry.$1], pin = entry.$2, client = clientFor(pin.item);
          return _authorized(pin) &&
              identical(client, binding.client) &&
              identical(client?.authenticationSessionId, binding.authentication);
        });
    return _change(() async {
      await ready?.call();
      final existing = await load();
      if (!current() ||
          copy.length != existing.length ||
          copy.map((pin) => pin.id).toSet().length != copy.length ||
          !copy.every((pin) => existing.any((value) => value.id == pin.id))) {
        throw StateError('Music pin selection changed');
      }
      await store.database.transaction(() async {
        for (final entry in copy.indexed) {
          if (!current()) throw StateError('Music pin account changed');
          final pin = entry.$2;
          await store.saveDocument(
            'homePin',
            pin.id,
            MusicHomePin(id: pin.id, account: pin.account, item: pin.item, order: entry.$1).toJson(),
          );
        }
        if (!current()) throw StateError('Music pin account changed');
      });
      if (current()) notifyListeners();
    });
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
