import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_library_store.dart';
import '../../utils/music_navigation.dart';

class MusicHistoryScreen extends StatefulWidget {
  const MusicHistoryScreen({super.key});
  @override
  State<MusicHistoryScreen> createState() => _MusicHistoryScreenState();
}

class _MusicHistoryScreenState extends State<MusicHistoryScreen> {
  late final MusicLibraryStore _store = context.read<MusicExperience>().store;
  StreamSubscription<void>? _changes;
  List<MusicHistoryEntry> _entries = [];
  (int, String)? _cursor;
  int _revision = 0;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _changes = _store.historyChanges.listen((_) => _load(refresh: true));
    unawaited(_load(refresh: true));
  }

  Future<void> _load({bool refresh = false}) async {
    if (!refresh && (_loading || _cursor == null)) return;
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await _store.historyPage(before: refresh ? null : _cursor);
      if (!mounted || revision != _revision) return;
      setState(() {
        _entries = refresh ? page.entries : [..._entries, ...page.entries];
        _cursor = page.cursor;
      });
    } catch (_) {
      if (mounted && revision == _revision) setState(() => _failed = true);
    } finally {
      if (mounted && revision == _revision) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _revision++;
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t.musicTools.recent)),
    body: RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _entries.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) return Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.historyHint));
          if (index > _entries.length) {
            if (_loading) return const Center(child: CircularProgressIndicator());
            if (_failed) {
              return TextButton(
                onPressed: () => _load(refresh: _entries.isEmpty),
                child: Text(t.common.retry),
              );
            }
            if (_cursor != null) return TextButton(onPressed: _load, child: Text(t.fileSources.loadMore));
            return _entries.isEmpty
                ? Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.noHistory))
                : const SizedBox.shrink();
          }
          final entry = _entries[index - 1];
          return ListTile(
            key: ValueKey(entry.id),
            title: Text(entry.item.displayTitle),
            subtitle: Text(
              '${entry.item.trackArtistTitle ?? ''}\n${MaterialLocalizations.of(context).formatFullDate(entry.startedAt.toLocal())} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(entry.startedAt.toLocal()))}',
            ),
            isThreeLine: true,
            onTap: () => playTrackWithAlbumContext(context, entry.item),
          );
        },
      ),
    ),
  );
}
