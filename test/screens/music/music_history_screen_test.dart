import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/music/music_history_screen.dart';
import 'package:plezy/services/music/music_experience.dart';
import 'package:plezy/services/music/music_library_store.dart';

import '../../test_helpers/music_experience_fakes.dart';

class _HistoryStore extends MusicLibraryStore {
  _HistoryStore(AppDatabase database) : super(database, 'test-profile');

  final changes = StreamController<void>.broadcast();
  final windows = <int>[];
  final olderPage = Completer<MusicHistoryPage>();
  bool hasImport = false;

  static MusicHistoryEntry entry(String id, int seconds) => MusicHistoryEntry(
    id: id,
    item: musicTrack(id),
    startedAt: DateTime.utc(2026, 11, 9, 0, 0, seconds),
    listenedMs: 30000,
    finished: true,
  );

  @override
  Stream<void> get historyChanges => changes.stream;

  @override
  Future<MusicHistoryPage> historyWindow(int pages) async {
    windows.add(pages);
    final recent = entry('recent', 1);
    return MusicHistoryPage([
      if (hasImport) entry('imported', 2),
      recent,
      if (pages > 1) entry('older', 0),
    ], pages == 1 ? recent.cursor : null);
  }

  @override
  Future<MusicHistoryPage> historyPage({int limit = MusicLibraryStore.historyPageSize, (int, String)? before}) =>
      olderPage.future;

  Future<void> close() => changes.close();
}

void main() {
  testWidgets('live imports coalesce and preserve a page being loaded', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final store = _HistoryStore(database);
    final music = ExperienceMusic();
    final experience = MusicExperience(music: music, store: store, clientFor: (_) => null);
    await tester.pumpWidget(
      ChangeNotifierProvider<MusicExperience>.value(
        value: experience,
        child: const MaterialApp(home: MusicHistoryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.windows, [1]);
    await tester.tap(find.text(t.fileSources.loadMore));
    await tester.pump();
    store.hasImport = true;
    store.changes.add(null);
    store.changes.add(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.windows, [1]);
    store.olderPage.complete(MusicHistoryPage([_HistoryStore.entry('older', 0)], null));
    await tester.pumpAndSettle();
    expect(store.windows, [1, 2]);
    for (final id in ['imported', 'recent', 'older']) {
      expect(find.byKey(ValueKey(id)), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    experience.dispose();
    music.dispose();
    await store.close();
    await tester.runAsync(database.close);
  });
}
