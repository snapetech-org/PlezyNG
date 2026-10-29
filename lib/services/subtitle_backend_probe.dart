import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'subtitle_ai_service.dart';
import 'subtitle_placement_evidence.dart';

final class SubtitleBackendProbeReport {
  const SubtitleBackendProbeReport({required this.result, required this.sampleDigest,
    required this.elapsedMs, required this.expectedText, required this.model});
  final SubtitleTranscriptionResult result;
  final String sampleDigest;
  final int elapsedMs;
  final String? expectedText;
  final Map<String, String> model;
  String get transcript => result.cues.map((cue) => cue.text).join(' ');
  bool get returnedSpeech => transcript.trim().isNotEmpty;
  bool? get textAgrees {
    final reference = expectedText;
    if (reference == null || reference.isEmpty) return null;
    String normalize(String value) => value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return normalize(reference) == normalize(transcript);
  }
  double get elapsedToAudioRatio => elapsedMs / result.durationMs;
  Uint8List encode() => Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert({
    'schema': 'plezyng.subtitle-backend-probe.v1',
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'sampleSha256': sampleDigest, 'sampleDurationMs': result.durationMs,
    'requestedProvider': result.requestedProvider.name, 'runtimeProvider': result.runtimeProvider,
    'cpuFallback': result.fellBackToCpu, 'placementEvidence': result.placementEvidence.name,
    'placementDescription': result.placementEvidence.displayLabel,
    'declaredModel': model, 'elapsedIncludingQueueAndModelLoadMs': elapsedMs,
    'elapsedToAudioRatio': elapsedToAudioRatio, 'returnedSpeech': returnedSpeech,
    'transcript': transcript, if (expectedText != null) 'viewerExpectedText': expectedText,
    'caseAndWhitespaceNormalizedTextAgreement': textAgrees,
    'qualityStatus': 'unqualified-single-viewer-sample',
    'perOperationPlacementMeasured': false, 'sustainedRealtimeMeasured': false,
  })));
}

/// Explicit real inference over a small viewer-selected sample, never a device
/// name/driver check presented as model qualification. No automatic activation.
final class SubtitleBackendProbe {
  static Future<SubtitleBackendProbeReport> run({required String wavPath,
    required SubtitleInferenceProvider provider, required bool Function() isCurrent,
    String? expectedText, String? languageCode,
  }) async {
    if (!SubtitleAiService.availableProviderRequests.contains(provider)) {
      throw UnsupportedError('The requested subtitle provider is unavailable on this platform.');
    }
    final reference = expectedText?.trim();
    if ((reference?.length ?? 0) > 2000) throw const FormatException('Reference text exceeds 2000 characters.');
    if (!isCurrent()) throw StateError('Backend check cancelled.');
    final ai = SubtitleAiService.instance;
    if (!await ai.isProviderModelInstalled(provider)) {
      throw StateError('Install the selected speech model in the foreground first.');
    }
    final file = File(wavPath);
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file || before.size < 44 || before.size > 8 * 1024 * 1024) {
      throw const FormatException('Choose a WAV sample no larger than 8 MiB.');
    }
    final staging = await (await getTemporaryDirectory()).createTemp('plezy-subtitle-probe-');
    try {
      final bytes = BytesBuilder(copy: false);
      final copying = Stopwatch()..start();
      await for (final chunk in file.openRead().timeout(const Duration(seconds: 5))) {
        if (!isCurrent() || copying.elapsed > const Duration(seconds: 20) || bytes.length + chunk.length > before.size) {
          throw StateError('Backend sample changed or copying was cancelled.');
        }
        bytes.add(chunk);
      }
      final after = await file.stat();
      if (bytes.length != before.size || after.modified != before.modified || after.changed != before.changed) {
        throw StateError('Backend sample changed during copying.');
      }
      final input = bytes.takeBytes();
      final staged = File(p.join(staging.path, 'sample.wav'));
      await staged.writeAsBytes(input, flush: true);
      final duration = await ai.readWavDurationMs(staged.path);
      if (duration < 500 || duration > 15000) {
        throw const FormatException('Choose a WAV sample lasting 0.5–15 seconds.');
      }
      final clock = Stopwatch()..start();
      bool current() => isCurrent() && clock.elapsed < const Duration(minutes: 2);
      final result = await ai.transcribeWav(staged.path, provider: provider, allowEmpty: true,
        allowModelDownload: false, languageCode: languageCode, isCurrent: current);
      if (!current()) throw StateError('Backend check cancelled or exceeded its time budget.');
      if (result.cues.length > 512 || result.cues.fold<int>(0, (sum, cue) => sum + cue.text.length) > 32000) {
        throw const FormatException('The sample returned an oversized transcript.');
      }
      return SubtitleBackendProbeReport(result: result, sampleDigest: sha256.convert(input).toString(),
        elapsedMs: clock.elapsedMilliseconds, expectedText: reference?.isEmpty == true ? null : reference,
        model: SubtitleAiService.providerModelIdentity(provider));
    } finally {
      // Native work has returned before its input is removed, including cancel.
      try { await staging.delete(recursive: true); } on Object { /* Temporary cleanup can retry. */ }
    }
  }
}
