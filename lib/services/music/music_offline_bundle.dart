import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_source_info.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import 'music_library_store.dart';

/// Enrich an explicitly downloaded track while its authorized server is still
/// available. Only server-provided lyrics are stored; missing/denied lyrics are
/// never scraped from a third party. Optional enrichment cannot fail a download.
class MusicOfflineBundle {
  MusicOfflineBundle(this.store);
  final MusicLibraryStore store;

  Future<void> prepare(MediaItem track, MediaServerClient client, {required bool Function() current}) async {
    final authentication = client.authenticationSessionId;
    bool valid() => store.active && current() && identical(authentication, client.authenticationSessionId);
    if (!valid() || client.isOfflineMode || track.serverId != client.serverId.value) return;
    try {
      final lyrics = await client.fetchLyrics(track).timeout(const Duration(seconds: 15));
      if (!valid()) return;
      if (lyrics == null) {
        await store.deleteDocument('lyrics', track.globalKey);
      } else {
        await store.saveDocument('lyrics', track.globalKey, {
          'version': 1,
          'updatedAt': track.updatedAt,
          'lyrics': lyrics.toJson(),
        });
      }
    } catch (_) {
      appLogger.d('Optional downloaded lyrics unavailable');
    }
    if (!valid() || client is! PlexLoudnessProfileClient) return;
    try {
      // Download source resolution has already cached the selected media. Do
      // not start a transcode or playback session just to enrich this bundle.
      final source = await client.fetchCachedMediaSourceInfo(track.id);
      if (!valid()) return;
      final stream = source?.audioTracks.where((audio) => audio.selected).firstOrNull;
      if (stream == null) return;
      final profile = await (client as PlexLoudnessProfileClient)
          .fetchAudioLoudnessProfile(stream.id)
          .timeout(const Duration(seconds: 15));
      if (!valid()) return;
      if (profile == null) {
        await store.deleteDocument('analysis', track.globalKey);
      } else {
        final document = musicAnalysisDocument(track, profile);
        if (document != null) await store.saveDocument('analysis', track.globalKey, document);
      }
    } catch (_) {
      appLogger.d('Optional downloaded analysis unavailable');
    }
  }
}

/// Bound persistent analysis independently of the provider's sample count.
/// A maximum per bucket retains quiet/loud edge information for seek prints.
Map<String, dynamic>? musicAnalysisDocument(MediaItem track, AudioLoudnessProfile profile) {
  final levels = profile.levelsDb;
  if (levels.isEmpty || levels.any((v) => !v.isFinite) || profile.totalSamples < 1) return null;
  final count = levels.length.clamp(1, 512);
  final bounded = List<double>.generate(count, (i) {
    final start = i * levels.length ~/ count, end = (i + 1) * levels.length ~/ count;
    return levels.sublist(start, end).reduce((a, b) => a > b ? a : b);
  });
  return {'version': 1, 'updatedAt': track.updatedAt, 'levels': bounded, 'samples': profile.totalSamples};
}

AudioLoudnessProfile? musicAnalysisProfile(MediaItem track, Map<String, dynamic>? document) {
  if (document == null || document['version'] != 1 || document['updatedAt'] != track.updatedAt) return null;
  final levels = document['levels'], samples = document['samples'];
  if (levels is! List ||
      levels.isEmpty ||
      levels.length > 512 ||
      levels.any((value) => value is! num || !value.isFinite) ||
      samples is! int ||
      samples < 1) {
    return null;
  }
  return AudioLoudnessProfile(
    levelsDb: levels.map((value) => (value as num).toDouble()).toList(),
    totalSamples: samples,
  );
}

/// A saved station/recipe is playable offline only through currently owned,
/// completed downloads. Cached metadata alone never grants a file or account.
List<MediaItem> musicSnapshotTracks(
  Map<String, dynamic>? snapshot,
  Iterable<MediaItem> downloads, {
  String? accountScope,
}) {
  if (snapshot?['version'] != 1 || snapshot?['tracks'] is! List) return [];
  if (accountScope != null && snapshot?['accountScope'] != accountScope) return [];
  final rows = snapshot!['tracks'] as List;
  if (rows.length > 5000) return [];
  final owned = {for (final track in downloads) track.globalKey: track};
  final result = <MediaItem>[];
  for (final row in rows) {
    if (row is! Map || row['id'] is! String || row['serverId'] is! String) continue;
    final item = owned['${row['serverId']}:${row['id']}'];
    if (item?.kind == MediaKind.track) result.add(item!);
  }
  return result;
}
