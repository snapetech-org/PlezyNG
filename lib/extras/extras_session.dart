import 'package:flutter/foundation.dart';
import '../media/canonical_video_identity.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../models/catalog/catalog_item.dart';
import 'extras_models.dart';
import 'extras_policy.dart';
import 'extras_repository.dart';
import 'extras_store.dart';

ExtrasSubject extrasSubjectForMedia(
  MediaItem media, {
  bool restricted = false,
  bool offline = false,
  String language = 'en',
  String region = 'US',
}) {
  final ids = canonicalVideoIdentitiesForMediaItem(media);
  final sorted = ids.toList()..sort();
  return ExtrasSubject(
    key: sorted.firstOrNull ?? 'library:${media.globalKey}',
    identities: ids,
    title: media.displayTitle,
    year: media.year,
    watched: media.isWatched,
    restricted: restricted,
    offline: offline,
    language: language,
    region: region,
  );
}

ExtrasSubject extrasSubjectForCatalog(
  CatalogItem item, {
  bool restricted = false,
  String language = 'en',
  String region = 'US',
}) {
  final kind = item.kind == MediaKind.movie ? 'movie' : 'show';
  final ids = canonicalVideoIdentitiesForExternalIds(
    identifiers: {
      if (item.ids.tmdb != null) 'tmdb': '${item.ids.tmdb}',
      if (item.ids.imdb != null) 'imdb': item.ids.imdb!,
      if (item.ids.tvdb != null) 'tvdb': '${item.ids.tvdb}',
    },
    mediaType: kind,
  );
  final sorted = ids.toList()..sort();
  return ExtrasSubject(
    key: sorted.firstOrNull ?? item.identityKey,
    identities: ids,
    title: item.title,
    year: item.year,
    restricted: restricted,
    language: language,
    region: region,
  );
}

ExtraKind nativeExtraKind(MediaItem item) {
  final raw = item.raw;
  final type = '${raw?['ExtraType'] ?? raw?['extraType'] ?? raw?['subtype'] ?? ''}'.toLowerCase().replaceAll(
    RegExp('[ _-]'),
    '',
  );
  return switch (type) {
    '1' || 'trailer' => ExtraKind.trailer,
    '2' || 'deletedscene' => ExtraKind.deletedScene,
    '3' || 'interview' => ExtraKind.interview,
    '4' || '5' || 'behindthescenes' || 'featurette' => ExtraKind.makingOf,
    'bloopers' => ExtraKind.bloopers,
    _ => ExtraKind.other,
  };
}

List<ExtraEntry> libraryExtraEntries(ExtrasSubject subject, List<MediaItem> items) => items
    .map(
      (item) => ExtraEntry(
        id: 'library:${item.globalKey}',
        parentIdentities: subject.allIdentities,
        title: item.displayTitle,
        kind: nativeExtraKind(item),
        origin: ExtraOrigin.library,
        nativeKey: item.globalKey,
        publisherId: 'library:${item.serverId ?? ''}',
        publisher: item.serverName ?? '',
        description: item.summary ?? '',
        durationSeconds: item.durationMs == null ? null : item.durationMs! ~/ 1000,
        // Native extras are attached by the library owner, but are not assumed to
        // be spoiler-free. Watched state or an explicit setting controls visibility.
      ),
    )
    .toList();

class ExtrasSession extends ChangeNotifier {
  ExtrasSession({
    required this.subject,
    required this.store,
    this.library = const [],
    this.isCurrent,
    this.catalog = const [],
    ExtrasRepository? repository,
  }) : repository = repository ?? ExtrasRepository(store);
  ExtrasSubject subject;
  final ExtrasStore store;
  List<MediaItem> library;
  List<ExtraEntry> catalog;
  final bool Function()? isCurrent;
  bool get active => !_disposed && (isCurrent?.call() ?? true);
  final ExtrasRepository repository;
  ExtrasPreferences preferences = const ExtrasPreferences();
  List<ExtraEntry> entries = const [];
  bool loading = false, unavailable = false;
  int _generation = 0;
  bool _disposed = false;
  List<ExtraEntry> get preview => const ExtrasPolicy().preview(entries);
  MediaItem? nativeItem(ExtraEntry entry) => library.where((item) => item.globalKey == entry.nativeKey).firstOrNull;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh({bool findMore = false, String query = ''}) async {
    if (!active) return;
    final generation = ++_generation;
    loading = true;
    _notify();
    try {
      final prefs = await store.preferences();
      final local = [...libraryExtraEntries(subject, library), ...await store.personalEntries()];
      if (!active || generation != _generation) return;
      preferences = prefs;
      entries = const ExtrasPolicy().select(local, subject, prefs);
      _notify();
      final result = await repository.load(
        subject,
        library: libraryExtraEntries(subject, library),
        catalog: catalog,
        findMore: findMore,
        query: query,
      );
      if (!active || generation != _generation) return;
      entries = result.entries;
      unavailable = result.serviceUnavailable;
    } catch (_) {
      if (!active || generation != _generation) return;
      unavailable = true;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    repository.close();
    super.dispose();
  }
}
