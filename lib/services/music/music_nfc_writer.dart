import 'dart:convert';

import 'package:flutter/services.dart';

import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../deep_links/item_links.dart';

class MusicNfcWriter {
  const MusicNfcWriter([this._channel = const MethodChannel('com.pleazyng/music_nfc')]);
  final MethodChannel _channel;

  Future<bool> get available => _available('available');
  Future<bool> get readAvailable => _available('readAvailable');

  Future<bool> _available(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> write(MediaItem item, {String? prompt}) async {
    if (!const [MediaKind.artist, MediaKind.album, MediaKind.track].contains(item.kind)) {
      throw ArgumentError('Not a music item');
    }
    final uri = serverItemLink(item)?.toUri();
    if (uri == null) throw ArgumentError('Music identity unavailable');
    try {
      return await _channel.invokeMethod<bool>('write', {'uri': uri.toString(), 'prompt': ?prompt}) ?? false;
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') return false;
      rethrow;
    }
  }

  Future<Uri?> read({String? prompt}) async {
    try {
      final raw = await _channel.invokeMethod<String>('read', {'prompt': ?prompt});
      if (raw == null) return null;
      final uri = utf8.encode(raw).length <= 2048 ? Uri.tryParse(raw) : null;
      final params = uri?.queryParametersAll;
      if (uri == null ||
          uri.scheme != 'pleazyng' ||
          uri.host != 'play' ||
          uri.path.isNotEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          uri.hasFragment ||
          params?.length != 2 ||
          !['server', 'id'].every((key) => params?[key]?.length == 1 && params![key]!.single.trim().isNotEmpty)) {
        throw PlatformException(code: 'invalid_link');
      }
      return uri;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') return null;
      rethrow;
    } on FormatException {
      throw PlatformException(code: 'invalid_link');
    }
  }

  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}
