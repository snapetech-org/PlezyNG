import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_cloud_sync.dart';
import '../../../services/subtitle_overlay_service.dart';
import '../../../services/subtitle_revision_service.dart';
import '../../../sources/source_controller.dart';
import '../../../sources/sync/sync_document.dart';
import '../../../sources/sync/sync_store.dart';

class _SubtitleCloudSyncDialogError implements Exception {
  const _SubtitleCloudSyncDialogError(this.message);
  final String message;
}

class SubtitleCloudSyncDialog extends StatefulWidget {
  const SubtitleCloudSyncDialog({super.key, required this.identity, required this.isCurrent});
  final SubtitleRevisionIdentity identity;
  final bool Function() isCurrent;
  @override
  State<SubtitleCloudSyncDialog> createState() => _SubtitleCloudSyncDialogState();
}

class _SubtitleCloudSyncDialogState extends State<SubtitleCloudSyncDialog> {
  final _code = TextEditingController();
  bool _busy = true, _loaded = false, _reveal = false;
  String? _error, _status, _paired;
  List<SubtitleRevision> _local = [];
  String? _selected;
  List<SubtitleSyncChoice> _choices = [];
  final Map<String, SubtitleRevision> _previews = {};
  SourceController? _controller;
  int? _sourceGeneration;

  Translations get _t => Translations.of(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _controller = context.read<SourceController>();
    _sourceGeneration = _controller!.generation;
    _action(() async {
      await _controller!.ready; _check();
      _paired = await SubtitleCloudSync.pairedCode(_controller!.repository, widget.identity);
      _code.text = _paired ?? '';
      _local = await SubtitleRevisionService.loadRevisions(widget.identity);
      _selected = _local.firstOrNull?.id;
    });
  }
  @override
  void dispose() { _code.dispose(); super.dispose(); }
  void _check() {
    if (!mounted) throw StateError('Dialog was disposed');
    if (!widget.isCurrent() || _controller?.profileId != widget.identity.profileId) {
      throw _SubtitleCloudSyncDialogError(_t.videoControls.subtitleCloudSync.profileOrMediaChanged);
    }
    _controller!.requireSession(_sourceGeneration);
  }
  Future<void> _action(Future<void> Function() action) async {
    if (mounted) setState(() { _busy = true; _error = null; });
    try { await action(); }
    catch (error) {
      if (mounted) setState(() => _error = error is _SubtitleCloudSyncDialogError ? error.message
          : error is SubtitleCloudSyncException ? error.message
          : error is FormatException ? _t.videoControls.subtitleCloudSync.invalidPairingOrCloudData
          : _t.videoControls.subtitleCloudSync.syncFailed);
    } finally { if (mounted) setState(() => _busy = false); }
  }
  SubtitleCloudSync _service() {
    _check();
    final config = _controller!.syncConfig;
    if (config == null) throw _SubtitleCloudSyncDialogError(_t.videoControls.subtitleCloudSync.configureCloudSource);
    if (_paired == null || _paired != _code.text.trim()) throw _SubtitleCloudSyncDialogError(_t.videoControls.subtitleCloudSync.savePairingFirst);
    final adapter = _controller!.adapter(config.sourceId);
    if (!ProviderSyncStore.supports(adapter.source.kind)) throw _SubtitleCloudSyncDialogError(_t.videoControls.subtitleCloudSync.supportedCloudSource);
    final paired = _paired;
    void current() {
      _check();
      final active = _controller!.syncConfig;
      if (active?.sourceId != config.sourceId || active?.folder != config.folder || _paired != paired) {
        throw _SubtitleCloudSyncDialogError(_t.videoControls.subtitleCloudSync.destinationChanged);
      }
    }
    return SubtitleCloudSync(repository: _controller!.repository, identity: widget.identity,
      store: ProviderSyncStore(adapter, folder: config.folder, check: current), code: _paired!, check: current);
  }
  Future<bool> _confirm(String title, String text, String action) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(title), content: Text(text), actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ]));
    return confirmed == true && mounted && widget.isCurrent();
  }
  Future<void> _savePair() => _action(() async {
    _check(); SyncCipher(_code.text.trim());
    final copy = _t.videoControls.subtitleCloudSync;
    if (!await _confirm(copy.pairTitle, copy.pairDescription, copy.savePairing)) return;
    _check();
    await SubtitleCloudSync.pair(_controller!.repository, widget.identity, _code.text.trim());
    _paired = _code.text.trim(); _choices = []; _previews.clear();
    _status = copy.pairedLocally;
  });
  Future<void> _synchronize({bool publish = false}) => _action(() async {
    final service = _service();
    final revision = _local.where((value) => value.id == _selected).firstOrNull;
    final copy = _t.videoControls.subtitleCloudSync;
    if (publish && revision == null) throw _SubtitleCloudSyncDialogError(copy.chooseReviewedRevision);
    if (publish && !await _confirm(copy.publishTitle, copy.publishDescription, copy.publishAction)) return;
    _check();
    _choices = await service.synchronize(publish: publish ? revision : null);
    _previews.removeWhere((key, _) => !_choices.any((value) => value.digest == key));
    _status = _choices.length > 1 ? copy.concurrentVersions(count: _choices.length)
        : _choices.isEmpty ? copy.noSharedSubtitle : copy.metadataSynchronized;
  });
  Future<void> _preview(SubtitleSyncChoice choice) => _action(() async {
    _previews[choice.digest] = await _service().download(choice);
  });
  Future<void> _import(SubtitleSyncChoice choice) => _action(() async {
    final revision = _previews[choice.digest];
    final copy = _t.videoControls.subtitleCloudSync;
    if (revision == null) throw _SubtitleCloudSyncDialogError(copy.previewAndVerifyFirst);
    if (!await _confirm(copy.importTitle,
      copy.importDescription(cues: revision.cues.length, clock: revision.onItemTimeline ? copy.itemClock : copy.openedFileClock),
      copy.importAction)) return;
    await _service().importRevision(choice, revision);
    _local = await SubtitleRevisionService.loadRevisions(widget.identity);
    _selected = _local.firstOrNull?.id;
    _status = copy.importedStatus;
  });
  Future<void> _resolve(SubtitleSyncChoice choice) => _action(() async {
    final copy = _t.videoControls.subtitleCloudSync;
    if (!_previews.containsKey(choice.digest)) throw _SubtitleCloudSyncDialogError(copy.previewBeforeResolve);
    if (!await _confirm(copy.resolveTitle, copy.resolveDescription, copy.useThisVersion)) return;
    _choices = await _service().resolve(choice, observedChoices: List.of(_choices));
    _status = _choices.length > 1 ? copy.newConflict : copy.sharedChoicePublished;
  });

  @override
  Widget build(BuildContext context) {
    final copy = _t.videoControls.subtitleCloudSync;
    return AlertDialog(title: Text(copy.title),
    content: SizedBox(width: 640, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(copy.description),
        TextField(controller: _code, obscureText: !_reveal, enabled: !_busy, autocorrect: false, enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: copy.codeLabel, suffixIcon: IconButton(
            onPressed: () => setState(() => _reveal = !_reveal), icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility)))),
        Wrap(spacing: 8, children: [
          TextButton(onPressed: _busy ? null : () => setState(() => _code.text = SyncCipher.newCode()), child: Text(copy.newTrackCode)),
          TextButton(onPressed: _busy || _code.text.isEmpty ? null : () async {
            await Clipboard.setData(ClipboardData(text: _code.text.trim()));
            if (mounted) setState(() => _status = copy.codeCopied);
          }, child: Text(copy.copyCode)),
          TextButton(onPressed: _busy ? null : _savePair, child: Text(copy.savePairing)),
          TextButton(onPressed: _busy || _paired == null ? null : () => _action(() async {
            _check(); await SubtitleCloudSync.pair(_controller!.repository, widget.identity, null);
            _paired = null; _code.clear(); _choices = []; _previews.clear();
            _status = copy.disconnectedStatus;
          }), child: Text(copy.disconnectItem)),
        ]),
        if (_local.isNotEmpty) DropdownButton<String>(value: _selected, isExpanded: true,
          items: [for (final revision in _local) DropdownMenuItem(value: revision.id,
            child: Text(copy.revisionSummary(operation: revision.operation, cues: revision.cues.length), overflow: TextOverflow.ellipsis))],
          onChanged: _busy ? null : (value) => setState(() => _selected = value)),
        Wrap(spacing: 8, children: [
          FilledButton(onPressed: _busy ? null : () => _synchronize(), child: Text(copy.pullVersions)),
          OutlinedButton(onPressed: _busy || _selected == null ? null : () => _synchronize(publish: true), child: Text(copy.publishRevision)),
        ]),
        if (_busy) const LinearProgressIndicator(),
        if (_status != null) Text(_status!),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        for (final choice in _choices) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(copy.choiceSummary(device: choice.device, kib: (choice.bytes / 1024).ceil(), digest: choice.digest.substring(0, 12))),
            if (_previews[choice.digest] case final SubtitleRevision revision) ...[
              Text(copy.previewSummary(language: revision.languageCode ?? copy.unknownLanguage,
                cues: revision.cues.length, clock: revision.onItemTimeline ? copy.itemClock : copy.openedFileClock)),
              SizedBox(height: 180, child: ListView.builder(itemCount: revision.cues.length, itemBuilder: (context, index) {
                final cue = revision.cues[index];
                return Text(copy.cuePreview(start: cue.startMs / 1000, end: cue.endMs / 1000,
                  text: SubtitleOverlayTrack.plain(cue.text)));
              })),
            ],
            Wrap(spacing: 8, children: [
              TextButton(onPressed: _busy ? null : () => _preview(choice), child: Text(copy.downloadPreview)),
              TextButton(onPressed: _busy || !_previews.containsKey(choice.digest) ? null : () => _import(choice), child: Text(copy.importToHistory)),
              if (_choices.length > 1) TextButton(onPressed: _busy || !_previews.containsKey(choice.digest) ? null : () => _resolve(choice), child: Text(copy.useThisVersion)),
            ]),
          ]))),
      ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t.common.close))]);
  }
}
