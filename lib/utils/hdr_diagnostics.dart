/// A common diagnostic vocabulary without treating a preference or source
/// transfer function as proof that a display is currently emitting HDR.
Map<String, Object?> hdrConfigurationDiagnostic({
  required String platform,
  required String backend,
  required bool? requested,
  bool? sourceIsHdr,
  String? sourceTransfer,
  String? sourcePrimaries,
  String? videoOutput,
  String? toneMapping,
  String? linuxOutputOverride,
}) {
  final linux = platform == 'linux';
  final override = linuxOutputOverride?.trim().toLowerCase();
  return {
    'platform': platform,
    'backend': backend,
    'source_hdr': sourceIsHdr,
    'source_transfer': sourceTransfer,
    'source_primaries': sourcePrimaries,
    'hdr_requested': requested,
    'video_output': videoOutput,
    'output_policy': switch (platform) {
      'linux' => 'linux-video-plane',
      'windows' => 'windows-system-hdr',
      'macos' || 'ios' || 'tvos' => 'apple-edr',
      'android' => 'android-native',
      _ => 'platform-native',
    },
    if (linux) 'tone_mapping': toneMapping,
    if (linux)
      'output_override': switch (override) {
        null || '' => 'auto',
        'auto' || 'hdr' || 'sdr' => override,
        _ => 'invalid',
      },
  };
}
