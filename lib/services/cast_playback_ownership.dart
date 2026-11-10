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
