import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/mixins/debounced_media_search.dart';

import '../test_helpers/media_items.dart';

class _SearchProbe extends StatefulWidget {
  const _SearchProbe({required this.search});

  final Future<List<MediaItem>> Function(String query) search;

  @override
  State<_SearchProbe> createState() => _SearchProbeState();
}

class _SearchProbeState extends State<_SearchProbe> with DebouncedMediaSearch<_SearchProbe, MediaItem> {
  @override
  Future<List<MediaItem>> performSearchQuery(String query) => widget.search(query);

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets('partial results remain usable while other legs are pending', (tester) async {
    final pending = Completer<List<MediaItem>>();
    await tester.pumpWidget(_SearchProbe(search: (_) => pending.future));
    final state = tester.state<_SearchProbeState>(find.byType(_SearchProbe));
    final request = state.runSearch('A');
    final publish = state.searchProgressPublisher('A');
    expect(publish([testMediaItem(id: 'fast', title: 'Fast')]), isTrue);
    await tester.pump();
    expect(state.searchResults.single.id, 'fast');
    expect(state.resultsQuery, 'A');
    expect(state.isSearching, isTrue);
    pending.complete([testMediaItem(id: 'final', title: 'Final')]);
    await request;
    await tester.pump();
    expect(state.searchResults.single.id, 'final');
    expect(state.isSearching, isFalse);
    expect(publish([]), isFalse);
  });

  testWidgets('A to B to A rejects progress from the first A generation', (tester) async {
    final pending = <Completer<List<MediaItem>>>[];
    await tester.pumpWidget(_SearchProbe(search: (_) {
      final request = Completer<List<MediaItem>>();
      pending.add(request);
      return request.future;
    }));
    final state = tester.state<_SearchProbeState>(find.byType(_SearchProbe));
    final first = state.runSearch('A');
    final stale = state.searchProgressPublisher('A');
    final second = state.runSearch('B');
    final third = state.runSearch('A');
    final current = state.searchProgressPublisher('A');
    expect(stale([testMediaItem(id: 'stale', title: 'Stale')]), isFalse);
    expect(current([testMediaItem(id: 'current', title: 'Current')]), isTrue);
    expect(state.searchResults.single.id, 'current');
    for (final request in pending) { request.complete(const []); }
    await Future.wait([first, second, third]);
    await tester.pump();
  });

  testWidgets('reverting to the shown query clears a spinner an earlier keystroke orphaned', (tester) async {
    final pending = <String, Completer<List<MediaItem>>>{};
    await tester.pumpWidget(
      _SearchProbe(
        search: (query) {
          if (query == 'abc') return Future.value([testMediaItem(id: 'abc', title: 'abc')]);
          return (pending[query] = Completer<List<MediaItem>>()).future;
        },
      ),
    );
    final state = tester.state<_SearchProbeState>(find.byType(_SearchProbe));

    state.searchController.text = 'abc';
    await tester.pump(DebouncedMediaSearch.searchDebounceDuration);
    await tester.pump();
    expect(state.lastSearchedQuery, 'abc');
    expect(state.isSearching, isFalse);

    state.searchController.text = 'abcd';
    await tester.pump(DebouncedMediaSearch.searchDebounceDuration);
    expect(state.isSearching, isTrue);

    // The next keystroke kills the 'abcd' pass and re-arms the debounce...
    state.searchController.text = 'abcde';
    await tester.pump();
    // ...and reverting cancels that debounce: no pass is left to end the spinner.
    state.searchController.text = 'abc';
    await tester.pump(const Duration(seconds: 1));

    expect(state.isSearching, isFalse);
    expect(state.searchResults.map((item) => item.id), ['abc']);
    expect(pending.keys, ['abcd']);
  });
}

