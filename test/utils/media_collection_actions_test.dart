import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_collection_actions.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/media_context_menu.dart' show MediaContextMenu, MediaContextMenuState;
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/music_experience_fakes.dart';

final _album = testMediaItem(id: 'album', kind: MediaKind.album, serverId: 's', libraryId: 'music');
Profile _actor(String id, {bool home = false, bool admin = false}) => home
    ? Profile.plexHome(id: id, displayName: id, createdAt: DateTime.utc(2024), plexAdmin: admin)
    : Profile.local(id: id, displayName: id, createdAt: DateTime.utc(2024));

class _Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  Profile? active = _actor('owner');
  @override
  String? get activeId => active?.id;
  @override
  bool isBinding = false;
  @override
  bool lastBindingSucceeded = true;
  @override
  int identityMutationGeneration = 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Hidden extends ChangeNotifier implements HiddenLibrariesProvider {
  @override
  bool get isDisposed => false;
  @override
  bool isInitialized = true;
  @override
  String? profileId = 'owner';
  @override
  final Set<String> hiddenLibraryKeys = {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Manager extends MultiServerManager {
  bool owner = true;
  @override
  bool isOwnerOrAdmin(ServerId serverId) => owner;
}

class _Client extends ExperienceClient {
  final List<String> removals = [];
  final List<String> deletions = [];
  @override
  Future<bool> deleteCollection(MediaItem item) async {
    deletions.add(item.id);
    return true;
  }

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) async {
    removals.add('$collectionId:${item.id}');
    return true;
  }
}

Future<({MediaCollectionWriteScope scope, _Client client, _Manager manager, _Profile profile, _Hidden hidden})> _scope(
  WidgetTester tester,
) async {
  final client = _Client();
  final manager = _Manager()..debugRegisterClientForTesting(client);
  final servers = testMultiServerProvider(manager);
  final profile = _Profile(), hidden = _Hidden();
  addTearDown(() {
    servers.dispose();
    manager.dispose();
    profile.dispose();
    hidden.dispose();
  });
  MediaCollectionWriteScope? scope;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<MultiServerProvider>.value(value: servers),
        ChangeNotifierProvider<ActiveProfileProvider>.value(value: profile),
        ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
      ],
      child: Builder(
        builder: (context) {
          scope ??= MediaCollectionWriteScope.forItem(context, _album);
          return const SizedBox();
        },
      ),
    ),
  );
  expect(scope, isNotNull);
  expect(scope!.current, isTrue);
  return (scope: scope!, client: client, manager: manager, profile: profile, hidden: hidden);
}

void main() {
  test('scope checks exact backend, source, authentication, account and online state', () {
    final client = _Client();
    var authorized = true;
    MediaCollectionWriteScope make(MediaItem item) =>
        MediaCollectionWriteScope(client: client, item: item, authorized: () => authorized);
    final scope = make(_album);
    expect(scope.current, isTrue);
    authorized = false;
    expect(scope.current, isFalse);
    authorized = true;
    expect(make(_album.copyWith(serverId: 'other')).current, isFalse);
    expect(
      make(testMediaItem(id: 'album', backend: MediaBackend.jellyfin, kind: MediaKind.album, serverId: 's')).current,
      isFalse,
    );
    client.isOfflineMode = true;
    expect(scope.current, isFalse);
    client.isOfflineMode = false;
    client.scopedServerId = 's/another-user';
    expect(scope.current, isFalse);
    client.scopedServerId = 's/user';
    client.authenticationSessionId = Object();
    expect(scope.current, isFalse);
  });

  testWidgets('shared user and managed Plex Home roles cannot write collections', (tester) async {
    final h = await _scope(tester);
    h.manager.owner = false;
    expect(h.scope.current, isFalse);
    h.manager.owner = true;
    h.profile.active = _actor('owner', home: true);
    expect(h.scope.current, isFalse);
    h.profile.active = _actor('owner', home: true, admin: true);
    expect(h.scope.current, isTrue);
  });

  testWidgets('profile changes cannot revive old decisions after switching back', (tester) async {
    final h = await _scope(tester);
    h.profile.active = _actor('other');
    expect(h.scope.current, isFalse);
    h.profile.active = _actor('owner');
    h.profile.identityMutationGeneration++;
    expect(h.scope.current, isFalse);
  });

  testWidgets('binding and failed binding prevent writes', (tester) async {
    final h = await _scope(tester);
    h.profile.isBinding = true;
    expect(h.scope.current, isFalse);
    h.profile.isBinding = false;
    h.profile.lastBindingSucceeded = false;
    expect(h.scope.current, isFalse);
  });

  testWidgets('hidden, uninitialized and foreign profile library rules prevent writes', (tester) async {
    final h = await _scope(tester);
    expect(h.scope.allowsLibrary('music'), isTrue);
    expect(h.scope.allowsLibrary('other'), isFalse);
    h.hidden.hiddenLibraryKeys.add('s:music');
    expect(h.scope.allowsLibrary('music'), isFalse);
    expect(h.scope.current, isFalse);
    h.hidden.hiddenLibraryKeys.clear();
    h.hidden.isInitialized = false;
    expect(h.scope.current, isFalse);
    h.hidden.isInitialized = true;
    h.hidden.profileId = 'other';
    expect(h.scope.current, isFalse);
  });

  testWidgets('hidden server, disconnected client and replaced account prevent writes', (tester) async {
    final h = await _scope(tester);
    h.manager.setVisibleServerIds({});
    expect(h.scope.current, isFalse);
    h.manager.setVisibleServerIds(null);
    h.manager.debugRegisterClientForTesting(h.client, online: false);
    expect(h.scope.current, isFalse);
    h.manager.debugRegisterClientForTesting(_Client());
    expect(h.scope.current, isFalse);
  });

  testWidgets('an unmounted collection action cannot write', (tester) async {
    final h = await _scope(tester);
    await tester.pumpWidget(const SizedBox());
    expect(h.scope.current, isFalse);
  });

  for (final deleting in [false, true]) {
    for (final changed in [false, true]) {
      testWidgets('collection delete=$deleting changed=$changed pins the confirmation account', (tester) async {
        LocaleSettings.setLocaleSync(AppLocale.en);
        TvDetectionService.debugSetAppleTVOverride(true);
        addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
        final original = _Client(), replacement = _Client();
        final manager = _Manager()..debugRegisterClientForTesting(original);
        final servers = testMultiServerProvider(manager), profile = _Profile();
        addTearDown(() {
          servers.dispose();
          manager.dispose();
          profile.dispose();
        });
        final key = GlobalKey<MediaContextMenuState>();
        await tester.pumpWidget(
          TranslationProvider(
            child: MultiProvider(
              providers: [
                ChangeNotifierProvider<MultiServerProvider>.value(value: servers),
                ChangeNotifierProvider<ActiveProfileProvider>.value(value: profile),
              ],
              child: MaterialApp(
                theme: monoTheme(MonoPalette.dark),
                home: Scaffold(
                  body: MediaContextMenu(
                    key: key,
                    item: deleting
                        ? testMediaItem(
                            id: 'collection',
                            title: 'Collection',
                            kind: MediaKind.collection,
                            serverId: 's',
                            libraryId: 'music',
                          )
                        : _album,
                    collectionId: 'collection',
                    child: const Text('target'),
                  ),
                ),
              ),
            ),
          ),
        );
        key.currentState!.showContextMenu(key.currentContext!);
        await tester.pumpAndSettle();
        await tester.tap(find.text(deleting ? t.common.delete : t.collections.removeFromCollection));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        if (changed) manager.debugRegisterClientForTesting(replacement);
        await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(t.common.delete)));
        await tester.pumpAndSettle();
        expect(original.removals, changed || deleting ? isEmpty : ['collection:album']);
        expect(original.deletions, changed || !deleting ? isEmpty : ['collection']);
        expect(replacement.deletions, isEmpty);
        expect(replacement.removals, isEmpty);
        if (deleting) {
          manager.owner = false;
          key.currentState!.showContextMenu(key.currentContext!);
          await tester.pumpAndSettle();
          expect(find.text(t.common.delete), findsNothing);
          expect(find.text(t.metadataEdit.editMetadata), findsNothing);
        }
      });
    }
  }
}
