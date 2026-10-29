import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'subtitle_retimer.dart';

class SubtitleDictionaryEntry {
  const SubtitleDictionaryEntry(this.term, this.definitions, this.caseSensitive);
  final String term;
  final List<String> definitions;
  final bool caseSensitive;
}

class SubtitleDictionaryPack {
  SubtitleDictionaryPack(this.digest, this.title, this.language, this.license, this.entries, this.bytes) {
    for (final entry in entries) { (byTerm[fold(entry.term)] ??= []).add(entry); }
  }
  final String digest, title, language, license;
  final int bytes;
  final List<SubtitleDictionaryEntry> entries;
  final Map<String, List<SubtitleDictionaryEntry>> byTerm = {};
  String fold(String value) {
    var text = unorm.nfc(value);
    // Dart's default lowercasing does not implement Turkic dotted/dotless I.
    if (const {'tr', 'az'}.contains(language.split('-').first)) text = text.replaceAll('I', 'ı').replaceAll('İ', 'i');
    return unorm.nfc(text.toLowerCase());
  }
  List<SubtitleDictionaryEntry> lookup(String term) => List.unmodifiable(byTerm[fold(term.trim())] ?? const []);
  bool contains(String term) => lookup(term).any((entry) => !entry.caseSensitive || unorm.nfc(term) == entry.term);
}

class SubtitleSpellingCandidate {
  const SubtitleSpellingCandidate(this.cue, this.start, this.end, this.term, this.suggestions);
  final int cue, start, end;
  final String term;
  final List<String> suggestions;
}

class SubtitleSpellingReport {
  const SubtitleSpellingReport(this.candidates, this.words, this.skippedStyled, this.limited);
  final List<SubtitleSpellingCandidate> candidates;
  final int words, skippedStyled;
  final bool limited;
}

/// User-supplied vocabulary, never a claim that an absent word is misspelled.
/// No network, language detection, morphology, or automatic subtitle changes.
class SubtitleDictionaryService {
  SubtitleDictionaryService._();
  static final instance = SubtitleDictionaryService._();
  static const maximumBytes = 8 * 1024 * 1024, maximumPacks = 8;
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  Future<void> _writes = Future.value();
  final Map<String, ({String title, String language, int bytes, int entries})> _saved = {};
  Future<void>? _loading;
  String? _root;
  Map<String, ({String title, String language, int bytes, int entries})> get saved => Map.unmodifiable(_saved);
  Future<void> initialize() => _loading ??= _initialize().catchError((Object error) { _loading = null; throw error; });
  Future<void> _initialize() async {
    _root = p.join((await getApplicationSupportDirectory()).path, 'subtitle_dictionaries_v1');
    final root = Directory(_root!);
    await root.create(recursive: true);
    _saved.clear();
    var count = 0;
    await for (final file in root.list(followLinks: false)) {
      if (++count > 32) throw const FormatException('Dictionary storage contains too many files.');
      if (file is File && RegExp(r'^[a-f0-9]{64}\.json\.partial$').hasMatch(p.basename(file.path))) {
        await file.delete(); continue;
      }
      if (file is! File || p.extension(file.path) != '.json') continue;
      final digest = p.basenameWithoutExtension(file.path);
      if (!_digest.hasMatch(digest)) continue;
      if (_saved.length >= maximumPacks) throw const FormatException('Dictionary storage exceeds eight packs.');
      final pack = await compute(_parse, await _read(file));
      if (pack.digest != digest) throw const FormatException('A saved dictionary digest changed.');
      _remember(pack);
    }
  }
  void _remember(SubtitleDictionaryPack pack) {
    _saved[pack.digest] = (title: pack.title, language: pack.language, bytes: pack.bytes, entries: pack.entries.length);
  }
  Future<T> _serialize<T>(Future<T> Function() body) {
    final pending = _writes.then((_) => body());
    _writes = pending.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return pending;
  }
  static Future<Uint8List> _read(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file ||
        await file.length() > maximumBytes) throw const FormatException('Choose a regular dictionary file up to 8 MiB.');
    final bytes = BytesBuilder(copy: false);
    await for (final part in file.openRead()) {
      if (bytes.length + part.length > maximumBytes) throw const FormatException('Dictionary exceeds 8 MiB.');
      bytes.add(part);
    }
    return bytes.takeBytes();
  }
  Future<SubtitleDictionaryPack> preview(File file) async => compute(_parse, await _read(file));
  Future<SubtitleDictionaryPack> importFile(File file, {required String expectedDigest}) => _serialize(() async {
    await initialize();
    final bytes = await _read(file);
    final pack = await compute(_parse, bytes);
    if (pack.digest != expectedDigest || sha256.convert(bytes).toString() != expectedDigest) {
      throw const FormatException('Dictionary changed after preview. Choose it again.');
    }
    if (_saved.containsKey(pack.digest)) return pack;
    if (_saved.length >= maximumPacks) throw const FormatException('Remove a dictionary before importing another (eight maximum).');
    final target = File(p.join(_root!, '${pack.digest}.json'));
    final staged = File('${target.path}.partial');
    try {
      await staged.writeAsBytes(bytes, flush: true);
      await staged.rename(target.path);
      _remember(pack);
    } finally { if (await staged.exists()) await staged.delete(); }
    return pack;
  });
  Future<SubtitleDictionaryPack> load(String digest) async {
    await initialize();
    if (!_digest.hasMatch(digest) || !_saved.containsKey(digest)) throw StateError('Choose an installed dictionary.');
    final pack = await compute(_parse, await _read(File(p.join(_root!, '$digest.json'))));
    if (pack.digest != digest) throw const FormatException('The dictionary no longer matches its digest.');
    return pack;
  }
  Future<void> remove(String digest) => _serialize(() async {
    await initialize();
    if (!_digest.hasMatch(digest) || !_saved.containsKey(digest)) return;
    await File(p.join(_root!, '$digest.json')).delete(); _saved.remove(digest);
  });
  static SubtitleDictionaryPack _parse(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maximumBytes) throw const FormatException('Dictionary exceeds its size bound.');
    final data = jsonDecode(utf8.decode(bytes));
    bool text(dynamic value, int limit) => value is String && value.trim().isNotEmpty && value.length <= limit &&
        !RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value);
    if (data is! Map || data['schema'] != 1 || !text(data['title'], 100) || !text(data['license'], 16384) ||
        data['language'] is! String || !RegExp(r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}$').hasMatch(data['language']) ||
        data['entries'] is! List || data['entries'].isEmpty || data['entries'].length > 50000) {
      throw const FormatException('Expected a schema-1 dictionary with title, language, attribution and 1–50,000 entries.');
    }
    final entries = <SubtitleDictionaryEntry>[];
    final seen = <String>{};
    for (final row in data['entries']) {
      if (row is! Map || !text(row['term'], 64) || row['term'] != row['term'].trim() ||
          RegExp(r'[\r\n\t]').hasMatch(row['term']) || row['definitions'] is! List || row['definitions'].length > 8 ||
          row['definitions'].any((value) => !text(value, 2000)) ||
          row['caseSensitive'] != null && row['caseSensitive'] is! bool) throw const FormatException('Invalid dictionary entry.');
      final term = unorm.nfc(row['term']);
      if (!seen.add(term)) throw const FormatException('Combine duplicate dictionary terms into one entry.');
      entries.add(SubtitleDictionaryEntry(term, List<String>.unmodifiable(row['definitions']), row['caseSensitive'] == true));
    }
    return SubtitleDictionaryPack(sha256.convert(bytes).toString(), data['title'], data['language'], data['license'],
      List.unmodifiable(entries), bytes.length);
  }

  static Future<SubtitleSpellingReport> check(SubtitleDictionaryPack pack, List<SubtitleCue> cues) => compute(_check, (pack, cues));
  static SubtitleSpellingReport _check((SubtitleDictionaryPack, List<SubtitleCue>) task) {
    final (pack, cues) = task;
    if (cues.length > SubtitleRetimer.maximumCueCount || cues.fold<int>(0, (n, c) => n + c.text.length) > 4 * 1024 * 1024) {
      throw const FormatException('Subtitle exceeds the spelling-review bound.');
    }
    final tokens = RegExp(r"[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*", unicode: true);
    final byLength = <int, List<String>>{};
    for (final term in pack.byTerm.keys) { (byLength[term.runes.length] ??= []).add(term); }
    final cache = <String, List<String>>{};
    final output = <SubtitleSpellingCandidate>[];
    var words = 0, skipped = 0, comparisons = 0;
    var limited = false;
    List<String> suggest(String term) {
      final key = pack.fold(term);
      if (cache.containsKey(key)) return cache[key]!;
      final found = <String>[];
      final letters = key.runes.toList();
      for (final length in [letters.length, letters.length - 1, letters.length + 1]) {
        for (final other in byLength[length] ?? const <String>[]) {
          if (++comparisons > 2000000) { limited = true; break; }
          if (!_oneEdit(letters, other.runes.toList())) continue;
          for (final entry in pack.byTerm[other]!) {
            if (!found.contains(entry.term)) found.add(entry.term);
            if (found.length >= 5) break;
          }
          if (found.length >= 5) break;
        }
        if (found.length >= 5 || comparisons > 2000000) break;
      }
      return cache[key] = List.unmodifiable(found);
    }
    scan: for (var index = 0; index < cues.length; index++) {
      final cue = cues[index];
      // Tag scope, karaoke and drawing syntax never enter spelling replacement.
      if (RegExp(r'<[^>]*>|\{[^}]*\}|\\[A-Za-z]').hasMatch(cue.text)) { skipped++; continue; }
      for (final match in tokens.allMatches(cue.text)) {
        if (++words > 100000 || output.length >= 200 || comparisons > 2000000) { limited = true; break scan; }
        final term = match[0]!;
        if (term.length > 64 || term.runes.length < 2 || pack.contains(term)) continue;
        output.add(SubtitleSpellingCandidate(index, match.start, match.end, term, suggest(term)));
      }
    }
    return SubtitleSpellingReport(List.unmodifiable(output), words, skipped, limited);
  }
  static bool _oneEdit(List<int> a, List<int> b) {
    if ((a.length - b.length).abs() > 1) return false;
    var i = 0, j = 0, edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) { i++; j++; continue; }
      if (++edits > 1) return false;
      // Adjacent transposition counts as one edit.
      if (a.length == b.length && i + 1 < a.length && a[i] == b[j + 1] && a[i + 1] == b[j]) { i += 2; j += 2; }
      else if (a.length > b.length) { i++; } else if (b.length > a.length) { j++; } else { i++; j++; }
    }
    return edits + (a.length - i) + (b.length - j) <= 1;
  }
}
