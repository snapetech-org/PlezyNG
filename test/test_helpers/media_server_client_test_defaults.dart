import 'package:plezy/media/artist_discography.dart';
import 'package:plezy/media/download_resolution.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_person.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/utils/media_server_http_client.dart';

/// Safe, empty-network defaults for test clients whose tests do not exercise
/// the newer metadata and enrichment endpoints.
mixin TestMediaServerClientDefaults implements MediaServerClient {
  @override
  Future<MediaItem?> fetchItem(String id) async => null;

  @override
  Future<List<CollectionMembership>> fetchCollectionMemberships(Set<String> itemIds, {AbortController? abort}) async =>
      const [];

  @override
  Future<List<ArtistDiscographyGroup>> fetchArtistDiscography(MediaItem artist) async => const [];

  @override
  Future<MediaPersonDetails> fetchPersonDetails(String personId, {AbortController? abort}) async =>
      MediaPersonDetails.empty;

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async => item;

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) => const [];
}
