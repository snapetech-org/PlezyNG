part of '../../video_player_screen.dart';

extension _VideoPlayerSubtitleSources on VideoPlayerScreenState {
  Future<SubtitleAnalysisSource> _openSubtitleAnalysisSource() async {
    final core = player, item = _currentMetadata, session = _playbackSession;
    if (core == null || widget.isLive || _shuttingDown) throw StateError('Open a seekable library item first.');
    final profiles = context.read<ActiveProfileProvider>(), profile = context.read<ActiveProfileProvider>().activeId;
    final mediaGeneration = core is PlayerMediaSessionIdentity ? core.mediaSessionGeneration : null;
    final mediaIndex = _effectiveSelectedMediaIndex, mediaSourceId = session?.mediaSourceId;
    bool current() => mounted && !_shuttingDown && identical(player, core) && !core.disposed &&
        _currentMetadata.globalKey == item.globalKey && identical(_playbackSession, session) &&
        profiles.activeId == profile && (mediaGeneration == null ||
          (core as PlayerMediaSessionIdentity).mediaSessionGeneration == mediaGeneration);
    if (_isOfflinePlayback) return SubtitleAnalysisSource.localPlayer(core, current);
    final client = _getOnlineMediaServerClient(context);
    if (client == null) return SubtitleAnalysisSource.localPlayer(core, current);
    final position = core.currentPosition;
    final gateway = SourceStreamGateway(valid: current);
    try {
      final target = await client.resolveExternalPlayback(item, mediaIndex: mediaIndex,
          mediaSourceId: mediaSourceId, position: position);
      if (!current() || target == null) throw StateError('Analysis source is no longer available.');
      final part = target.partTimeline?.current;
      final offset = part?.start.inMilliseconds ?? 0;
      final uri = await gateway.registerUri(Uri.parse(target.url), renew: () async {
        if (!current()) throw StateError('The analysis source expired.');
        final refreshed = await client.resolveExternalPlayback(item, mediaIndex: mediaIndex,
            mediaSourceId: mediaSourceId, position: position);
        if (!current() || refreshed == null || refreshed.partTimeline?.current.partId != part?.partId ||
            (refreshed.partTimeline?.current.start.inMilliseconds ?? 0) != offset) {
          throw StateError('Renewal changed the selected source file.');
        }
        return (uri: Uri.parse(refreshed.url), headers: const <String, String>{});
      });
      if (!current()) throw StateError('Playback changed during source preparation.');
      return SubtitleAnalysisSource(uri: uri, identity: sourceDigest('$profile:${item.globalKey}:$mediaIndex:$mediaSourceId:${part?.partId}'),
        timelineOffsetMs: offset, durationMs: part?.duration.inMilliseconds ?? item.durationMs,
        isCurrent: current, close: gateway.close);
    } catch (_) { await gateway.close(); rethrow; }
  }
}
