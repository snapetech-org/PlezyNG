// Opt-in export of the production EPUB reader engine.
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/sources/publication_archive.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/sources/reader_preferences.dart';

void main() {
  final output = Platform.environment['PLEAZYNG_FEATURE_OUTPUT'];
  if (output == null) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  test('capture production ebook reader', () async {
    final directory = Directory('$output/reader-state')..createSync(recursive: true);
    final zip = Archive();
    const paragraphs = [
      'The library opened only after sunset. By then the harbour had grown quiet, and the last ferry was a line of warm windows moving across the water. Nora climbed the narrow steps with a notebook tucked beneath her coat.',
      'Inside, the shelves rose almost to the rafters. There were atlases of places she had never heard of, field guides with pressed flowers between their pages, and a small collection of letters tied together with blue thread.',
      'She chose the table beside the western window. From there she could see the lighthouse turning its patient beam across the bay. Every few seconds the room became silver, and then it belonged to the lamplight again.',
      'A book lay open on the table. Someone had drawn a map in its margin: three islands, a long curved shore, and a star where the old observatory should have been. Beneath it, in careful handwriting, were four words: begin where the light returns.',
      'Nora traced the route with one finger. The sea beyond the glass was dark, but the map made it seem familiar. She had spent the whole afternoon searching for a destination. Now, at last, she had found a beginning.',
      'She turned the page slowly. The next chapter was not a list of instructions. It was an invitation to notice the things that were usually passed by: the shape of a cloud, a half-remembered song, the welcome of a door left open.',
    ];
    final files = <String, String>{
      'META-INF/container.xml':
          '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      'EPUB/package.opf':
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">night-library</dc:identifier><dc:title>The Night Library</dc:title><dc:language>en</dc:language></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>',
      'EPUB/nav.xhtml':
          '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="one.xhtml">The light returns</a></li><li><a href="two.xhtml">Across the water</a></li></ol></nav></body></html>',
      'EPUB/one.xhtml':
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>The light returns</title></head><body><h1>The light returns</h1>${[...paragraphs, ...paragraphs].map((p) => '<p>$p</p>').join()}</body></html>',
      'EPUB/two.xhtml':
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Across the water</title></head><body><h1>Across the water</h1>${paragraphs.reversed.map((p) => '<p>$p</p>').join()}</body></html>',
    };
    for (final entry in files.entries) {
      zip.add(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
    }
    final file = File('${directory.path}/night-library.epub')..writeAsBytesSync(ZipEncoder().encode(zip));
    final archive = await PublicationArchive.open(file, directory);
    late PublicationServer server;
    Object? failure;
    server = PublicationServer(
      archive,
      valid: () => true,
      onEvent: (events) async {
        if (events.first['type'] == 'engineReady') {
          try {
            await server.execute('open', {
              'title': 'The Night Library',
              'interfaceLocale': 'en',
              'formattingLocale': 'en-US',
              'interfaceDirection': 'ltr',
              'icons': {
                'zoomIn': Symbols.zoom_in_rounded.codePoint,
                'zoomOut': Symbols.zoom_out_rounded.codePoint,
                'fitPage': Symbols.fit_screen_rounded.codePoint,
                'page': Symbols.numbers_rounded.codePoint,
                'prev': Symbols.chevron_left_rounded.codePoint,
                'next': Symbols.chevron_right_rounded.codePoint,
                'toc': Symbols.format_list_bulleted_rounded.codePoint,
                'search': Symbols.search_rounded.codePoint,
                'note': Symbols.bookmarks_rounded.codePoint,
                'settings': Symbols.text_fields_rounded.codePoint,
                'full': Symbols.fullscreen_rounded.codePoint,
                'speak': Symbols.record_voice_over_rounded.codePoint,
              },
              'settings': {
                ...normalizeReaderPreferences({'theme': 'night', 'fontSize': 24, 'columns': 2}),
                'background': '#131313',
                'foreground': '#e7e4dc',
                'dark': true,
                'reduceMotion': true,
                'textScale': 1,
              },
              'labels': {
                'zoomIn': t.fileSources.zoomIn,
                'zoomOut': t.fileSources.zoomOut,
                'zoom': t.fileSources.zoom,
                'actualSize': t.fileSources.actualSize,
                'font': t.fileSources.font,
                'serif': t.fileSources.serif,
                'sans': t.fileSources.sans,
                'mono': t.fileSources.mono,
                'theme': t.fileSources.readerTheme,
                'app': t.fileSources.appTheme,
                'paper': t.fileSources.paper,
                'sepia': t.fileSources.sepia,
                'night': t.fileSources.night,
                'lineHeight': t.fileSources.lineHeight,
                'margin': t.fileSources.margin,
                'justify': t.fileSources.justify,
                'reset': t.fileSources.resetReader,
                'fitPage': t.fileSources.fitPage,
                'fitWidth': t.fileSources.fitWidth,
                'fitHeight': t.comics.fitHeight,
                'comicMode': t.comics.readingMode,
                'paged': t.comics.paged,
                'webtoon': t.comics.webtoon,
                'coverAlone': t.comics.coverAlone,
                'splitWide': t.comics.splitWide,
                'thumbnails': t.comics.thumbnails,
                'comicHelp': '${t.fileSources.readerControlsHelp}\n\n${t.comics.controlsHelp}',
                'retry': t.common.retry,

                'pageLayout': t.fileSources.pageLayout,
                'singlePage': t.fileSources.singlePage,
                'twoPages': t.fileSources.twoPages,
                'readingDirection': t.fileSources.readingDirection,
                'automatic': t.fileSources.automatic,
                'leftToRight': t.fileSources.leftToRight,
                'rightToLeft': t.fileSources.rightToLeft,
                'imagePage': t.fileSources.imagePage,
                'goToPage': t.fileSources.goToPage,
                'goToSection': t.fileSources.goToSection,
                'letterSpacing': t.fileSources.letterSpacing,
                'wordSpacing': t.fileSources.wordSpacing,
                'prev': t.fileSources.previousPage,
                'next': t.fileSources.nextPage,
                'toc': t.fileSources.contents,
                'search': t.fileSources.searchBook,
                'note': t.fileSources.bookmarks,
                'notes': t.fileSources.bookmarks,
                'addNote': t.fileSources.note,
                'bookmark': t.fileSources.bookmark,
                'settings': t.fileSources.readerSettings,
                'full': t.fileSources.fullscreen,
                'speak': t.fileSources.readAloud,
                'close': t.fileSources.close,
                'save': t.fileSources.save,
                'fontSize': t.fileSources.fontSize,
                'columns': t.fileSources.columns,
                'scrolled': t.fileSources.scroll,
                'on': t.fileSources.on,
                'off': t.common.off,
                'error': t.fileSources.errorUnavailable,
                'disconnected': t.fileSources.errorCancelled,
                'noMatches': t.fileSources.noMatches,
                'pageRange': t.fileSources.pageRange(count: '{count}'),
              },
            });
          } catch (error) {
            failure = error;
          }
        } else if (events.first['type'] == 'browserSettings') {
          await server.execute('settings', {
            ...normalizeReaderPreferences(Map<String, dynamic>.from(events.first['settings'] as Map)),
            'background': '#131313',
            'foreground': '#e7e4dc',
            'dark': true,
          });
        }
      },
    );
    final url = (await server.start()).replace(queryParameters: {'external': '1'});
    try {
      final result = await Process.run('node', [
        'tools/store-assets/feature_reader_capture.cjs',
        url.toString(),
        output,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}; bridge: $failure');
      expect(failure, isNull);
    } finally {
      await server.close();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
