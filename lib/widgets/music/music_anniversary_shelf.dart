import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../screens/music/album_detail_screen.dart';
import '../../services/music/music_anniversaries.dart';
import '../../services/music/music_experience.dart';
import '../../utils/media_server_http_client.dart' show AbortController;

class MusicAnniversaryShelf extends StatefulWidget {
  const MusicAnniversaryShelf({super.key});
  @override
  State<MusicAnniversaryShelf> createState() => _MusicAnniversaryShelfState();
}

class _MusicAnniversaryShelfState extends State<MusicAnniversaryShelf> {
  Future<List<MediaItem>>? _future;
  AbortController? _abort;
  String? _signature;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final libraries = context.watch<LibrariesProvider?>();
    final servers = context.watch<MultiServerProvider?>();
    final hidden = context.watch<HiddenLibrariesProvider?>();
    final signature = [
      libraries?.libraries
          .map(
            (library) =>
                '${library.globalKey}:${library.updatedAt}:${libraries.libraryContentEpoch(library.globalKey)}',
          )
          .join('|'),
      servers?.serverManager.visibleOnlineClients.values
          .map((client) => '${client.serverId}:${identityHashCode(client.authenticationSessionId)}')
          .join('|'),
      hidden?.hiddenLibraryKeys.join('|'),
      DateTime.now().toIso8601String().substring(0, 10),
    ].join(';');
    if (_signature == signature) return;
    _signature = signature;
    _abort?.abort();
    final abort = _abort = AbortController();
    _future = _load(libraries, servers, hidden, abort);
  }

  Future<List<MediaItem>> _load(
    LibrariesProvider? libraries,
    MultiServerProvider? servers,
    HiddenLibrariesProvider? hidden,
    AbortController abort,
  ) async {
    final store = context.read<MusicExperience>().store;
    if (libraries == null || servers == null || hidden == null) return [];
    await hidden.ensureInitialized();
    abort.throwIfAborted();
    if (!mounted) return [];
    final result = <MediaItem>[];
    for (final library in libraries.libraries) {
      if (library.kind != MediaKind.artist ||
          library.serverId == null ||
          hidden.hiddenLibraryKeys.contains(library.globalKey)) {
        continue;
      }
      final server = ServerId(library.serverId!);
      final client = servers.getClientForServer(server);
      if (client == null) continue;
      result.addAll(
        await MusicAnniversaries(store).load(
          client,
          library.id,
          libraryRevision: library.updatedAt,
          contentEpoch: libraries.libraryContentEpoch(library.globalKey),
          abort: abort,
          isCurrent: () =>
              mounted &&
              identical(_abort, abort) &&
              servers.serverManager.isServerVisible(server) &&
              identical(client, servers.getClientForServer(server)) &&
              !hidden.hiddenLibraryKeys.contains(library.globalKey),
        ),
      );
    }
    return result;
  }

  @override
  void dispose() {
    _abort?.abort();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MediaItem>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) return const LinearProgressIndicator();
      if (snapshot.hasError) return Padding(padding: const EdgeInsets.all(16), child: Text(t.musicExperience.error));
      final albums = snapshot.data ?? [];
      if (albums.isEmpty) return Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.noHistory));
      return Column(
        children: [
          for (final album in albums)
            ListTile(
              title: Text(album.displayTitle),
              subtitle: Text('${album.parentTitle ?? ''} · ${album.originallyAvailableAt?.split('T').first ?? ''}'),
              onTap: () =>
                  Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album))),
            ),
        ],
      );
    },
  );
}
