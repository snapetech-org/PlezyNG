import '../../media/library_query.dart';
import '../../media/media_filter.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import 'music_account_scope.dart';
import 'music_discovery.dart';

class MusicFavoriteSource {
  const MusicFavoriteSource({required this.client, required this.libraryId, required this.isCurrent});
  final MediaServerClient client;
  final String libraryId;
  final bool Function() isCurrent;
}

class MusicFavoriteSelection {
  MusicFavoriteSelection._(this._batches);
  final List<({MusicFavoriteSource source, Object authentication, String account, List<MediaItem> tracks})> _batches;

  List<MediaItem> get tracks => MusicDiscovery.interleave([
    for (final batch in _batches)
      if (batch.source.isCurrent() &&
          !batch.source.client.isOfflineMode &&
          identical(batch.authentication, batch.source.client.authenticationSessionId) &&
          batch.account == musicAccountScope(batch.source.client))
        batch.tracks,
  ], limit: 200);

  static Future<MusicFavoriteSelection> load(Iterable<MusicFavoriteSource> sources) async {
    final batches = await Future.wait(
      sources.take(16).map((source) async {
        final client = source.client;
        final authentication = client.authenticationSessionId;
        final account = musicAccountScope(client);
        final tracks = <MediaItem>[];
        if (source.isCurrent() &&
            !client.isOfflineMode &&
            (client.capabilities.userFavorites || client.capabilities.numericUserRating)) {
          try {
            final favorites = client.capabilities.userFavorites;
            final page = await client
                .fetchLibraryPagedContent(
                  source.libraryId,
                  query: LibraryQuery(
                    kind: MediaKind.track,
                    limit: 200,
                    filters: [
                      LibraryFilter(
                        field: favorites ? MediaFilterField.favorite : 'userRating',
                        op: favorites ? LibraryFilterOperator.is_ : LibraryFilterOperator.atLeast,
                        values: favorites ? ['1'] : ['8'],
                      ),
                    ],
                  ),
                )
                .timeout(const Duration(seconds: 10));
            tracks.addAll(
              page.items.where(
                (track) =>
                    track.kind == MediaKind.track &&
                    track.serverId == client.serverId.value &&
                    track.libraryId == source.libraryId &&
                    (favorites ? track.isFavorite == true : (track.userRating ?? 0) >= 8),
              ),
            );
          } catch (_) {
            tracks.clear();
          }
        }
        return (source: source, authentication: authentication, account: account, tracks: tracks);
      }),
    );
    return MusicFavoriteSelection._(batches);
  }
}
