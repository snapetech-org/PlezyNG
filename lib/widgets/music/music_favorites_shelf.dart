import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_kind.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_favorites.dart';
import '../../services/music/music_playback_service.dart';
import '../../services/music/music_account_scope.dart';
import '../../utils/snackbar_helper.dart';

Future<MusicFavoriteSelection> loadProfileMusicFavorites(BuildContext context) async {
  final libraries = context.read<LibrariesProvider?>();
  final servers = context.read<MultiServerProvider?>();
  final hidden = context.read<HiddenLibrariesProvider?>();
  final store = context.read<MusicExperience?>()?.store;
  if (libraries == null || servers == null || hidden == null) return MusicFavoriteSelection.load([]);
  await hidden.ensureInitialized();
  if (libraries.isDisposed || hidden.isDisposed || store != null && !store.active) {
    return MusicFavoriteSelection.load([]);
  }
  final sources = <MusicFavoriteSource>[];
  for (final library in libraries.libraries) {
    if (library.kind != MediaKind.artist ||
        library.serverId == null ||
        library.hidden ||
        hidden.hiddenLibraryKeys.contains(library.globalKey)) {
      continue;
    }
    final serverId = ServerId(library.serverId!);
    final manager = servers.serverManager;
    final client = manager.isServerVisible(serverId) ? manager.getClient(serverId) : null;
    if (client == null) continue;
    sources.add(
      MusicFavoriteSource(
        client: client,
        libraryId: library.id,
        isCurrent: () =>
            !libraries.isDisposed &&
            !hidden.isDisposed &&
            (store == null || store.active) &&
            manager.isServerVisible(serverId) &&
            identical(manager.getClient(serverId), client) &&
            !hidden.hiddenLibraryKeys.contains(library.globalKey) &&
            libraries.libraries.any((current) => current.globalKey == library.globalKey && !current.hidden),
      ),
    );
  }
  return MusicFavoriteSelection.load(sources);
}

class MusicFavoritesShelf extends StatefulWidget {
  const MusicFavoritesShelf({super.key});
  @override
  State<MusicFavoritesShelf> createState() => _MusicFavoritesShelfState();
}

class _MusicFavoritesShelfState extends State<MusicFavoritesShelf> {
  String? _signature;
  Future<MusicFavoriteSelection>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final libraries = context.watch<LibrariesProvider?>();
    final servers = context.watch<MultiServerProvider?>();
    final hidden = context.watch<HiddenLibrariesProvider?>();
    final signature = [
      libraries?.libraries.map((library) => '${library.globalKey}:${library.updatedAt}:${library.hidden}').join('|'),
      servers?.serverManager.visibleOnlineClients.values
          .map(
            (client) =>
                '${client.serverId}:${identityHashCode(client.authenticationSessionId)}:${musicAccountScope(client)}',
          )
          .join('|'),
      hidden?.hiddenLibraryKeys.join('|'),
    ].join(';');
    if (_signature != signature) {
      _signature = signature;
      _future = loadProfileMusicFavorites(context);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MusicFavoriteSelection>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) return const LinearProgressIndicator();
      final tracks = snapshot.data?.tracks ?? [];
      if (tracks.isEmpty) return Padding(padding: const EdgeInsets.all(16), child: Text(t.messages.noResultsFound));
      return Column(
        children: [
          for (final track in tracks.take(30))
            ListTile(
              title: Text(track.displayTitle),
              subtitle: Text(track.trackArtistTitle ?? ''),
              onTap: () async {
                final current = snapshot.data?.tracks ?? [];
                if (!current.any((item) => item.globalKey == track.globalKey)) return;
                try {
                  await context.read<MusicPlaybackService>().playFromList(
                    tracks: current,
                    startTrack: track,
                    playContext: MusicPlayContext(
                      title: t.libraries.filterCategories.favorites,
                      kind: MusicPlayContextKind.tracks,
                    ),
                  );
                } catch (_) {
                  if (context.mounted) showErrorSnackBar(context, t.musicExperience.error);
                }
              },
            ),
        ],
      );
    },
  );
}
