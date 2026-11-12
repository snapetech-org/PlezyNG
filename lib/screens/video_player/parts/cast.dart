part of '../../video_player_screen.dart';

extension _VideoPlayerCastMethods on VideoPlayerScreenState {
  bool get _canCastActiveVideo =>
      CastMediaService.isSupportedPlatform &&
      !widget.isLive &&
      !widget.isPreroll &&
      !_offlineLibraryMode &&
      !_workspaceSurfaceDetached &&
      _watchTogetherRoom() == null &&
      _externalSourceFor(_currentMetadata) == null &&
      _currentMetadata.serverId != null &&
      (_currentMetadata.isEpisode || _currentMetadata.isMovie);

  Future<void> _moveVideoToCast() async {
    final currentPlayer = player;
    if (_movingVideoOutput || !_canCastActiveVideo || !_firstFrame.rendered || currentPlayer == null) return;
    final client = _getOnlineMediaServerClient(context);
    if (client == null) {
      showErrorSnackBar(context, t.cast.serverNotAvailable);
      return;
    }
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    final metadata = _currentMetadata;
    final generation = _transitionGate.generation;
    PlaybackTransitionLease? lease;
    bool current() =>
        mounted &&
        route?.isCurrent == true &&
        !_shuttingDown &&
        _canCastActiveVideo &&
        _transitionGate.generation == generation &&
        (lease == null ? _transitionGate.transition == PlaybackTransition.idle : _transitionGate.owns(lease!)) &&
        identical(player, currentPlayer) &&
        !currentPlayer.state.completed &&
        _currentMetadata.globalKey == metadata.globalKey;

    Future<void> restore() async {
      _videoOutputFrozen = false;
      if (current()) await _playWithPlaybackIntent(currentPlayer);
    }

    _setPlayerState(() => _movingVideoOutput = true);
    try {
      final output = await CastMediaService.instance.moveActiveVideo(
        context,
        client: client,
        item: metadata,
        mediaIndex: _effectiveSelectedMediaIndex,
        mediaSourceId: _requestedMediaSourceId,
        source: CastVideoSource(
          position: () => currentPlayer.state.position,
          isCurrent: current,
          freeze: () async {
            if (!current()) return null;
            lease = _transitionGate.tryAcquire(PlaybackTransition.movingOutput);
            if (lease == null) return null;
            final wasPlaying =
                currentPlayer.state.playing || (currentPlayer.state.buffering && _playbackIntentShouldPlay);
            _setPlayerState(() => _videoOutputFrozen = true);
            _relativeSkip.cancel();
            try {
              await _pauseWithPlaybackIntent(currentPlayer);
            } catch (_) {
              if (wasPlaying) await restore();
              rethrow;
            }
            return (position: currentPlayer.state.position, playing: wasPlaying);
          },
          restore: restore,
        ),
      );
      if (output == null) return;

      // Retire the local decoder and its progress writer. The receiver's
      // reporting starts after the outgoing route releases the local trackers.
      final shutdown = mounted ? _shutdownVideo() : _shutdownOperation;
      unawaited(
        Future.wait<void>([?shutdown, _routeDisposed.future])
            .catchError((Object error, StackTrace stack) {
              appLogger.w('Local video cleanup after Cast failed', error: error, stackTrace: stack);
              return <void>[];
            })
            .then((_) => output.startReporting()),
      );
      if (!mounted) return;
      if (route?.isCurrent == true) {
        unawaited(
          navigator.pushReplacement<void, bool>(
            MaterialPageRoute(builder: (_) => CastVideoControlsScreen(playback: output)),
            result: true,
          ),
        );
      } else if (route != null && route.isActive) {
        navigator.removeRoute(route, true);
      }
    } on CastVideoTransferUncertain {
      if (mounted) showErrorSnackBar(context, t.musicDevices.uncertain);
    } catch (error) {
      appLogger.d('Video output selection failed (${error.runtimeType})');
      if (mounted) showErrorSnackBar(context, t.cast.startFailed);
    } finally {
      if (lease case final owned?) _transitionGate.release(owned);
      if (mounted && !_shuttingDown) {
        _setPlayerState(() {
          _movingVideoOutput = false;
          _videoOutputFrozen = false;
        });
      }
    }
  }
}
