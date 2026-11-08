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
