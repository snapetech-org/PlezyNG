/// What the app can prove about the inference request.
///
/// Current Whisper and Sherpa bindings expose provider selection, successful
/// initialization/inference, and whole-run CPU fallback. They do not expose a
/// device assignment for each graph operation.
enum SubtitlePlacementEvidence {
  unverified,
  cpuOnlyConfigured,
  acceleratorRequestSucceededButUnverified,
  cpuFallbackAfterAcceleratorUnavailable,
}

extension SubtitlePlacementEvidenceLabel on SubtitlePlacementEvidence {
  String get displayLabel => switch (this) {
    SubtitlePlacementEvidence.unverified => 'execution placement could not be established',
    SubtitlePlacementEvidence.cpuOnlyConfigured =>
      'CPU path configured; operation-level profiling is unavailable',
    SubtitlePlacementEvidence.acceleratorRequestSucceededButUnverified =>
      'provider request initialized and inference succeeded; per-operation placement is unverified',
    SubtitlePlacementEvidence.cpuFallbackAfterAcceleratorUnavailable =>
      'accelerator unavailable or failed; transcription completed on CPU',
  };
}
