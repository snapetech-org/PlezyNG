import 'dart:async';

Future<void> loadAcknowledgedCastMedia<Status>({
  required Stream<Status> statuses,
  required bool Function(Status) acknowledge,
  required Future<void> Function() load,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final accepted = Completer<void>();
  final subscription = statuses.listen(
    (status) {
      if (!accepted.isCompleted && acknowledge(status)) accepted.complete();
    },
    onError: (Object error, StackTrace stack) {
      if (!accepted.isCompleted) accepted.completeError(error, stack);
    },
    onDone: () {
      if (!accepted.isCompleted) accepted.completeError(StateError('Cast status stream closed'));
    },
  );
  final deadline = Timer(timeout, () {
    if (!accepted.isCompleted) accepted.completeError(TimeoutException('Cast load was not acknowledged', timeout));
  });
  try {
    await Future.wait<void>([Future.sync(load), accepted.future], eagerError: true);
  } finally {
    deadline.cancel();
    await subscription.cancel();
  }
}

class CastPlaybackOwnership {
  String? _token;
  int? _session;
  bool Function()? _authorized;
  int _revision = 0;
  int get revision => _revision;

  void begin(String token, bool Function() authorized) {
    _revision++;
    _token = token;
    _session = null;
    _authorized = authorized;
  }

  bool acknowledge(String? token, int session) {
    if (session <= 0 || token == null || token != _token || _authorized?.call() != true) return false;
    if (_session != null && _session != session) return false;
    _session = session;
    return true;
  }

  bool owns(String? token, int session) =>
      _session != null && session == _session && (token == null || token == _token) && _authorized?.call() == true;

  bool get authorized => _token != null && _authorized?.call() == true;

  void clear() {
    _revision++;
    _token = null;
    _session = null;
    _authorized = null;
  }
}
