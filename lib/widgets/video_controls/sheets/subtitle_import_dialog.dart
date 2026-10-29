import 'dart:async';

import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_text_codec.dart';
import '../../../services/subtitle_text_importer.dart';

/// Explicit charset/format review. Preview parsing runs on an isolate and never
/// mutates the picked source. Changing an option invalidates the old preview.
class SubtitleImportDialog extends StatefulWidget {
  const SubtitleImportDialog({super.key, required this.bytes, required this.extension, required this.name});
  final List<int> bytes;
  final String extension;
  final String name;
  @override
  State<SubtitleImportDialog> createState() => _SubtitleImportDialogState();
}

class _SubtitleImportDialogState extends State<SubtitleImportDialog> {
  final _fps = TextEditingController();
  final _tail = TextEditingController(text: '2000');
  final _samiClass = TextEditingController();
  final _sccOrigin = TextEditingController(text: '0');
  int _sccChannel = 1;
  bool _sccNtsc = true;
  String _encoding = 'unicode';
  SubtitleTextImport? _result;
  String? _error;
  bool _parsing = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_preview());
    });
  }
  @override
  void dispose() { ++_generation; _fps.dispose(); _tail.dispose(); _samiClass.dispose(); _sccOrigin.dispose(); super.dispose(); }

  void _invalidate() { ++_generation; setState(() { _result = null; _error = null; }); }

  Translations get _t => Translations.of(context);

  Map<String, String> _sccMessages() {
    final c = _t.videoControls;
    return {
      'subtitleImportSccChannelRangeError': c.subtitleImportSccChannelRangeError,
      'subtitleImportSccMissingHeaderError': c.subtitleImportSccMissingHeaderError,
      'subtitleImportSccLineLimitError': c.subtitleImportSccLineLimitError,
      'subtitleImportSccMalformedLine': c.subtitleImportSccMalformedLine(line: '{line}'),
      'subtitleImportSccDropFrameError': c.subtitleImportSccDropFrameError,
      'subtitleImportSccPacketOrderError': c.subtitleImportSccPacketOrderError,
      'subtitleImportSccParityError': c.subtitleImportSccParityError(line: '{line}'),
      'subtitleImportSccTimelineError': c.subtitleImportSccTimelineError,
      'subtitleImportSccNoPacketsError': c.subtitleImportSccNoPacketsError,
      'subtitleImportSccColumnLimitError': c.subtitleImportSccColumnLimitError,
      'subtitleImportSccSnapshotLimitError': c.subtitleImportSccSnapshotLimitError,
      'subtitleImportSccXdsUnsupportedError': c.subtitleImportSccXdsUnsupportedError,
      'subtitleImportSccTextUnsupportedError': c.subtitleImportSccTextUnsupportedError,
      'subtitleImportSccRowAddressError': c.subtitleImportSccRowAddressError,
      'subtitleImportSccSecondCharacterError': c.subtitleImportSccSecondCharacterError,
      'subtitleImportSccControlPairError': c.subtitleImportSccControlPairError,
      'subtitleImportSccDecodedSummary': c.subtitleImportSccDecodedSummary(
        channel: '{channel}', fps: '{fps}', frameType: '{frameType}', clockOrigin: '{clockOrigin}'),
      'subtitleImportSccFlattenedWarning': c.subtitleImportSccFlattenedWarning,
      'subtitleImportSccOpenTailWarning': c.subtitleImportSccOpenTailWarning(duration: '{duration}'),
      'subtitleImportSccDropFrameLabel': c.subtitleImportSccDropFrameLabel,
      'subtitleImportSccNonDropFrameLabel': c.subtitleImportSccNonDropFrameLabel,
    };
  }

  Future<void> _preview() async {
    if (_parsing) return;
    final generation = ++_generation;
    setState(() { _parsing = true; _result = null; _error = null; });
    try {
      final fps = _fps.text.trim().isEmpty ? null : double.tryParse(_fps.text.trim());
      if (_fps.text.trim().isNotEmpty && fps == null) throw FormatException(_t.videoControls.subtitleImportFrameRateRequired);
      final tail = int.tryParse(_tail.text.trim());
      if (tail == null) throw FormatException(_t.videoControls.subtitleImportTailRequired);
      final origin = int.tryParse(_sccOrigin.text.trim());
      if (origin == null) throw FormatException(_t.videoControls.subtitleImportClockOriginRequired);
      final result = await SubtitleTextImporter.parseAsync(widget.bytes, widget.extension,
        encoding: _encoding, framesPerSecond: fps, finalCueDurationMs: tail, samiClass: _samiClass.text,
        sccChannel: _sccChannel, sccNtsc: _sccNtsc, sccClockOriginMs: origin,
        localizedMessages: widget.extension.toLowerCase() == '.scc' ? _sccMessages() : null);
      if (mounted && generation == _generation) setState(() => _result = result);
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error is FormatException ? error.message.toString() : _t.videoControls.subtitleImportDecodeError);
    } finally { if (mounted) setState(() => _parsing = false); }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final result = _result;
    final count = result?.cues.length ?? 0;
    final sample = <int>{0, 1, count ~/ 2, count - 2, count - 1}.where((i) => i >= 0 && i < count).toList()..sort();
    return AlertDialog(title: Text(t.videoControls.subtitleImportTitle),
      content: SizedBox(width: 680, height: (MediaQuery.sizeOf(context).height - 210).clamp(250.0, 650.0).toDouble(),
        child: ListView(children: [
          Text(widget.name),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(initialValue: _encoding, isExpanded: true,
            decoration: InputDecoration(labelText: t.videoControls.subtitleImportSourceEncoding),
            items: SubtitleTextCodec.encodings.entries.map((e) => DropdownMenuItem(value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: _parsing ? null : (value) { _encoding = value ?? _encoding; _invalidate(); }),
          if (widget.extension == '.sub') TextField(controller: _fps,
            keyboardType: const TextInputType.numberWithOptions(decimal: true), maxLength: 16,
            decoration: InputDecoration(labelText: t.videoControls.subtitleImportMicroDvdFps, helperText: t.videoControls.subtitleImportMicroDvdFpsHint),
            onChanged: (_) => _invalidate()),
          if (const {'.smi', '.sami'}.contains(widget.extension)) TextField(controller: _samiClass, maxLength: 128,
            decoration: InputDecoration(labelText: t.videoControls.subtitleImportSamiClass, helperText: t.videoControls.subtitleImportSamiClassHint), onChanged: (_) => _invalidate()),
          if (widget.extension == '.scc') ...[
            DropdownButtonFormField<int>(initialValue: _sccChannel,
              decoration: InputDecoration(labelText: t.videoControls.subtitleImportSccChannel),
              items: [DropdownMenuItem(value: 1, child: Text(t.videoControls.subtitleImportChannel1)), DropdownMenuItem(value: 2, child: Text(t.videoControls.subtitleImportChannel2))],
              onChanged: _parsing ? null : (value) { _sccChannel = value ?? 1; _invalidate(); }),
            DropdownButtonFormField<bool>(initialValue: _sccNtsc,
              decoration: InputDecoration(labelText: t.videoControls.subtitleImportSccFrameClock),
              items: [DropdownMenuItem(value: true, child: Text(t.videoControls.subtitleImportNtscRate)),
                DropdownMenuItem(value: false, child: Text(t.videoControls.subtitleImport30Rate))],
              onChanged: _parsing ? null : (value) { _sccNtsc = value ?? true; _invalidate(); }),
            TextField(controller: _sccOrigin, maxLength: 8, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: t.videoControls.subtitleImportSccClockOrigin,
                helperText: t.videoControls.subtitleImportSccClockOriginHint),
              onChanged: (_) => _invalidate()),
          ],
          if (const {'.smi', '.sami', '.lrc', '.scc'}.contains(widget.extension)) TextField(controller: _tail, maxLength: 5,
            keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t.videoControls.subtitleImportFinalCueDuration),
            onChanged: (_) => _invalidate()),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _parsing ? null : _preview, child: Text(t.videoControls.subtitleImportRefreshPreview)),
          if (_parsing) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (result != null) ...[
            Text(t.videoControls.subtitleImportCueSummary(count: count)),
            for (final warning in result.warnings) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(warning)),
            for (final index in sample) ListTile(dense: true,
              title: SelectableText(widget.extension.toLowerCase() == '.scc'
                  ? SubtitleTextImporter.decodeHtmlEntities(result.cues[index].text)
                  : result.cues[index].text),
              subtitle: Text('${Duration(milliseconds: result.cues[index].startMs)} → ${Duration(milliseconds: result.cues[index].endMs)}')),
          ],
        ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: result == null || _parsing ? null : () => Navigator.pop(context, result), child: Text(t.videoControls.subtitleImportUseDecoding))]);
  }
}
