import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/screens/music/music_group_screen.dart';

class _Remote extends CompanionRemoteProvider {
  final hosts = StreamController<List<DiscoveredHost>>.broadcast(sync: true);
  final selected = <DiscoveredHost>[];
  bool listening = false;
  int stopped = 0;
  @override
  bool get canManageMusicGroups => true;
  @override
  bool get supportsMusicGroup => false;
  @override
  bool get musicGroupActive => selected.isNotEmpty;
  @override
  bool get isDiscoveringHosts => listening;
  @override
  bool isOwnMusicEndpoint(DiscoveredHost host) => false;
  @override
  List<DiscoveredHost> get musicGroupEndpoints => List.of(selected);
  @override
  bool musicGroupEndpointJoined(DiscoveredHost host) => selected.contains(host);
  @override
  Stream<List<DiscoveredHost>>? discoverHosts() {
    listening = true;
    return hosts.stream;
  }

  @override
  void stopDiscovery() {
    stopped++;
    listening = false;
  }

  @override
  Future<bool> addMusicGroupEndpoint(DiscoveredHost host, {String? pairingCode}) async {
    selected.add(host);
    notifyListeners();
    return true;
  }

  @override
  Future<void> removeMusicGroupEndpoint(DiscoveredHost host) async {
    selected.remove(host);
    notifyListeners();
  }

  @override
  void leaveMusicGroup() {
    selected.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(hosts.close());
    super.dispose();
  }
}

void main() {
  testWidgets('discovered endpoints can join and leave independently from the music group screen', (tester) async {
    final remote = _Remote();
    addTearDown(remote.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: remote,
        child: MaterialApp(home: const MusicGroupScreen()),
      ),
    );
    final first = DiscoveredHost(
      authContextId: 'account',
      clientId: 'first',
      name: 'Kitchen',
      platform: 'linux',
      port: 48634,
      ips: ['192.0.2.1'],
    );
    final second = DiscoveredHost(
      authContextId: 'account',
      clientId: 'second',
      name: 'Office',
      platform: 'linux',
      port: 48634,
      ips: ['192.0.2.2'],
    );
    remote.hosts.add([first, second]);
    await tester.pump();
    await tester.tap(find.text('Kitchen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Office'));
    await tester.pumpAndSettle();
    expect(remote.selected, [first, second]);
    expect(find.text(t.watchTogether.connected), findsNWidgets(2));
    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('joined:account:first')), matching: find.byType(IconButton)),
    );
    await tester.pumpAndSettle();
    expect(remote.selected, [second]);
    expect(find.byKey(const ValueKey('joined:account:second')), findsOneWidget);
    await tester.tap(find.byTooltip(t.common.cancel).first);
    await tester.pumpAndSettle();
    expect(remote.selected, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(remote.stopped, 1);
  });

  testWidgets('leaving the group screen preserves an existing discovery listener', (tester) async {
    final remote = _Remote()..listening = true;
    addTearDown(remote.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: remote,
        child: MaterialApp(home: const MusicGroupScreen()),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(remote.stopped, 0);
  });
}
