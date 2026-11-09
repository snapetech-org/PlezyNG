import 'dart:async';

import '../sources/source_controller.dart';
import '../sources/source_models.dart';
import '../sources/source_playback.dart';
import 'workspace_controller.dart';
import 'workspace_models.dart';

/// Observes the existing profile's source player, including background audio.
/// Disposing the player screen must not erase a still-running audio session.
class SourceRecoveryBinder {
  SourceRecoveryBinder({required this.workspace, required this.playback, required this.profileId}) {
    playback.addListener(_schedule);
    sources.addListener(_schedule);
    _schedule();
  }

  final MultiviewWorkspaceController workspace;
  final SourcePlayback playback;
  final String? profileId;
  SourceController get sources => playback.sources;
  String? _entryKey;
  String? _identity;
  int _revision = 0;
  bool _scheduled = false;
  bool _disposed = false;

  bool get _eligible =>
      !_disposed &&
      workspace.active &&
      profileId != null &&
      sources.profileId == profileId &&
      !sources.blocked &&
      playback.active &&
      !playback.isTransientInput &&
      !playback.isSamplePreview &&
      !playback.isLiveInput;

  void _schedule() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_disposed) unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    final item = playback.entry;
    if (!_eligible || item == null) {
      _revision++;
      _entryKey = null;
      _identity = null;
      workspace.unwatchRecovery(this);
      return;
    }
    if (_entryKey == item.key) return;
    final revision = ++_revision;
    _entryKey = item.key;
    _identity = null;
    workspace.unwatchRecovery(this);
    try {
      final identity = await sources.repository.recoveryIdentity(profileId!, item);
      if (!_eligible || revision != _revision || playback.entry?.key != item.key) return;
      if (identity == null) {
        _entryKey = null;
        return;
      }
      _identity = identity;
      workspace.watchRecovery(this, _snapshot);
    } catch (_) {
      if (revision == _revision) _entryKey = null;
    }
  }

  WorkspaceSessionDescriptor? _snapshot() {
    final item = playback.entry;
    final progress = playback.progress;
    final identity = _identity;
    if (!_eligible || item == null || item.key != _entryKey || identity == null || progress == null) return null;
    // Preserve the selected edition/order, not an arbitrary newly discovered
    // file list. These are bounded digests, never file names or locations.
    if (playback.files.isEmpty || playback.files.length > 256) return null;
    final fingerprints = playback.files.map((file) => file.fingerprint).toList(growable: false);
    return WorkspaceSessionDescriptor(
      id: 'source:' + sourceDigest(progress.key + ':' + playback.mode.name),
      kind: playback.video ? MultiviewMediaKind.video
          : item.kind == SourceItemKind.music ? MultiviewMediaKind.music : MultiviewMediaKind.audiobook,
      title: item.title.isEmpty ? playback.files.first.name : item.title,
      hasAudio: true,
      hasVideo: playback.video,
      openedAt: DateTime.now(),
      resume: WorkspaceResumeTarget(
        kind: WorkspaceResumeKind.source,
        providerId: item.sourceId,
        itemId: identity,
        fileIds: fingerprints,
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    playback.removeListener(_schedule);
    sources.removeListener(_schedule);
    workspace.unwatchRecovery(this);
  }
}
