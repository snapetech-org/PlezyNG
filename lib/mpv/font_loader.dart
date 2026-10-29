import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';
import '../services/subtitle_font_store.dart';

/// One bundled subtitle font: its asset, the file name libass sees, and the
/// asset's byte length, which is what decides whether an extracted copy is
/// current. The cache directory outlives app updates, so "the file exists"
/// says nothing about which build wrote it; the length does, at the cost of
/// one stat. Every [SubtitleFontLoader.fonts] length is pinned to the real
/// asset by `test/mpv/font_loader_test.dart`, so regenerating a font without
/// updating its length fails the test instead of shipping the stale copy.
class SubtitleFont {
  const SubtitleFont({required this.asset, required this.fileName, required this.length});

  final String asset;
  final String fileName;
  final int length;
}

/// Extracts font files from Flutter assets to the cache directory for
/// comprehensive Unicode coverage (including CJK and Hangul characters) for
/// libass subtitles.
///
/// GoNotoCurrent (the primary font) covers every common script except Korean,
/// and the Android libmpv build has no fontconfig/system-font fallback, so
/// libass can only find glyphs in this directory. libass only considers fonts
/// whose name-table family equals the requested `sub-font` ([fontName]) and
/// then picks, per codepoint, the candidate that has the glyph. The Hangul
/// companion next to the primary therefore carries the primary's family name
/// (not its upstream one) and exactly the codepoints the primary lacks: the
/// 11172 Hangul syllables. It is generated from GoNotoKurrent-Regular
/// (satbyy/go-noto-universal v7.0) by
/// `scripts/codegen/generate_hangul_subtitle_font.py`, which also verifies
/// those invariants (`--check`).
class SubtitleFontLoader {
  static const String _fontName = 'Go Noto Current-Regular';

  /// Font files extracted to the subtitle fonts directory, in extraction order:
  /// the primary, then its Hangul-syllable companion (see class docs).
  static const List<SubtitleFont> fonts = [
    SubtitleFont(
      asset: 'assets/go-noto-current-regular.ttf',
      fileName: 'go-noto-current-regular.ttf',
      length: 14700060,
    ),
    SubtitleFont(asset: 'assets/go-noto-kurrent-hangul.ttf', fileName: 'go-noto-kurrent-hangul.ttf', length: 1976696),
  ];

  /// Suffix of a copy still being written; a leftover one is stale by definition.
  static const String _partialSuffix = '.partial';

  /// In-memory cache of the resolved font directory. The filesystem work
  /// (temp dir lookup, length checks, asset extraction) is idempotent per
  /// process — caching the result skips ~20ms on every subsequent Player
  /// instantiation.
  static Future<String?>? _cachedFontDir;
  static Future<void> _extractionQueue = Future.value();
  static Future<void>? _overlayFonts;
  static const overlayFamily = 'Plezy Subtitle Universal';
  static const overlayHangulFamily = 'Plezy Subtitle Hangul';

  /// Register the shipped, licensed fonts for Flutter captions too. The two
  /// families remain separate so SkParagraph can select the Hangul fallback.
  /// No network or media-attached font is consulted by this operation.
  static Future<void> loadOverlayFonts() => _overlayFonts ??= _loadOverlayFonts();

  static Future<void> _loadOverlayFonts() async {
    for (var index = 0; index < fonts.length; index++) {
      final loader = FontLoader(index == 0 ? overlayFamily : overlayHangulFamily);
      loader.addFont(rootBundle.load(fonts[index].asset));
      await loader.load();
    }
    try { await SubtitleFontStore.instance.initialize(); } catch (error, stack) {
      appLogger.w('Imported subtitle fonts are unavailable; bundled fonts remain active', error: error, stackTrace: stack);
    }
  }

  static Future<String?> loadSubtitleFont() {
    return _cachedFontDir ??= () {
      final result = _extractionQueue.then((_) => _loadSubtitleFontOnce());
      _extractionQueue = result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
      return result;
    }();
  }

  /// Forget the resolved directory so the next [loadSubtitleFont] re-runs the
  /// extraction against the current temp directory.
  @visibleForTesting
  static void resetForTesting() {
    _cachedFontDir = null;
  }

  /// Imported fonts are read when a new native player opens; existing libass
  /// contexts retain their current font provider until that player is reopened.
  static void importedFontsChanged() { _cachedFontDir = null; }

  static Future<String?> _loadSubtitleFontOnce() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final fontDir = Directory(path.join(cacheDir.path, 'subtitle_fonts'));
      await fontDir.create(recursive: true);
      final imported = SubtitleFontStore.instance;
      var customFonts = <SubtitleStoredFont>[];
      try { await imported.initialize(); customFonts = imported.fonts; } catch (error, stack) {
        appLogger.w('Imported native subtitle fonts are unavailable', error: error, stackTrace: stack);
      }

      // libass loads every file in the directory, so anything that is not a
      // current copy of a bundled font or an explicit verified import goes:
      // an earlier build's version
      // of the same file name, a copy truncated by a crash, an interrupted
      // write. Length is the currency check; a file of the right name and
      // length is a copy of the asset this build ships. Imported copies are
      // always replaced from the hash-verified durable store.
      final expected = {for (final font in fonts) font.fileName: font.length,
        for (final font in customFonts) '${font.digest}.otf': font.bytes};
      final current = <String>{};
      await for (final entry in fontDir.list(followLinks: false)) {
        final name = path.basename(entry.path);
        if (entry is File && !name.endsWith('.otf') && expected[name] == await entry.length()) {
          current.add(name);
        } else {
          await entry.delete(recursive: true);
        }
      }

      for (final font in fonts) {
        if (current.contains(font.fileName)) continue;
        final data = await rootBundle.load(font.asset);
        final partial = File(path.join(fontDir.path, font.fileName + _partialSuffix));
        await partial.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
        await partial.rename(path.join(fontDir.path, font.fileName));
      }

      for (final font in customFonts) {
        try {
          final bytes = await imported.verifiedBytes(font);
          final partial = File(path.join(fontDir.path, '${font.digest}.otf$_partialSuffix'));
          await partial.writeAsBytes(bytes, flush: true);
          await partial.rename(path.join(fontDir.path, '${font.digest}.otf'));
        } catch (error, stack) {
          appLogger.w('An imported subtitle font could not be staged', error: error, stackTrace: stack);
        }
      }

      return fontDir.path;
    } catch (e, st) {
      appLogger.w('Failed to load subtitle font', error: e, stackTrace: st);
      return null;
    }
  }

  static String get fontName => _fontName;
}
