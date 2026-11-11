/// Maps the live WAV frame position reported by the audio renderer to the
/// receiver's monotonic clock. Audio-PTS includes driver delay; wall time never
/// participates. Small bounded corrections follow hardware drift continuously.
class XitaOutputClock {
  XitaOutputClock(this.sampleRate) {
    if (sampleRate < 8000 || sampleRate > 384000) throw ArgumentError('Unsupported output rate');
  }
  final int sampleRate;
  int? _originTime, _originPts, _lastTime, _lastPts, _rateTime, _ratePts;
  double _microsPerMediaMicro = 1;
  bool get ready => _originTime != null;
  double get rateRatio => 1 / _microsPerMediaMicro;
  int? get lastObservationMicros => _lastTime;

  bool observe(Duration audible, int nowMicros) {
    final pts = audible.inMicroseconds;
    if (pts < 0 || nowMicros < 0 || _lastTime != null && nowMicros <= _lastTime!) return false;
    if (_lastPts != null && pts <= _lastPts!) return false;
    if (_originTime == null) {
      _originTime = _lastTime = _rateTime = nowMicros;
      _originPts = _lastPts = _ratePts = pts;
      return true;
    }
    final predicted = _originTime! + (pts - _originPts!) * _microsPerMediaMicro;
    final error = nowMicros - predicted;
    if (error.abs() > 100000) return false;
    // At most 100 us of phase correction per observation. Corrections remain
    // much smaller than a render tick, so active PCM never seeks or rewinds.
    _originTime = (_originTime! + (error * .05).clamp(-100, 100)).round();
    if (pts - _ratePts! >= 1000000) {
      final measured = ((nowMicros - _rateTime!) / (pts - _ratePts!)).clamp(.998, 1.002);
      final next = _microsPerMediaMicro * .98 + measured * .02;
      _originTime = (_originTime! + (pts - _originPts!) * (_microsPerMediaMicro - next)).round();
      _microsPerMediaMicro = next;
      _ratePts = pts;
      _rateTime = nowMicros;
    }
    _lastPts = pts;
    _lastTime = nowMicros;
    return true;
  }

  double frameAtMicros(int nowMicros) {
    if (!ready) throw StateError('Output clock has no audible anchor');
    return (_originPts! + (nowMicros - _originTime!) / _microsPerMediaMicro) * sampleRate / 1000000;
  }

  double presentationMicros(int waveFrame) {
    if (!ready) throw StateError('Output clock has no audible anchor');
    return _originTime! + (waveFrame * 1000000 / sampleRate - _originPts!) * _microsPerMediaMicro;
  }

  double get microsPerFrame => 1000000 / sampleRate * _microsPerMediaMicro;
}
