import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/widgets/tv_spotlight_background.dart';
import 'package:plezy/widgets/tv_spotlight_scaffold.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

class _ArtworkServers extends ChangeNotifier implements MultiServerProvider {
  MediaServerClient? client;
  List<String> visible = ['spotlight-owner'];

  @override
  List<String> get serverIds => visible;
  @override
  MediaServerClient? getClientForServer(ServerId serverId) => client;
  void changed() => notifyListeners();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ArtworkClient implements MediaServerClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('stable TV spotlight observes client arrival and profile visibility', (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final item = testMediaItem(id: 'movie', title: 'Movie', serverId: 'spotlight-owner');
    final hub = MediaHub(id: 'hub', title: 'Hub', type: 'movie', size: 1, items: [item]);
    final selection = ValueNotifier(item);
    final servers = _ArtworkServers();
    addTearDown(selection.dispose);
    addTearDown(servers.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MultiServerProvider>.value(
          value: servers,
          child: MaterialApp(
            home: Scaffold(
              body: TvSpotlightScaffold(
                hubs: [hub],
                spotlightListenable: selection,
                resolveSpotlight: () => item,
                resolveClient: (_) => null,
                foreground: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    TvSpotlightBackground background() => tester.widget<TvSpotlightBackground>(find.byType(TvSpotlightBackground));
    expect(background().client, isNull);
    final client = _ArtworkClient();
    servers.client = client;
    servers.changed();
    await tester.pump();
    expect(background().client, same(client));
    expect(selection.value, same(item));
    servers.visible = [];
    servers.changed();
    await tester.pump();
    expect(background().client, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
