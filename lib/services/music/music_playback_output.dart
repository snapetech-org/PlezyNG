import '../../media/media_item.dart';
import '../../mpv/player/player.dart';
import 'music_source_resolver.dart';

abstract interface class MusicPlaybackOutput {
  String get name;
  Player get player;
  bool get available;
  Stream<void> get revoked;
  Future<MusicSource> resolve(MediaItem track);
}

abstract interface class MusicOutputControls {
  String? get remoteOutputName;
  Future<bool> selectOutput(MusicPlaybackOutput? output, {bool resume = true});
}
