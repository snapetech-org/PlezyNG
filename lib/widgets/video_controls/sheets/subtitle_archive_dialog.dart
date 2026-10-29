import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_external_archive.dart';
import '../../../services/subtitle_revision_service.dart';

Future<void> showSubtitleArchiveDialog(BuildContext context, {
  required SubtitleRevisionIdentity identity, required bool Function() isCurrent,
}) => showDialog<void>(context: context, builder: (_) => _ArchiveDialog(identity, isCurrent));

class _ArchiveDialog extends StatefulWidget {
  const _ArchiveDialog(this.identity, this.isCurrent);
  final SubtitleRevisionIdentity identity;
  final bool Function() isCurrent;
  @override
  State<_ArchiveDialog> createState() => _ArchiveDialogState();
}

class _ArchiveDialogState extends State<_ArchiveDialog> {
  String? _root, _status;
  List<SubtitleArchiveSnapshot> _snapshots = const [];
  bool _busy = false;
  bool get _current => mounted && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    _perform(() async {
      _root = await SubtitleExternalArchive.selectedRoot(widget.identity.profileId);
      await _refresh();
    });
  }

  Future<void> _refresh() async {
    final root = _root;
    final snapshots = root == null ? const <SubtitleArchiveSnapshot>[] :
        await SubtitleExternalArchive.list(root, widget.identity, isCurrent: () => _current);
    if (_current) setState(() => _snapshots = snapshots);
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    if (mounted) setState(() { _busy = true; _status = null; });
    try {
      if (!_current) throw const SubtitleArchiveException(SubtitleArchiveFailure.stale);
      await action();
    } catch (error) {
      if (mounted) {
        final copy = t.videoControls.subtitleArchive;
        final message = switch (error) {
          SubtitleArchiveException(failure: SubtitleArchiveFailure.changed) => copy.changed,
          SubtitleArchiveException(failure: SubtitleArchiveFailure.limit) => copy.limit,
          SubtitleArchiveException(failure: SubtitleArchiveFailure.empty) => copy.emptyHistory,
          SubtitleArchiveException(failure: SubtitleArchiveFailure.stale) => copy.stale,
          SubtitleArchiveException(failure: SubtitleArchiveFailure.invalid) => copy.invalid,
          _ => copy.unavailable,
        };
        setState(() => _status = message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseRoot() => _perform(() async {
    final selected = await FilePickerService.instance.getDirectoryPath(
      dialogTitle: t.videoControls.subtitleArchive.chooseFolder);
    if (selected == null) return;
    await SubtitleExternalArchive.selectRoot(widget.identity.profileId, selected, isCurrent: () => _current);
    _root = await SubtitleExternalArchive.selectedRoot(widget.identity.profileId);
    _snapshots = const [];
    await _refresh();
  });

  Future<void> _save() => _perform(() async {
    final root = _root;
    if (root == null) return;
    await SubtitleExternalArchive.save(root, widget.identity, isCurrent: () => _current);
    await _refresh();
    if (_current) setState(() => _status = t.videoControls.subtitleArchive.saved);
  });

  Future<void> _review(SubtitleArchiveSnapshot snapshot) => _perform(() async {
    final root = _root;
    if (root == null) return;
    final revisions = await SubtitleExternalArchive.read(root, widget.identity, snapshot, isCurrent: () => _current);
    if (!_current) return;
    final copy = t.videoControls.subtitleArchive;
    var confirmedCopy = false;
    final selected = await showDialog<SubtitleRevision>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setReviewState) => AlertDialog(
      title: Text(copy.reviewTitle),
      content: SizedBox(width: 600, height: (MediaQuery.sizeOf(dialogContext).height * .6).clamp(180.0, 480.0).toDouble(),
        child: ListView(children: [
          Text(copy.importDescription),
          CheckboxListTile(value: confirmedCopy, title: Text(copy.confirmCopy),
            onChanged: (value) => setReviewState(() => confirmedCopy = value == true)),
          const SizedBox(height: 12),
          for (final revision in revisions) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(revision.operation, style: Theme.of(dialogContext).textTheme.titleSmall),
              Text(copy.revisionSummary(count: revision.cues.length,
                language: revision.languageCode ?? copy.unknownLanguage,
                clock: revision.onItemTimeline ? copy.itemClock : copy.fileClock)),
              for (final cue in revision.cues.take(3)) Padding(padding: const EdgeInsets.only(top: 8),
                child: Text(cue.text, maxLines: 3, overflow: TextOverflow.ellipsis)),
              TextButton(onPressed: !confirmedCopy || !_current ? null : () => Navigator.of(dialogContext).pop(revision),
                child: Text(copy.importRevision)),
            ]))),
        ])),
      actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(t.common.cancel))],
    )));
    if (selected == null || !_current) return;
    // Retire stale operations before local-history publication. Saved bytes
    // always belong to the original profile/item, including after a late close.
    // Saved revisions retain their original file-vs-item clock; no offset is
    // baked into these archival copies and no playback track is attached here.
    await SubtitleRevisionService.saveRevision(identity: widget.identity,
      operation: selected.operation, languageCode: selected.languageCode,
      cues: selected.cues, wordTimings: selected.wordTimings,
      onItemTimeline: selected.onItemTimeline, isCurrent: () => _current);
    if (_current) setState(() => _status = copy.imported);
  });

  @override
  Widget build(BuildContext context) {
    final copy = t.videoControls.subtitleArchive;
    return AlertDialog(title: Text(copy.title),
      content: SizedBox(width: 620, height: (MediaQuery.sizeOf(context).height * .65).clamp(180.0, 520.0).toDouble(),
        child: ListView(children: [
          Text(copy.description),
          const SizedBox(height: 12),
          SelectableText(_root ?? copy.noFolder),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: _busy ? null : _chooseRoot, child: Text(copy.chooseFolder)),
            if (_root != null) TextButton(onPressed: _busy ? null : () => _perform(() async {
              await SubtitleExternalArchive.selectRoot(widget.identity.profileId, null, isCurrent: () => _current);
              if (_current) setState(() { _root = null; _snapshots = const []; });
            }), child: Text(copy.forgetFolder)),
          ]),
          if (_busy) const LinearProgressIndicator(),
          if (_status != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
            child: Semantics(liveRegion: true, child: Text(_status!))),
          if (_root != null) ...[
            FilledButton(onPressed: _busy ? null : _save, child: Text(copy.saveHistory)),
            const SizedBox(height: 12),
            Text(copy.snapshotsTitle, style: Theme.of(context).textTheme.titleSmall),
            if (!_busy && _snapshots.isEmpty) Text(copy.noSnapshots),
            for (final snapshot in _snapshots) ListTile(
              title: Text(snapshot.title.isEmpty ? copy.untitled : snapshot.title),
              subtitle: Text(copy.snapshotSummary(date: snapshot.createdAt.toLocal().toString(),
                count: snapshot.revisionCount, size: (snapshot.bytes / 1048576).toStringAsFixed(2))),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : () => _review(snapshot),
            ),
          ],
        ])),
      actions: [TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(t.common.close))],
    );
  }
}
