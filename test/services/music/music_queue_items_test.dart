import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_queue_controller.dart';
import 'package:plezy/services/music/music_queue_items.dart';
import '../../test_helpers/media_items.dart';

MediaItem track(String id) =>
    testMediaItem(id: id, kind: MediaKind.track, serverId: 'server', parentId: 'album', title: 'Track $id');

void main() {
  late Directory root;
  setUp(() {
    final parent = Directory('.dart_tool/queue-spool-tests')..createSync(recursive: true);
    root = parent.createTempSync('case-');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('small queues do not create scratch files and snapshots remain immutable', () {
    final items = MusicQueueItems(spill: true, scratchRoot: root, threshold: 2);
    final first = track('first');
    items.add(first);
    final snapshot = items.snapshot();
    expect(items.isSpilled, isFalse);
    expect(root.listSync(), isEmpty);
    expect(snapshot.single, same(first));
    expect(() => snapshot[0] = track('other'), throwsUnsupportedError);
    items.clear();
    expect(snapshot.single, same(first));
  });

  test('spilling preserves occurrence keys and leases across replacement', () {
    final items = MusicQueueItems(spill: true, scratchRoot: root, threshold: 2);
    final duplicate = track('repeat');
    items.addAll([duplicate, duplicate]);
    final before = items.snapshot();
    items.add(track('third'));
    expect(items.isSpilled, isTrue);
    final spilled = items.snapshot();
    expect(spilled.occurrenceAt(0), same(before.occurrenceAt(0)));
    expect(spilled.occurrenceAt(1), same(before.occurrenceAt(1)));
    expect(spilled.occurrenceAt(0), isNot(same(spilled.occurrenceAt(1))));
    items.trimDecodedMetadata();
    expect(spilled.map((item) => item.id), ['repeat', 'repeat', 'third']);
    items.replaceWith([track('replacement')]);
    expect(items.single.id, 'replacement');
    expect(spilled.map((item) => item.id), ['repeat', 'repeat', 'third']);
    expect(before.map((item) => item.id), ['repeat', 'repeat']);
    items.clear();
  });

  test('large scratch reads retain a bounded decoded window and stable snapshots', () {
    final items = MusicQueueItems(spill: true, scratchRoot: root);
    items.addAll(Iterable.generate(10000, (index) => track('$index')));
    expect(items.isSpilled, isTrue);
    final snapshot = items.snapshot();
    items.trimDecodedMetadata();
    for (var index = 0; index < items.length; index++) {
      expect(items[index].id, '$index');
    }
    expect(items.cachedItems, lessThanOrEqualTo(96));
    expect(snapshot[0].id, '0');
    final key = snapshot.occurrenceAt(0);
    items.trimDecodedMetadata();
    expect(snapshot[0].id, '0');
    expect(snapshot.occurrenceAt(0), same(key));
    expect(items.cachedItems, 1);
    items.clear();
    expect(snapshot.last.id, '9999');
  });

  test('spool serialization failure leaves the existing queue intact', () {
    final items = MusicQueueItems(spill: true, scratchRoot: root, threshold: 1)..add(track('first'));
    final snapshot = items.snapshot();
    final invalid = track('invalid').copyWith(raw: {'notJson': Object()});
    expect(() => items.add(invalid), throwsA(anything));
    expect(items.single.id, 'first');
    expect(items.isSpilled, isFalse);
    expect(snapshot.single.id, 'first');
    expect(root.listSync(), isEmpty);
    items.clear();
  });

  test('disk-backed controller keeps duplicates, edits, shuffle and persisted snapshots', () {
    final queue = MusicQueueController(spillLargeQueues: true, queueScratchDirectory: root);
    final items = [for (var index = 0; index < 2000; index++) track((index % 10).toString())];
    queue.load(items, startIndex: 1000);
    final view = queue.queue as MusicQueueView;
    final key = view.occurrenceAt(1000);
    queue.trimDecodedMetadata();
    expect(queue.current?.id, '0');
    expect((queue.queue as MusicQueueView).occurrenceAt(1000), same(key));
    queue.toggleShuffle();
    final shuffled = queue.captureState();
    expect(queue.current?.id, '0');
    queue.jumpTo(50);
    final retained = queue.queue.take(51).map((item) => item.id).toList();
    queue.clearUpcoming();
    expect(queue.queue.map((item) => item.id), retained);
    queue.trimDecodedMetadata();
    expect(queue.queue.map((item) => item.id), retained);
    queue.clear();
    expect(view.length, 2000);
    expect(view[1000].id, '0');
    final restored = MusicQueueController(spillLargeQueues: true, queueScratchDirectory: root);
    expect(restored.restoreState(shuffled), isTrue);
    restored.trimDecodedMetadata();
    expect(restored.queue.length, 2000);
    expect(restored.current?.id, '0');
    restored.clear();
  });
}
