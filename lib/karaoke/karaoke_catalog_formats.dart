import 'dart:convert';

import 'package:xml/xml.dart';

import 'karaoke_models.dart';

/// Serializes catalog files. Markup and schema text here belongs to the
/// exported document format, not to Flutter's user interface.
class KaraokeCatalogFormats {
  static String xml(List<KaraokeTrack> songs) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'songbook',
      attributes: const {'version': '1'},
      nest: () {
        for (final song in songs) {
          builder.element(
            'song',
            attributes: {'id': song.id},
            nest: () {
              builder.element('title', nest: () => builder.text(song.title));
              builder.element('artist', nest: () => builder.text(song.artist));
              builder.element('language', nest: () => builder.text(song.language));
              builder.element('genre', nest: () => builder.text(song.genre));
              builder.element('year', nest: () => builder.text(song.year?.toString() ?? ''));
              builder.element('difficulty', nest: () => builder.text(song.difficulty?.toString() ?? ''));
              builder.element('producer', nest: () => builder.text(song.producer));
            },
          );
        }
      },
    );
    return builder.buildDocument().toXmlString();
  }

  static String html({
    required String title,
    required String countLabel,
    required String generated,
    required List<String> columns,
    required List<List<String>> rows,
  }) {
    final escape = const HtmlEscape(HtmlEscapeMode.element).convert;
    final output = StringBuffer()
      ..write('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">')
      ..write('<title>${escape(title)}</title>')
      ..write('<style>body{font:14px system-ui;margin:24px}table{border-collapse:collapse;width:100%}')
      ..write('th,td{text-align:left;border-bottom:1px solid #bbb;padding:8px}')
      ..write('thead{display:table-header-group}tr{break-inside:avoid}')
      ..write('@media print{body{margin:0}td:first-child,th:first-child{display:none}}</style>')
      ..write('<h1>${escape(title)}</h1><p>${escape(countLabel)} · ${escape(generated)}</p>')
      ..write('<table><thead><tr>');
    for (final column in columns) {
      output.write('<th>${escape(column)}</th>');
    }
    output.write('</tr></thead><tbody>');
    for (final row in rows.skip(1)) {
      output.write('<tr>');
      for (final value in row) {
        output.write('<td>${escape(value)}</td>');
      }
      output.write('</tr>');
    }
    output.write('</tbody></table>');
    return output.toString();
  }
}
