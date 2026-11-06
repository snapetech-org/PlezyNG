import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'karaoke_session.dart';

/// SeerrNG/relay transport-independent bridge. The host remains the sole queue
/// authority. An adapter may forward these envelopes over an authenticated
/// channel; tokens and media URLs never belong in them.
class KaraokeIntegrationBridge {
  KaraokeIntegrationBridge(this.session);
  final KaraokeSession session;
  static const protocol = 'plezyng.karaoke.v1';
  Map<String, dynamic> hello() => {
    'protocol': protocol,
    'authority': 'plezyng',
    'revision': session.revision,
    'epoch': session.epoch,
    'commands': ['request', 'cancel', 'approve', 'reorder', 'start', 'pause', 'resume', 'finish', 'seek', 'end'],
    'catalog': [
      for (final t in session.catalog.values)
        {
          'songId': t.songId,
          'renditionId': t.id,
          'title': t.title,
          'artist': t.artist,
          'packageDigest': sha256.convert(utf8.encode(jsonEncode(t.assets.map((a) => a.toJson()).toList()))).toString(),
          'readiness': t.assets.isEmpty ? 'source-dependent' : 'local-unverified',
        },
    ],
  };
  Future<Map<String, dynamic>> execute(Map<String, dynamic> envelope, {required bool hostAuthorized}) async {
    if (!hostAuthorized) {
      throw StateError('An authenticated host capability is required');
    }
    if (envelope['protocol'] != protocol || envelope['authority'] != 'plezyng') {
      throw const FormatException('Protocol/queue-authority mismatch');
    }
    final action = envelope['command'] as String;
    if (!{
      'request',
      'cancel',
      'approve',
      'reorder',
      'start',
      'pause',
      'resume',
      'finish',
      'seek',
      'end',
    }.contains(action)) {
      throw const FormatException('Unsupported integration command');
    }
    final result = await session.command(
      envelope['id'] as String,
      envelope['expectedRevision'] as int,
      action,
      Map<String, dynamic>.from(envelope['payload'] as Map),
    );
    return {
      'protocol': protocol,
      'id': envelope['id'],
      'ack': result,
      'playback': {
        'epoch': session.epoch,
        'playing': session.playing,
        'sourcePositionMs': session.positionMs.value,
        'renditionId': session.track?.id,
      },
    };
  }
}
