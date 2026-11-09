import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:freezed_annotation/freezed_annotation.dart';

import '../models/plex/plex_home_user.dart';

part 'profile.freezed.dart';

/// Top-level profile — the user-facing identity in the app.
///
/// Two kinds:
/// - [LocalProfile]: a Plezy-only profile created by the user. May have
///   an optional 4-digit PIN.
/// - [PlexHomeProfile]: auto-surfaced from a connected Plex account's
///   Home users. PIN protection is handled server-side by Plex via the
///   `/home/users/{uuid}/switch` flow — `pinHash` is unused.
///
/// A profile owns 1+ connections via the `profile_connections` join table.
/// The join row carries the per-profile user-level token used to talk to
/// each connection.
@freezed
sealed class Profile with _$Profile {
  const Profile._();

  const factory Profile.local({
    required String id,
    required String displayName,
    String? avatarThumbUrl,

    /// Hashed PIN if set. The raw PIN is never persisted; see [computePinHash].
    String? pinHash,
    @Default(0) int sortOrder,
    required DateTime createdAt,
    DateTime? lastUsedAt,
  }) = LocalProfile;

  const factory Profile.plexHome({
    required String id,
    required String displayName,
    String? avatarThumbUrl,

    /// The parent Plex account's connection id.
    String? parentConnectionId,

    /// The Plex Home user UUID. Used by the active-profile binder to call
    /// `/home/users/{uuid}/switch`.
    String? plexHomeUserUuid,
    @Default(false) bool plexRestricted,
    @Default(false) bool plexAdmin,

    /// Plex's `protected` flag — true when the home user has a PIN that must
    /// be entered before `/home/users/{uuid}/switch` will succeed.
    @Default(false) bool plexProtected,
    @Default(0) int sortOrder,
    required DateTime createdAt,
    DateTime? lastUsedAt,
  }) = PlexHomeProfile;

  /// Construct an in-memory virtual `Profile` for a Plex Home user. These
  /// are never persisted — Plex owns the Home user list, so the picker
  /// reads them live from [PlexHomeService] and merges them with the local
  /// rows from `ProfileRegistry`.
  factory Profile.virtualPlexHome({
    required String connectionId,
    required PlexHomeUser homeUser,
    DateTime? lastUsedAt,
  }) => Profile.plexHome(
    id: plexHomeProfileId(accountConnectionId: connectionId, homeUserUuid: homeUser.uuid),
    displayName: homeUser.displayName,
    avatarThumbUrl: homeUser.thumb.isNotEmpty ? homeUser.thumb : null,
    parentConnectionId: connectionId,
    plexHomeUserUuid: homeUser.uuid,
    plexRestricted: homeUser.restricted,
    plexAdmin: homeUser.admin,
    plexProtected: homeUser.protected,
    sortOrder: homeUser.admin ? 0 : 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    lastUsedAt: lastUsedAt,
  );

  factory Profile.fromRow({
    required String id,
    required String kind,
    required String displayName,
    required String? avatarThumbUrl,
    required Map<String, Object?> json,
    required int sortOrder,
    required DateTime createdAt,
    required DateTime? lastUsedAt,
  }) {
    final parsedKind = ProfileKind.fromId(kind);
    return switch (parsedKind) {
      ProfileKind.local => Profile.local(
        id: id,
        displayName: displayName,
        avatarThumbUrl: avatarThumbUrl,
        pinHash: json['pinHash'] as String?,
        sortOrder: sortOrder,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt,
      ),
      ProfileKind.plexHome => Profile.plexHome(
        id: id,
        displayName: displayName,
        avatarThumbUrl: avatarThumbUrl,
        parentConnectionId: json['parentConnectionId'] as String?,
        plexRestricted: json['restricted'] as bool? ?? false,
        plexAdmin: json['admin'] as bool? ?? false,
        plexProtected: (json['protected'] as bool?) ?? (json['hasPassword'] as bool? ?? false),
        sortOrder: sortOrder,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt,
      ),
    };
  }

  bool get isLocal => this is LocalProfile;
  bool get isPlexHome => this is PlexHomeProfile;

  ProfileKind get kind => switch (this) {
    LocalProfile() => ProfileKind.local,
    PlexHomeProfile() => ProfileKind.plexHome,
  };

  /// True when entering this profile requires user-supplied PIN.
  ///
  /// Locals: gated by their own [pinHash].
  /// Plex Home: gated by Plex's own protected flag (`plexProtected`).
  bool get isPinProtected => switch (this) {
    LocalProfile(:final pinHash) => pinHash != null && pinHash.isNotEmpty,
    PlexHomeProfile(:final plexProtected) => plexProtected,
  };

  /// Hashed PIN, only set for [LocalProfile]. Returns null for plexHome.
  String? get pinHash => switch (this) {
    LocalProfile(:final pinHash) => pinHash,
    PlexHomeProfile() => null,
  };

  /// Parent Plex account connection id, only set for [PlexHomeProfile].
  String? get parentConnectionId => switch (this) {
    LocalProfile() => null,
    PlexHomeProfile(:final parentConnectionId) => parentConnectionId,
  };

  /// Plex Home user UUID, only set for [PlexHomeProfile].
  String? get plexHomeUserUuid => switch (this) {
    LocalProfile() => null,
    PlexHomeProfile(:final plexHomeUserUuid) => plexHomeUserUuid,
  };

  bool get plexRestricted => switch (this) {
    LocalProfile() => false,
    PlexHomeProfile(:final plexRestricted) => plexRestricted,
  };

  bool get plexAdmin => switch (this) {
    LocalProfile() => false,
    PlexHomeProfile(:final plexAdmin) => plexAdmin,
  };

  bool get plexProtected => switch (this) {
    LocalProfile() => false,
    PlexHomeProfile(:final plexProtected) => plexProtected,
  };

  Map<String, Object?> toConfigJson() => switch (this) {
    LocalProfile(:final pinHash) => {'pinHash': pinHash},
    PlexHomeProfile(:final parentConnectionId, :final plexRestricted, :final plexAdmin, :final plexProtected) => {
      'parentConnectionId': parentConnectionId,
      'restricted': plexRestricted,
      'admin': plexAdmin,
      'protected': plexProtected,
    },
  };
}

enum ProfileKind {
  local,
  plexHome;

  String get id => switch (this) {
    ProfileKind.local => 'local',
    ProfileKind.plexHome => 'plex_home',
  };

  static ProfileKind fromId(String id) => switch (id) {
    'local' => ProfileKind.local,
    'plex_home' => ProfileKind.plexHome,
    _ => throw ArgumentError('Unknown ProfileKind id: $id'),
  };
}

/// Versioned, per-PIN salted verifier. A short PIN remains a local parental
/// control, not a substitute for device encryption or an account password.
const _pinIterations = 210000;
const _pinPrefix = 'pbkdf2-sha256';

bool isLegacyPinHash(String hash) => RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);

Future<String> computePinHash(String rawPin) async {
  if (!RegExp(r'^\d{4}$').hasMatch(rawPin)) throw ArgumentError('PIN must contain four digits');
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final key = await cryptography.Pbkdf2(
    macAlgorithm: cryptography.Hmac.sha256(),
    iterations: _pinIterations,
    bits: 256,
  ).deriveKeyFromPassword(password: rawPin, nonce: salt);
  return '$_pinPrefix:$_pinIterations:${base64Encode(salt)}:${base64Encode(await key.extractBytes())}';
}

bool _samePinBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

Future<bool> verifyPin(String rawPin, String hash) async {
  if (hash.length > 256 || !RegExp(r'^\d{4}$').hasMatch(rawPin)) return false;
  if (isLegacyPinHash(hash)) {
    final digest = sha256.convert(utf8.encode('plezy-app-profile-pin-v1:$rawPin')).toString();
    return _samePinBytes(utf8.encode(digest), utf8.encode(hash));
  }
  try {
    final parts = hash.split(':');
    if (parts.length != 4 || parts[0] != _pinPrefix || parts[1] != '$_pinIterations') return false;
    final salt = base64Decode(parts[2]);
    final expected = base64Decode(parts[3]);
    if (salt.length != 16 || expected.length != 32) return false;
    final key = await cryptography.Pbkdf2(
      macAlgorithm: cryptography.Hmac.sha256(),
      iterations: _pinIterations,
      bits: 256,
    ).deriveKeyFromPassword(password: rawPin, nonce: salt);
    return _samePinBytes(await key.extractBytes(), expected);
  } on FormatException {
    return false;
  }
}

/// Deterministic id for a Plex Home profile so re-discovery is idempotent.
String plexHomeProfileId({required String accountConnectionId, required String homeUserUuid}) {
  return 'plex-home-$accountConnectionId-$homeUserUuid';
}

/// Anchor on the trailing home-user uuid — `accountConnectionId` may contain
/// hyphens, so a `lastIndexOf('-')` would slice inside a dashed uuid. The
/// `$` anchor resolves ambiguous hyphens: an earlier candidate split only
/// wins if the remainder is exactly one uuid.
///
/// Real plex.tv `/api/v2/home/users` uuids are 16-char plain hex
/// (e.g. `7b4af7a9f26254bd`); the 36-char dashed RFC-4122 shape is kept as a
/// defensive alternate.
final RegExp _trailingHomeUserUuidPattern = RegExp(
  r'-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{16})$',
);

/// Prefs scope for a profile id: Plex Home profiles scope by their bare
/// home-user uuid (`user_{uuid}_*`), other profiles by the full id.
///
/// Every `user_{scope}_{key}` prefs-key builder must apply this —
/// [StorageService]'s `_migratePlexHomeUserScopes` relocates full-profile-id
/// keys onto the uuid scope at every launch, so a builder that skips the
/// normalization writes keys that vanish on the next restart (Trakt
/// "unlinking" on hot restart was exactly this).
String profileUserScope(String profileId) => parsePlexHomeProfileId(profileId)?.homeUserUuid ?? profileId;

/// THE builder for profile-scoped prefs keys: `user_{scope}_{baseKey}`, or
/// the bare [baseKey] for the empty (signed-out/account-level) scope.
/// Pairs the `user_` prefix with [profileUserScope] in one place so no key
/// builder can skip the normalization (see the warning above).
String profileScopedPrefsKey(String userUuid, String baseKey) =>
    userUuid.isEmpty ? baseKey : 'user_${profileUserScope(userUuid)}_$baseKey';

/// Inverse of [plexHomeProfileId]. Returns `null` if [id] doesn't match the
/// `plex-home-{accountConnectionId}-{homeUserUuid}` shape.
({String accountConnectionId, String homeUserUuid})? parsePlexHomeProfileId(String id) {
  const prefix = 'plex-home-';
  if (!id.startsWith(prefix)) return null;
  final rest = id.substring(prefix.length);
  final match = _trailingHomeUserUuidPattern.firstMatch(rest);
  if (match == null) return null;
  final accountId = rest.substring(0, match.start);
  if (accountId.isEmpty) return null;
  return (accountConnectionId: accountId, homeUserUuid: match.group(1)!);
}
