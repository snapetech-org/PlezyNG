import 'caldera_group.dart';

/// The shared music session retains audio focus, OS controls and teardown.
abstract interface class CalderaAudioOutput {
  Future<bool> openCalderaAudio(Object owner, Uri source, String title, bool Function() current);
  bool ownsCalderaAudio(Object owner);
  Future<void> closeCalderaAudio(Object owner);
}

abstract interface class CalderaAudioVolumeOutput {
  double get calderaAudioVolume;
  Future<void> setCalderaAudioVolume(Object owner, double value);
}

abstract interface class CalderaAudioClockOutput {
  bool hasCalderaAudioClock(Object owner);
  Future<Duration?> readCalderaAudioClock(Object owner);
}

abstract interface class CalderaAudioMetadataOutput {
  void updateCalderaMetadata(Object owner, CalderaNowPlaying metadata);
}
