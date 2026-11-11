import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/screens/playlist/playlist_metadata_editor.dart';

const original = MediaPlaylist(
  id: '42',
  backend: MediaBackend.plex,
  serverId: 'srv',
  title: 'Original',
  summary: 'Description',
  playlistType: 'audio',
);

class _EditorClient implements PlaylistMetadataClient {
  final calls = <({String? title, String? summary})>[];
  final result = Completer<MediaPlaylist>();
  @override
  Future<MediaPlaylist> updatePlaylistMetadata({
    required MediaPlaylist playlist,
    String? title,
    String? summary,
    bool Function()? isCurrent,
  }) {
    if (isCurrent?.call() == false) throw StateError('Retired account');
    calls.add((title: title, summary: summary));
    return result.future;
  }
}

void main() {
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  Future<void> open(
    WidgetTester tester,
    _EditorClient client, {
    bool Function()? isCurrent,
    void Function(MediaPlaylist?)? onResult,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              child: const Text('Open'),
              onPressed: () async {
                final result = await showDialog<MediaPlaylist>(
                  context: context,
                  builder: (_) =>
                      PlaylistMetadataEditor(playlist: original, client: client, isCurrent: isCurrent ?? () => true),
                );
                onResult?.call(result);
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  final title = find.byKey(const ValueKey('playlist_metadata_title'));
  final summary = find.byKey(const ValueKey('playlist_metadata_summary'));
  final save = find.byKey(const ValueKey('playlist_metadata_save'));

  testWidgets('only changed fields save and accepted metadata returns to caller', (tester) async {
    final client = _EditorClient();
    MediaPlaylist? result;
    await open(tester, client, onResult: (value) => result = value);
    await tester.enterText(title, ' Renamed ');
    await tester.tap(save);
    await tester.pump();
    expect(client.calls, [(title: 'Renamed', summary: null)]);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    const updated = MediaPlaylist(
      id: '42',
      backend: MediaBackend.plex,
      title: 'Renamed',
      serverId: 'srv',
      summary: 'Description',
      playlistType: 'audio',
    );
    client.result.complete(updated);
    await tester.pumpAndSettle();
    expect(result, same(updated));
    expect(find.byType(PlaylistMetadataEditor), findsNothing);
  });

  testWidgets('clearing summary sends empty string while preserving title', (tester) async {
    final client = _EditorClient();
    await open(tester, client);
    await tester.enterText(summary, '');
    await tester.tap(save);
    await tester.pump();
    expect(client.calls, [(title: null, summary: '')]);
    client.result.complete(original);
    await tester.pumpAndSettle();
  });

  testWidgets('blank title is rejected locally and cancel has no write', (tester) async {
    final client = _EditorClient();
    await open(tester, client);
    await tester.enterText(title, ' ');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text(t.playlists.enterPlaylistName), findsOneWidget);
    expect(client.calls, isEmpty);
    await tester.tap(find.text(t.common.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistMetadataEditor), findsNothing);
  });

  testWidgets('unchanged form closes without a write', (tester) async {
    final client = _EditorClient();
    await open(tester, client);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(client.calls, isEmpty);
    expect(find.byType(PlaylistMetadataEditor), findsNothing);
  });

  testWidgets('failed save retains inputs and enables retry', (tester) async {
    final client = _EditorClient();
    await open(tester, client);
    await tester.enterText(title, 'Keep draft');
    await tester.tap(save);
    await tester.pump();
    client.result.completeError(StateError('Permission denied'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistMetadataEditor), findsOneWidget);
    expect(tester.widget<TextFormField>(title).controller!.text, 'Keep draft');
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account switch before save makes no request', (tester) async {
    var current = true;
    final client = _EditorClient();
    await open(tester, client, isCurrent: () => current);
    await tester.enterText(title, 'Draft');
    current = false;
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(client.calls, isEmpty);
    expect(find.byType(PlaylistMetadataEditor), findsOneWidget);
  });

  testWidgets('retired completion cannot return success', (tester) async {
    var current = true;
    MediaPlaylist? result;
    final client = _EditorClient();
    await open(tester, client, isCurrent: () => current, onResult: (value) => result = value);
    await tester.enterText(title, 'Draft');
    await tester.tap(save);
    await tester.pump();
    current = false;
    client.result.complete(original);
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byType(PlaylistMetadataEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
