import 'package:flutter/widgets.dart';
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

/// The original actor and source of an asynchronous track/album decision.
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
    if (!_actorCurrent || !_visible(seed)) return false;
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
        files.isDownloaded(seed.globalKey) &&
        files.downloadedTracks.any((item) => item.globalKey == seed.globalKey && item.backend == seed.backend);
  }

  bool ownsAlbumTrack(MediaItem item, String albumId) =>
      current &&
      item.kind == MediaKind.track &&
      item.backend == seed.backend &&
      item.serverId == seed.serverId &&
      item.parentId == albumId &&
      (seed.libraryId == null || item.libraryId == seed.libraryId) &&
      _visible(item);

  static Future<MusicReadScope?> forTrack(BuildContext context, MediaItem track, {bool offline = false}) async {
    final profiles = context.read<ActiveProfileProvider?>();
    final servers = context.read<MultiServerProvider?>();
    final downloads = context.read<DownloadProvider?>();
    final hidden = context.read<HiddenLibrariesProvider?>();
    final server = serverIdOrNull(track.serverId);
    if (profiles?.activeId == null || server == null || track.kind != MediaKind.track) return null;
    final candidate = servers?.getClientForServer(server);
    final client =
        !offline &&
            candidate != null &&
            !candidate.isOfflineMode &&
            servers!.serverManager.isServerVisible(server) &&
            servers.serverManager.isClientOnline(server)
        ? candidate
        : null;
    final scope = MusicReadScope._(context, track, profiles!, servers, downloads, hidden, client);
    if (!scope._actorCurrent) return null;
    try {
      await hidden?.ensureInitialized();
    } catch (_) {
      return null;
    }
    return scope.current ? scope : null;
  }
}
