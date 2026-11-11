import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/focusable_action_bar.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/music/queue_sheet.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:plezy/widgets/music/track_row.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';
import '../../test_helpers/stub_music_playback_service.dart';

MediaItem _track(String id, String title) => testMediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: MediaKind.track,
  title: title,
  parentId: 'album_1',
  parentTitle: 'First Light',
  grandparentId: 'artist_1',
  grandparentTitle: 'Test Artist',
  durationMs: 180000,
  serverId: 'server_1',
  serverName: 'Server',
);

class _FakeQueueService extends StubMusicPlaybackService {
  final _queue = MusicQueueController();
  final List<int> jumps = [], removals = [];
  final List<(int, int)> moves = [];
  int _session = 0;

  _FakeQueueService(List<MediaItem> tracks, {int start = 1}) {
    _queue.load(tracks, startIndex: start);
  }

  @override
  MediaItem? get currentTrack => _queue.current;
  @override
  MusicPlaybackStatus get status => MusicPlaybackStatus.playing;
  @override
  List<MediaItem> get queue => _queue.queue;
  @override
  int get currentIndex => _queue.cursor;
  @override
  int get queueSessionRevision => _session;
  @override
  bool get shuffled => _queue.shuffled;
  @override
  void toggleShuffle() {
    _queue.toggleShuffle();
    notifyListeners();
  }

  @override
  Future<void> jumpTo(int index) async {
    jumps.add(index);
    _queue.jumpTo(index);
    notifyListeners();
  }

  @override
  void removeAt(int index) {
    removals.add(index);
    _queue.removeAt(index);
    notifyListeners();
  }

  @override
  void reorder(int from, int to) {
    moves.add((from, to));
    _queue.move(from, to);
    notifyListeners();
  }

  @override
  void clearUpcoming() {
    _queue.clearUpcoming();
    notifyListeners();
  }

  void replace(List<MediaItem> tracks) {
    _session++;
    _queue.load(tracks);
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
  });

  Widget wrap(MusicPlaybackService service) {
    addTearDown(service.dispose);
    final multiServerProvider = testMultiServer().provider;

    return TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
          ChangeNotifierProvider<MusicPlaybackService>.value(value: service),
        ],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: const Scaffold(body: SizedBox(width: 500, height: 700, child: QueueSheet())),
        ),
      ),
    );
  }

  testWidgets('renders header and the full queue including history', (tester) async {
    final service = _FakeQueueService([_track('t1', 'Alpha'), _track('t2', 'Beta'), _track('t3', 'Gamma')]);

    await tester.pumpWidget(wrap(service));
    // pumpAndSettle would never settle: the current-track equalizer animates
    // forever while the fake reports "playing".
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(t.music.queue), findsOneWidget);
    expect(find.text(t.music.trackCount(n: 3)), findsOneWidget);

    // The whole queue renders as TrackRows: played, current, and upcoming.
    expect(find.byType(TrackRow), findsNWidgets(3));
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
  });

  testWidgets('renders all queue header action icons at 20px', (tester) async {
    final service = _FakeQueueService([_track('t1', 'Alpha'), _track('t2', 'Beta'), _track('t3', 'Gamma')]);

    await tester.pumpWidget(wrap(service));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final headerIcons = tester
        .widgetList<AppIcon>(find.descendant(of: find.byType(FocusableActionBar), matching: find.byType(AppIcon)))
        .toList();

    expect(headerIcons, hasLength(3));
    expect(headerIcons.map((icon) => icon.size), everyElement(20));
  });

  testWidgets('tapping a played or upcoming row jumps to its queue index', (tester) async {
    final service = _FakeQueueService([_track('t1', 'Alpha'), _track('t2', 'Beta'), _track('t3', 'Gamma')]);

    await tester.pumpWidget(wrap(service));
    // pumpAndSettle would never settle: the current-track equalizer animates
    // forever while the fake reports "playing".
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Gamma'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Alpha'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Alpha'));
    await tester.pump();

    expect(service.jumps, [2, 0]);
  });

  Future<void> draw(WidgetTester tester, _FakeQueueService service) async {
    await tester.pumpWidget(wrap(service));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Back To returns to the original occurrence and restores its following queue', (tester) async {
    final service = _FakeQueueService([_track('t1', 'Alpha'), _track('t2', 'Beta'), _track('t3', 'Gamma')]);
    await draw(tester, service);
    await tester.tap(find.text(t.music.backTo));
    await tester.pump();
    expect(find.byType(TrackRow), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(service.jumps, [0]);
    expect(service.queue.map((item) => item.id), ['t1', 't2', 't3']);
    await tester.tap(find.text(t.music.upNext));
    await tester.pump();
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
  });

  testWidgets('Up Next jumps to the intended duplicate occurrence', (tester) async {
    final repeated = _track('repeat', 'Repeat');
    final service = _FakeQueueService([repeated, _track('t2', 'Beta'), _track('t3', 'Gamma'), repeated]);
    await draw(tester, service);
    await tester.tap(find.text(t.music.upNext));
    await tester.pump();
    await tester.tap(find.text('Repeat'));
    await tester.pump();
    expect(service.jumps, [3]);
    expect(service.queue, hasLength(4));
  });

  testWidgets('filtered reorder maps playback indices and preserves the playing occurrence', (tester) async {
    final service = _FakeQueueService([
      _track('t1', 'Alpha'),
      _track('t2', 'Beta'),
      _track('t3', 'Gamma'),
      _track('t4', 'Delta'),
    ]);
    await draw(tester, service);
    await tester.tap(find.text(t.music.upNext));
    await tester.pump();
    tester.widget<ReorderableListView>(find.byType(ReorderableListView)).onReorderItem?.call(0, 1);
    await tester.pump();
    expect(service.moves, [(2, 3)]);
    expect(service.currentTrack?.id, 't2');
    expect(service.queue.map((item) => item.id), ['t1', 't2', 't4', 't3']);
  });

  testWidgets('swiping the first identical duplicate retires only that occurrence widget', (tester) async {
    final repeated = _track('repeat', 'Repeat');
    final service = _FakeQueueService([_track('t1', 'Alpha'), _track('t2', 'Beta'), repeated, repeated]);
    await draw(tester, service);
    await tester.tap(find.text(t.music.upNext));
    await tester.pump();
    await tester.drag(find.byType(Dismissible).first, const Offset(-600, 0));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(service.removals, [2]);
    expect(service.queue, hasLength(3));
    expect(find.text('Repeat'), findsOneWidget);
    expect(service.currentTrack?.id, 't2');
  });

  testWidgets('stale row and reorder callbacks cannot edit a replacement session', (tester) async {
    final service = _FakeQueueService([_track('t1', 'Alpha'), _track('t2', 'Beta'), _track('t3', 'Gamma')]);
    await draw(tester, service);
    final row = tester.widgetList<TrackRow>(find.byType(TrackRow)).last;
    final reorder = tester.widget<ReorderableListView>(find.byType(ReorderableListView)).onReorderItem;
    service.replace([_track('new', 'New')]);
    row.onTap?.call();
    row.onTrailingTap?.call();
    reorder?.call(0, 1);
    await tester.pump();
    expect(service.jumps, isEmpty);
    expect(service.removals, isEmpty);
    expect(service.moves, isEmpty);
    expect(service.currentTrack?.id, 'new');
  });

  testWidgets('queue sections and controls fit a narrow screen at 200 percent text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final service = _FakeQueueService([_track('t1', 'Alpha'), _track('t2', 'Beta'), _track('t3', 'Gamma')]);
    await draw(tester, service);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(t.music.upNext));
    await tester.pump();
    expect(find.text('Gamma'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
