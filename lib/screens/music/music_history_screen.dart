import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_library_store.dart';
import '../../utils/music_navigation.dart';
import '../../providers/companion_remote_provider.dart';
import '../../utils/snackbar_helper.dart';

class MusicHistoryScreen extends StatefulWidget {
  const MusicHistoryScreen({super.key});
  @override
  State<MusicHistoryScreen> createState() => _MusicHistoryScreenState();
}

class _MusicHistoryScreenState extends State<MusicHistoryScreen> {
  late final MusicLibraryStore _store = context.read<MusicExperience>().store;
  StreamSubscription<void>? _changes;
  Timer? _refreshTimer;
  List<MusicHistoryEntry> _entries = [];
  (int, String)? _cursor;
  int _pages = 1;
  bool _refreshPending = false;
  bool _loading = false;
  bool? _failedRefresh;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _changes = _store.historyChanges.listen((_) {
      _refreshTimer ??= Timer(const Duration(milliseconds: 150), () {
        _refreshTimer = null;
        unawaited(_load(refresh: true));
      });
    });
    unawaited(_load(refresh: true));
  }

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    if (_loading) {
      _refreshPending |= refresh;
      return;
    }
    if (!refresh && _cursor == null) return;
    setState(() {
      _loading = true;
      _failedRefresh = null;
    });
    try {
      final page = refresh ? await _store.historyWindow(_pages) : await _store.historyPage(before: _cursor);
      if (!mounted) return;
      setState(() {
        if (!refresh) _pages++;
        _entries = refresh ? page.entries : [..._entries, ...page.entries];
        _cursor = page.cursor;
      });
    } catch (_) {
      if (mounted) setState(() => _failedRefresh = refresh);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_refreshPending) {
          _refreshPending = false;
          unawaited(_load(refresh: true));
        }
      }
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final companion = context.watch<CompanionRemoteProvider?>();
    return Scaffold(
      appBar: AppBar(
        title: Text(t.musicTools.recent),
        actions: [
          if (companion?.supportsMusicHistory == true)
            IconButton(
              tooltip: '${t.homeLayout.sync}: ${companion!.connectedDevice?.name ?? t.companionRemote.unknownDevice}',
              icon: _syncing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              onPressed: _syncing
                  ? null
                  : () async {
                      setState(() => _syncing = true);
                      try {
                        final result = await companion.synchronizeMusicHistory();
                        if (context.mounted && !result) showErrorSnackBar(context, t.musicExperience.error);
                      } finally {
                        if (mounted) setState(() => _syncing = false);
                      }
                    },
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: _entries.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) return Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.historyHint));
            if (index > _entries.length) {
              if (_loading) return const Center(child: CircularProgressIndicator());
              if (_failedRefresh case final refresh?) {
                return TextButton(
                  onPressed: () => _load(refresh: refresh),
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
}
