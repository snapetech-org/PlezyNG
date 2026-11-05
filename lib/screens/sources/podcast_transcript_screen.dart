import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/subtitle_retimer.dart';
import '../../sources/adapters/podcast_rss_source.dart';
import '../../sources/podcast_transcript.dart';
import '../../sources/source_controller.dart';
import '../../sources/source_models.dart';
import '../../sources/source_playback.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import 'source_widgets.dart';

class PodcastTranscriptScreen extends StatefulWidget {
  const PodcastTranscriptScreen({super.key, required this.entry});
  final SourceEntry entry;
  @override
  State<PodcastTranscriptScreen> createState() => _PodcastTranscriptScreenState();
}

class _PodcastTranscriptScreenState extends State<PodcastTranscriptScreen> {
  PodcastTranscript? _transcript;
  List<SubtitleCue> _visible = const [];
  SourceController? _owner;
  int? _epoch;
  String _query = '';
  bool _loading = true;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = context.watch<SourceController>();
    if (!identical(owner, _owner) || _epoch != owner.generation) {
      _owner = owner; _epoch = owner.generation;
      _transcript = null; _visible = const []; _loading = true; _error = null;
      _load();
    }
  }
  void _filter() {
    _visible = (_transcript?.cues ?? const <SubtitleCue>[])
        .where((cue) => _query.isEmpty || cue.text.toLowerCase().contains(_query)).toList();
  }
  Future<void> _load({bool refresh = false}) async {
    final owner = _owner!, epoch = owner.generation;
    final key = 'podcast-transcript-v1:${sourceDigest(widget.entry.key)}';
    try {
      await owner.ready;
      owner.requireSession(epoch);
      final profile = owner.profileId!;
      final cached = await owner.repository.privatePreference(profile, key);
      owner.requireSession(epoch);
      final fingerprint = widget.entry.files.firstOrNull?.fingerprint;
      PodcastTranscript? transcript;
      if (!refresh && cached['fingerprint'] == fingerprint && cached['document'] is Map) {
        try { transcript = PodcastTranscript.fromJson(sourceMap(cached['document'])); }
        on Object { /* Re-fetch a damaged optional cache. */ }
      }
      if (transcript == null) {
        final adapter = owner.adapter(widget.entry.sourceId);
        if (adapter is! PodcastRssSourceAdapter) throw const SourceException(SourceFailure.unsupported);
        transcript = await adapter.transcript(widget.entry);
        owner.requireSession(epoch);
        if (transcript == null) throw const SourceException(SourceFailure.unavailable);
        await owner.repository.savePrivatePreference(profile, key,
          {'fingerprint': fingerprint, 'document': transcript.toJson()});
      }
      owner.requireSession(epoch);
      if (mounted) setState(() { _transcript = transcript; _loading = false; _error = null; _filter(); });
    } on Object catch (error) {
      if (mounted && owner.current(epoch)) setState(() { _loading = false; _error = error; });
    }
  }
  Future<void> _forget() async {
    final owner = _owner!, epoch = owner.generation;
    await sourceAction(context, () async {
      owner.requireSession(epoch);
      await owner.repository.forgetPreference(owner.profileId!, 'podcast-transcript-v1:${sourceDigest(widget.entry.key)}');
      if (mounted && owner.current(epoch)) Navigator.pop(context);
    });
  }
  @override
  Widget build(BuildContext context) {
    final playback = context.watch<SourcePlayback>();
    final canSeek = playback.entry?.key == widget.entry.key && playback.player?.state.seekable == true;
    final cues = _visible;
    return FocusedScrollScaffold(title: Text(t.subtitleAiUi.searchTranscript), actions: [
      IconButton(tooltip: t.fileSources.refresh, icon: const Icon(Icons.refresh), onPressed: _loading ? null : () {
        setState(() => _loading = true); _load(refresh: true);
      }),
      IconButton(tooltip: t.downloads.deleteDownload, icon: const Icon(Icons.delete_outline), onPressed: _loading ? null : _forget),
    ], slivers: [
      if (_loading) const SliverToBoxAdapter(child: LinearProgressIndicator()),
      if (_error != null) SliverToBoxAdapter(child: SourceErrorMessage(message: sourceFailureText(_error!))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: TextField(
        decoration: InputDecoration(labelText: t.common.search),
        onChanged: (value) => setState(() { _query = value.trim().toLowerCase(); _filter(); })))),
      if (_transcript?.cues.isNotEmpty == true)
        SliverList.builder(itemCount: cues.length, itemBuilder: (context, index) {
          final cue = cues[index];
          final active = canSeek && playback.positionMs >= cue.startMs && playback.positionMs <= cue.endMs;
          return FocusableListTile(selected: active, title: Text(cue.text),
            subtitle: Text(Duration(milliseconds: cue.startMs).toString().split('.').first),
            onTap: !canSeek ? null : () => sourceAction(context, () => playback.seek(cue.startMs)));
        })
      else if (_transcript != null)
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: SelectableText(_transcript!.text))),
    ]);
  }
}
