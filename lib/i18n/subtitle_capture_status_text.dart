import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../services/subtitle_capture_status.dart';
import '../services/subtitle_speech_progress.dart';
import 'strings.g.dart';

String subtitleCaptureStatusText(BuildContext context, SubtitleCaptureStatus? status) {
  if (status == null) return '';
  final numbers = NumberFormat.decimalPattern(Localizations.localeOf(context).toLanguageTag());
  return resolveSubtitleCaptureStatus(context.t, status, number: numbers.format);
}

String subtitleSpeechProgressText(BuildContext context, SubtitleSpeechProgress progress) {
  final numbers = NumberFormat.decimalPattern(Localizations.localeOf(context).toLanguageTag());
  return resolveSubtitleSpeechProgress(context.t, progress, number: numbers.format);
}

String resolveSubtitleSpeechProgress(Translations t, SubtitleSpeechProgress progress, {String Function(int)? number}) {
  final messages = t.subtitleCapture;
  final percent = progress.percent;
  String count(int n) => number?.call(n) ?? n.toString();
  return switch (progress.phase) {
    SubtitleSpeechPhase.downloadingModel => percent == null ? messages.downloadingModel : messages.downloadingModelProgress(percent: count(percent)),
    SubtitleSpeechPhase.downloadingDetector => percent == null ? messages.downloadingDetector : messages.downloadingDetectorProgress(percent: count(percent)),
    SubtitleSpeechPhase.loadingModel => percent == null ? messages.loadingModel : messages.loadingModelProgress(percent: count(percent)),
    SubtitleSpeechPhase.transcribing => percent == null ? messages.transcribing : messages.transcribingProgress(percent: count(percent)),
    SubtitleSpeechPhase.translating => percent == null ? messages.translating : messages.translatingProgress(percent: count(percent)),
    SubtitleSpeechPhase.inference => percent == null ? messages.processingAudio : messages.processingAudioProgress(percent: count(percent)),
    SubtitleSpeechPhase.cpuFallback => messages.cpuFallback,
  };
}

/// Resolve on every build so changing the app locale also changes a live status.
String resolveSubtitleCaptureStatus(Translations t, SubtitleCaptureStatus status, {String Function(int)? number}) {
  final messages = t.subtitleCapture;
  String count(int n) => number?.call(n) ?? n.toString();
  final percent = status.percent;
  return switch (status.phase) {
    SubtitleCapturePhase.loadingModel => percent == null ? messages.loadingModel : messages.loadingModelProgress(percent: count(percent)),
    SubtitleCapturePhase.downloadingModel => percent == null ? messages.downloadingModel : messages.downloadingModelProgress(percent: count(percent)),
    SubtitleCapturePhase.capturing => messages.capturing,
    SubtitleCapturePhase.startFailed => messages.startFailed,
    SubtitleCapturePhase.inferenceFailed => messages.inferenceFailed,
    SubtitleCapturePhase.noSpeech => messages.noSpeech,
    SubtitleCapturePhase.captured => messages.captured(count: count(status.count)),
    SubtitleCapturePhase.playbackEnded => messages.playbackEnded,
    SubtitleCapturePhase.playbackChanged => messages.playbackChanged,
    SubtitleCapturePhase.audioTrackChanged => messages.audioTrackChanged,
    SubtitleCapturePhase.listening => messages.listening(count: count(status.count)),
    SubtitleCapturePhase.captureUnavailable => messages.captureUnavailable,
    SubtitleCapturePhase.waitingForAudio => messages.waitingForAudio,
    SubtitleCapturePhase.captureStopped => messages.captureStopped,
  };
}
