import 'dart:async';

import 'package:flutter/foundation.dart';

import '../mpv/mpv.dart';
import '../utils/media_server_http_client.dart' show AbortController;

enum SubtitleFetchStage { idle, searching, downloading, refreshing, completed, noMatch, failed, cancelled, expired }

/// One bounded startup operation. Cancelling releases the playback startup
/// wait immediately and aborts supported provider transports. A request already
/// accepted by a server may still finish there; it cannot attach itself locally.
final class SubtitleAutomaticFetch extends ChangeNotifier {
  static final _owners = Expando<SubtitleAutomaticFetch>();
  static SubtitleAutomaticFetch? forPlayer(Player player) => _owners[player];
  Player? _player;
  SubtitleFetchAttempt? _active;
  SubtitleFetchStage _stage = SubtitleFetchStage.idle;
  SubtitleFetchStage get stage => _stage;
  bool get busy => _active != null;
  void bind(Player player) {
    if (identical(_owners[_player ?? player], this)) _owners[_player ?? player] = null;
    _player = player; _owners[player] = this;
  }
  SubtitleFetchAttempt start({required bool Function() isCurrent}) {
    cancel();
    final attempt = SubtitleFetchAttempt._(this, isCurrent);
    _active = attempt; _stage = SubtitleFetchStage.searching;
    notifyListeners();
    attempt._watch = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!isCurrent()) { attempt.finish(SubtitleFetchStage.cancelled); }
      else if (DateTime.now().isAfter(attempt.deadline)) { attempt.finish(SubtitleFetchStage.expired); }
    });
    return attempt;
  }
  void reset() { cancel(); _stage = SubtitleFetchStage.idle; notifyListeners(); }
  void _changed() => notifyListeners();
  void cancel() => _active?.finish(SubtitleFetchStage.cancelled);
  @override
  void dispose() {
    cancel();
    final player = _player;
    if (player != null && identical(_owners[player], this)) _owners[player] = null;
    super.dispose();
  }
}

final class SubtitleFetchAttempt {
  SubtitleFetchAttempt._(this._owner, this._sourceCurrent);
  final SubtitleAutomaticFetch _owner;
  final bool Function() _sourceCurrent;
  final abort = AbortController();
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  Timer? _watch;
  bool get current => identical(_owner._active, this) && !abort.isAborted && _sourceCurrent() && DateTime.now().isBefore(deadline);
  void check() { if (!current) throw StateError('Automatic subtitle fetch retired.'); }
  void phase(SubtitleFetchStage stage) {
    check(); _owner._stage = stage; _owner._changed();
  }
  Future<T> wait<T>(Future<T> Function() operation) async {
    check();
    final result = await Future.any<T>([operation(),
      abort.trigger.then<T>((_) => throw StateError('Automatic subtitle fetch retired.'))]);
    check(); return result;
  }
  void finish(SubtitleFetchStage stage) {
    if (!identical(_owner._active, this)) return;
    _watch?.cancel(); _owner._active = null;
    _owner._stage = DateTime.now().isAfter(deadline) &&
        stage != SubtitleFetchStage.cancelled && stage != SubtitleFetchStage.completed
        ? SubtitleFetchStage.expired : stage;
    abort.abort();
    _owner._changed();
  }
}
