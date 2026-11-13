import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/deep_links/deep_link.dart';
import 'package:plezy/services/deep_links/legacy_link_converter.dart';

void main() {
  group('previewLegacyLink', () {
    for (final scheme in ['pleazyng', 'plezyng', 'plezxyng', 'plezy']) {
      test('converts supported $scheme links without changing URI components', () {
        const suffix = '://play?server=s1&id=i1&profile=Kids%20%26%20Teens&tag=%2f&tag=two#chapter%201';
        final result = previewLegacyLink('$scheme$suffix');

        expect(result.error, isNull);
        expect(result.output, 'pleazyng$suffix');
        expect(result.schemeChanged, scheme != 'pleazyng');
        expect(DeepLink.tryParse(result.output!), isA<PlayLink>());
      });
    }

    test('accepts a supported canonical link unchanged', () {
      const link = 'pleazyng://open?profile=Kids#library';
      final result = previewLegacyLink(link);

      expect(result.output, link);
      expect(result.schemeChanged, isFalse);
    });

    test('rejects blank, invalid, unsupported-scheme, and unsupported-route input', () {
      expect(previewLegacyLink('  ').error, LegacyLinkConversionError.empty);
      expect(previewLegacyLink('not a URI').error, LegacyLinkConversionError.invalidUri);
      expect(
        previewLegacyLink('pleazyng://play?server=s1&id=%E0%A4%A').error,
        LegacyLinkConversionError.unsupportedRoute,
      );
      expect(previewLegacyLink('https://example.com/play').error, LegacyLinkConversionError.unsupportedScheme);
      expect(previewLegacyLink('plezy://unknown').error, LegacyLinkConversionError.unsupportedRoute);
    });

    test('does not add upstream plezy to the registered deep-link grammar', () {
      expect(DeepLink.tryParse('plezy://open'), isNull);
      expect(previewLegacyLink('plezy://open').output, 'pleazyng://open');
    });
  });
}
