part of '../../video_player_screen.dart';

extension _VideoPlayerSubtitleSources on VideoPlayerScreenState {
  Future<SubtitleAnalysisSource> _openSubtitleAnalysisSource() async {
    final core = player, item = _currentMetadata, session = _playbackSession;
    if (core == null || _shuttingDown) throw StateError('Open a library item first.');
    final profiles = context.read<ActiveProfileProvider>(), profile = context.read<ActiveProfileProvider>().activeId;
    final mediaGeneration = core is PlayerMediaSessionIdentity ? core.mediaSessionGeneration : null;
    final mediaIndex = _effectiveSelectedMediaIndex, mediaSourceId = session?.mediaSourceId;
    bool current() => mounted && !_shuttingDown && identical(player, core) && !core.disposed &&
        _currentMetadata.globalKey == item.globalKey && identical(_playbackSession, session) &&
        profiles.activeId == profile && (mediaGeneration == null ||
          (core as PlayerMediaSessionIdentity).mediaSessionGeneration == mediaGeneration);
    if (widget.isLive) {
      final liveSession = _live.session;
      final streamGeneration = _live.streamGeneration;
      bool liveCurrent() => current() && liveSession != null && identical(_live.session, liveSession) &&
          streamGeneration == _live.streamGeneration;
      final opened = Uri.tryParse(await core.getProperty('path') ?? '');
      if (!liveCurrent() || opened == null || !const {'http', 'https'}.contains(opened.scheme)) {
        throw UnsupportedError('This live player does not expose an owned HTTP live source');
      }
      final gateway = SourceStreamGateway(valid: liveCurrent, subtitleLiveAnalysis: true);
      try {
        final uri = await gateway.registerUri(opened, headers: liveSession is IptvLiveTvPlaybackSession
            ? liveSession.streamHeaders : const <String, String>{});
        if (!liveCurrent()) throw StateError('The live source changed');
        return SubtitleAnalysisSource(uri: uri, identity: sourceDigest('$profile:${item.globalKey}:live:$streamGeneration'),
          isCurrent: liveCurrent, close: gateway.close, liveSeekableEpochRange: () {
            if (!liveCurrent()) return null;
            final timeline = _liveTimelineForPosition(core.currentPosition);
            final window = timeline.seekable;
            if (!timeline.playback.active || window?.isValid != true ||
                timeline.playback.accuracy == LiveTvTimeAccuracy.stale || timeline.playback.accuracy == LiveTvTimeAccuracy.unknown) return null;
            return (startMs: (window!.startEpoch * 1000).round(), endMs: (window.endEpoch * 1000).round());
          }, liveEpochForPosition: (positionMs) {
            if (!liveCurrent()) return null;
            final currentPosition = core.currentPosition;
            final position = _live.playbackPosition(currentPosition);
            return position.active && position.epoch?.isFinite == true
                ? (position.epoch! * 1000).round() + positionMs - currentPosition.inMilliseconds : null;
          });
      } catch (_) { await gateway.close(); rethrow; }
    }
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
