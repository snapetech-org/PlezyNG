import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/library_sync_correction.dart';
import '../../../services/player_sync_offsets.dart';
import '../../../services/subtitle_artifact_export.dart';
import '../../../services/subtitle_timing_transfer.dart';

class SubtitleTimingTransferDialog extends StatefulWidget {
  const SubtitleTimingTransferDialog({super.key, required this.binding, required this.currentValue,
    required this.isCurrent});
  final LibrarySyncBinding binding;
  final LibrarySyncValue currentValue;
  final bool Function() isCurrent;
  @override
  State<SubtitleTimingTransferDialog> createState() => _SubtitleTimingTransferDialogState();
}

class _SubtitleTimingTransferDialogState extends State<SubtitleTimingTransferDialog> {
  bool _busy = false, _saved = false;
  String? _message;
  SubtitleTimingTransfer? _incoming;
  LibrarySyncValue? _expected;
  Translations$videoSettings$en get _copy => Translations.of(context).videoSettings;

  void _check() {
    if (!mounted || !widget.isCurrent()) throw StateError('Subtitle timing context changed.');
    widget.binding.checkCurrent();
  }
  Future<void> _run(Future<void> Function() action) async {
    setState(() { _busy = true; _message = null; });
    try { _check(); await action(); }
    catch (_) { if (mounted) _message = _copy.subtitleTimingTransferFailed; }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _export() => _run(() async {
    final bytes = SubtitleTimingTransfer(bindingKey: widget.binding.key, property: widget.binding.property,
      value: widget.currentValue).encode();
    final path = await SubtitleArtifactExport.saveFile(dialogTitle: _copy.subtitleTimingExport,
      fileName: 'PlezyNG_native_subtitle_correction.json', bytes: bytes,
      type: FileType.custom, allowedExtensions: const ['json']);
    _check(); if (path != null) _message = _copy.subtitleTimingExported;
  });

  Future<void> _pick() => _run(() async {
    final result = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: const ['json']);
    _check(); if (result == null || result.files.length != 1) return;
    final selected = result.files.single;
    if (selected.size <= 0 || selected.size > SubtitleTimingTransfer.maximumBytes) {
      throw const FormatException('Timing document exceeds 4 KiB.');
    }
    Uint8List bytes;
    if (selected.bytes != null) { bytes = selected.bytes!; }
    else {
      final path = selected.path;
      if (path == null || await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file) {
        throw const FormatException('Timing document is not a regular file.');
      }
      final input = await File(path).open();
      try { bytes = await input.read(SubtitleTimingTransfer.maximumBytes + 1); }
      finally { await input.close(); }
    }
    _check();
    final incoming = SubtitleTimingTransfer.decode(bytes)..requireBinding(widget.binding);
    _expected = LibrarySyncCorrections.read(widget.binding.profileId, widget.binding.key);
    _incoming = incoming; _saved = false;
  });

  Future<void> _save() => _run(() async {
    final incoming = _incoming!;
    await incoming.save(widget.binding, expected: _expected); _check();
    _saved = true; _message = _copy.subtitleTimingSavedForNextOpen;
  });

  Future<void> _undo() => _run(() async {
    final incoming = _incoming!;
    await LibrarySyncCorrections.write(widget.binding.profileId, widget.binding.key, _expected,
      compareExisting: true, expectedValue: incoming.value, checkCurrent: _check);
    _check(); _saved = false; _message = _copy.subtitleTimingImportUndone;
  });

  String _value(LibrarySyncValue value) => _copy.subtitleTimingValue(
    delay: value.delayMs, rate: value.rate.toStringAsFixed(6));

  @override
  Widget build(BuildContext context) {
    final copy = _copy, common = Translations.of(context).common;
    return PopScope(canPop: !_busy, child: AlertDialog(title: Text(copy.subtitleTimingTransfer),
      content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(copy.subtitleTimingTransferHelp), const SizedBox(height: 12),
        Text(copy.subtitleTimingCurrent(value: _value(widget.currentValue))),
        if (_incoming != null) ...[
          Text(copy.subtitleTimingPrevious(value: _expected == null ? copy.subtitleTimingNoSaved : _value(_expected!))),
          Text(copy.subtitleTimingIncoming(value: _value(_incoming!.value))),
        ],
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!)),
        if (_busy) const LinearProgressIndicator(),
      ]))), actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(common.close)),
        TextButton(onPressed: _busy ? null : _export, child: Text(copy.subtitleTimingExport)),
        TextButton(onPressed: _busy ? null : _pick, child: Text(copy.subtitleTimingImport)),
        if (_incoming != null && !_saved) FilledButton(onPressed: _busy ? null : _save,
          child: Text(copy.subtitleTimingSave)),
        if (_saved) FilledButton(onPressed: _busy ? null : _undo, child: Text(copy.subtitleTimingUndo)),
      ]));
  }
}
