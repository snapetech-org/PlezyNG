import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uuid/uuid.dart';
import '../i18n/strings.g.dart' as l10n;
import 'karaoke_catalog_formats.dart';
import 'karaoke_models.dart';
import 'karaoke_session.dart';

/// User-selected files are the transport. Credentials, room grants, recordings
/// and media-server locators never enter portable collection metadata.
class KaraokeCollections {
  KaraokeCollections(this.session);
  final KaraokeSession session;
  String digest(KaraokeTrack track) => sha256
      .convert(utf8.encode(jsonEncode((track.assets.map((a) => '${a.path}:${a.sha256}').toList()..sort()))))
      .toString();
  Map<String, dynamic> snapshot() => {
    'schema': 'plezyng.karaoke-collection.v1',
    'id': const Uuid().v4(),
    'created': DateTime.now().toUtc().toIso8601String(),
    'singers': session.singers.map((s) => s.toJson()).toList(),
    'setlists': session.setlists,
    'catalog': [
      for (final t in session.catalog.values)
        {
          'id': t.id,
          'songId': t.songId,
          'title': t.title,
          'artist': t.artist,
          'language': t.language,
          'genre': t.genre,
          'year': t.year,
          'difficulty': t.difficulty,
          'producer': t.producer,
          'parts': t.parts.toList(),
          'packageDigest': digest(t),
        },
    ],
  };
  Future<void> export(String destination) async {
    await File('$destination.pending').writeAsString(jsonEncode(snapshot()), flush: true);
    await File('$destination.pending').rename(destination);
  }

  Future<Map<String, dynamic>> read(String path) async {
    final file = File(path);
    if (await file.length() > 8 * 1024 * 1024) {
      throw const FormatException('Collection exceeds 8 MiB');
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['schema'] != 'plezyng.karaoke-collection.v1') {
      throw const FormatException('Unsupported collection');
    }
    final people = data['singers'] as List, lists = data['setlists'] as Map, tracks = data['catalog'] as List;
    if (people.length > 64 || lists.length > 100 || tracks.length > 2000) {
      throw const FormatException('Collection limits exceeded');
    }
    final ids = <String>{};
    for (final raw in people) {
      final s = KaraokeSinger.fromJson(Map<String, dynamic>.from(raw as Map));
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(s.id) ||
          !ids.add(s.id) ||
          s.name.isEmpty ||
          s.name.length > 80 ||
          s.favorites.length > 2000 ||
          s.history.length > 500 ||
          s.keys.length > 2000 ||
          s.tempos.length > 2000 ||
          s.keys.values.any((v) => !v.isFinite || v.abs() > 12) ||
          s.tempos.values.any((v) => !v.isFinite || v < .5 || v > 2)) {
        throw const FormatException('Invalid singer preferences');
      }
    }
    for (final e in lists.entries) {
      if (e.key is! String ||
          (e.key as String).isEmpty ||
          (e.key as String).length > 100 ||
          e.value is! List ||
          (e.value as List).length > 256 ||
          (e.value as List).any((v) => v is! String)) {
        throw const FormatException('Invalid setlist');
      }
    }
    for (final raw in tracks) {
      final t = raw as Map, local = session.catalog[t['id']];
      if (local != null && digest(local) != t['packageDigest']) {
        throw StateError('Rendition ${t['title']} has different assets. Import it as a separate rendition first.');
      }
    }
    return data;
  }

  Future<void> merge(Map<String, dynamic> data, {required bool preferIncoming}) async {
    if (session.hasPerformance) {
      throw StateError('Import collection preferences between performances');
    }
    await session.store.write('collection-before-import', snapshot());
    for (final raw in data['singers'] as List) {
      final incoming = KaraokeSinger.fromJson(Map<String, dynamic>.from(raw as Map));
      final index = session.singers.indexWhere((s) => s.id == incoming.id);
      if (index < 0) {
        if (session.singers.length >= 64) {
          throw StateError('Room singer limit reached');
        }
        session.singers.add(incoming);
      } else if (preferIncoming) {
        session.singers[index] = incoming;
      }
    }
    for (final e in (data['setlists'] as Map).entries) {
      if (preferIncoming || !session.setlists.containsKey(e.key)) {
        session.setlists[e.key as String] = List<String>.from(e.value as List);
      }
    }
    await session.host('settings');
  }

  Future<void> catalog(String destination, String format) async {
    final songs = session.search('');
    const columns = [
      'Rendition',
      'Title',
      'Artist',
      'Language',
      'Genre',
      'Year',
      'Difficulty',
      'Producer',
      'Parts',
      'Package assets',
      'Reviewed chart',
    ];
    final rows = [
      columns,
      for (final s in songs)
        [
          s.id,
          s.title,
          s.artist,
          s.language,
          s.genre,
          '${s.year ?? ''}',
          '${s.difficulty ?? ''}',
          s.producer,
          s.parts.join(' / '),
          '${s.assets.length}',
          s.canScore ? 'Yes' : 'No',
        ],
    ];
    String csv(String s) {
      if (RegExp(r'^[=+@\-\t\r]').hasMatch(s)) {
        s = "'$s";
      }
      return '"${s.replaceAll('"', '""')}"';
    }

    final songbookTitle = session.banner.isEmpty ? l10n.t.karaokeUi.karaokeTools : session.banner;

    if (format == 'pdf') {
      final bytes = await _songbookPdf(songs);
      await File(destination).writeAsBytes(bytes, flush: true);
      return;
    }

    final output = switch (format) {
      'csv' => rows.map((r) => r.map(csv).join(',')).join('\r\n'),
      'xml' => KaraokeCatalogFormats.xml(songs),
      'html' => KaraokeCatalogFormats.html(
        title: songbookTitle,
        countLabel: l10n.t.karaokeUi.songs(value1: songs.length.toString()),
        generated: DateTime.now().toIso8601String().substring(0, 10),
        columns: [
          columns[0],
          l10n.t.metadataEdit.title,
          l10n.t.common.mediaKind.artist,
          l10n.t.settings.language,
          l10n.t.libraries.filterCategories.genre,
          l10n.t.libraries.filterCategories.year,
          l10n.t.karaokeUi.allDifficultyLevels,
          l10n.t.metadataEdit.producer,
          l10n.t.karaokeUi.assignSingersAndParts,
          columns[9],
          l10n.t.karaokeUi.scoredCharts,
        ],
        rows: rows,
      ),
      _ => throw UnsupportedError('Catalog format unavailable'),
    };
    await File(destination).writeAsString(output, flush: true);
  }

  Future<List<int>> _songbookPdf(List<KaraokeTrack> songs) async {
    if (songs.length > 5000) {
      throw StateError('PDF songbooks are limited to 5,000 renditions. Export CSV or XML for a larger catalog.');
    }
    final regularFont = pw.Font.ttf((await rootBundle.load('assets/go-noto-current-regular.ttf')).buffer.asByteData());
    final hangulFont = pw.Font.ttf((await rootBundle.load('assets/go-noto-kurrent-hangul.ttf')).buffer.asByteData());
    final title = session.banner.isEmpty ? l10n.t.karaokeUi.karaokeTools : session.banner;
    final generated = DateTime.now().toIso8601String().substring(0, 10);
    final document = pw.Document(title: title, author: 'Pleazyng');

    pw.Widget cell(String value, {bool bold = false, double fontSize = 9}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: pw.Text(
        value,
        style: pw.TextStyle(fontSize: fontSize, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal),
      ),
    );

    String details(KaraokeTrack song) => [
      if (song.language.isNotEmpty) '${l10n.t.settings.language}: ${song.language}',
      if (song.genre.isNotEmpty) '${l10n.t.libraries.filterCategories.genre}: ${song.genre}',
      if (song.year != null) '${l10n.t.libraries.filterCategories.year}: ${song.year}',
      if (song.difficulty != null) l10n.t.karaokeUi.difficulty5(value1: '${song.difficulty}/5'),
      if (song.producer.isNotEmpty) '${l10n.t.metadataEdit.producer}: ${song.producer}',
      if (song.parts.isNotEmpty) '${l10n.t.karaokeUi.assignSingersAndParts}: ${song.parts.join(' / ')}',
      if (song.canScore) l10n.t.karaokeUi.scoredCharts,
    ].join(' · ');

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: pw.EdgeInsets.all(PdfPageFormat.mm * 12),
        maxPages: 500,
        theme: pw.ThemeData.withFont(base: regularFont, bold: regularFont, fontFallback: [hangulFont]),
        header: (_) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Text('${l10n.t.app.title} · $title', style: pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('${context.pageNumber}', style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        ),
        build: (_) => [
          pw.Text(title, style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text(
            '${l10n.t.karaokeUi.songs(value1: songs.length.toString())} · $generated',
            style: const pw.TextStyle(fontSize: 10),
          ),
          pw.SizedBox(height: 14),
          if (songs.isNotEmpty)
            pw.Table(
              border: pw.TableBorder(
                horizontalInside: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
                bottom: pw.BorderSide(color: PdfColors.grey500, width: 0.8),
              ),
              columnWidths: const {0: pw.FlexColumnWidth(3), 1: pw.FlexColumnWidth(2), 2: pw.FlexColumnWidth(4)},
              defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                  children: [
                    cell(l10n.t.metadataEdit.title, bold: true),
                    cell(l10n.t.common.mediaKind.artist, bold: true),
                    cell(l10n.t.discover.findNext.details, bold: true),
                  ],
                ),
                for (final song in songs)
                  pw.TableRow(
                    children: [cell(song.title, bold: true), cell(song.artist), cell(details(song), fontSize: 8)],
                  ),
              ],
            ),
        ],
      ),
    );
    return document.save();
  }

  Future<List<String>> audit(Iterable<String> ids) async {
    final problems = <String>[];
    for (final id in ids.toSet()) {
      final song = session.catalog[id];
      if (song == null) {
        problems.add('$id: rendition missing');
        continue;
      }
      if (song.assets.isEmpty) {
        problems.add('${song.title}: source requires its server');
        continue;
      }
      for (final error in await session.packages.verify(song)) {
        problems.add('${song.title}: $error');
      }
      if (!song.hasLocalAudio && !song.assets.any((a) => a.kind == KaraokeAssetKind.video)) {
        problems.add('${song.title}: render MIDI before offline performance');
      }
    }
    return problems;
  }
}
