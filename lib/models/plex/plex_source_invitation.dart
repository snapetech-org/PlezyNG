/// Pending item-sharing source, not accepted playback access.
/// Decisions cover the entire invitation, including non-music items.
class PlexSourceInvitation {
  const PlexSourceInvitation._(this.id, this.ownerId, this.recipientId, this.ownerName);
  final int id, ownerId, recipientId;
  final String ownerName;
  bool sameDecision(PlexSourceInvitation other) =>
      id == other.id && ownerId == other.ownerId && recipientId == other.recipientId && ownerName == other.ownerName;

  static int? _id(Object? value) {
    final id = value is int
        ? value
        : value is String
        ? int.tryParse(value)
        : null;
    return id != null && id > 0 && id <= 9007199254740991 ? id : null;
  }

  static List<PlexSourceInvitation> parsePending(Object? data) {
    if (data is! List || data.length > 512) throw const FormatException('Invalid Plex invitations');
    final seen = <int>{}, result = <PlexSourceInvitation>[];
    for (final row in data) {
      if (row is! Map) throw const FormatException('Invalid Plex invitation');
      // The pending route supplies state; exclude an explicitly non-pending row.
      if (row['status'] != null && row['status'] != 'pending') continue;
      final id = _id(row['id']), owner = row['owner'], recipient = row['invited'];
      if (id == null || owner is! Map || recipient is! Map) {
        throw const FormatException('Invalid Plex invitation identity');
      }
      final ownerId = _id(owner['id']), recipientId = _id(recipient['id']);
      final name = [owner['title'], owner['username'], owner['email']]
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty && s.length <= 320 && !s.runes.any((r) => r < 32 || r == 127))
          .firstOrNull;
      if (ownerId == null || recipientId == null || name == null || !seen.add(id)) {
        throw const FormatException('Ambiguous Plex invitation');
      }
      result.add(PlexSourceInvitation._(id, ownerId, recipientId, name));
    }
    return List.unmodifiable(result);
  }
}
