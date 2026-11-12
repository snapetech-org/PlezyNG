import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../media/ids.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/music/music_account_scope.dart';

bool isAdminActionAllowedForMediaItem({
  required bool isOwnerOrAdmin,
  required MediaBackend? itemBackend,
  required Profile? activeProfile,
}) {
  final blockedByPlexHomeRole =
      itemBackend == MediaBackend.plex && activeProfile != null && activeProfile.isPlexHome && !activeProfile.plexAdmin;
  return isOwnerOrAdmin && !blockedByPlexHomeRole;
}

/// Pins the actor shown a collection action. Live permissions and source
/// visibility are rechecked after pickers/confirmations, never re-resolved
/// into a replacement account when a delayed decision completes.
class MediaCollectionWriteScope {
  MediaCollectionWriteScope({required this.client, required this.item, required this.authorized, this.libraryVisible})
    : _authentication = client.authenticationSessionId,
      _account = musicAccountScope(client);
  final MediaServerClient client;
  final MediaItem item;
  final bool Function() authorized;
  final bool Function(String libraryId)? libraryVisible;

  bool allowsLibrary(String libraryId) =>
      current &&
      libraryId.isNotEmpty &&
      (item.libraryId == null || item.libraryId == libraryId) &&
      (libraryVisible?.call(libraryId) ?? true);
  final Object _authentication;
  final String _account;
  bool get current =>
      authorized() &&
      !client.isOfflineMode &&
      item.backend == client.backend &&
      item.serverId == client.serverId.value &&
      identical(_authentication, client.authenticationSessionId) &&
      _account == musicAccountScope(client);

  static MediaCollectionWriteScope? forItem(BuildContext context, MediaItem item) {
    final server = serverIdOrNull(item.serverId);
    final servers = context.read<MultiServerProvider?>();
    final profiles = context.read<ActiveProfileProvider?>();
    if (server == null || servers == null || profiles == null) return null;
    final profileId = profiles.activeId;
    final identityGeneration = profiles.identityMutationGeneration;
    final hidden = context.read<HiddenLibrariesProvider?>();
    final client = servers.getClientForServer(server);
    if (profileId == null || client == null) return null;
    return MediaCollectionWriteScope(
      client: client,
      item: item,
      libraryVisible: (id) => hidden == null || !hidden.hiddenLibraryKeys.contains('$server:$id'),
      authorized: () {
        if (!context.mounted ||
            servers.isDisposed ||
            !identical(context.read<MultiServerProvider?>(), servers) ||
            !identical(context.read<ActiveProfileProvider?>(), profiles) ||
            profiles.activeId != profileId ||
            profiles.identityMutationGeneration != identityGeneration ||
            profiles.isBinding ||
            !profiles.lastBindingSucceeded) {
          return false;
        }
        final manager = servers.serverManager;
        if (!manager.isServerVisible(server) ||
            !manager.isClientOnline(server) ||
            !identical(manager.getClient(server), client) ||
            !isAdminActionAllowedForMediaItem(
              isOwnerOrAdmin: manager.isOwnerOrAdmin(server),
              itemBackend: item.backend,
              activeProfile: profiles.active,
            )) {
          return false;
        }
        if (!identical(context.read<HiddenLibrariesProvider?>(), hidden)) return false;
        return hidden == null ||
            !hidden.isDisposed &&
                (hidden.profileId == null || hidden.profileId == profileId) &&
                hidden.isInitialized &&
                (item.libraryId == null || !hidden.hiddenLibraryKeys.contains('$server:${item.libraryId}'));
      },
    );
  }
}
