import 'server_music_radio.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import 'music_account_scope.dart';

class MusicRecommendationSource {
  const MusicRecommendationSource({
    required this.client,
    required this.libraryId,
    required this.libraryName,
    required this.isCurrent,
  });
  final MediaServerClient client;
  final String libraryId, libraryName;
  final bool Function() isCurrent;

  bool owns(MediaItem item) =>
      const {MediaKind.artist, MediaKind.album, MediaKind.track}.contains(item.kind) &&
      item.backend == client.backend &&
      item.serverId == client.serverId.value &&
      item.libraryId == libraryId;
}

class MusicServerRecommendation {
  MusicServerRecommendation._(this.hub, this.source, this._current);
  final MediaHub hub;
  final MusicRecommendationSource source;
  final bool Function() _current;
  bool get isCurrent => _current();
}

class MusicServerRadioRecommendation {
  MusicServerRadioRecommendation._(this.radio, this.source, this._current);
  final ServerMusicRadio radio;
  final MusicRecommendationSource source;
  final bool Function() _current;
  bool get isCurrent => _current() && (source.client as ServerMusicRadioClient).serverMusicRadioCurrent(radio);
}

class _Batch {
  _Batch(this.source)
    : authentication = source.client.authenticationSessionId,
      account = musicAccountScope(source.client);
  final MusicRecommendationSource source;
  final Object authentication;
  final String account;
  List<MusicServerRecommendation> shelves = [];
  bool _hubsFailed = false, _radioFailed = false;
  bool get failed => _hubsFailed || _radioFailed;
  List<MusicServerRadioRecommendation> radios = [];
  bool get current =>
      source.isCurrent() &&
      !source.client.isOfflineMode &&
      identical(authentication, source.client.authenticationSessionId) &&
      account == musicAccountScope(source.client);

  Future<void> load() async {
    await Future.wait([_loadHubs(), _loadRadios()]);
  }

  Future<void> _loadRadios() async {
    final client = source.client;
    if (client is! ServerMusicRadioClient || !current) return;
    final radioClient = client as ServerMusicRadioClient;
    try {
      final issued = await radioClient.serverMusicRadios(source.libraryId).timeout(const Duration(seconds: 10));
      if (!current) return;
      final seen = <String>{};
      radios = List.unmodifiable([
        for (final row in issued.take(32))
          if (row.valid &&
              row.serverId == client.serverId.value &&
              row.libraryId == source.libraryId &&
              seen.add(row.key) &&
              radioClient.serverMusicRadioCurrent(row))
            MusicServerRadioRecommendation._(row, source, () => current),
      ]);
    } catch (_) {
      _radioFailed = true;
      radios = [];
    }
  }

  Future<void> _loadHubs() async {
    if (!current) return;
    try {
      final diagnostics = HubFetchDiagnostics();
      final hubs = await source.client
          .fetchLibraryHubs(
            source.libraryId,
            libraryName: source.libraryName,
            libraryKind: MediaKind.artist,
            limit: MusicServerRecommendations.previewSize,
            includePlaybackHubs: false,
            diagnostics: diagnostics,
          )
          .timeout(const Duration(seconds: 10));
      if (!current) return;
      _hubsFailed = diagnostics.failed;
      final seen = <String>{};
      for (final hub in hubs.take(64)) {
        if (shelves.length >= 8) break;
        if (hub.id.isEmpty ||
            !seen.add(hub.id) ||
            hub.serverId != source.client.serverId.value ||
            hub.libraryId != null && hub.libraryId != source.libraryId) {
          continue;
        }
        final identities = <String>{};
        final items = hub.items
            .take(256)
            .where((item) => source.owns(item) && identities.add(item.globalKey))
            .take(MusicServerRecommendations.previewSize)
            .toList(growable: false);
        if (items.isEmpty) continue;
        // Freeze the bounded preview, preserving the server's family/title.
        // It is never relabelled as an independently generated sonic mix.
        final preview = MediaHub(
          id: hub.id,
          identifier: hub.identifier,
          title: hub.title,
          type: hub.type,
          items: List.unmodifiable(items),
          size: hub.size,
          more: hub.more,
          libraryId: source.libraryId,
          serverId: source.client.serverId.value,
          serverName: source.client.serverName,
        );
        shelves.add(MusicServerRecommendation._(preview, source, () => current));
      }
    } catch (_) {
      _hubsFailed = true;
      shelves = [];
    }
  }
}

/// Bounded server-authored music previews. Account/visibility revocation also
/// invalidates completed results and retained callbacks, not just late fetches.
class MusicServerRecommendations {
  MusicServerRecommendations._(this._batches);
  static const previewSize = 12, maximumSources = 16, maximumShelves = 24;
  final List<_Batch> _batches;
  bool get hasFailures => _batches.any((batch) => batch.current && batch.failed);
  List<MusicServerRecommendation> get shelves {
    final pools = [
      for (final batch in _batches)
        if (batch.current) batch.shelves,
    ];
    final rows = <MusicServerRecommendation>[];
    for (var index = 0; index < 8 && rows.length < maximumShelves; index++) {
      for (final pool in pools) {
        if (index < pool.length) rows.add(pool[index]);
        if (rows.length == maximumShelves) break;
      }
    }
    return List.unmodifiable(rows);
  }

  List<MusicServerRadioRecommendation> get radios {
    final pools = [
      for (final batch in _batches)
        if (batch.current) batch.radios,
    ];
    final rows = <MusicServerRadioRecommendation>[];
    for (var index = 0; index < 32 && rows.length < 64; index++) {
      for (final pool in pools) {
        if (index < pool.length && pool[index].isCurrent) rows.add(pool[index]);
        if (rows.length == 64) break;
      }
    }
    return List.unmodifiable(rows);
  }

  static Future<MusicServerRecommendations> load(Iterable<MusicRecommendationSource> sources) async {
    // Pin every owner before the first request, including queued batches.
    final batches = sources.take(maximumSources).map(_Batch.new).toList(growable: false);
    for (var start = 0; start < batches.length; start += 4) {
      await Future.wait(batches.skip(start).take(4).map((batch) => batch.load()));
    }
    return MusicServerRecommendations._(batches);
  }
}
