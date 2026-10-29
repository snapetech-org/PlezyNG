import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/game_library_controller.dart';
import 'package:plezy/games/game_models.dart';
import 'package:plezy/games/game_streaming_client.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';

class FakeEngine implements GameStreamingClient {
  Completer<List<StreamGame>>? waiting;
  bool cancelled = false;
  @override
  Future<GameClientCapabilities> capabilities(GameHost host) async =>
      const GameClientCapabilities(available: true, inlinePairing: true, library: true);
  @override
  Future<void> pair(GameHost host, String pin) async {}
  @override
  Future<List<StreamGame>> games(GameHost host) => waiting?.future ?? Future.value([]);
  @override
  Future<void> open(
    GameHost host, {
    required StreamGame game,
    bool touchControls = true,
    bool pyrowave = false,
  }) async {}
  @override
  void cancel() {
    cancelled = true;
  }
}

void main() {
  late SourceDatabase db;
  late SourceRepository repository;
  late FakeEngine client;
  late GameLibraryController controller;
  var current = true;
  final host = GameHost(id: 'pc', name: 'PC', address: '192.168.1.2', protocol: GameProtocol.gameStream);
  late StreamGame game;
  setUp(() {
    current = true;
    db = SourceDatabase(NativeDatabase.memory());
    repository = SourceRepository(db);
    client = FakeEngine();
    controller = GameLibraryController(
      repository: repository,
      profileId: 'alice',
      sessionCurrent: () => current,
      client: client,
    );
    game = StreamGame(hostKey: host.key, id: '1', name: 'Desktop');
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });
  Future<void> catalog({String id = '76561198000000000', String? session, String? protected}) =>
      controller.saveSteamCatalog(
        steamId: id,
        games: [SteamCatalogGame(appId: 620, name: 'Portal 2')],
        catalogAvailable: true,
        catalogTruncated: false,
        sessionCredential: session,
        protectedCredential: protected,
      );
  test('session-only authorization supports refresh without persisting the grant', () async {
    await catalog(session: 'session-secret');
    expect(controller.catalogCredential, 'session-secret');
    expect(controller.usesSessionSteamCredential, isTrue);
    await catalog();
    await controller.toggleLibraryFavorite(controller.library.entries.single);
    await controller.load();
    expect(controller.catalogCredential, 'session-secret');
    expect(controller.library.steamCatalogCredential, isNull);
    final stored = await repository.preference('alice', GameLibraryController.preferenceKey);
    expect(stored.toString(), isNot(contains('session-secret')));
    final reopened = GameLibraryController(
      repository: repository,
      profileId: 'alice',
      sessionCurrent: () => true,
      client: FakeEngine(),
    );
    await reopened.load();
    expect(reopened.library.entries.single.name, 'Portal 2');
    expect(reopened.catalogCredential, isNull);
    reopened.dispose();
    current = false;
    expect(controller.catalogCredential, isNull);
    expect(controller.usesSessionSteamCredential, isFalse);
  });
  test('account replacement and unlink retire session authorization', () async {
    await catalog(session: 'first-account-secret');
    await catalog(id: '76561198000000001');
    expect(controller.catalogCredential, isNull);
    await catalog();
    expect(controller.catalogCredential, isNull);
    await catalog(session: 'new-session-secret');
    await catalog(protected: 'protected-value');
    expect(controller.catalogCredential, 'protected-value');
    expect(controller.usesSessionSteamCredential, isFalse);
    await catalog(session: 'replacement-session-secret');
    expect(controller.library.steamCatalogCredential, isNull);
    await controller.unlinkSteamAccount();
    expect(controller.catalogCredential, isNull);
    expect(controller.usesSessionSteamCredential, isFalse);
  });
  test('failed persistence cannot publish a session grant', () async {
    await repository.forgetProfile('alice');
    await expectLater(catalog(session: 'rejected-secret'), throwsA(isA<SourceException>()));
    expect(controller.catalogCredential, isNull);
    expect(controller.library.steamAccountId, isNull);
  });
  test('ambiguous or oversized session credentials are rejected', () async {
    await expectLater(catalog(session: 'raw', protected: 'protected'), throwsA(isA<GameClientException>()));
    await expectLater(catalog(session: ''), throwsA(isA<GameClientException>()));
    await expectLater(catalog(session: 'x' * 4097), throwsA(isA<GameClientException>()));
    expect(controller.catalogCredential, isNull);
  });
  test('profile persistence keeps libraries separate', () async {
    await controller.saveHost(host);
    await controller.saveGame(game);
    await controller.toggleFavorite(game);
    await controller.opened(game);
    expect(await repository.preference('bob', GameLibraryController.preferenceKey), isEmpty);
    await controller.load();
    expect(controller.library.favorites, {game.key});
    expect(controller.library.recent, [game.key]);
  });
  test('serialized edits do not overwrite each other', () async {
    await controller.saveHost(host);
    await Future.wait([
      controller.saveGame(game),
      controller.saveGame(StreamGame(hostKey: host.key, id: '2', name: 'Game')),
    ]);
    expect(controller.library.games, hasLength(2));
  });
  test('forget removes dependent shortcuts, favorites and recents', () async {
    await controller.saveHost(host);
    await controller.saveGame(game);
    await controller.toggleFavorite(game);
    await controller.opened(game);
    await controller.removeHost(host);
    expect(controller.library.games, isEmpty);
    expect(controller.library.favorites, isEmpty);
    expect(controller.library.recent, isEmpty);
  });
  test('late library result cannot publish into a retired profile session', () async {
    await controller.saveHost(host);
    client.waiting = Completer();
    final pending = controller.refreshGames(host);
    current = false;
    client.waiting!.complete([game]);
    await expectLater(pending, throwsA(isA<GameClientException>()));
    expect(controller.library.games, isEmpty);
    expect(
      GameLibrary.fromJson(await repository.preference('alice', GameLibraryController.preferenceKey)).games,
      isEmpty,
    );
  });
  test('a deleted profile cannot be resurrected by a stale write', () async {
    await repository.forgetProfile('alice');
    await expectLater(controller.saveHost(host), throwsA(isA<SourceException>()));
    expect(await repository.preference('alice', GameLibraryController.preferenceKey), isEmpty);
  });
  test('failed library refresh preserves the last usable library', () async {
    await controller.saveHost(host);
    await controller.saveGame(game);
    client.waiting = Completer()..completeError(const GameClientException(GameClientFailure.unavailable));
    await expectLater(controller.refreshGames(host), throwsA(isA<GameClientException>()));
    expect(controller.library.games.single.id, '1');
  });
  test('Steam interface refresh preserves user shortcuts, favorites and recents', () async {
    final steam = GameHost(id: '123', name: 'Steam PC', address: '192.168.1.2', protocol: GameProtocol.steam);
    final shortcut = StreamGame(hostKey: steam.key, id: '620', name: 'Portal 2');
    await controller.saveHost(steam);
    await controller.saveGame(shortcut);
    await controller.toggleFavorite(shortcut);
    await controller.opened(shortcut);
    client.waiting = Completer()..complete([StreamGame(hostKey: steam.key, id: '0', name: 'Steam Library')]);
    await controller.refreshGames(steam);
    expect(controller.library.games.map((g) => g.id), containsAll(['620', '0']));
    expect(controller.library.favorites, contains(shortcut.key));
    expect(controller.library.recent, contains(shortcut.key));
  });
  test('explicit computer selection survives playing elsewhere and persists without marking play', () async {
    final otherHost = GameHost(id: 'other', name: 'BC250', address: '192.168.1.3', protocol: GameProtocol.gameStream);
    await controller.saveHost(host);
    await controller.saveHost(otherHost);
    await controller.saveGame(StreamGame(hostKey: host.key, id: '1', name: 'Portal', steamAppId: 620));
    await controller.saveGame(StreamGame(hostKey: otherHost.key, id: '2', name: 'Portal', steamAppId: 620));
    var entry = controller.library.entries.single;
    final preferred = entry.routes.first;
    await controller.preferRoute(entry, preferred);
    expect(controller.library.recent, isEmpty);
    await controller.connected(entry.routes.last);
    await controller.load();
    entry = controller.library.entries.single;
    expect(entry.preferredRoute(controller.library)?.key, preferred.key);
    await controller.preferRoute(entry, null);
    await controller.load();
    expect(controller.library.entries.single.preferredRoute(controller.library), isNull);
    final before = controller.library.toJson();
    current = false;
    await expectLater(controller.preferRoute(entry, preferred), throwsA(isA<GameClientException>()));
    expect(controller.library.toJson(), before);
  });
}
