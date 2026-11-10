import 'dart:async';

import '../../media/media_item.dart';
import 'music_connect_channel.dart';
import 'music_device_session.dart';
import 'music_playback_service.dart';
import 'music_transfer_snapshot.dart';

/// The receiver keeps transaction receipts for its profile lifetime, across
/// controller reconnects. Repeating commit reads the receipt and cannot start
/// a second occurrence. Local queue/transport edits invalidate reservations.
class MusicDeviceEndpoint {
  MusicDeviceEndpoint(this.session, {required this.allowed});

  final MusicDeviceSession session;
  final bool Function() allowed;
  ({String ticket, PreparedMusicDeviceTransfer commit})? _prepared;
  Timer? _prepareExpiry;
  ({String ticket, String revision, bool playing})? _frozen;
  final Map<String, bool?> _commits = {};
  bool _closed = false;
  int _generation = 0;

  bool get current => !_closed && allowed();

  MusicConnectMessage _state(String? known) {
    final offer = session.offerTransfer();
    final volume = session.playback.volume;
    if (offer == null) {
      return {'ok': true, 'empty': true, 'revision': 'idle', 'position': 0, 'playing': false, 'volume': volume};
    }
    final revision = musicDeviceRevision(offer);
    return {
      'ok': true,
      'revision': revision,
      'position': offer.snapshot.position.inMilliseconds,
      'playing': offer.snapshot.playing,
      'volume': volume,
      if (known != revision) 'queue': offer.snapshot.toJson(itemLimit: MusicTransferSnapshot.maxTransferItems),
    };
  }

  Future<MusicConnectMessage?> handle(MusicConnectMessage message) async {
    if (!current) return null;
    switch (message['op']) {
      case 'state':
        return _state(message['revision'] as String?);
      case 'prepare':
        final snapshot = MusicTransferSnapshot.tryParse(
          message['queue'],
          itemLimit: MusicTransferSnapshot.maxTransferItems,
        );
        if (snapshot == null || session.musicDeviceOutput != null) return const {'ok': false};
        final generation = ++_generation;
        _cancelPreparation();
        final commit = await session.prepareMusicDeviceTransfer(
          snapshot,
          current: () => current && generation == _generation,
        );
        if (commit == null || !current || generation != _generation) return const {'ok': false};
        final ticket = newMusicConnectId();
        _prepared = (ticket: ticket, commit: commit);
        _prepareExpiry = Timer(const Duration(seconds: 45), () {
          _generation++;
          _cancelPreparation();
        });
        return {'ok': true, 'ticket': ticket};
      case 'cancel':
        if (_prepared?.ticket == message['ticket']) {
          _generation++;
          _cancelPreparation();
        }
        return const {'ok': true};
      case 'commit':
        final ticket = message['ticket'];
        if (!isMusicConnectId(ticket)) return const {'ok': false};
        if (_commits.containsKey(ticket)) {
          final result = _commits[ticket];
          return result == null ? const {'pending': true} : {'ok': result};
        }
        final prepared = _prepared;
        final position = message['position'];
        final play = message['playing'];
        if (prepared == null ||
            prepared.ticket != ticket ||
            position is! int ||
            position < 0 ||
            position > const Duration(hours: 24).inMilliseconds ||
            play is! bool) {
          return const {'ok': false};
        }
        _cancelPreparation();
        if (_commits.length >= 32) _commits.remove(_commits.keys.first);
        _commits[ticket as String] = null;
        var accepted = false;
        try {
          accepted = await prepared.commit(Duration(milliseconds: position), play);
        } finally {
          _commits[ticket] = accepted;
        }
        return {'ok': accepted};
      case 'freeze':
        final offer = session.offerTransfer();
        if (offer == null || message['revision'] != musicDeviceRevision(offer)) return const {'ok': false};
        if (!await session.finishTransfer(offer) || !current) return const {'ok': false};
        final paused = session.offerTransfer();
        if (paused == null) return const {'ok': false};
        final ticket = newMusicConnectId();
        _frozen = (ticket: ticket, revision: musicDeviceRevision(paused), playing: offer.snapshot.playing);
        return {
          'ok': true,
          'ticket': ticket,
          'position': paused.snapshot.position.inMilliseconds,
          'playing': offer.snapshot.playing,
        };
      case 'resume':
        final frozen = _frozen;
        final offer = session.offerTransfer();
        if (frozen == null ||
            message['ticket'] != frozen.ticket ||
            offer == null ||
            frozen.revision != musicDeviceRevision(offer)) {
          return const {'ok': false};
        }
        _frozen = null;
        if (frozen.playing) await session.resumeFrozenMusicDevice();
        return const {'ok': true};
      case 'control':
        final offer = session.offerTransfer();
        if (offer == null || message['revision'] != musicDeviceRevision(offer) || session.musicDeviceOutput != null) {
          return const {'ok': false};
        }
        final action = message['action'];
        final args = message['args'];
        if (action is! String || args is! Map<String, dynamic>) return const {'ok': false};
        final success = await _control(action, args);
        return {'ok': success, if (success) 'state': _state(null)};
      default:
        return const {'ok': false};
    }
  }

  Future<bool> _control(String action, Map<String, dynamic> args) async {
    final playback = session.playback;
    final index = args['index'];
    switch (action) {
      case 'play':
        await playback.play();
      case 'pause':
        await playback.pause();
      case 'toggle':
        await playback.togglePlayPause();
      case 'next':
        await playback.next();
      case 'previous':
        await playback.previous();
      case 'stop':
        await playback.stop();
      case 'seek':
        final position = args['position'];
        if (position is! int || position < 0 || position > const Duration(hours: 24).inMilliseconds) return false;
        await playback.seek(Duration(milliseconds: position));
      case 'volume':
        final volume = args['volume'];
        if (volume is! num || !volume.isFinite || volume < 0 || volume > 100) return false;
        await playback.setVolume(volume.toDouble());
      case 'shuffle':
        playback.toggleShuffle();
      case 'repeat':
        final mode = MusicRepeatMode.values.where((mode) => mode.name == args['mode']).firstOrNull;
        if (mode == null) return false;
        playback.setRepeatMode(mode);
      case 'jump':
        if (index is! int || index < 0 || index >= playback.queue.length) return false;
        await playback.jumpTo(index);
      case 'remove':
        if (index is! int || index < 0 || index >= playback.queue.length) return false;
        playback.removeAt(index);
      case 'reorder':
        final target = args['to'];
        if (index is! int ||
            target is! int ||
            index < 0 ||
            target < 0 ||
            index >= playback.queue.length ||
            target >= playback.queue.length) {
          return false;
        }
        playback.reorder(index, target);
      case 'clear':
        playback.clearUpcoming();
      case 'addNext' || 'addToEnd':
        final value = MusicTransferSnapshot.tryParse(args['tracks'], itemLimit: MusicTransferSnapshot.maxTransferItems);
        if (value == null ||
            playback.queue.length + value.queue.items.length > MusicTransferSnapshot.maxTransferItems) {
          return false;
        }
        final List<MediaItem> tracks = value.queue.items;
        if (action == 'addNext') {
          playback.addNext(tracks);
        } else {
          playback.addToEnd(tracks);
        }
      default:
        return false;
    }
    return current;
  }

  void _cancelPreparation() {
    _prepareExpiry?.cancel();
    _prepareExpiry = null;
    _prepared = null;
  }

  void reset() {
    _generation++;
    _cancelPreparation();
    _frozen = null;
    _commits.clear();
  }

  void close() {
    _closed = true;
    reset();
  }
}
