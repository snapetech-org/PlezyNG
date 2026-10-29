import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/subtitle_cloud_sync.dart';
import '../../../services/subtitle_overlay_service.dart';
import '../../../services/subtitle_revision_service.dart';
import '../../../sources/source_controller.dart';
import '../../../sources/sync/sync_document.dart';
import '../../../sources/sync/sync_store.dart';

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
    if (!mounted || !widget.isCurrent() || _controller?.profileId != widget.identity.profileId) {
      throw StateError('The subtitle profile or media item changed');
    }
    _controller!.requireSession(_sourceGeneration);
  }
  Future<void> _action(Future<void> Function() action) async {
    if (mounted) setState(() { _busy = true; _error = null; });
    try { await action(); }
    catch (error) {
      if (mounted) setState(() => _error = error is FormatException ? error.message
          : error is StateError ? error.message : 'Subtitle sync failed. Check the paired code, cloud source, folder and network.');
    } finally { if (mounted) setState(() => _busy = false); }
  }
  SubtitleCloudSync _service() {
    _check();
    final config = _controller!.syncConfig;
    if (config == null) throw StateError('Configure a cloud sync source and folder in Sources → Sync first');
    if (_paired == null || _paired != _code.text.trim()) throw StateError('Save this item’s pairing code first');
    final adapter = _controller!.adapter(config.sourceId);
    if (!ProviderSyncStore.supports(adapter.source.kind)) throw StateError('Choose a supported cloud sync source');
    final paired = _paired;
    void current() {
      _check();
      final active = _controller!.syncConfig;
      if (active?.sourceId != config.sourceId || active?.folder != config.folder || _paired != paired) {
        throw StateError('The subtitle sync destination changed');
      }
    }
    return SubtitleCloudSync(repository: _controller!.repository, identity: widget.identity,
      store: ProviderSyncStore(adapter, folder: config.folder, check: current), code: _paired!, check: current);
  }
  Future<bool> _confirm(String title, String text, String action) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(title), content: Text(text), actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ]));
    return confirmed == true && mounted && widget.isCurrent();
  }
  Future<void> _savePair() => _action(() async {
    _check(); SyncCipher(_code.text.trim());
    if (!await _confirm('Pair this subtitle track?',
      'Use a new code for each subtitle track. Enter the same code on your other device while opening the same edition, part and audio. '
      'The app cannot prove that two devices opened the same cut. Anyone with the code and access to the cloud folder can read and change the shared track.',
      'Save pairing')) return;
    _check();
    await SubtitleCloudSync.pair(_controller!.repository, widget.identity, _code.text.trim());
    _paired = _code.text.trim(); _choices = []; _previews.clear();
    _status = 'Paired locally. No subtitle has been uploaded or selected.';
  });
  Future<void> _synchronize({bool publish = false}) => _action(() async {
    final service = _service();
    final revision = _local.where((value) => value.id == _selected).firstOrNull;
    if (publish && revision == null) throw StateError('Choose a reviewed local revision first');
    if (publish && !await _confirm('Publish the selected revision?',
      'Encrypted subtitle text and timings will be written to your configured cloud folder. '
      'Media and account credentials are excluded. Concurrent edits stay visible as conflicts. '
      'Immutable content chunks remain in that folder for recovery even after a newer revision is chosen.', 'Publish')) return;
    _check();
    _choices = await service.synchronize(publish: publish ? revision : null);
    _previews.removeWhere((key, _) => !_choices.any((value) => value.digest == key));
    _status = _choices.length > 1 ? '${_choices.length} concurrent versions. Preview them and explicitly choose a shared winner, or retain the conflict.'
        : _choices.isEmpty ? 'No shared subtitle is published yet.' : 'Shared metadata synchronized. Playback and local revisions are unchanged.';
  });
  Future<void> _preview(SubtitleSyncChoice choice) => _action(() async {
    _previews[choice.digest] = await _service().download(choice);
  });
  Future<void> _import(SubtitleSyncChoice choice) => _action(() async {
    final revision = _previews[choice.digest];
    if (revision == null) throw StateError('Preview and verify this revision first');
    if (!await _confirm('Import this revision?',
      '${revision.cues.length} cues; ${revision.onItemTimeline ? 'item' : 'opened-file'} clock. '
      'Confirm the edition, part, selected audio and clock match this item. This adds a local history revision without changing playback. '
      'Normal history retention still applies. Concurrent shared versions remain unresolved.', 'Import to history')) return;
    await _service().importRevision(choice, revision);
    _local = await SubtitleRevisionService.loadRevisions(widget.identity);
    _selected = _local.firstOrNull?.id;
    _status = 'Imported. Open subtitle history to review or attach it.';
  });
  Future<void> _resolve(SubtitleSyncChoice choice) => _action(() async {
    if (!_previews.containsKey(choice.digest)) throw StateError('Preview this version before choosing it');
    if (!await _confirm('Use this shared version?',
      'This resolves the concurrent versions currently shown in favor of this content. '
      'Local revision histories are retained. An unseen edit from an offline device can create a new conflict later.', 'Use this version')) return;
    _choices = await _service().resolve(choice, observedChoices: List.of(_choices));
    _status = _choices.length > 1 ? 'A new concurrent edit arrived. Review the remaining choices.' : 'The shared choice was published. Playback is unchanged.';
  });

  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Sync reviewed subtitles across devices'),
    content: SizedBox(width: 640, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Uses your configured Sources cloud-sync account and folder, with a separate encrypted namespace for this track. '
          'The pairing code is its encryption key. Keep it private and keep a recovery copy. Sync is explicit; nothing is attached automatically.'),
        TextField(controller: _code, obscureText: !_reveal, enabled: !_busy, autocorrect: false, enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: 'Subtitle pairing code', suffixIcon: IconButton(
            onPressed: () => setState(() => _reveal = !_reveal), icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility)))),
        Wrap(spacing: 8, children: [
          TextButton(onPressed: _busy ? null : () => setState(() => _code.text = SyncCipher.newCode()), child: const Text('New track code')),
          TextButton(onPressed: _busy || _code.text.isEmpty ? null : () async {
            await Clipboard.setData(ClipboardData(text: _code.text.trim()));
            if (mounted) setState(() => _status = 'Pairing code copied. The clipboard may be available to other apps.');
          }, child: const Text('Copy code')),
          TextButton(onPressed: _busy ? null : _savePair, child: const Text('Save pairing')),
          TextButton(onPressed: _busy || _paired == null ? null : () => _action(() async {
            _check(); await SubtitleCloudSync.pair(_controller!.repository, widget.identity, null);
            _paired = null; _code.clear(); _choices = []; _previews.clear();
            _status = 'Item disconnected. Cloud content and local history were retained.';
          }), child: const Text('Disconnect item')),
        ]),
        if (_local.isNotEmpty) DropdownButton<String>(value: _selected, isExpanded: true,
          items: [for (final revision in _local) DropdownMenuItem(value: revision.id,
            child: Text('${revision.operation} · ${revision.cues.length} cues', overflow: TextOverflow.ellipsis))],
          onChanged: _busy ? null : (value) => setState(() => _selected = value)),
        Wrap(spacing: 8, children: [
          FilledButton(onPressed: _busy ? null : () => _synchronize(), child: const Text('Pull shared versions')),
          OutlinedButton(onPressed: _busy || _selected == null ? null : () => _synchronize(publish: true), child: const Text('Publish selected revision')),
        ]),
        if (_busy) const LinearProgressIndicator(),
        if (_status != null) Text(_status!),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        for (final choice in _choices) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Device ${choice.device} · ${(choice.bytes / 1024).ceil()} KiB · ${choice.digest.substring(0, 12)}'),
            if (_previews[choice.digest] case final SubtitleRevision revision) ...[
              Text('${revision.languageCode ?? 'Unknown language'} · ${revision.cues.length} cues · '
                '${revision.onItemTimeline ? 'Item' : 'Opened-file'} clock'),
              SizedBox(height: 180, child: ListView.builder(itemCount: revision.cues.length, itemBuilder: (context, index) {
                final cue = revision.cues[index];
                return Text('${cue.startMs / 1000}–${cue.endMs / 1000}s  ${SubtitleOverlayTrack.plain(cue.text)}');
              })),
            ],
            Wrap(spacing: 8, children: [
              TextButton(onPressed: _busy ? null : () => _preview(choice), child: const Text('Download and preview')),
              TextButton(onPressed: _busy || !_previews.containsKey(choice.digest) ? null : () => _import(choice), child: const Text('Import to history')),
              if (_choices.length > 1) TextButton(onPressed: _busy || !_previews.containsKey(choice.digest) ? null : () => _resolve(choice), child: const Text('Use this shared version')),
            ]),
          ]))),
      ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]);
}
