// Populated data for opt-in exports of production feature widgets.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:plezy/games/game_artwork.dart';
import 'package:plezy/games/game_models.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_playback.dart';
import '../../test/appearance/appearance_fixtures.dart';
import '../../test/sources/fixtures/memory_sources.dart';
import '../../test/test_helpers/media_items.dart';
import '../../test/test_helpers/stub_music_playback_service.dart';

const featureBook = SourceEntry(
  sourceId: 'gallery-books',
  id: 'night-library',
  title: 'The Night Library',
  author: 'Nora Vale',
  narrator: 'Mira Ellis',
  kind: SourceItemKind.audiobook,
  language: 'en',
  description:
      'A quiet harbour. A forgotten map. A library that opens only after sunset. Follow Nora across a chain of islands as she discovers the stories that connect them.',
  files: [
    PublicationFile(
      id: 'audio-1',
      name: 'The Night Library — Part One.m4b',
      mimeType: 'audio/mp4',
      durationMs: 5280000,
    ),
    PublicationFile(id: 'epub-1', name: 'The Night Library.epub', mimeType: 'application/epub+zip'),
  ],
  chapters: [
    BookChapter(title: 'The light returns', startMs: 0, endMs: 900000),
    BookChapter(title: 'Across the water', startMs: 900000, endMs: 1920000),
    BookChapter(title: 'The island observatory', startMs: 1920000, endMs: 3600000),
    BookChapter(title: 'A door left open', startMs: 3600000, endMs: 5280000),
  ],
);
const featurePodcast = SourceEntry(
  sourceId: 'gallery-podcasts',
  id: 'signals',
  title: 'Signal & Story · The sound of distant worlds',
  author: 'Northstar Audio',
  kind: SourceItemKind.music,
  description: 'A conversation about the discoveries that change how we see our place in the universe.',
  identifiers: {'feed': 'https://example.org/signal-and-story/feed.xml'},
  files: [
    PublicationFile(
      id: 'episode-1',
      name: 'The sound of distant worlds.mp3',
      mimeType: 'audio/mpeg',
      durationMs: 3120000,
    ),
  ],
  chapters: [
    BookChapter(title: 'A signal in the noise', startMs: 0, endMs: 900000),
    BookChapter(title: 'Listening to the universe', startMs: 900000, endMs: 2100000),
    BookChapter(title: 'What comes next', startMs: 2100000, endMs: 3120000),
  ],
);

class FeatureSources extends MemorySources {
  FeatureSources(super.repository, super.directory);
  @override
  Future<File?> cover(SourceEntry entry, {bool refresh = false}) => SynchronousFuture(
    File('tools/store-assets/fixtures/features/${entry.id == 'signals' ? 'signal-story' : 'night-library'}.jpg'),
  );
  @override
  Future<SourceEntry> hydrate(SourceEntry entry) async => entry;
}

class FeaturePlayer extends AppearanceFakePlayer {
  @override
  String get playerType => 'mpv';
  @override
  PlayerState get state => PlayerState(
    volume: 60,
    position: const Duration(minutes: 27),
    duration: const Duration(minutes: 88),
    seekable: true,
  );
  @override
  Future<String?> getProperty(String name) async => null;
  @override
  Future<void> setProperty(String name, String value) async {}
}

class FeaturePlayback extends ChangeNotifier implements SourcePlayback {
  FeaturePlayback(this.player, this.entry, this.sources) {
    _queueOrder.addAll(
      List.generate(
        entry.files.where((f) => f.kind == SourceItemKind.audiobook || f.kind == SourceItemKind.music).length,
        (i) => i,
      ),
    );
  }
  @override
  final SourceController sources;
  final bool audio = true;
  final String? localBookmarkKey = null;
  final bool _queueEnabled = true;
  final List<int> _queueOrder = [];
  bool _queueShuffled = false;
  MusicRepeatMode _queueRepeatMode = MusicRepeatMode.off;
  int _fileIndex = 0;

  @override
  final SourceEntry entry;
  @override
  PublicationProgress? get progress => null;
  @override
  PublicationMode get mode => audio ? PublicationMode.listening : PublicationMode.watching;
  @override
  bool get active => true;
  @override
  bool get video => !audio;
  @override
  bool get isTransientInput => false;
  @override
  bool get isLiveInput => false;
  @override
  bool get isSamplePreview => false;
  @override
  bool get isCapturePreview => false;
  @override
  bool get isRecordingStream => false;
  @override
  bool get canExportLocalPlaylist => false;
  @override
  String? get localMediaBookmarkKey => localBookmarkKey;
  @override
  final Player player;
  @override
  bool get opening => false;
  @override
  bool get playing => true;
  @override
  bool get muted => false;
  @override
  bool get canExportActiveExternalSubtitle => false;
  @override
  bool get hasSelectedPersistentExternalSubtitle => false;
  @override
  bool fullPlayerVisible = false;
  @override
  int positionMs = 27 * 60 * 1000;
  @override
  int get durationMs => files.fold(0, (total, file) => total + (file.durationMs ?? 0));
  @override
  int get timelineStartMs => 0;
  @override
  int get timelineEndMs => durationMs;
  @override
  int? get bookRemainingMs => durationMs - positionMs;
  @override
  int? get chapterRemainingMs => null;
  @override
  bool get chapterTimeline => false;
  @override
  int get currentFilePositionMs => positionMs;
  @override
  int get currentFileDurationMs => files[_fileIndex].durationMs!;
  @override
  int get fileIndex => _fileIndex;
  @override
  List<PublicationFile> get files => entry.files.where((f) => f.mimeType.startsWith('audio/')).toList();
  @override
  bool get canUseDirectQueueControls => _queueEnabled;
  @override
  bool get queueShuffled => _queueShuffled;
  @override
  MusicRepeatMode get queueRepeatMode => _queueRepeatMode;
  @override
  int get currentQueuePosition => _queueOrder.indexOf(_fileIndex);
  @override
  List<int> get queueFileIndices => List.unmodifiable(_queueOrder);
  @override
  bool get hasCompleteTimeline => true;
  @override
  bool get canUndoSeek => false;
  @override
  DateTime? get sleepDeadline => null;
  @override
  double get speed => 1.25;
  @override
  int get backwardSeconds => 15;
  @override
  int get forwardSeconds => 30;
  @override
  bool get sleepEnabled => false;
  @override
  BookChapter? get currentChapter => entry.chapters.length > 1 ? entry.chapters[1] : null;
  @override
  List<BookChapter> get chapters => entry.chapters;
  @override
  SourceFailure? get failure => null;

  @override
  Future<void> seek(int position) async {
    positionMs = position;
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> previousChapter() async {}
  @override
  Future<void> nextChapter() async {}
  @override
  Future<void> toggleQueueShuffle() async {
    if (!_queueEnabled) return;
    final position = currentQueuePosition;
    final prefix = _queueOrder.take(position + 1).toList();
    final remaining = _queueOrder.skip(position + 1).toList().reversed.toList();
    _queueOrder
      ..clear()
      ..addAll([...prefix, ...remaining]);
    _queueShuffled = !_queueShuffled;
    notifyListeners();
  }

  @override
  Future<void> setQueueRepeatMode(MusicRepeatMode mode) async {
    _queueRepeatMode = mode;
    notifyListeners();
  }

  @override
  Future<void> selectQueueFile(int fileIndex) async {
    if (_queueEnabled && _queueOrder.contains(fileIndex)) {
      _fileIndex = fileIndex;
      notifyListeners();
    }
  }

  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FeatureGameArtwork extends GameArtworkLoader {
  @override
  Future<Uint8List?> loadSteam(int appId) => SynchronousFuture(
    File(
      'tools/store-assets/fixtures/games/${{620: 'portal2', 413150: 'stardew', 1145360: 'hades'}[appId] ?? 'portal2'}.jpg',
    ).readAsBytesSync(),
  );
  @override
  Future<Uint8List?> load(GameHost host, StreamGame game) => loadSteam(int.tryParse(game.id) ?? 620);
}

class FeatureMusic extends StubMusicPlaybackService {
  FeatureMusic(String origin)
    : tracks = [
        for (final (i, title) in [
          'Blue Hour',
          'Tide Pools',
          'Northern Lights',
          'A Quiet Crossing',
          'First Light',
        ].indexed)
          testMediaItem(
            id: 'track-$i',
            backend: MediaBackend.jellyfin,
            kind: MediaKind.track,
            title: title,
            parentTitle: 'Blue Hour Sessions',
            grandparentTitle: 'North Coast',
            durationMs: 246000,
            thumbPath: '$origin/blue-hour.jpg',
          ),
      ];
  final List<MediaItem> tracks;
  @override
  MediaItem get currentTrack => tracks.first;
  @override
  MusicPlaybackStatus get status => MusicPlaybackStatus.paused;
  @override
  Duration get duration => const Duration(minutes: 4, seconds: 6);
  @override
  Duration get position => const Duration(minutes: 1, seconds: 42);
  @override
  List<MediaItem> get queue => tracks;
  @override
  int get currentIndex => 0;
  @override
  MusicPlayContext get playContext =>
      const MusicPlayContext(title: 'Blue Hour Sessions', kind: MusicPlayContextKind.album);
}
