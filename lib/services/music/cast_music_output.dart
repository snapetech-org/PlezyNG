import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../mpv/models.dart';
import '../multi_server_manager.dart';
import 'cast_music_player.dart';
import 'music_playback_output.dart';
import 'music_source_resolver.dart';

class CastMusicOutput implements MusicPlaybackOutput {
  CastMusicOutput({
    required this.name,
    required this.serverManager,
    required bool Function() authorized,
    required CastMusicReceiver receiver,
  }) : player = CastMusicPlayer(receiver, authorized: authorized);

  final MultiServerManager serverManager;
  @override
  final String name;
  @override
  final CastMusicPlayer player;
  @override
  bool get available => player.available;
  @override
  Stream<void> get revoked => player.revoked;

  @override
  Future<MusicSource> resolve(MediaItem track) async {
    final server = track.serverId;
    if (!available || server == null || track.kind != MediaKind.track) {
      throw StateError('Cast music source is unavailable');
    }
    final id = ServerId(server);
    final client = serverManager.getClient(id);
    if (client == null ||
        client.backend != track.backend ||
        client.isOfflineMode ||
        !serverManager.isServerVisible(id)) {
      throw StateError('Cast music source is not authorized');
    }
    final authentication = client.authenticationSessionId;
    bool current() =>
        available &&
        identical(client.authenticationSessionId, authentication) &&
        identical(serverManager.getClient(id), client) &&
        serverManager.isServerVisible(id) &&
        !client.isOfflineMode;
    final target = await client.resolveExternalPlayback(track);
    if (!current() || target == null || target.partTimeline != null) {
      throw StateError('Cast music source changed or requires unsupported part playback');
    }
    final source = MusicSource(url: target.url, playSessionId: target.playSessionId, reportingClient: client);
    player.prepare(track, source, current);
    return source;
  }
}

typedef CastReceiverKey = ({String session, String device});

CastReceiverKey? castReceiverKey(GoogleCastSession? session) {
  if (session?.connectionState != GoogleCastConnectState.connected) return null;
  final id = session?.sessionID;
  final device = session?.device?.deviceID;
  return id == null || id.isEmpty || device == null || device.isEmpty ? null : (session: id, device: device);
}

class GoogleMusicCastReceiver implements CastMusicReceiver {
  GoogleMusicCastReceiver() : _connection = castReceiverKey(GoogleCastSessionManager.instance.currentSession);
  final _remote = GoogleCastRemoteMediaClient.instance;
  final _sessions = GoogleCastSessionManager.instance;
  final CastReceiverKey? _connection;

  @override
  bool get connected => _connection != null && castReceiverKey(_sessions.currentSession) == _connection;
  @override
  Stream<bool> get connections =>
      _sessions.currentSessionStream.map((session) => _connection != null && castReceiverKey(session) == _connection);
  @override
  CastMusicStatus? get status => _status(_remote.mediaStatus);
  @override
  Stream<CastMusicStatus> get statuses =>
      _remote.mediaStatusStream.map(_status).where((status) => status != null).cast<CastMusicStatus>();
  @override
  Stream<Duration> get positions => _remote.playerPositionStream.where((_) => connected);

  CastMusicStatus? _status(GoggleCastMediaStatus? status) {
    if (!connected || status == null) return null;
    final token = status.mediaInformation?.customData?['pleazyngOwner'];
    return CastMusicStatus(
      session: status.mediaSessionID,
      token: token == null
          ? null
          : token is String
          ? token
          : '',
      duration: status.mediaInformation?.duration,
      volume: status.volume.toDouble() * 100,
      state: switch (status.playerState) {
        CastMediaPlayerState.playing => CastMusicState.playing,
        CastMediaPlayerState.paused => CastMusicState.paused,
        CastMediaPlayerState.buffering || CastMediaPlayerState.loading => CastMusicState.loading,
        CastMediaPlayerState.idle => switch (status.idleReason) {
          GoogleCastMediaIdleReason.finished => CastMusicState.finished,
          GoogleCastMediaIdleReason.error => CastMusicState.error,
          _ => CastMusicState.stopped,
        },
        _ => CastMusicState.loading,
      },
    );
  }

  @override
  Future<void> load(MediaItem track, MusicSource source, Media media, String token) async {
    if (!connected) throw StateError('Cast receiver connection changed');
    final uri = Uri.parse(source.url);
    await _remote.loadMedia(
      GoogleCastMediaInformation(
        contentId: source.url,
        contentUrl: uri,
        contentType: castMusicContentType(uri, container: track.mediaVersions?.firstOrNull?.container),
        streamType: CastMediaStreamType.buffered,
        duration: track.durationMs == null ? null : Duration(milliseconds: track.durationMs!),
        metadata: GoogleCastGenericMediaMetadata(title: track.displayTitle, subtitle: track.displaySubtitle),
        customData: {'pleazyngOwner': token},
      ),
      autoPlay: false,
      playPosition: media.start ?? Duration.zero,
    );
  }

  @override
  Future<void> play() => _remote.play();
  @override
  Future<void> pause() => _remote.pause();
  @override
  Future<void> stop() => _remote.stop();
  @override
  Future<void> seek(Duration position) => _remote.seek(GoogleCastMediaSeekOption(position: position));
  @override
  Future<void> setVolume(double volume) async => _sessions.setDeviceVolume(volume / 100);
  @override
  Future<void> setRate(double rate) => _remote.setPlaybackRate(rate);
}

String castMusicContentType(Uri uri, {String? container}) {
  final path = uri.path.toLowerCase();
  final pathExtension = path.split('.').last;
  final extension = {'mp3', 'flac', 'ogg', 'oga', 'opus', 'wav', 'aac', 'm3u8', 'm4a', 'mp4'}.contains(pathExtension)
      ? pathExtension
      : container?.toLowerCase();
  return switch (extension) {
    'mp3' => 'audio/mpeg',
    'flac' => 'audio/flac',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    'aac' => 'audio/aac',
    'm3u8' => 'application/vnd.apple.mpegurl',
    _ => 'audio/mp4',
  };
}
