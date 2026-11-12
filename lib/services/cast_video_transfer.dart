typedef CastVideoPoint = ({Duration position, bool playing});

class CastVideoSource {
  const CastVideoSource({required this.position, required this.isCurrent, required this.freeze, required this.restore});

  final Duration Function() position;
  final bool Function() isCurrent;
  final Future<CastVideoPoint?> Function() freeze;
  final Future<void> Function() restore;
}

/// The receiver is already loaded and paused. Freeze the source, use its
/// latest playhead, and preserve its play/pause intent.
Future<CastVideoPoint> commitPreparedCastVideo({
  required CastVideoSource source,
  required Future<void> Function(Duration) positionReceiver,
  required Future<void> Function() playReceiver,
  required Future<bool> Function() stopReceiver,
}) async {
  CastVideoPoint? frozen;
  var receiverMayBePlaying = false;
  try {
    frozen = await source.freeze();
    if (frozen == null || !source.isCurrent()) throw StateError('The source video session changed');
    await positionReceiver(frozen.position);
    if (frozen.playing) {
      receiverMayBePlaying = true;
      await playReceiver();
    }
    return frozen;
  } catch (_) {
    final stopped = await stopReceiver();
    if (receiverMayBePlaying && !stopped) throw const CastVideoTransferUncertain();
    if (frozen?.playing == true && source.isCurrent()) await source.restore();
    rethrow;
  }
}

class CastVideoTransferUncertain implements Exception {
  const CastVideoTransferUncertain();
}
