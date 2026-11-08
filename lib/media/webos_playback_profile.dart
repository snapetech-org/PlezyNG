import 'media_source_info.dart';

/// Original-file metadata is a source-track fallback when LG's parser cannot
/// identify a codec its software decoder plays. Never describe a converted
/// rendition using the original file's format. No receiver/output inference.
List<Map<String, Object?>> webosDirectAudioMetadata(MediaSourceInfo? source, {required bool isTranscoding}) {
  if (isTranscoding || source == null) return const [];
  final tracks = source.audioTracks.where((track) => !track.isExternal).toList();
  if (tracks.length > 128) return const [];
  String? bounded(String? value) => value != null && value.length <= 64 ? value : null;
  return [
    for (final track in tracks)
      {
        'codec': bounded(track.codec),
        'codecProfile': bounded(track.codecProfile),
        'channels': track.channels,
        'sampleRate': track.sampleRate,
        'bitRate': track.bitrate,
      },
  ];
}

/// A fallback target used only after the native audio path rejects a format.
/// Initial playback keeps original audio and the TV/receiver's passthrough.
const webosTranscodeAudioCodecs = 'eac3,ac3,aac,mp3';

/// Initialization, window, network and output-device failures do not establish
/// an unsupported codec. Only explicit native audio-format rejection does.
bool webosMediaErrorRejectsAudio(Object? error) {
  if (error == null) return false;
  final message = error.toString().toLowerCase().replaceAll(RegExp(r'[_-]'), ' ');
  return RegExp(
    r'(?:unsupported|not supported).{0,48}(?:audio codec|audio format|dts|truehd)'
    r'|(?:audio codec|audio format|dts|truehd).{0,48}(?:unsupported|not supported)',
  ).hasMatch(message);
}
