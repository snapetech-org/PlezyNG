import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/screens/playlist/playlist_artwork_editor.dart';
import 'package:plezy/services/file_picker_service.dart';

const playlist = MediaPlaylist(
  id: '42',
  backend: MediaBackend.plex,
  title: 'Mix',
  playlistType: 'audio',
  serverId: 'srv',
);

class _Client extends Fake implements MediaServerClient, PlaylistArtworkClient {
  final calls = <({String? key, List<int>? bytes, bool reset})>[];
  Future<List<PlaylistArtworkOption>> Function()? load;
  Future<MediaPlaylist> Function()? save;
  @override
  Future<List<PlaylistArtworkOption>> fetchPlaylistArtwork(MediaPlaylist playlist, {bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) throw StateError('Retired');
    return load == null ? [] : load!();
  }

  @override
  Future<MediaPlaylist> updatePlaylistArtwork({
    required MediaPlaylist playlist,
    String? artworkKey,
    List<int>? bytes,
    bool reset = false,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false) throw StateError('Retired');
    calls.add((key: artworkKey, bytes: bytes, reset: reset));
    return save == null ? playlist : save!();
  }

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) => '';
}

class _Picker extends Fake implements FilePickerDelegate {
  final result = Completer<FilePickerResult?>();
  bool? withData;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    bool withData = false,
  }) {
    this.withData = withData;
    return result.future;
  }
}

void main() {
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));
  tearDown(() => FilePickerService.setDelegateForTesting(null));

  Future<void> open(
    WidgetTester tester,
    _Client client, {
    bool Function()? current,
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
                      PlaylistArtworkEditor(playlist: playlist, client: client, isCurrent: current ?? () => true),
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

  testWidgets('selecting a server option returns the acknowledged artwork', (tester) async {
    final client = _Client()
      ..load = () async => [
        const PlaylistArtworkOption(key: 'upload://choice', thumbnailPath: '/poster', selected: true),
      ];
    MediaPlaylist? result;
    await open(tester, client, onResult: (value) => result = value);
    expect(find.bySemanticsLabel(t.metadataEdit.selectedArtworkOption(index: 1)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist_artwork_0')));
    await tester.pumpAndSettle();
    expect(client.calls.single.key, 'upload://choice');
    expect(result, same(playlist));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retired options read cannot expose another accounts images', (tester) async {
    var current = true;
    final gate = Completer<List<PlaylistArtworkOption>>();
    final client = _Client()..load = () => gate.future;
    // Avoid settling the still-pending loading indicator.
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: PlaylistArtworkEditor(playlist: playlist, client: client, isCurrent: () => current),
        ),
      ),
    );
    await tester.pump();
    current = false;
    gate.complete([const PlaylistArtworkOption(key: 'old', thumbnailPath: '/old', selected: false)]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playlist_artwork_0')), findsNothing);
    expect(client.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty choices still allow restoring default artwork', (tester) async {
    final client = _Client();
    MediaPlaylist? result;
    await open(tester, client, onResult: (value) => result = value);
    expect(find.text(t.metadataEdit.noArtworkAvailable), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist_artwork_reset')));
    await tester.pumpAndSettle();
    expect(client.calls.single.reset, isTrue);
    expect(result, same(playlist));
  });

  testWidgets('failed default reset keeps dialog available for explicit retry', (tester) async {
    final client = _Client()..save = () async => throw StateError('Denied');
    await open(tester, client);
    await tester.tap(find.byKey(const ValueKey('playlist_artwork_reset')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistArtworkEditor), findsOneWidget);
    expect(client.calls, hasLength(1));
    client.save = null;
    await tester.tap(find.byKey(const ValueKey('playlist_artwork_reset')));
    await tester.pumpAndSettle();
    expect(client.calls, hasLength(2));
    expect(find.byType(PlaylistArtworkEditor), findsNothing);
  });

  testWidgets('load failure offers explicit retry', (tester) async {
    final client = _Client()..load = () async => throw StateError('Unavailable');
    await open(tester, client);
    expect(find.text(t.common.retry), findsOneWidget);
    client.load = () async => [];
    await tester.tap(find.text(t.common.retry));
    await tester.pumpAndSettle();
    expect(find.text(t.metadataEdit.noArtworkAvailable), findsOneWidget);
  });

  testWidgets('account switch before an action prevents the write', (tester) async {
    var current = true;
    final client = _Client();
    await open(tester, client, current: () => current);
    current = false;
    await tester.tap(find.byKey(const ValueKey('playlist_artwork_reset')));
    await tester.pumpAndSettle();
    expect(client.calls, isEmpty);
    expect(find.byType(PlaylistArtworkEditor), findsOneWidget);
  });

  testWidgets('account switch during an acknowledged write cannot return success', (tester) async {
    var current = true;
    final gate = Completer<MediaPlaylist>();
    final client = _Client()..save = () => gate.future;
    MediaPlaylist? result;
    await open(tester, client, current: () => current, onResult: (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('playlist_artwork_reset')));
    await tester.pump();
    current = false;
    gate.complete(playlist);
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byType(PlaylistArtworkEditor), findsOneWidget);
  });

  testWidgets('account switch while file picker is open discards its result', (tester) async {
    var current = true;
    final client = _Client();
    final picker = _Picker();
    FilePickerService.setDelegateForTesting(picker);
    await open(tester, client, current: () => current);
    await tester.tap(find.byKey(const ValueKey('playlist_artwork_upload')));
    await tester.pump();
    expect(picker.withData, isFalse);
    current = false;
    picker.result.complete(
      FilePickerResult([
        PlatformFile(name: 'x.png', size: 3, bytes: Uint8List.fromList([1, 2, 3])),
      ]),
    );
    await tester.pumpAndSettle();
    expect(client.calls, isEmpty);
  });

  for (final oversized in [false, true]) {
    testWidgets('rejects ${oversized ? "oversized" : "invalid"} image before upload', (tester) async {
      final client = _Client();
      final picker = _Picker();
      FilePickerService.setDelegateForTesting(picker);
      await open(tester, client);
      await tester.tap(find.byKey(const ValueKey('playlist_artwork_upload')));
      await tester.pump();
      picker.result.complete(
        FilePickerResult([
          PlatformFile(
            name: 'x.png',
            size: oversized ? PlaylistArtworkClient.maxUploadBytes + 1 : 3,
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(client.calls, isEmpty);
      expect(find.byType(PlaylistArtworkEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('valid bounded image uploads once and returns accepted playlist', (tester) async {
    final client = _Client();
    final picker = _Picker();
    FilePickerService.setDelegateForTesting(picker);
    await open(tester, client);
    await tester.tap(find.byKey(const ValueKey('playlist_artwork_upload')));
    await tester.pump();
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jB7sAAAAASUVORK5CYII=',
    );
    picker.result.complete(FilePickerResult([PlatformFile(name: 'x.png', size: bytes.length, bytes: bytes)]));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(client.calls, hasLength(1));
    expect(client.calls.single.bytes, bytes);
    expect(find.byType(PlaylistArtworkEditor), findsNothing);
  });
}
