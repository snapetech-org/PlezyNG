import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/i18n/strings_ar.g.dart';
import 'package:plezy/i18n/strings_de.g.dart';
import 'package:plezy/i18n/subtitle_capture_status_text.dart';
import 'package:plezy/services/subtitle_capture_status.dart';

void main() {
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
