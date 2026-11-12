import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:provider/provider.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../profiles/active_profile_provider.dart';
import '../providers/download_provider.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/music/music_account_scope.dart';

/// The original actor and source of an asynchronous music decision.
/// Owned offline files remain usable without inventing a live server actor.
class MusicReadScope {
  MusicReadScope._(this.context, this.seed, this.profiles, this.servers, this.downloads, this.hidden, this.client)
    : profile = profiles.activeId!,
      generation = profiles.identityMutationGeneration,
      authentication = client?.authenticationSessionId,
      account = client == null ? null : musicAccountScope(client);
  final BuildContext context;
  final MediaItem seed;
  final ActiveProfileProvider profiles;
  final MultiServerProvider? servers;
  final DownloadProvider? downloads;
  final HiddenLibrariesProvider? hidden;
  final MediaServerClient? client;
  final String profile;
  final int generation;
  final Object? authentication;
  final String? account;
  bool get offline => client == null;
  Set<String>? _visibility;
  List<MediaItem> _offlineTracks = const [];
  List<MediaItem> get offlineTracks => _offlineTracks;

  bool get _actorCurrent =>
      context.mounted &&
      identical(context.read<ActiveProfileProvider?>(), profiles) &&
      identical(context.read<MultiServerProvider?>(), servers) &&
      identical(context.read<DownloadProvider?>(), downloads) &&
      identical(context.read<HiddenLibrariesProvider?>(), hidden) &&
      profiles.activeId == profile &&
      profiles.identityMutationGeneration == generation &&
      !profiles.isBinding &&
      profiles.lastBindingSucceeded &&
      (servers == null || !servers!.isDisposed) &&
      (hidden == null || !hidden!.isDisposed && (hidden!.profileId == null || hidden!.profileId == profile));

  bool _visible(MediaItem item) =>
      hidden == null ||
      hidden!.isInitialized &&
          (item.libraryId == null || !hidden!.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}'));

  bool get current {
    if (!_actorCurrent || !_visible(seed) || !setEquals(hidden?.hiddenLibraryKeys, _visibility)) return false;
    final source = client;
    if (source != null) {
      final server = serverIdOrNull(seed.serverId);
      return server != null &&
          source.backend == seed.backend &&
          source.serverId.value == seed.serverId &&
          !source.isOfflineMode &&
          identical(source.authenticationSessionId, authentication) &&
          musicAccountScope(source) == account &&
          servers != null &&
          servers!.serverManager.isServerVisible(server) &&
          servers!.serverManager.isClientOnline(server) &&
          identical(servers!.serverManager.getClient(server), source);
    }
    final files = downloads;
    return files != null &&
        !files.isDisposed &&
        files.activeProfileId == profile &&
        _offlineTracks.isNotEmpty &&
        _offlineTracks.every((item) => files.isDownloaded(item.globalKey) && _visible(item));
  }

  bool ownsAlbumTrack(MediaItem item, String albumId) =>
      current &&
      item.kind == MediaKind.track &&
      item.backend == seed.backend &&
      item.serverId == seed.serverId &&
      item.parentId == albumId &&
      (seed.libraryId == null || item.libraryId == seed.libraryId) &&
      _visible(item);

  /// Validate descendants without changing the captured server or account.
  bool ownsTrack(MediaItem item) => current && _matchesTrack(item);

  /// A synchronous batch needs one live ownership check. In particular,
  /// offline ownership must not re-scan the entire file list for each row.
  bool ownsTracks(Iterable<MediaItem> items) => current && items.every(_matchesTrack);

  bool _matchesTrack(MediaItem item) =>
      item.kind == MediaKind.track &&
      item.backend == seed.backend &&
      item.serverId == seed.serverId &&
      (seed.libraryId == null || item.libraryId == seed.libraryId) &&
      (seed.kind != MediaKind.album || item.parentId == seed.id) &&
      _visible(item);

  static Future<MusicReadScope?> forTrack(BuildContext context, MediaItem track, {bool offline = false}) {
    if (track.kind != MediaKind.track) return Future.value(null);
    return forItem(context, track, offline: offline);
  }

  /// [selectedClient] is an exact source, not a hint for server failover.
  /// Offline playlists require their already saved occurrence list; container
  /// queues are built from the current profile's completed owned files.
  static Future<MusicReadScope?> forItem(
    BuildContext context,
    MediaItem item, {
    bool offline = false,
    MediaServerClient? selectedClient,
    List<MediaItem>? offlinePlaylistTracks,
  }) async {
    final profiles = context.read<ActiveProfileProvider?>();
    final servers = context.read<MultiServerProvider?>();
    final downloads = context.read<DownloadProvider?>();
    final hidden = context.read<HiddenLibrariesProvider?>();
    final server = serverIdOrNull(item.serverId);
    if (profiles?.activeId == null ||
        server == null ||
        !{MediaKind.track, MediaKind.album, MediaKind.artist, MediaKind.playlist}.contains(item.kind)) {
      return null;
    }
    final candidate = servers?.getClientForServer(server);
    if (selectedClient != null &&
        (selectedClient.backend != item.backend ||
            selectedClient.serverId != server ||
            !selectedClient.isOfflineMode && !identical(candidate, selectedClient))) {
      return null;
    }
    final client =
        !offline &&
            selectedClient?.isOfflineMode != true &&
            candidate != null &&
            !candidate.isOfflineMode &&
            servers!.serverManager.isServerVisible(server) &&
            servers.serverManager.isClientOnline(server)
        ? candidate
        : null;
    if (selectedClient != null && !offline && !selectedClient.isOfflineMode && client == null) return null;
    final scope = MusicReadScope._(context, item, profiles!, servers, downloads, hidden, client);
    if (!scope._actorCurrent) return null;
    try {
      await hidden?.ensureInitialized();
    } catch (_) {
      return null;
    }
    if (!scope._actorCurrent || !scope._visible(item)) return null;
    scope._visibility = hidden == null ? null : Set.of(hidden.hiddenLibraryKeys);
    if (scope.offline) {
      if (downloads == null || downloads.isDisposed || downloads.activeProfileId != scope.profile) return null;
      final owned = {
        for (final track in downloads.downloadedTracks)
          if (track.kind == MediaKind.track &&
              track.backend == item.backend &&
              track.serverId == item.serverId &&
              scope._visible(track))
            track.globalKey: track,
      };
      final selected = switch (item.kind) {
        MediaKind.track => [?owned[item.globalKey]],
        MediaKind.album =>
          owned.values.where((track) => track.parentId == item.id).toList()..sort((a, b) {
            final disc = (a.parentIndex ?? 1).compareTo(b.parentIndex ?? 1);
            return disc != 0 ? disc : (a.index ?? 0).compareTo(b.index ?? 0);
          }),
        MediaKind.artist => owned.values.where((track) => track.grandparentId == item.id).toList(),
        MediaKind.playlist => offlinePlaylistTracks ?? <MediaItem>[],
        _ => <MediaItem>[],
      };
      if (selected.isEmpty ||
          selected.any(
            (track) =>
                track.kind != MediaKind.track ||
                track.backend != item.backend ||
                track.serverId != item.serverId ||
                !owned.containsKey(track.globalKey) ||
                !scope._matchesTrack(track),
          )) {
        return null;
      }
      scope._offlineTracks = List.unmodifiable(selected);
    }
    return scope.current ? scope : null;
  }
}
