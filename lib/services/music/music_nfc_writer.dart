import 'package:flutter/services.dart';

import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../deep_links/item_links.dart';

class MusicNfcWriter {
  const MusicNfcWriter([this._channel = const MethodChannel('com.pleazyng/music_nfc')]);
  final MethodChannel _channel;

  Future<bool> get available async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> write(MediaItem item) async {
    if (!const [MediaKind.artist, MediaKind.album, MediaKind.track].contains(item.kind)) {
      throw ArgumentError('Not a music item');
    }
    final uri = serverItemLink(item)?.toUri();
    if (uri == null) throw ArgumentError('Music identity unavailable');
    try {
      return await _channel.invokeMethod<bool>('write', {'uri': uri.toString()}) ?? false;
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') return false;
      rethrow;
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
