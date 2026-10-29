import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.g.dart';
import '../services/subtitle_retimer.dart';

/// Shared source-clock picker. The caller captures and checks its player,
/// profile, opened part, audio and subtitle identity before applying a result.
class SubtitleCuePickerSheet extends StatefulWidget {
  const SubtitleCuePickerSheet({super.key, required this.cues, required this.positions,
    required this.currentPositionMs, required this.isCurrent,
    required this.initialDelayMs, required this.initialRate});
  final List<SubtitleCue> cues;
  final Stream<Duration> positions;
  final int Function() currentPositionMs;
  final bool Function() isCurrent;
  final int initialDelayMs;
  final double initialRate;
  @override
  State<SubtitleCuePickerSheet> createState() => _SubtitleCuePickerSheetState();
}

class _SubtitleCuePickerSheetState extends State<SubtitleCuePickerSheet> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  late final List<String> _text;
  late final List<String> _searchable;
  late List<int> _visible;
  String _time(int ms) {
    final value = Duration(milliseconds: ms < 0 ? 0 : ms);
    return '${value.inHours}:${(value.inMinutes % 60).toString().padLeft(2, '0')}:'
      '${(value.inSeconds % 60).toString().padLeft(2, '0')}.${(value.inMilliseconds % 1000).toString().padLeft(3, '0')}';
  }
  @override
  void initState() {
    super.initState();
    _text = widget.cues.map((cue) => cue.text.replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\s+'), ' ').trim()).toList(growable: false);
    _searchable = _text.map((text) => text.toLowerCase()).toList(growable: false);
    _visible = List.generate(widget.cues.length, (index) => index);
    var nearest = 0, distance = 1 << 62;
    final position = widget.currentPositionMs();
    for (var i = 0; i < widget.cues.length; i++) {
      final delta = ((widget.cues[i].startMs * widget.initialRate).round() + widget.initialDelayMs - position).abs();
      if (delta < distance) { distance = delta; nearest = i; }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo((nearest * 76.0).clamp(0.0, _scroll.position.maxScrollExtent).toDouble());
      }
    });
  }
  @override
  void dispose() { _scroll.dispose(); _search.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => SafeArea(child: SizedBox(
    height: MediaQuery.sizeOf(context).height * .72,
    child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
      Row(children: [Expanded(child: Text(t.videoSettings.subtitleCueTools,
        style: Theme.of(context).textTheme.titleMedium)),
        IconButton(tooltip: t.common.close, onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close))]),
      TextField(controller: _search, inputFormatters: [LengthLimitingTextInputFormatter(120)],
        decoration: InputDecoration(labelText: t.common.search, prefixIcon: const Icon(Icons.search)),
        onChanged: (value) {
          final query = value.trim().toLowerCase();
          setState(() => _visible = [for (var i = 0; i < _searchable.length; i++)
            if (query.isEmpty || _searchable[i].contains(query)) i]);
          if (_scroll.hasClients) _scroll.jumpTo(0);
        }),
      StreamBuilder<Duration>(stream: widget.positions, builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(widget.isCurrent()
          ? '${t.videoSettings.subtitleUsePlaybackTime}: ${_time(widget.currentPositionMs())}'
          : t.videoSettings.subtitleCueUnavailable))),
      Expanded(child: ListView.builder(controller: _scroll, itemExtent: 76, itemCount: _visible.length,
        itemBuilder: (context, index) {
          final i = _visible[index], cue = widget.cues[i];
          return ListTile(leading: SizedBox(width: 86, child: Text(_time(cue.startMs),
              style: Theme.of(context).textTheme.labelSmall)),
            title: Text(_text[i], maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () {
              if (!widget.isCurrent()) { Navigator.of(context).pop(); return; }
              final position = widget.currentPositionMs();
              if (position < 0) return;
              Navigator.of(context).pop((cue: cue, playbackPositionMs: position));
            });
        })),
    ])),
  ));
}
