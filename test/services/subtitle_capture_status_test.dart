import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/i18n/strings_ar.g.dart';
import 'package:plezy/i18n/strings_de.g.dart';
import 'package:plezy/i18n/subtitle_capture_status_text.dart';
import 'package:plezy/services/subtitle_capture_status.dart';
import 'package:plezy/services/subtitle_speech_progress.dart';

void main() {
  test('file speech phases resolve through the selected locale', () {
    for (final phase in SubtitleSpeechPhase.values) {
      final progress = SubtitleSpeechProgress(phase, received: 37, total: 100);
      final en = resolveSubtitleSpeechProgress(Translations(), progress);
      for (final translations in [TranslationsAr(), TranslationsDe()]) {
        final text = resolveSubtitleSpeechProgress(translations, progress);
        expect(text.trim(), isNotEmpty);
        expect(text, isNot(contains(r'${')));
        expect(text, isNot(en));
      }
    }
    final progress = SubtitleSpeechProgress(SubtitleSpeechPhase.inference, received: 37, total: 100);
    expect(resolveSubtitleSpeechProgress(TranslationsAr(), progress, number: (_) => '٣٧'), contains('٣٧'));
    expect(const SubtitleSpeechProgress(SubtitleSpeechPhase.loadingModel).percent, isNull);
    expect(const SubtitleSpeechProgress(SubtitleSpeechPhase.inference, received: -1, total: 100).percent, 0);
    expect(const SubtitleSpeechProgress(SubtitleSpeechPhase.inference, received: 200, total: 100).percent, 100);
  });

  test('every capture phase resolves in English, Arabic and German', () {
    for (final translations in [Translations(), TranslationsAr(), TranslationsDe()]) {
      for (final phase in SubtitleCapturePhase.values) {
        final text = resolveSubtitleCaptureStatus(translations,
          SubtitleCaptureStatus(phase, count: 12, received: 25, total: 100));
        expect(text.trim(), isNotEmpty);
        expect(text, isNot(contains(r'${')));
      }
    }
    const status = SubtitleCaptureStatus(SubtitleCapturePhase.loadingModel);
    expect(resolveSubtitleCaptureStatus(TranslationsAr(), status), isNot(resolveSubtitleCaptureStatus(Translations(), status)));
    expect(resolveSubtitleCaptureStatus(TranslationsDe(), status), isNot(resolveSubtitleCaptureStatus(Translations(), status)));
  });

  test('status stores data and resolves numbers using the selected presentation', () {
    const status = SubtitleCaptureStatus(SubtitleCapturePhase.captured, count: 12);
    expect(resolveSubtitleCaptureStatus(TranslationsAr(), status, number: (_) => '١٢'), contains('١٢'));
    expect(status, const SubtitleCaptureStatus(SubtitleCapturePhase.captured, count: 12));
    expect(const SubtitleCaptureStatus(SubtitleCapturePhase.downloadingModel).percent, isNull);
    expect(const SubtitleCaptureStatus(SubtitleCapturePhase.downloadingModel, received: 200, total: 100).percent, 100);
    expect(const SubtitleCaptureStatus(SubtitleCapturePhase.downloadingModel, received: -1, total: 100).percent, 0);
  });
}
