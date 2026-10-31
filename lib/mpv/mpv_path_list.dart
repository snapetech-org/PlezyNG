/// Serializes MPV's path-list option syntax without treating path separators
/// inside an entry as list boundaries.
abstract final class MpvPathList {
  /// Escapes one item for MPV's platform-specific path-list separator.
  /// MPV's splitter removes a backslash only when it is immediately before
  /// [separator], preserving other backslashes in Windows paths.
  static String escapeEntry(String entry, String separator) {
    if (separator.isEmpty) throw ArgumentError.value(separator, 'separator', 'Must not be empty');
    return entry.replaceAll(separator, '\\$separator');
  }

  /// Joins [entries] for a `change-list OPTION set VALUE` command.
  static String encode(Iterable<String> entries, {required String separator}) {
    if (separator.isEmpty) throw ArgumentError.value(separator, 'separator', 'Must not be empty');
    return entries.map((entry) => escapeEntry(entry, separator)).join(separator);
  }
}
