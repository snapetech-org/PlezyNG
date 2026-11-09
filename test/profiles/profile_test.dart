import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/profiles/profile.dart';

void main() {
  group('Profile', () {
    test('local PIN hash is round-tripped via configJson', () async {
      final p = Profile.local(
        id: 'local-1',
        displayName: 'Kids',
        pinHash: await computePinHash('1234'),
        createdAt: DateTime(2026, 1, 1),
      );
      final json = p.toConfigJson();
      final restored = Profile.fromRow(
        id: p.id,
        kind: 'local',
        displayName: p.displayName,
        avatarThumbUrl: null,
        json: json,
        sortOrder: 0,
        createdAt: p.createdAt,
        lastUsedAt: null,
      );
      expect(restored.pinHash, p.pinHash);
      expect(restored.isPinProtected, isTrue);
    });

    test('plex_home configJson round-trips with all flags', () {
      final p = Profile.plexHome(
        id: 'plex-home-acct1-uuid1',
        displayName: 'Admin',
        parentConnectionId: 'acct1',
        plexAdmin: true,
        plexRestricted: false,
        plexProtected: true,
        createdAt: DateTime(2026, 1, 1),
      );
      final json = p.toConfigJson();
      final restored = Profile.fromRow(
        id: p.id,
        kind: 'plex_home',
        displayName: p.displayName,
        avatarThumbUrl: null,
        json: json,
        sortOrder: 0,
        createdAt: p.createdAt,
        lastUsedAt: null,
      );
      expect(restored.plexAdmin, isTrue);
      expect(restored.plexRestricted, isFalse);
      expect(restored.plexProtected, isTrue);
      expect(restored.parentConnectionId, 'acct1');
    });

    test('plexHomeProfileId is deterministic', () {
      expect(plexHomeProfileId(accountConnectionId: 'plex.dev1', homeUserUuid: 'uuid-1'), 'plex-home-plex.dev1-uuid-1');
    });

    test('parsePlexHomeProfileId round-trips a real 16-hex uuid', () {
      // Real plex.tv home-user uuids are 16-char plain hex, and the account
      // connection id itself usually ends in one (plex.{accountUuid}).
      const acct = 'plex.e443d57860076fc3';
      const uuid = '379704d0c6601309';
      final id = plexHomeProfileId(accountConnectionId: acct, homeUserUuid: uuid);
      final parsed = parsePlexHomeProfileId(id);
      expect(parsed, isNotNull);
      expect(parsed!.accountConnectionId, acct);
      expect(parsed.homeUserUuid, uuid);
    });

    test('parsePlexHomeProfileId round-trips a hyphenated RFC-4122 uuid', () {
      // Defensive alternate shape; accountConnectionId can carry hyphens too
      // (e.g. plex.client-id).
      const acct = 'plex.client-id-123';
      const uuid = 'a1b2c3d4-e5f6-7890-abcd-ef0123456789';
      final id = plexHomeProfileId(accountConnectionId: acct, homeUserUuid: uuid);
      final parsed = parsePlexHomeProfileId(id);
      expect(parsed, isNotNull);
      expect(parsed!.accountConnectionId, acct);
      expect(parsed.homeUserUuid, uuid);
    });

    test('parsePlexHomeProfileId splits at the last uuid-shaped segment', () {
      // A hex-ending account id must not steal the uuid slot: the $ anchor
      // forces the trailing segment to be the home-user uuid.
      const acct = 'acct-aaaaaaaaaaaaaaaa';
      const uuid = 'bbbbbbbbbbbbbbbb';
      final parsed = parsePlexHomeProfileId(plexHomeProfileId(accountConnectionId: acct, homeUserUuid: uuid));
      expect(parsed, isNotNull);
      expect(parsed!.accountConnectionId, acct);
      expect(parsed.homeUserUuid, uuid);
    });

    test('parsePlexHomeProfileId rejects non-Plex-Home ids', () {
      expect(parsePlexHomeProfileId('local-1'), isNull);
      expect(parsePlexHomeProfileId('plex-home-only'), isNull);
      expect(parsePlexHomeProfileId('plex-home-acct-not-a-uuid'), isNull);
      // 15 and 17 hex chars are not uuids.
      expect(parsePlexHomeProfileId('plex-home-acct-aaaaaaaaaaaaaaa'), isNull);
      expect(parsePlexHomeProfileId('plex-home-acct-aaaaaaaaaaaaaaaaa'), isNull);
    });
  });

  group('PIN hashing', () {
    test('independent salts protect identical PINs and both verify', () async {
      final first = await computePinHash('1234');
      final second = await computePinHash('1234');
      expect(first, isNot(second));
      expect(await verifyPin('1234', first), isTrue);
      expect(await verifyPin('1234', second), isTrue);
      expect(await verifyPin('1111', first), isFalse);
    });

    test('legacy hash remains readable for migration', () async {
      expect(await verifyPin('1234', 'a2779ae69839fea3247e7f508276ea5a588d45734004bced89590b08549d37fe'), isTrue);
      expect(await verifyPin('1111', 'a2779ae69839fea3247e7f508276ea5a588d45734004bced89590b08549d37fe'), isFalse);
    });

    test('malformed parameters cannot request unbounded KDF work', () async {
      expect(await verifyPin('1234', 'pbkdf2-sha256:999999999:x:y'), isFalse);
      expect(await verifyPin('1234', 'pbkdf2-sha256:210000:!:!'), isFalse);
      expect(
        await verifyPin('unbounded input', 'a2779ae69839fea3247e7f508276ea5a588d45734004bced89590b08549d37fe'),
        isFalse,
      );
    });
  });
}
