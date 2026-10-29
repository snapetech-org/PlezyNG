import 'package:flutter/material.dart';

import '../i18n/presentation_formats.dart';
import '../i18n/strings.g.dart';
import '../services/subtitle_calibration_history.dart';
import '../services/subtitle_sync_calibration.dart';

typedef SubtitleCalibrationChoice = ({SubtitleSyncCalibration value, List<SubtitleSyncAnchor> anchors});

class SubtitleCalibrationDialog extends StatefulWidget {
  const SubtitleCalibrationDialog({super.key, required this.history, required this.currentPositionSeconds,
    required this.isCurrent, required this.preview, required this.rollback});
  final List<SubtitleCalibrationRecord> history;
  final double Function() currentPositionSeconds;
  final bool Function() isCurrent;
  final Future<bool> Function(SubtitleSyncCalibration) preview;
  final Future<void> Function() rollback;
  @override
  State<SubtitleCalibrationDialog> createState() => _SubtitleCalibrationDialogState();
}

class _SubtitleCalibrationDialogState extends State<SubtitleCalibrationDialog> {
  final _form = GlobalKey<FormState>();
  final _rows = <(TextEditingController, TextEditingController)>[];
  final _retired = <TextEditingController>[];
  SubtitleSyncFit? _fit;
  SubtitleCalibrationRecord? _restored;
  String? _error;
  bool _busy = false;
  bool _previewApplied = false;
  bool _accepted = false;
  @override
  void initState() { super.initState(); _add(); _add(); }
  void _add([SubtitleSyncAnchor? anchor]) {
    _rows.add((TextEditingController(text: anchor?.subtitleSeconds.toStringAsFixed(3)),
      TextEditingController(text: anchor?.playbackSeconds.toStringAsFixed(3))));
  }
  void _changed() { _fit = null; _restored = null; _error = null; }
  double? _number(String value) => double.tryParse(value.trim().replaceAll(',', '.'));
  SubtitleCalibrationChoice? _read() {
    if (!widget.isCurrent()) { setState(() => _error = t.videoSettings.subtitleCueUnavailable); return null; }
    final restored = _restored;
    if (restored != null) return (value: restored.value, anchors: restored.anchors);
    if (!(_form.currentState?.validate() ?? false)) return null;
    try {
      final fit = SubtitleSyncCalibration.fitAnchors([
        for (final row in _rows) SubtitleSyncAnchor(_number(row.$1.text)!, _number(row.$2.text)!),
      ]);
      setState(() { _fit = fit; _error = fit.consistent ? null : t.videoSettings.subtitleCalibrationInconsistent; });
      if (!fit.consistent) return null;
      return (value: fit.calibration, anchors: fit.anchors);
    } catch (_) { setState(() => _error = t.videoSettings.subtitleDriftInvalidAnchors); return null; }
  }
  Future<void> _preview() async {
    final choice = _read();
    if (choice == null) return;
    setState(() => _busy = true);
    final succeeded = await widget.preview(choice.value);
    _previewApplied = succeeded;
    if (!mounted) { if (succeeded && !_accepted) await widget.rollback(); return; }
    setState(() { _busy = false; if (!succeeded) _error = t.videoSettings.subtitleDriftPreviewFailed; });
  }
  @override
  void dispose() {
    for (final row in _rows) { row.$1.dispose(); row.$2.dispose(); }
    for (final controller in _retired) { controller.dispose(); }
    super.dispose();
  }
  void _load(SubtitleCalibrationRecord record) {
    for (final row in _rows) { _retired.addAll([row.$1, row.$2]); }
    _rows.clear();
    for (final anchor in record.anchors) { _add(anchor); }
    while (_rows.length < 2) { _add(); }
    setState(() { _restored = record; _fit = null; _error = null; });
  }
  Widget _field(TextEditingController controller, String label) => TextFormField(
    controller: controller, enabled: !_busy, keyboardType: const TextInputType.numberWithOptions(decimal: true),
    textInputAction: TextInputAction.next, decoration: InputDecoration(labelText: label, suffixText: 's'),
    validator: (text) {
      final value = _number(text ?? '');
      return value == null || !value.isFinite || value < 0 || value > 60 * 24 * 60 * 60
        ? t.settings.validationErrorEnterNumber : null;
    }, onChanged: (_) => setState(_changed));
  @override
  Widget build(BuildContext context) => PopScope(canPop: !_busy, child: AlertDialog(
    title: Text(t.videoSettings.subtitleDriftCalibration),
    content: SizedBox(width: 520, child: SingleChildScrollView(child: Form(key: _form,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.videoSettings.subtitleMultiAnchorHelp),
        if (widget.history.isNotEmpty) DropdownButtonFormField<int>(
          isExpanded: true, decoration: InputDecoration(labelText: t.videoSettings.subtitleCalibrationHistory),
          items: [for (var i = 0; i < widget.history.length; i++) DropdownMenuItem(value: i,
            child: Text('${DateTime.fromMillisecondsSinceEpoch(widget.history[i].savedAtMs).toLocal().toString().split('.').first}'
              ' · ${formatPercent(widget.history[i].value.timestampMultiplier)} · ${widget.history[i].value.delayMs} ms',
              maxLines: 1, overflow: TextOverflow.ellipsis))],
          onChanged: _busy ? null : (index) { if (index != null) _load(widget.history[index]); }),
        if (_restored != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('${formatPercent(_restored!.value.timestampMultiplier)} · ${_restored!.value.delayMs} ms')),
        for (var i = 0; i < _rows.length; i++) Padding(padding: const EdgeInsets.only(top: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [Expanded(child: Text(t.videoSettings.subtitleAnchorNumber(number: i + 1))),
              IconButton(tooltip: t.videoSettings.subtitleRemoveAnchor,
                onPressed: _busy || _rows.length <= 2 ? null : () {
                  setState(() { final row = _rows.removeAt(i); _retired.addAll([row.$1, row.$2]); _changed(); });
                }, icon: const Icon(Icons.remove_circle_outline))]),
            _field(_rows[i].$1, t.videoSettings.subtitleSourceTime),
            _field(_rows[i].$2, t.videoSettings.subtitlePlaybackTime),
            Align(alignment: AlignmentDirectional.centerEnd, child: TextButton.icon(
              onPressed: _busy || !widget.isCurrent() ? null : () {
                final position = widget.currentPositionSeconds();
                if (position < 0) return;
                _rows[i].$2.text = position.toStringAsFixed(3);
                setState(_changed);
              }, icon: const Icon(Icons.my_location), label: Text(t.videoSettings.subtitleUsePlaybackTime))),
          ])),
        TextButton.icon(onPressed: _busy || _rows.length >= 12 ? null : () => setState(() { _add(); _changed(); }),
          icon: const Icon(Icons.add), label: Text(t.videoSettings.subtitleAddAnchor)),
        if (_fit != null) ...[
          Text(t.videoSettings.subtitleCalibrationResiduals(
            maximum: formatDecimal(_fit!.maximumResidualSeconds * 1000, maximumDecimals: 1),
            rms: formatDecimal(_fit!.rmsSeconds * 1000, maximumDecimals: 1))),
          Text([for (var i = 0; i < _fit!.residualSeconds.length; i++)
            '${i + 1}: ${formatDecimal(_fit!.residualSeconds[i] * 1000, maximumDecimals: 1)} ms'].join(' · ')),
        ],
        if (_previewApplied) Text(t.videoSettings.subtitleDriftPreviewActive),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ])))),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
      TextButton(onPressed: _busy ? null : _preview, child: Text(t.videoSettings.subtitleDriftPreview)),
      TextButton(onPressed: _busy ? null : () {
        final choice = _read();
        if (choice != null) { _accepted = true; Navigator.of(context).pop(choice); }
      }, child: Text(t.common.save)),
    ],
  ));
}
