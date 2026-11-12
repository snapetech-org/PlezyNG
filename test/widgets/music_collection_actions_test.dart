import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/dialog_action_button.dart';
import 'package:plezy/widgets/media_context_menu.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/music_experience_fakes.dart';

class _Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  Profile active = Profile.local(id: 'p', displayName: 'Owner', createdAt: DateTime.utc(2024));
  @override
  String get activeId => active.id;
  @override
  bool isBinding = false;
  @override
  bool lastBindingSucceeded = true;
  @override
  int identityMutationGeneration = 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Manager extends MultiServerManager {
  bool owner = true;
  @override
  bool isOwnerOrAdmin(ServerId id) => owner;
}

class _Client extends ExperienceClient {
  final List<(String, String)> additions = [];
  final List<(MediaKind?, String)> creations = [];
  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => LibraryPage(
    items: [
      for (final subtype in ['album', 'artist'])
        MediaItem.plex(
          id: '$subtype-collection',
          kind: MediaKind.collection,
          title: '$subtype collection',
          subtype: subtype,
          serverId: 's',
          libraryId: libraryId,
        ),
    ],
    offset: start ?? 0,
    totalCount: 2,
  );
  @override
  Future<bool> addToCollection({
    required String collectionId,
    required List<MediaItem> items,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() != true) throw StateError('Expired test scope');
    additions.add((collectionId, items.single.id));
    return true;
  }

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() != true) throw StateError('Expired test scope');
    creations.add((itemKind, title));
    return 'created';
  }
}

Future<({GlobalKey<MediaContextMenuState> key, _Client client, _Profile profile})> _menu(
  WidgetTester tester, {
  MediaKind kind = MediaKind.album,
  bool owner = true,
  bool managed = false,
}) async {
  LocaleSettings.setLocaleSync(AppLocale.en);
  TvDetectionService.debugSetAppleTVOverride(true);
  addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
  final client = _Client(), profile = _Profile();
  if (managed) profile.active = Profile.plexHome(id: 'p', displayName: 'Managed', createdAt: DateTime.utc(2024));
  final manager = _Manager()
    ..owner = owner
    ..debugRegisterClientForTesting(client);
  final servers = testMultiServerProvider(manager);
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
              item: testMediaItem(id: 'seed', kind: kind, serverId: 's', libraryId: 'music'),
              child: const Text('source'),
            ),
          ),
        ),
      ),
    ),
  );
  key.currentState!.showContextMenu(key.currentContext!);
  await tester.pumpAndSettle();
  return (key: key, client: client, profile: profile);
}

void main() {
  testWidgets('album collection action disables artist destinations and adds to matching collection', (tester) async {
    final h = await _menu(tester);
    await tester.tap(find.text(t.common.addTo));
    await tester.pumpAndSettle();
    final artist = tester.widget<FocusableListTile>(
      find.ancestor(of: find.text('artist collection'), matching: find.byType(FocusableListTile)),
    );
    final album = tester.widget<FocusableListTile>(
      find.ancestor(of: find.text('album collection'), matching: find.byType(FocusableListTile)),
    );
    expect(artist.enabled, isFalse);
    expect(album.enabled, isTrue);
    await tester.tap(find.text('album collection'));
    await tester.pumpAndSettle();
    expect(h.client.additions, [('album-collection', 'seed')]);
  });

  testWidgets('artist action creates an artist collection after the name decision', (tester) async {
    final h = await _menu(tester, kind: MediaKind.artist);
    await tester.tap(find.text(t.common.addTo));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.common.createNew));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Favorite artists');
    await tester.tap(find.widgetWithText(DialogActionButton, t.common.save));
    await tester.pumpAndSettle();
    expect(h.client.creations, [(MediaKind.artist, 'Favorite artists')]);
  });

  testWidgets('a retained collection picker cannot add after authentication changes', (tester) async {
    final h = await _menu(tester);
    await tester.tap(find.text(t.common.addTo));
    await tester.pumpAndSettle();
    h.client.authenticationSessionId = Object();
    await tester.tap(find.text('album collection'));
    await tester.pumpAndSettle();
    expect(h.client.additions, isEmpty);
  });

  for (final managed in [false, true]) {
    testWidgets('shared or managed=$managed music menus have no collection write action', (tester) async {
      await _menu(tester, owner: managed, managed: managed);
      expect(find.text(t.common.addTo), findsNothing);
    });
  }

  testWidgets('track menu cannot create track collections', (tester) async {
    await _menu(tester, kind: MediaKind.track);
    expect(find.text(t.common.addTo), findsNothing);
  });
}
