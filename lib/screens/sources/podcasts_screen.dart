import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../i18n/locale_preferences.dart';
import '../../sources/podcast_library.dart';
import '../../sources/podcast_metadata.dart';
import '../../sources/offline_readiness.dart';
import '../../sources/publication_library.dart';
import '../../sources/source_controller.dart';
import '../../sources/source_models.dart';
import '../../sources/source_playback.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/music/mini_player.dart';
import 'add_source_screen.dart';
import 'podcast_actions.dart';
import 'podcast_discover_screen.dart';
import 'source_detail_screen.dart';
import 'source_player_screen.dart';
import 'source_widgets.dart';
import 'sources_screen.dart';

class PodcastsScreen extends StatefulWidget {
  const PodcastsScreen({super.key, this.sourceId, this.parentId, this.title});
  final String? sourceId, parentId, title;
  @override
  State<PodcastsScreen> createState() => _PodcastsScreenState();
}

class _PodcastsScreenState extends State<PodcastsScreen> {
  final _search = TextEditingController();
  SourceController? _sources;
  int? _epoch;
  List<SourceEntry> _episodes = const [];
  Map<String, PublicationProgress> _progress = {};
  Set<String> _offline = {}, _actions = {};
  bool _loading = true, _shows = false, _oldest = false, _offlineOnly = false;
  PublicationStatus _status = PublicationStatus.all;
  Object? _error;
  int _request = 0, _limit = 200;
  bool _more = false;
  Timer? _searchTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sources = context.watch<SourceController>();
    if (!identical(sources, _sources) || _epoch != sources.generation) {
      _sources = sources; _epoch = sources.generation; _request++;
      _searchTimer?.cancel();
      _episodes = const []; _progress = {}; _offline = {}; _actions = {};
      _search.clear(); _status = PublicationStatus.all; _shows = false; _offlineOnly = false;
      _oldest = false; _limit = 200; _more = false; _error = null; _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(refresh: widget.sourceId != null));
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    final sources = _sources!, epoch = sources.generation, request = ++_request;
    final status = _status, offlineOnly = _offlineOnly, oldest = _oldest, query = _search.text.trim();
    Object? refreshError;
    setState(() { _loading = true; _error = null; });
    try {
      await sources.ready;
      sources.requireSession(epoch);
      final profile = sources.profileId!;
      if (refresh) {
        if (widget.sourceId != null) {
          final source = sources.sources.where((s) => s.id == widget.sourceId).firstOrNull;
          if (source != null) {
            try {
              if (source.kind == FileSourceKind.podcastRss) await sources.browse(source.id);
              await sources.browse(source.id, parent: widget.parentId);
            } catch (error) { refreshError = error; }
          }
        } else if (await PodcastLibrary(sources).refreshFeeds() > 0) {
          if (mounted && sources.current(epoch)) showSnackBar(context, t.podcasts.refreshPartial);
        }
      }
      sources.requireSession(epoch);
      final entries = <SourceEntry>[];
      final latest = <String, PublicationProgress>{};
      final offline = <String>{};
      final records = await sources.repository.downloads(profile);
      var offset = 0;
      // Apply status/offline filters before taking the display page. A rare
      // unfinished episode must not disappear behind 200 finished episodes.
      while (entries.length <= _limit && offset < 10000) {
        sources.requireSession(epoch);
        if (!mounted || request != _request) return;
        final batch = await sources.repository.podcastEntries(profile, limit: 200, offset: offset,
            source: widget.sourceId, parent: widget.parentId, query: query, oldestFirst: oldest);
        if (batch.isEmpty) break;
        offset += batch.length;
        final progress = await sources.repository.progressForEntries(profile, batch.map((e) => e.key));
        final downloads = await sources.downloads.verifiedFiles(profile, batch, records: records);
        final seeds = {for (final entry in batch) entry.key: PodcastLibrary.seed(entry).key};
        for (final value in progress) {
          if (value.key != seeds[value.entryKey]) continue;
          if ((latest[value.entryKey]?.updatedAt ?? -1) < value.updatedAt) latest[value.entryKey] = value;
        }
        for (final entry in batch) {
          final downloaded = PublicationOfflineReadiness.evaluate(entry, downloads).isReady;
          if (downloaded) offline.add(entry.key);
          if ((entry.unavailable && !downloaded) || (offlineOnly && !downloaded)) continue;
          final progress = latest[entry.key];
          final started = (progress?.positionMs ?? 0) > 0 || (progress?.fraction ?? 0) > 0;
          final matches = switch (status) {
            PublicationStatus.all => true,
            PublicationStatus.unstarted => progress?.finished != true && !started,
            PublicationStatus.inProgress => progress?.finished != true && started,
            PublicationStatus.finished => progress?.finished == true,
          };
          if (matches) entries.add(entry);
        }
        if (batch.length < 200) break;
      }
      sources.requireSession(epoch);
      if (!mounted || request != _request) return;
      setState(() {
        _error = refreshError;
        _more = entries.length > _limit; _episodes = entries.take(_limit).toList();
        _progress = latest;
        _offline = offline;
      });
    } catch (error) {
      if (mounted && request == _request && sources.current(epoch)) setState(() => _error = error);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _route(Widget screen, {bool refresh = false}) async {
    final sources = _sources!, epoch = sources.generation;
    await Navigator.push(context, MaterialPageRoute(
        settings: screen is SourcePlayerScreen ? const RouteSettings(name: 'source-player') : null,
        builder: (_) => screen));
    if (mounted && sources.current(epoch)) await _load(refresh: refresh);
  }

  Future<void> _play(SourceEntry entry) async {
    if (entry.audio.isEmpty) { await _route(SourceDetailScreen(entry: entry)); return; }
    final sources = _sources!, epoch = sources.generation;
    var current = entry;
    try { current = await sources.hydrate(entry); } catch (_) { /* Cached offline episode. */ }
    sources.requireSession(epoch);
    if (!mounted) return;
    await context.read<SourcePlayback>().start(current, current.audio);
    sources.requireSession(epoch);
    if (mounted) await _route(const SourcePlayerScreen());
  }

  Future<void> _episodeAction(SourceEntry entry, String action) async {
    if (_actions.contains(entry.key)) return;
    final sources = _sources!, epoch = sources.generation;
    setState(() => _actions.add(entry.key));
    try {
      if (action == 'play') {
        await _play(entry);
      } else if (action == 'download') {
        for (final file in entry.files.where((file) => !file.sampleOnly)) {
          sources.requireSession(epoch);
          await sources.content(entry, file);
        }
      } else if (action == 'finished') {
        final playback = context.read<SourcePlayback>();
        if (playback.entry?.key == entry.key) await playback.stop();
        sources.requireSession(epoch);
        await PodcastLibrary(sources).markFinished(entry, _progress[entry.key]?.finished != true);
      } else {
        await _route(SourceDetailScreen(entry: entry));
      }
    } finally {
      if (mounted && sources.current(epoch)) { setState(() => _actions.remove(entry.key)); await _load(); }
    }
  }

  Future<void> _disconnect(FileSource source) async {
    final sources = _sources!, epoch = sources.generation;
    if (!await showConfirmDialog(context, title: t.fileSources.removeSource,
        message: t.fileSources.disconnectMessage, confirmText: t.common.disconnect)) return;
    sources.requireSession(epoch);
    await sources.remove(source);
    if (mounted && sources.current(epoch)) await _load();
  }

  String _statusLabel(PublicationStatus status) => switch (status) {
    PublicationStatus.all => t.audiobook.statusAll,
    PublicationStatus.unstarted => t.audiobook.statusNew,
    PublicationStatus.inProgress => t.audiobook.statusProgress,
    PublicationStatus.finished => t.audiobook.statusFinished,
  };

  @override
  void dispose() { _request++; _searchTimer?.cancel(); _search.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final sources = context.watch<SourceController>();
    final query = _search.text.trim().toLowerCase();
    final visible = organizePublications(_episodes.where((entry) =>
      (!entry.unavailable || _offline.contains(entry.key)) && (!_offlineOnly || _offline.contains(entry.key)) &&
      '${entry.title} ${entry.series} ${entry.author} ${entry.description}'.toLowerCase().contains(query)).toList(),
      _progress.values.toList(), status: _status);
    visible.sort((a, b) {
      final time = (podcastPublishedAt(a)?.millisecondsSinceEpoch ?? 0)
          .compareTo(podcastPublishedAt(b)?.millisecondsSinceEpoch ?? 0);
      return time == 0 ? a.key.compareTo(b.key) : _oldest ? time : -time;
    });
    final shows = sources.sources.where((s) => s.kind == FileSourceKind.podcastRss &&
        s.name.toLowerCase().contains(query)).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final servers = sources.sources.where((s) => s.kind == FileSourceKind.audiobookshelf).toList();
    final root = widget.sourceId == null;
    return FocusedScrollScaffold(title: Text(widget.title ?? t.podcasts.title), focusableAppBarActions: true,
      actions: [
        IconButton(tooltip: t.fileSources.refresh, onPressed: _loading ? null : () => _load(refresh: true),
          icon: const AppIcon(Symbols.refresh_rounded)),
        AppMenuButton<String>(tooltip: t.common.options, icon: const AppIcon(Symbols.more_vert_rounded),
          adaptiveSheet: true, entriesBuilder: (_) => [
          AppMenuItem(value: 'discover', label: t.podcasts.discover, icon: Symbols.search_rounded),
          AppMenuItem(value: 'feed', label: t.podcasts.addFeed, icon: Symbols.rss_feed_rounded),
          AppMenuItem(value: 'server', label: 'Audiobookshelf', icon: Symbols.dns_rounded),
          AppMenuItem(value: 'import', label: t.podcasts.importOpml, icon: Symbols.file_open_rounded),
          AppMenuItem(value: 'export', label: t.podcasts.exportOpml, icon: Symbols.ios_share_rounded),
        ], onSelected: (action) => sourceAction(context, () async {
          if (action == 'discover') { await _route(const PodcastDiscoverScreen(), refresh: true); }
          else if (action == 'feed') { await _route(const AddSourceScreen(initialKind: FileSourceKind.podcastRss), refresh: true); }
          else if (action == 'server') { await _route(const AddSourceScreen(initialKind: FileSourceKind.audiobookshelf)); }
          else if (action == 'import') { await importPodcastOpml(context); if (mounted) await _load(refresh: true); }
          else { await exportPodcastOpml(context); }
        })),
      ],
      slivers: [SliverPadding(padding: const EdgeInsets.all(24), sliver: SliverToBoxAdapter(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (root) Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(label: Text(t.podcasts.episodes), selected: !_shows, onSelected: (_) => setState(() => _shows = false)),
            ChoiceChip(label: Text(t.podcasts.shows), selected: _shows, onSelected: (_) => setState(() => _shows = true)),
            OutlinedButton.icon(onPressed: () => _route(const PodcastDiscoverScreen(), refresh: true),
              icon: const AppIcon(Symbols.search_rounded), label: Text(t.podcasts.discover)),
          ]),
          const SizedBox(height: 12),
          FocusableTextField(controller: _search, decoration: InputDecoration(labelText: t.common.search),
            onChanged: (_) {
              _searchTimer?.cancel(); _request++;
              setState(() { _limit = 200; _loading = true; });
              _searchTimer = Timer(const Duration(milliseconds: 300), () => _load());
            }),
          if (!_shows || !root) Padding(padding: const EdgeInsets.only(top: 12), child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final value in PublicationStatus.values)
              ChoiceChip(label: Text(_statusLabel(value)), selected: _status == value,
                onSelected: (_) { setState(() { _status = value; _limit = 200; }); _load(); }),
            FilterChip(label: Text(t.fileSources.offline), selected: _offlineOnly,
                onSelected: (value) { setState(() { _offlineOnly = value; _limit = 200; }); _load(); }),
            ActionChip(label: Text(_oldest ? t.podcasts.oldest : t.podcasts.newest),
                onPressed: () { setState(() { _oldest = !_oldest; _limit = 200; }); _load(); }),
          ])),
          if (_loading) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 16),
              child: SourceErrorMessage(message: sourceFailureText(_error!))),
          if (!_loading && (_shows ? shows.isEmpty : visible.isEmpty))
            Padding(padding: const EdgeInsets.only(top: 16), child: Text(t.podcasts.empty)),
          if (_shows && servers.isNotEmpty) ...[
            const SizedBox(height: 16), Text(t.podcasts.serverHelp),
            for (final server in servers) SourceTile(title: server.name, subtitle: 'Audiobookshelf',
                onTap: () => _route(SourcesScreen(source: server))),
          ],
        ]))),
        SliverPadding(padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 24), sliver:
          _shows && root ? SliverList.builder(itemCount: shows.length, itemBuilder: (context, index) {
            final source = shows[index];
            return SourceTile(title: source.name, icon: Symbols.podcasts_rounded, index: index, count: shows.length,
              onTap: () => _route(PodcastsScreen(sourceId: source.id, parentId: 'podcast:episodes', title: source.name)),
              trailing: AppMenuButton<String>(tooltip: t.common.options, icon: const AppIcon(Symbols.more_vert_rounded),
                adaptiveSheet: true, entriesBuilder: (_) => [
                AppMenuItem(value: 'edit', label: t.common.settings, icon: Symbols.settings_rounded),
                AppMenuItem(value: 'remove', label: t.common.disconnect, icon: Symbols.link_off_rounded),
              ], onSelected: (action) => sourceAction(context, () async {
                if (action == 'remove') { await _disconnect(source); }
                else { await _route(AddSourceScreen(existing: source), refresh: true); }
              })));
          }) : SliverList.builder(itemCount: visible.length, itemBuilder: (context, index) {
            final entry = visible[index], progress = _progress[visible[index].key];
            final busy = _actions.contains(entry.key), date = podcastPublishedAt(entry);
            final subtitle = [entry.series, if (date != null) DateFormat.yMMMd(LocalePreferences.formattingLocaleName).format(date),
              if ((entry.files.firstOrNull?.durationMs ?? 0) > 0) sourceTime(entry.files.first.durationMs!),
              if (_offline.contains(entry.key)) t.fileSources.offline,
              if (progress?.finished == true) t.fileSources.finished,
              if (const {'yes', 'true', 'explicit'}.contains(entry.identifiers['explicit']?.toLowerCase())) t.podcasts.explicit,
            ].where((value) => value.isNotEmpty).join(' · ');
            return SourceTile(title: entry.title, subtitle: subtitle, index: index, count: visible.length,
              leading: SizedBox.square(dimension: 56, child: SourceCover(entry: entry)), progress: progress?.fraction,
              onTap: () => _route(SourceDetailScreen(entry: entry)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: t.common.play, onPressed: busy ? null : () =>
                    sourceAction(context, () => _episodeAction(entry, 'play')), icon: const AppIcon(Symbols.play_arrow_rounded)),
                AppMenuButton<String>(tooltip: t.common.options, icon: const AppIcon(Symbols.more_vert_rounded),
                  adaptiveSheet: true, entriesBuilder: (_) => [
                  AppMenuItem(value: 'download', label: t.fileSources.download, icon: Symbols.download_rounded,
                    enabled: !busy && !_offline.contains(entry.key)),
                  AppMenuItem(value: 'finished', label: progress?.finished == true ? t.fileSources.markUnfinished : t.fileSources.markFinished,
                    icon: Symbols.check_circle_rounded, enabled: !busy),
                  AppMenuItem(value: 'details', label: t.podcasts.inLibrary, icon: Symbols.info_rounded),
                ], onSelected: (action) => sourceAction(context, () => _episodeAction(entry, action))),
              ]));
          })),
        if (_more && !_shows && _limit < 10000) SliverToBoxAdapter(child: Center(child: TextButton(
          onPressed: _loading ? null : () { _limit = (_limit + 200).clamp(200, 10000); _load(); },
          child: Text(t.podcasts.viewAll)))),
        SliverToBoxAdapter(child: SizedBox(height: 32 + (context.watch<MiniPlayerInsetController?>()?.overlayHeight ?? 88))),
      ],
    );
  }
}
