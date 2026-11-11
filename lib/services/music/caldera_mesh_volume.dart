import 'dart:async';

/// A native mesh volume command is local to the addressed player. Serialize it
/// separately from membership and recheck the connection/account at execution.
class CalderaMeshVolume {
  CalderaMeshVolume({required this.write, required this.read});
  final Future<void> Function(double value) write;
  final double Function() read;
  Future<void> _tail = Future.value();
  int _queued = 0;

  Future<void> apply(Object? payload, {required bool Function() current, required void Function() changed}) {
    if (payload is! Map || payload.length != 1 || payload['volume'] is! num) {
      throw const FormatException('Invalid native volume');
    }
    final volume = (payload['volume'] as num).toDouble();
    if (!volume.isFinite || volume < 0 || volume > 100) {
      throw const FormatException('Invalid native volume');
    }
    if (!current() || _queued >= 32) throw StateError('Native volume unavailable');
    _queued++;
    final operation = _tail.then((_) async {
      if (!current()) throw StateError('Native volume scope changed');
      await write(volume);
      if (current()) changed();
    });
    _tail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation.whenComplete(() => _queued--);
  }

  Map<String, Object?> state(String source) {
    final volume = read();
    return {
      'version': '1.0.0',
      'capabilities': null,
      'source': source,
      'volume': volume.isFinite ? volume.round().clamp(0, 100) : 0,
    };
  }
}
