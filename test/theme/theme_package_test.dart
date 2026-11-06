import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/theme/mono_tokens.dart';
import 'package:plezy/theme/theme_package.dart';

void main() {
  Map<String, Object?> manifest() => ThemePackage(id: 'test', name: 'Test', palette: MonoPalette.dark).toJson();
  test('package export/import retains geometry, typography and navigation', () {
    final value = manifest();
    value['geometry'] = {'radiusSm': 2, 'radiusMd': 4, 'radiusLg': 8, 'space': 20};
    value['typography'] = {'scale': 1.2};
    value['layout'] = {'navigation': 'bottom'};
    final package = ThemePackage.decode(jsonEncode(value));
    final restored = ThemePackage.decode(package.encode());
    final painted = restored.apply(monoTheme(restored.palette));
    expect(painted.extension<MonoTokens>()!.radiusMd, 4);
    expect(painted.extension<MonoTokens>()!.space, 20);
    expect(painted.extension<ThemeLayout>()!.navigation, ThemeNavigation.bottom);
    expect(
      painted.textTheme.bodyMedium!.fontSize!,
      greaterThan(monoTheme(restored.palette).textTheme.bodyMedium!.fontSize!),
    );
  });
  test('unknown executable or remote asset fields are rejected', () {
    for (final key in ['script', 'stylesheetUrl', 'fontUrl']) {
      final value = manifest()..[key] = 'https://example.com/file';
      expect(() => ThemePackage.decode(jsonEncode(value)), throwsFormatException);
    }
  });
  test('unsupported versions and unbounded geometry cannot replace a theme', () {
    expect(() => ThemePackage.fromJson(manifest()..['schemaVersion'] = 2), throwsFormatException);
    expect(() => ThemePackage.fromJson(manifest()..['geometry'] = {'space': 0}), throwsFormatException);
    expect(() => ThemePackage.fromJson(manifest()..['typography'] = {'scale': double.nan}), throwsFormatException);
    expect(() => ThemePackage.fromJson(manifest()..['layout'] = {'navigation': 'script'}), throwsFormatException);
    expect(() => ThemePackage.fromJson(manifest()..['id'] = '../escape'), throwsFormatException);
  });
  test('existing palette-only themes are unchanged by absent package tokens', () {
    final package = ThemePackage.fromJson({
      'schemaVersion': 1,
      'id': 'legacy',
      'name': 'Legacy',
      'palette': MonoPalette.paper.toJson(),
    });
    expect(package.palette, MonoPalette.paper);
    expect(package.navigation, ThemeNavigation.adaptive);
    expect(package.space, monoTheme(MonoPalette.paper).extension<MonoTokens>()!.space);
  });
}
