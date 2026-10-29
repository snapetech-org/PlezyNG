import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../mpv/mpv.dart';
import '../../../mpv/player/player_media_session_identity.dart';
import '../../../mpv/player/subtitle_pcm_capture_source.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/media_bookmark_service.dart';
import '../../../services/subtitle_retimer.dart';
import 'subtitle_dictionary_dialog.dart';

/// Text-backed study controls on the owning player's source clock. Closing the
/// dialog cancels looping; no timer can resume a replaced player or profile.
class SubtitleStudyDialog extends StatefulWidget {
  const SubtitleStudyDialog({super.key, required this.player, required this.cues,
    required this.isCurrent, required this.title, this.identityKey});
  final Player player;
  final List<SubtitleCue> cues;
  final bool Function() isCurrent;
  final String title;
  final String? identityKey;
  @override
  State<SubtitleStudyDialog> createState() => _SubtitleStudyDialogState();
}

class _SubtitleStudyDialogState extends State<SubtitleStudyDialog> {
  final _search = TextEditingController();
  late final _cues = List<SubtitleCue>.of(widget.cues)..sort((a, b) => a.startMs.compareTo(b.startMs));
  late final int? _session = widget.player is PlayerMediaSessionIdentity
      ? (widget.player as PlayerMediaSessionIdentity).mediaSessionGeneration : null;
  late final String? _audio = widget.player.state.track.audio?.id;
  StreamSubscription<Duration>? _positions;
  StreamSubscription<bool>? _playing;
  Timer? _gap;
  SubtitleCue? _selected;
  int? _timeline;
  int _generation = 0;
  int _position = 0;
  bool _armed = false;
  bool _seeking = false;
  bool _ownsPause = false;
  bool _repeat = false;
  bool _autoPause = true;
  bool _hideFuture = false;
  double _preroll = 500;
  double _gapMs = 1000;
  String? _message;

  bool get _current => mounted && !widget.player.disposed && widget.isCurrent() &&
      (_session == null || (widget.player as PlayerMediaSessionIdentity).mediaSessionGeneration == _session) &&
      widget.player.state.track.audio?.id == _audio;

  @override
  void initState() {
    super.initState();
    _position = widget.player.currentPosition.inMilliseconds;
    _positions = widget.player.streams.position.listen(_onPosition);
    _playing = widget.player.streams.playing.listen((playing) {
      if (!_current) { _stop(); return; }
      // User play during the scheduled gap takes ownership of playback.
      if ((playing && _ownsPause) || (!playing && !_ownsPause && !_seeking)) _stop();
    });
  }

  @override
  void dispose() {
    ++_generation;
    _gap?.cancel();
    unawaited(_positions?.cancel());
    unawaited(_playing?.cancel());
    _search.dispose();
    super.dispose();
  }

  void _stop() {
    ++_generation;
    _gap?.cancel();
    _armed = false;
    _ownsPause = false;
    if (mounted) setState(() {});
  }

  void _onPosition(Duration value) {
    if (!_current) { _stop(); return; }
    final player = widget.player;
    if (!_seeking && (_armed || _ownsPause) && _timeline != null && player is SubtitlePcmCaptureSource &&
        player.playbackTimelineGeneration != _timeline) {
      _stop();
    }
    final position = value.inMilliseconds;
    // Only update the spoiler-filter view at one-second granularity.
    if (_position ~/ 1000 != position ~/ 1000) setState(() => _position = position);
    final cue = _selected;
    if (!_armed || _seeking || cue == null || !player.state.playing) return;
    if (position < cue.startMs - _preroll.round() - 2000 || position > cue.endMs + 2000) {
      _stop();
      return;
    }
    if (position >= cue.endMs) {
      _armed = false;
      if (_autoPause || _repeat) unawaited(_finishCue(cue));
    }
  }

  Future<void> _finishCue(SubtitleCue cue) async {
    final generation = _generation;
    try {
      if (!_current) return;
      _ownsPause = true;
      await widget.player.pause();
      if (!_current || generation != _generation) return;
      if (_repeat) {
        _gap = Timer(Duration(milliseconds: _gapMs.round()), () {
          final player = widget.player;
          if (!_current || generation != _generation || !_ownsPause || player.state.playing ||
              (player is SubtitlePcmCaptureSource && player.playbackTimelineGeneration != _timeline)) return;
          unawaited(_replay(cue));
        });
      }
    } catch (_) { _stop(); if (mounted) setState(() => _message = 'Playback could not pause at this cue.'); }
  }

  Future<void> _replay(SubtitleCue cue) async {
    if (_seeking || !_current || !widget.player.state.seekable) return;
    _stop();
    final generation = _generation;
    _selected = cue;
    _seeking = true;
    try {
      await widget.player.seek(Duration(milliseconds: (cue.startMs - _preroll.round()).clamp(0, cue.startMs).toInt()));
      if (!_current || generation != _generation) return;
      final player = widget.player;
      _timeline = player is SubtitlePcmCaptureSource ? player.playbackTimelineGeneration : null;
      _ownsPause = false;
      _armed = true;
      await player.play();
      if (_current && generation == _generation) setState(() => _message = 'Replaying cue ${cue.index}');
    } catch (_) { _stop(); if (mounted) setState(() => _message = 'This player could not replay the cue.'); }
    finally { _seeking = false; }
  }

  static String _plain(SubtitleCue cue) => cue.text.replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), '').replaceAll(r'\N', '\n');

  Future<void> _dictionary(SubtitleCue cue) async {
    if (!_current) return;
    final query = TextEditingController();
    try {
      final term = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(
        title: const Text('Look up a word or phrase'),
        content: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(_plain(cue)),
          const SizedBox(height: 12),
          TextField(controller: query, autofocus: true, maxLength: 128,
            decoration: const InputDecoration(labelText: 'Word or phrase to look up')),
          const Text('Opens Wiktionary in your browser and sends only the term you enter. Copying text remains available offline.'),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(onPressed: () async {
            if (!_current) return;
            await showDialog<void>(context: dialogContext, builder: (_) => SubtitleDictionaryDialog(
              isCurrent: () => _current, contextText: _plain(cue)));
          }, child: const Text('Offline dictionaries')),
          FilledButton(onPressed: () {
            final value = query.text.trim();
            if (value.isNotEmpty && value.length <= 128) Navigator.pop(dialogContext, value);
          }, child: const Text('Open dictionary'))]));
      if (term == null || !_current) return;
      final uri = Uri.https('en.wiktionary.org', '/w/index.php', {'title': 'Special:Search', 'search': term});
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
        setState(() => _message = 'This device cannot open a dictionary browser. Copy the term for lookup on another device.');
      }
    } catch (_) { if (mounted) setState(() => _message = 'The dictionary could not be opened.'); }
    finally { query.dispose(); }
  }

  Future<void> _bookmark(SubtitleCue cue) async {
    final identity = widget.identityKey;
    if (identity == null || !_current) return;
    final plain = _plain(cue).replaceAll('\n', ' ');
    final label = TextEditingController(text: plain.length > 80 ? plain.substring(0, 80) : plain);
    try {
      final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
        title: const Text('Save phrase or bookmark'),
        content: TextField(controller: label, maxLength: 80,
          decoration: const InputDecoration(labelText: 'Phrase, meaning, or note')),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save'))],
      ));
      if (accepted != true || !_current) return;
      await MediaBookmarkService.add('subtitle-study:$identity', label.text, cue.startMs);
      if (mounted) setState(() => _message = 'Saved with this media item and source time.');
    } catch (_) { if (mounted) setState(() => _message = 'Bookmark could not be saved (100 per item maximum).'); }
    finally { label.dispose(); }
  }

  Future<void> _exportBookmarks() async {
    final identity = widget.identityKey;
    if (identity == null || !_current) return;
    String cell(String text) => text.replaceAll(RegExp(r'[\t\r\n]'), ' ');
    final marks = MediaBookmarkService.forMedia('subtitle-study:$identity');
    if (marks.isEmpty) { setState(() => _message = 'Save a phrase or bookmark first.'); return; }
    final output = StringBuffer('Phrase / note\tSource title\tTime (ms)\tSource identity\n');
    for (final mark in marks) { output.writeln('${cell(mark.label)}\t${cell(widget.title)}\t${mark.positionMs}\t${cell(identity)}'); }
    try {
      await FilePickerService.instance.saveFile(dialogTitle: 'Export phrases for flashcards', fileName: 'subtitle_phrases.tsv',
        bytes: Uint8List.fromList(utf8.encode(output.toString())), type: FileType.custom, allowedExtensions: const ['tsv']);
    } catch (_) { if (mounted) setState(() => _message = 'The phrase export could not be saved.'); }
  }

  Future<void> _manageBookmarks() async {
    final identity = widget.identityKey;
    if (identity == null || !_current) return;
    await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, refresh) {
        final marks = MediaBookmarkService.forMedia('subtitle-study:$identity');
        return AlertDialog(title: const Text('Saved phrases'),
          content: SizedBox(width: 560, height: 340, child: marks.isEmpty
              ? const Center(child: Text('No saved phrases for this item.'))
              : ListView.builder(itemCount: marks.length, itemBuilder: (_, index) {
                final mark = marks[index];
                return ListTile(title: SelectableText(mark.label),
                  subtitle: Text(Duration(milliseconds: mark.positionMs).toString()),
                  leading: IconButton(tooltip: 'Go to source time', icon: const Icon(Icons.replay),
                    onPressed: () async {
                      if (!_current || _seeking || !widget.player.state.seekable) return;
                      _stop();
                      try { await widget.player.seek(Duration(milliseconds: mark.positionMs)); }
                      catch (_) { if (mounted) setState(() => _message = 'The bookmark could not be replayed.'); }
                    }),
                  trailing: IconButton(tooltip: 'Delete phrase', icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (!_current) return;
                      try {
                        await MediaBookmarkService.remove('subtitle-study:$identity', mark.id);
                        if (dialogContext.mounted) refresh(() {});
                      } catch (_) { if (mounted) setState(() => _message = 'The phrase could not be deleted.'); }
                    }));
              })),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))]);
      }));
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final visible = _cues.where((cue) => (!_hideFuture || cue.startMs <= _position) &&
        (query.isEmpty || _plain(cue).toLowerCase().contains(query))).toList();
    return AlertDialog(
      title: const Text('Transcript study'),
      content: SizedBox(width: 720, height: (MediaQuery.sizeOf(context).height - 200).clamp(260.0, 650.0).toDouble(),
        child: Column(children: [
          TextField(controller: _search, onChanged: (_) => setState(() {}), maxLength: 128,
            decoration: const InputDecoration(labelText: 'Search dialogue', counterText: '')),
          const Text('Replay uses the selected transcript’s source times. Use a synchronized transcript for this media and audio track.'),
          Wrap(spacing: 8, children: [
            FilterChip(label: const Text('Hide future dialogue'), selected: _hideFuture, onSelected: (v) => setState(() => _hideFuture = v)),
            FilterChip(label: const Text('Pause after line'), selected: _autoPause, onSelected: (v) => setState(() => _autoPause = v)),
            FilterChip(label: const Text('Repeat selected line'), selected: _repeat, onSelected: (v) { _stop(); setState(() => _repeat = v); }),
          ]),
          Row(children: [
            Text('Lead-in ${_preroll.round()} ms'),
            Expanded(child: Slider(value: _preroll, min: 0, max: 2500, divisions: 25,
              label: '${_preroll.round()} ms', onChanged: (v) => setState(() => _preroll = v))),
          ]),
          if (_repeat) Row(children: [Text('Loop gap ${_gapMs.round()} ms'),
            Expanded(child: Slider(value: _gapMs, min: 0, max: 5000, divisions: 50,
              label: '${_gapMs.round()} ms', onChanged: (v) => setState(() => _gapMs = v)))]),
          if (_message != null) Text(_message!),
          Expanded(child: ListView.builder(itemCount: visible.length, itemBuilder: (context, index) {
            final cue = visible[index];
            return ListTile(
              selected: _selected?.stableId == cue.stableId,
              title: SelectableText(_plain(cue)),
              subtitle: Text('${Duration(milliseconds: cue.startMs)}'),
              leading: IconButton(tooltip: 'Replay cue ${cue.index}', onPressed: _current && widget.player.state.seekable
                  ? () => _replay(cue) : null, icon: const Icon(Icons.replay)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: 'Look up a word or phrase', onPressed: () => _dictionary(cue), icon: const Icon(Icons.menu_book_outlined)),
                IconButton(tooltip: 'Copy cue text', onPressed: () => Clipboard.setData(ClipboardData(text: _plain(cue))), icon: const Icon(Icons.copy)),
                if (widget.identityKey != null) IconButton(tooltip: 'Save phrase or bookmark', onPressed: () => _bookmark(cue), icon: const Icon(Icons.bookmark_add_outlined)),
              ]),
            );
          })),
        ])),
      actions: [
        TextButton(onPressed: _stop, child: const Text('Stop loop')),
        if (widget.identityKey != null) TextButton(onPressed: _manageBookmarks, child: const Text('Saved phrases')),
        if (widget.identityKey != null) TextButton(onPressed: _exportBookmarks, child: const Text('Export phrases')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
