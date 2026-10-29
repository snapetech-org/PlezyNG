import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/game_models.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/games/steam_lan_install_dialog.dart';

void main() {
  testWidgets('install assistance excludes the target and uninstalled routes', (tester) async {
    GameHost host(String id) => GameHost(id: id, name: id, address: '$id.local', protocol: GameProtocol.steam);
    final target = host('target'), donor = host('donor'), empty = host('empty');
    GameRoute route(GameHost h, GameInstallation state) => GameRoute(
      host: h,
      game: StreamGame(hostKey: h.key, id: '620', name: 'Portal 2'),
      installation: state,
      observedAt: DateTime(2026, 10, 29),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SteamLanInstallDialog(
            target: target,
            isCurrent: () => true,
            game: LibraryGame(
              key: 'steam:620',
              name: 'Portal 2',
              steamAppId: 620,
              routes: [
                route(target, GameInstallation.installed),
                route(donor, GameInstallation.installed),
                route(donor, GameInstallation.installed),
                route(empty, GameInstallation.incomplete),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text(t.games.lanInstallCandidates), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
