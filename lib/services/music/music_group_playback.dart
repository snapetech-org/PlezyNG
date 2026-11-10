import 'music_group_exchange.dart';
import 'music_playback_service.dart';
import 'music_transfer_snapshot.dart';

abstract interface class MusicGroupSession implements MusicTransferSession {
  Future<bool> prepareGroupTransfer(MusicTransferSnapshot snapshot, {required bool Function() current});
  bool groupOfferCurrent(MusicTransferOffer offer);
  bool Function() captureGroupAuthority();
  Object get groupControlRevision;
  bool get isMusicGroupFollower;
  void setMusicGroupFollower(bool follower);
}

class MusicGroupPlayback {
  MusicGroupPlayback(this.music, this.session);
  final MusicPlaybackService music;
  final MusicGroupSession session;
  MusicTransferOffer? _lease;
  bool Function()? _authorized;
  int _roleEpoch = 0;

  bool get _owns => _lease != null && session.groupOfferCurrent(_lease!) && _authorized?.call() == true;

  MusicTransferSnapshot? capture() {
    _authorized ??= session.captureGroupAuthority();
    return _authorized?.call() == true ? session.offerTransfer()?.snapshot : null;
  }

  Future<bool> _run(Future<void> Function() action, bool Function() current) async {
    final operation = action();
    final revision = session.groupControlRevision;
    await operation;
    if (!current() || _authorized?.call() != true || revision != session.groupControlRevision) return false;
    _lease = session.offerTransfer();
    return _owns;
  }

  Future<bool> prepare(MusicTransferSnapshot snapshot, bool Function() current) async {
    _roleEpoch++;
    _lease = null;
    _authorized = null;
    if (!await session.prepareGroupTransfer(snapshot, current: current) || !current()) return false;
    _lease = session.offerTransfer();
    _authorized = session.captureGroupAuthority();
    return _owns;
  }

  Future<bool> align(MusicTransferSnapshot snapshot, bool Function() current) async {
    if (!current() || !_owns) return false;
    final offered = session.offerTransfer();
    if (offered == null ||
        MusicGroupExchange.queueIdentity(offered.snapshot) != MusicGroupExchange.queueIdentity(snapshot)) {
      return false;
    }
    if (music.currentIndex != snapshot.queue.cursor) {
      if (!await _run(() => music.jumpTo(snapshot.queue.cursor), current)) return false;
    }
    if ((music.position - snapshot.position).abs() > const Duration(milliseconds: 250)) {
      if (!await _run(() => music.seek(snapshot.position), current)) return false;
    }
    if (music.isPlaying != snapshot.playing) {
      if (!await _run(snapshot.playing ? music.play : music.pause, current)) return false;
    }
    return _owns && music.isPlaying == snapshot.playing;
  }

  Future<void> release() async {
    final epoch = ++_roleEpoch;
    final owned = _lease != null && session.groupOfferCurrent(_lease!);
    _lease = null;
    _authorized = null;
    if (owned) await music.pause();
    if (epoch == _roleEpoch) session.setMusicGroupFollower(false);
  }
}
