/// Briefly remembers failed, fully resolved artwork URLs. Relative paths are
/// not identities: two servers can use the same metadata ID for different art.
class ArtworkFailureCache {
  ArtworkFailureCache({DateTime Function()? now, this.retryAfter = const Duration(minutes: 2), this.maxEntries = 512})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration retryAfter;
  final int maxEntries;
  final _entries = <String, DateTime>{};

  bool contains(String? url) {
    if (url == null) return false;
    final expiry = _entries[url];
    if (expiry == null) return false;
    if (!expiry.isAfter(_now())) {
      _entries.remove(url);
      return false;
    }
    return true;
  }

  void remember(String? url) {
    if (url == null || url.isEmpty || maxEntries <= 0) return;
    _entries.remove(url);
    _entries[url] = _now().add(retryAfter);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}
