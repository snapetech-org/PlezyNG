import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_ai_service.dart';
import '../../../services/subtitle_artifact_export.dart';
import '../../../services/subtitle_backend_probe.dart';
import '../../../services/subtitle_placement_evidence.dart';

class SubtitleBackendProbeDialog extends StatefulWidget {
  const SubtitleBackendProbeDialog({super.key, required this.wavPath, required this.provider,
    required this.isCurrent, this.languageCode});
  final String wavPath;
  final SubtitleInferenceProvider provider;
  final bool Function() isCurrent;
  final String? languageCode;
  @override
  State<SubtitleBackendProbeDialog> createState() => _SubtitleBackendProbeDialogState();
}

class _SubtitleBackendProbeDialogState extends State<SubtitleBackendProbeDialog> {
  final _reference = TextEditingController();
  var _generation = 0, _busy = false, _cancelled = false;
  String? _message;
  SubtitleBackendProbeReport? _report;

  Future<void> _run() async {
    final generation = ++_generation;
    setState(() { _busy = true; _cancelled = false; _message = null; _report = null; });
    try {
      final report = await SubtitleBackendProbe.run(wavPath: widget.wavPath, provider: widget.provider,
        languageCode: widget.languageCode, expectedText: _reference.text,
        isCurrent: () => mounted && _generation == generation && widget.isCurrent());
      if (mounted && generation == _generation && widget.isCurrent()) setState(() => _report = report);
    } catch (error) {
      if (mounted && !_cancelled) {
        final copy = Translations.of(context).videoSettings;
        setState(() => _message = error is StateError &&
            error.message == 'Install the selected speech model in the foreground first.'
                ? copy.subtitleBackgroundModelRequired
                : error is FormatException ? copy.subtitleBackendCheckSampleLimit : copy.subtitleBackendCheckFailed);
      }
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _export() async {
    final report = _report;
    if (report == null || _busy) return;
    setState(() => _busy = true);
    try {
      await SubtitleArtifactExport.saveFile(dialogTitle: Translations.of(context).videoSettings.subtitleBackendCheckExport,
        fileName: 'PlezyNG.subtitle-backend-report.json', bytes: report.encode(), allowedExtensions: const ['json']);
    } on Object {
      if (mounted) setState(() => _message = Translations.of(context).videoSettings.subtitleBackendCheckFailed);
    } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  void dispose() { ++_generation; _reference.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context), copy = t.videoSettings, report = _report;
    return PopScope(canPop: !_busy || _cancelled, child: AlertDialog(
      title: Text(copy.subtitleBackendCheckTitle),
      content: SizedBox(width: 640, child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(copy.subtitleBackendCheckHelp),
          const SizedBox(height: 12),
          Text(widget.provider.displayName),
          TextField(controller: _reference, enabled: !_busy, maxLength: 2000, maxLines: 3,
            onChanged: (_) { if (_report != null) setState(() => _report = null); },
            decoration: InputDecoration(labelText: copy.subtitleBackendCheckExpected)),
          if (_busy && !_cancelled) ...[const LinearProgressIndicator(), Text(copy.subtitleBackendCheckRunning)],
          if (_cancelled) Text(copy.subtitleBackendCheckCancelled),
          if (_message != null) Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (report != null) ...[
            Text(copy.subtitleBackendCheckRuntime(requested: report.result.requestedProvider.displayName,
              runtime: report.result.runtimeProvider, fallback: report.result.fellBackToCpu ? t.common.yes : t.common.no)),
            Text(copy.subtitleBackendCheckPlacement(evidence: report.result.placementEvidence.displayLabel)),
            Text(copy.subtitleBackendCheckElapsed(seconds: (report.elapsedMs / 1000).toStringAsFixed(2),
              ratio: report.elapsedToAudioRatio.toStringAsFixed(2))),
            const SizedBox(height: 8),
            SelectableText(report.returnedSpeech ? report.transcript : copy.subtitleBackendCheckNoSpeech),
            const SizedBox(height: 8),
            Text(switch (report.textAgrees) {
              true => copy.subtitleBackendCheckAgrees, false => copy.subtitleBackendCheckDiffers,
              null => copy.subtitleBackendCheckUnknown,
            }),
          ],
        ]))),
      actions: [
        if (_busy && !_cancelled && _report == null) TextButton(onPressed: () => setState(() {
          ++_generation; _cancelled = true;
        }), child: Text(t.common.cancel)),
        if (!_busy || _cancelled) TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.close)),
        if (report != null) TextButton(onPressed: _busy ? null : _export, child: Text(copy.subtitleBackendCheckExport)),
        FilledButton(onPressed: _busy ? null : _run, child: Text(copy.subtitleBackendCheckRun)),
      ],
    ));
  }
}
