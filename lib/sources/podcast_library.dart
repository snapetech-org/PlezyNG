import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'adapters/podcast_rss_source.dart';
import 'podcast_opml.dart';
import 'source_controller.dart';
import 'source_models.dart';
import 'source_transport.dart';

/// UI actions share the normal source vault, cache, download and progress
/// owners. There is no second podcast player or parallel history database.
class PodcastLibrary {
  PodcastLibrary(this.sources);
  final SourceController sources;
  static const indexCredentialsKey = 'podcast-index-credentials-v1';

  Future<int> subscribe(PodcastSubscription subscription) async {
    await sources.ready;
    sources.requireSession();
    final epoch = sources.generation, profile = sources.profileId!;
    // Validate the actual feed before adding it. The URL may be a private
    // subscription secret and stays out of public source metadata and logs.
    final probe = PodcastRssSourceAdapter(
      FileSource(
        id: 'podcast-preview',
        profileId: profile,
        kind: FileSourceKind.podcastRss,
        name: subscription.title,
        endpoint: sourceOrigin(subscription.url),
      ),
      SourceTransport(),
      () async => {'feedUrl': subscription.url.toString()},
      protect: sources.repository.protect, reveal: sources.repository.reveal,
    );
    late String title;
    try {
      title = (await probe.browse()).entries.first.title;
    } finally {
      probe.close();
    }
    sources.requireSession(epoch);
    return sources.importPodcastSubscriptions([PodcastSubscription(title: title, url: subscription.url)]);
  }

  /// Refresh only connected podcast feeds. ABS libraries are indexed through
  /// their existing source scan, preserving server pagination and permissions.
  Future<int> refreshFeeds() async {
    await sources.ready;
    sources.requireSession();
    final epoch = sources.generation;
    await sources.podcastAutomation.refresh(force: true);
    sources.requireSession(epoch);
    return sources.podcastAutomation.lastFailedCount;
  }

  static PublicationProgress seed(SourceEntry episode, {String session = ''}) {
    final video = episode.kind == SourceItemKind.video;
    final files = video ? episode.files.where((file) => file.kind == SourceItemKind.video).take(1) : episode.audio;
    return PublicationProgress(
      entryKey: episode.key,
      edition: sourceDigest(jsonEncode(files.map((file) => file.fingerprint).toList())),
      mode: video ? PublicationMode.watching : PublicationMode.listening,
      session: session,
    );
  }

  Future<void> markFinished(SourceEntry episode, bool finished) async {
    sources.requireSession();
    final epoch = sources.generation, profile = sources.profileId!;
    final initial = seed(episode, session: const Uuid().v4());
    if (sources.activeProgressKeys.contains(initial.key)) throw const SourceException(SourceFailure.conflict);
    final current = await sources.openProgress(episode, initial);
    sources.requireSession(epoch);
    if (sources.activeProgressKeys.contains(initial.key) ||
        sources.cloudConflict(initial.key) ||
        await sources.repository.remoteConflict(profile, initial.key) != null) {
      throw const SourceException(SourceFailure.conflict);
    }
    sources.requireSession(epoch);
    // Preserve the saved position on mark-unfinished; reset is a separate
    // explicit action in the existing episode detail screen.
    await sources.repository.saveProgress(
      profile,
      current.copyWith(finished: finished, fraction: finished ? 1 : 0),
      kind: 'podcast-status',
    );
    sources.requireSession(epoch);
  }
}
