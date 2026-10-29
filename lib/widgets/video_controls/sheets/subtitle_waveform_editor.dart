import 'package:flutter/material.dart';

import '../../../services/subtitle_retimer.dart';
import '../../../services/subtitle_waveform_service.dart';

class SubtitleWaveformEditor extends StatefulWidget {
  const SubtitleWaveformEditor({super.key, required this.waveform, required this.cues});
  final SubtitleWaveform waveform;
  final List<SubtitleCue> cues;
  @override
  State<SubtitleWaveformEditor> createState() => _SubtitleWaveformEditorState();
}

class _SubtitleWaveformEditorState extends State<SubtitleWaveformEditor> {
  late final List<SubtitleCue> _cues = List.of(widget.cues);
  late final List<int> _indices = List.generate(_cues.length, (i) => i).where((i) =>
      _cues[i].startMs < widget.waveform.endMs && _cues[i].endMs > widget.waveform.startMs).toList();
  final List<(int, SubtitleCue)> _undo = [];
  final _start = TextEditingController(), _end = TextEditingController();
  var _selection = 0;
  var _spectrum = false;
  var _editStart = true;
  String? _error;

  @override
  void initState() { super.initState(); _syncFields(); }
  @override
  void dispose() { _start.dispose(); _end.dispose(); super.dispose(); }

  void _syncFields() {
    if (_indices.isEmpty) return;
    final cue = _cues[_indices[_selection]];
    _start.text = '${cue.startMs}'; _end.text = '${cue.endMs}';
  }

  void _apply(int start, int end) {
    final data = widget.waveform;
    if (start < data.startMs || end > data.endMs || end <= start) {
      setState(() => _error = 'Use start < end within ${data.startMs}–${data.endMs} ms.');
      return;
    }
    final index = _indices[_selection], cue = _cues[_indices[_selection]];
    if (start == cue.startMs && end == cue.endMs) return;
    setState(() {
      if (_undo.length == 100) _undo.removeAt(0);
      _undo.add((index, cue));
      _cues[index] = SubtitleCue(index: cue.index, startMs: start, endMs: end, text: cue.text, cueId: cue.stableId);
      _error = null;
      _syncFields();
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.waveform;
    final cue = _indices.isEmpty ? null : _cues[_indices[_selection]];
    return AlertDialog(
      title: const Text('Waveform and timing anchors'),
      content: SizedBox(width: 800, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${data.startMs}–${data.endMs} ms · 16 kHz analysis · spectrogram 0–8 kHz'),
        SwitchListTile(title: const Text('Show spectrogram'), value: _spectrum, onChanged: (v) => setState(() => _spectrum = v)),
        Semantics(label: 'Audio waveform. Exact cue timing is editable in the fields below.',
          child: LayoutBuilder(builder: (context, constraints) => GestureDetector(
            onTapDown: cue == null ? null : (details) {
              final time = (data.startMs + details.localPosition.dx / constraints.maxWidth *
                  (data.endMs - data.startMs)).round().clamp(data.startMs, data.endMs).toInt();
              _apply(_editStart ? time : cue.startMs, _editStart ? cue.endMs : time);
            },
            child: CustomPaint(size: Size(constraints.maxWidth, 180), painter: _WaveformPainter(data, cue, _spectrum,
                Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.surfaceContainerHighest)),
          )),
        ),
        if (cue == null) const Text('No subtitle cues overlap this audio interval.') else ...[
          Row(children: [
            IconButton(tooltip: 'Previous cue', onPressed: _selection == 0 ? null : () => setState(() { --_selection; _syncFields(); }), icon: const Icon(Icons.chevron_left)),
            Expanded(child: Text('Cue ${cue.index} · ${_selection + 1}/${_indices.length}')),
            IconButton(tooltip: 'Next cue', onPressed: _selection + 1 == _indices.length ? null : () => setState(() { ++_selection; _syncFields(); }), icon: const Icon(Icons.chevron_right)),
          ]),
          SelectableText(cue.text),
          SegmentedButton<bool>(segments: const [ButtonSegment(value: true, label: Text('Tap sets start')),
            ButtonSegment(value: false, label: Text('Tap sets end'))], selected: {_editStart},
            onSelectionChanged: (values) => setState(() => _editStart = values.first)),
          Row(children: [
            Expanded(child: TextField(controller: _start, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Start (ms)'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _end, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'End (ms)'))),
            TextButton(onPressed: () => _apply(int.tryParse(_start.text) ?? -1, int.tryParse(_end.text) ?? -1), child: const Text('Set anchors')),
          ]),
        ],
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const Text('A waveform shows energy, not a verified speech boundary. Timing changes are reviewed before attachment. Originals remain intact.'),
      ]))),
      actions: [
        TextButton(onPressed: _undo.isEmpty ? null : () => setState(() {
          final old = _undo.removeLast(); _cues[old.$1] = old.$2; _syncFields(); _error = null;
        }), child: const Text('Undo')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _cues), child: const Text('Review changes')),
      ],
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.data, this.cue, this.spectrum, this.color, this.background);
  final SubtitleWaveform data;
  final SubtitleCue? cue;
  final bool spectrum;
  final Color color;
  final Color background;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final width = size.width / data.columns;
    final paint = Paint()..color = color..strokeWidth = 1;
    if (spectrum) {
      final height = size.height / data.bins;
      for (var x = 0; x < data.columns; x++) {
        for (var y = 0; y < data.bins; y++) {
          final value = data.spectrum[x * data.bins + y] / 255;
          if (value < 0.04) continue;
          paint.color = Color.lerp(background, color, value)!;
          canvas.drawRect(Rect.fromLTWH(x * width, size.height - (y + 1) * height, width + 0.5, height + 0.5), paint);
        }
      }
    } else {
      for (var x = 0; x < data.columns; x++) {
        final peak = data.peaks[x] * size.height / 2;
        canvas.drawLine(Offset(x * width, size.height / 2 - peak), Offset(x * width, size.height / 2 + peak), paint);
      }
    }
    final active = cue;
    if (active != null) {
      double position(int ms) => ((ms - data.startMs) / (data.endMs - data.startMs)).clamp(0.0, 1.0).toDouble() * size.width;
      final start = position(active.startMs), end = position(active.endMs);
      canvas.drawRect(Rect.fromLTRB(start, 0, end, size.height), Paint()..color = color.withValues(alpha: 0.18));
      paint..color = color..strokeWidth = 2;
      canvas.drawLine(Offset(start, 0), Offset(start, size.height), paint);
      canvas.drawLine(Offset(end, 0), Offset(end, size.height), paint);
    }
  }
  @override
  bool shouldRepaint(covariant _WaveformPainter old) => old.data != data || old.cue != cue || old.spectrum != spectrum || old.color != color || old.background != background;
}
