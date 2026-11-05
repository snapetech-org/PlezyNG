import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../i18n/strings.g.dart';
import '../../services/dv_offline_tools.dart';
import '../../services/settings_service.dart';
import '../../widgets/focused_scroll_scaffold.dart';

class DvOfflineExportScreen extends StatefulWidget {
  const DvOfflineExportScreen({super.key});

  @override
  State<DvOfflineExportScreen> createState() => _DvOfflineExportScreenState();
}

class _DvOfflineExportScreenState extends State<DvOfflineExportScreen> {
  final _fps = TextEditingController(text: '24000/1001');
  String? _base;
  String? _enhancement;
  String _target = 'hdr10';
  String? _status;
  Process? _process;
  bool _busy = false;
  bool _cancelled = false;

  @override
  void dispose() {
    _process?.kill(ProcessSignal.sigint);
    _fps.dispose();
    super.dispose();
  }

  Future<void> _choose({required bool enhancement}) async {
    final selection = await FilePicker.pickFiles(type: FileType.any, allowMultiple: false);
    if (!mounted || selection == null || selection.files.isEmpty) return;
    final path = selection.files.single.path;
    setState(() {
      if (path == null) {
        _status = t.universalMedia.converterLocalOnly;
      } else if (enhancement) {
        _enhancement = path;
      } else {
        _base = path;
      }
    });
  }

  Future<void> _export() async {
    if (_busy || _base == null || _enhancement == null) return;
    if (!SettingsService.instance.read(SettingsService.experimentalDolbyVision)) return;
    final fps = _fps.text.trim();
    if (!DvOfflineTools.validFrameRate(fps) || p.equals(_base!, _enhancement!)) {
      setState(() => _status = t.settings.dvOfflineInvalid);
      return;
    }
    final output = await FilePicker.saveFile(
      dialogTitle: t.universalMedia.converterSaveAs,
      fileName: '${p.basenameWithoutExtension(_base!)}-$_target.mkv',
      type: FileType.custom,
      allowedExtensions: const ['mkv'],
    );
    if (!mounted || output == null) return;
    if (p.extension(output) != '.mkv' || await File(output).exists() || await File('$output.json').exists()) {
      if (mounted) setState(() => _status = t.settings.dvOfflineNewOutput);
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _status = t.universalMedia.converterProgress;
    });
    try {
      final process = await Process.start(
        DvOfflineTools.executable,
        DvOfflineTools.arguments(base: _base!, enhancement: _enhancement!, fps: fps, target: _target, output: output),
        runInShell: false,
      );
      _process = process;
      final streams = Future.wait([process.stdout.drain<void>(), process.stderr.drain<void>()]);
      if (!mounted || _cancelled) process.kill(ProcessSignal.sigint);
      final exit = await process.exitCode;
      await streams;
      if (mounted) {
        setState(
          () => _status = _cancelled
              ? t.universalMedia.converterCancelled
              : exit == 0
              ? t.universalMedia.converterComplete
              : t.universalMedia.converterFailed,
        );
      }
    } on Object {
      if (mounted) setState(() => _status = t.universalMedia.converterFailed);
    } finally {
      _process = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: FocusedScrollScaffold(
      title: Text(t.settings.dvOfflineTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(24),
          sliver: SliverList.list(
            children: [
              Text(t.settings.dvOfflineDescription),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: _busy ? null : () => _choose(enhancement: false),
                child: Text(_base == null ? t.settings.dvOfflineBase : p.basename(_base!)),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : () => _choose(enhancement: true),
                child: Text(_enhancement == null ? t.settings.dvOfflineEnhancement : p.basename(_enhancement!)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _fps,
                enabled: !_busy,
                decoration: InputDecoration(labelText: t.settings.dvOfflineFrameRate),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _target,
                decoration: InputDecoration(labelText: t.universalMedia.converterFormat),
                items: [
                  DropdownMenuItem(value: 'hdr10', child: Text(t.settings.dvOfflineHdr10)),
                  DropdownMenuItem(value: 'sdr', child: Text(t.settings.dvOfflineSdr)),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) setState(() => _target = value);
                      },
              ),
              const SizedBox(height: 16),
              if (_busy) const LinearProgressIndicator(),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Semantics(liveRegion: true, child: Text(_status!)),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy || _base == null || _enhancement == null ? null : _export,
                child: Text(t.universalMedia.converterStart),
              ),
              if (_busy)
                TextButton(
                  onPressed: () {
                    _cancelled = true;
                    _process?.kill(ProcessSignal.sigint);
                  },
                  child: Text(t.common.cancel),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
