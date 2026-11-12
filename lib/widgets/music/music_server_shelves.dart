import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_account_scope.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_playback_service.dart';
import '../../utils/music_navigation.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../services/music/music_server_recommendations.dart';
import '../../utils/media_navigation_helper.dart';

/// The server's actual music recommendation families, independently of local
/// listening charts. No recommendation data is persisted across accounts.
class MusicServerShelves extends StatefulWidget {
  const MusicServerShelves({super.key});
  @override
  State<MusicServerShelves> createState() => _MusicServerShelvesState();
}

class _MusicServerShelvesState extends State<MusicServerShelves> {
  Object? _signature, _generation;
  Future<MusicServerRecommendations>? _future;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final libraries = context.watch<LibrariesProvider?>();
    final servers = context.watch<MultiServerProvider?>();
    final hidden = context.watch<HiddenLibrariesProvider?>();
    final experience = context.watch<MusicExperience?>();
    final profiles = context.watch<ActiveProfileProvider?>();
    final signature = [
      identityHashCode(libraries),
      identityHashCode(servers),
      identityHashCode(hidden),
      identityHashCode(experience),
      identityHashCode(profiles),
      profiles?.activeId,
      profiles?.isBinding,
      profiles?.lastBindingSucceeded,
      libraries?.libraries
          .map(
            (library) => (
              library.globalKey,
              library.updatedAt,
              library.hidden,
              libraries.libraryContentEpoch(library.globalKey),
            ),
          )
          .join('|'),
      servers?.serverManager.visibleOnlineClients.values
          .map(
            (client) =>
                '${client.serverId}:${identityHashCode(client.authenticationSessionId)}:${musicAccountScope(client)}',
          )
          .join('|'),
      (hidden?.hiddenLibraryKeys.toList() ?? <String>[])..sort(),
    ].join(';');
    if (_signature == signature) return;
    _signature = signature;
    final generation = _generation = Object();
    bool current() =>
        mounted &&
        identical(generation, _generation) &&
        experience != null &&
        experience.store.active &&
        profiles != null &&
        profiles.activeId == experience.store.profileId &&
        !profiles.isBinding &&
        profiles.lastBindingSucceeded;
    _future = _load(libraries, servers, hidden, current);
  }

  Future<MusicServerRecommendations> _load(
    LibrariesProvider? libraries,
    MultiServerProvider? servers,
    HiddenLibrariesProvider? hidden,
    bool Function() current,
  ) async {
    if (libraries == null || servers == null || hidden == null) {
      return MusicServerRecommendations.load([]);
    }
    await hidden.ensureInitialized();
    if (!current() || libraries.isDisposed || hidden.isDisposed) return MusicServerRecommendations.load([]);
    final manager = servers.serverManager;
    final sources = <MusicRecommendationSource>[];
    for (final library in libraries.libraries) {
      if (library.kind != MediaKind.artist ||
          library.serverId == null ||
          library.hidden ||
          hidden.hiddenLibraryKeys.contains(library.globalKey)) {
        continue;
      }
      final server = ServerId(library.serverId!);
      final client = manager.isServerVisible(server) && manager.isClientOnline(server)
          ? manager.getClient(server)
          : null;
      if (client == null || client.backend != library.backend) continue;
      if (sources.length == MusicServerRecommendations.maximumSources) break;
      sources.add(
        MusicRecommendationSource(
          client: client,
          libraryId: library.id,
          libraryName: library.title,
          isCurrent: () =>
              current() &&
              !libraries.isDisposed &&
              !hidden.isDisposed &&
              manager.isServerVisible(server) &&
              manager.isClientOnline(server) &&
              identical(manager.getClient(server), client) &&
              !hidden.hiddenLibraryKeys.contains(library.globalKey) &&
              libraries.libraries.any((row) => row.globalKey == library.globalKey && !row.hidden),
        ),
      );
    }
    return MusicServerRecommendations.load(sources);
  }

  Future<void> _open(MusicServerRecommendation shelf, MediaItem item) async {
    if (!mounted || !shelf.isCurrent || !shelf.hub.items.contains(item)) return;
    if (item.kind != MediaKind.track) {
      await navigateToMediaItem(context, item);
      return;
    }
    final music = context.read<MusicPlaybackService>();
    final intent = music.beginPlayIntent();
    bool current() =>
        mounted &&
        shelf.isCurrent &&
        music.isPlayIntentCurrent(intent) &&
        identical(context.read<MusicPlaybackService>(), music);
    var tracks = <MediaItem>[item];
    var album = false;
    try {
      final id = item.parentId;
      if (id != null && id.isNotEmpty) {
        final rows = await shelf.source.client.fetchAlbumTracks(id).timeout(const Duration(seconds: 10));
        if (!current()) return;
        final owned = rows
            .where((row) => row.kind == MediaKind.track && shelf.source.owns(row) && row.parentId == id)
            .toList(growable: false);
        if (owned.any((row) => row.globalKey == item.globalKey)) {
          tracks = owned;
          album = true;
        }
      }
    } catch (_) {
      if (!current()) return;
      // A failed album read can fall back to this authorized track only.
    }
    if (!current()) return;
    try {
      await music.playFromList(
        tracks: tracks,
        startTrack: tracks.firstWhere((row) => row.globalKey == item.globalKey),
        playContext: MusicPlayContext(
          title: album ? item.albumTitle ?? shelf.hub.title : shelf.hub.title,
          kind: album ? MusicPlayContextKind.album : MusicPlayContextKind.tracks,
        ),
      );
      if (mounted && current() && PlatformDetector.isTV()) await openNowPlaying(context);
    } catch (_) {
      if (mounted && current()) showErrorSnackBar(context, t.musicExperience.error);
    }
  }

  @override
  void dispose() {
    _generation = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MusicServerRecommendations>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) return const LinearProgressIndicator();
      final selection = snapshot.data, shelves = selection?.shelves ?? [];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (snapshot.hasError || selection?.hasFailures == true)
            Padding(padding: const EdgeInsets.all(16), child: Text(t.musicExperience.error)),
          if (shelves.isEmpty && !snapshot.hasError && selection?.hasFailures != true)
            Padding(padding: const EdgeInsets.all(16), child: Text(t.libraries.noRecommendations)),
          for (final shelf in shelves)
            ExpansionTile(
              key: ValueKey((shelf.source.client.serverId.value, shelf.source.libraryId, shelf.hub.id)),
              title: Text(shelf.hub.title),
              subtitle: Text(
                [
                  shelf.source.client.serverName,
                  shelf.source.libraryName,
                ].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
              ),
              children: [
                for (final item in shelf.hub.items)
                  ListTile(
                    title: Text(item.displayTitle),
                    subtitle: Text(item.trackArtistTitle ?? item.parentTitle ?? ''),
                    onTap: () => _open(shelf, item),
                  ),
              ],
            ),
        ],
      );
    },
  );
}
