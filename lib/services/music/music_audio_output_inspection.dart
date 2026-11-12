import '../../mpv/player/player.dart';

/// Reads the currently owned physical renderer. These are decoder/OS reports,
/// not measurements of the DAC or proof that a route is bit-perfect.
Future<Map<String, String>> inspectMusicAudioOutput(Player? player, {required bool Function() current}) async {
  if (player == null || player.disposed || player.playerType != 'mpv' || !current()) return const {};
  final result = <String, String>{};
  for (final property in const [
    'audio-params/samplerate',
    'audio-params/channel-count',
    'audio-out-params/samplerate',
    'audio-out-params/channel-count',
    'audio-out-params/format',
    'current-ao',
    'audio-device',
    'replaygain',
    'replaygain-fallback',
    'replaygain-clip',
    'af',
  ]) {
    if (!current() || player.disposed) return const {};
    final value = await player.getProperty(property);
    if (!current() || player.disposed) return const {};
    if (value != null && value.isNotEmpty && value.length <= 4096) result[property] = value;
  }
  return Map.unmodifiable(result);
}
