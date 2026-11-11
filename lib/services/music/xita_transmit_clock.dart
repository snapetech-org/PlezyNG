/// Maps the captured hardware clock onto bounded UDP send deadlines. Buffer
/// feedback follows small device-rate differences without accumulating latency.
class XitaTransmitClock {
  XitaTransmitClock({required int startMicros, required DateTime timestamp})
    : _nextMicros = startMicros.toDouble(),
      _anchorMicros = startMicros,
      _timestamp = timestamp.toUtc();
  static const sampleRate = 48000, periodFrames = 1024;
  final int _anchorMicros;
  final DateTime _timestamp;
  double _nextMicros, _correction = 0;
  int? _targetFrames;
  int get nextMicros => _nextMicros.round();
  double get rateRatio => 1 + _correction;
  bool due(int nowMicros) => nowMicros >= nextMicros;
  DateTime timestampAt(int monotonicMicros) => _timestamp.add(Duration(microseconds: monotonicMicros - _anchorMicros));
  int lateness(int nowMicros) {
    final elapsed = nowMicros - nextMicros;
    if (elapsed > 250000) throw StateError('Native source clock stalled');
    return elapsed.clamp(0, 250000);
  }

  void advance(int nowMicros, {required int bufferedFrames}) {
    lateness(nowMicros);
    _targetFrames ??= bufferedFrames.clamp(periodFrames * 2, sampleRate ~/ 4);
    final desired = ((bufferedFrames - _targetFrames!) / sampleRate * .02).clamp(-.002, .002);
    _correction += (desired - _correction) * .01;
    _nextMicros += periodFrames * 1000000 / sampleRate / rateRatio;
  }
}
