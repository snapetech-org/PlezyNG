import '../services/file_picker_service.dart';
import '../widgets/app_icon.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart' as l10n;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../media/lyrics.dart';
import '../services/subtitle_revision_service.dart';
import '../services/subtitle_retimer.dart';
import '../services/subtitle_word_timing.dart';
import 'karaoke_formats.dart';
import 'karaoke_models.dart';
import 'karaoke_session.dart';

/// Edits a derived document; original lyric/ASS/CDG assets remain untouched.
class KaraokeEditor extends StatefulWidget {
  const KaraokeEditor({super.key, required this.session, required this.track});
  final KaraokeSession session;
  final KaraokeTrack track;
  @override
  State<KaraokeEditor> createState() => _KaraokeEditorState();
}

class _KaraokeEditorState extends State<KaraokeEditor> {
  late KaraokeTrack _track = widget.track;
  final List<Map<String, dynamic>> _undo = [], _redo = [];
  List<List<double>> _waveform = [];
  bool _busy = false;
  int _tap = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_loadWaveform());
  }

  Future<void> _loadWaveform() async {
    try {
      final key = 'waveform-${sha256.convert(utf8.encode(_track.id))}';
      final saved = await widget.session.store.read(key);
      if (saved?['schema'] != 1 || saved?['renditionId'] != _track.id || saved?['waveform'] is! Map) {
        return;
      }
      final raw = (saved!['waveform'] as Map)['peaks'];
      if (raw is! List || raw.length > 100000) {
        throw const FormatException('Invalid waveform data');
      }
      final peaks = <List<double>>[];
      for (final entry in raw) {
        if (entry is! List || entry.length != 2 || entry.any((v) => v is! num)) {
          throw const FormatException('Invalid waveform peak');
        }
        final low = (entry[0] as num).toDouble(), high = (entry[1] as num).toDouble();
        if (!low.isFinite || !high.isFinite || low < -1 || high > 1 || low > high) {
          throw const FormatException('Invalid waveform amplitude');
        }
        peaks.add([low, high]);
      }
      if (mounted) {
        setState(() => _waveform = peaks);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _waveform = []);
      }
    }
  }

  void _edit(KaraokeTrack value) {
    _undo.add(_track.toJson());
    if (_undo.length > 40) {
      _undo.removeAt(0);
    }
    _redo.clear();
    setState(() => _track = value);
  }

  void _restore(bool undo) {
    final from = undo ? _undo : _redo, to = undo ? _redo : _undo;
    if (from.isEmpty) {
      return;
    }
    to.add(_track.toJson());
    setState(() => _track = KaraokeTrack.fromJson(from.removeLast()));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _line(int? index) async {
    final original = index == null ? null : _track.lyrics.lines[index];
    final fields = {
      'text': TextEditingController(text: original?.text ?? ''),
      'startMs': TextEditingController(text: '${original?.startMs ?? 0}'),
      'endMs': TextEditingController(text: original?.endMs?.toString() ?? ''),
      'part': TextEditingController(text: original?.part ?? ''),
      'translation': TextEditingController(text: original?.translation ?? ''),
      'pronunciation': TextEditingController(text: original?.pronunciation ?? ''),
      'spans': TextEditingController(
        text: const JsonEncoder.withIndent('  ').convert(original?.spans.map((s) => s.toJson()).toList() ?? []),
      ),
    };
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t.karaokeUi.lyricTiming),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final e in fields.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: TextField(
                      controller: e.value,
                      decoration: InputDecoration(
                        labelText: e.key == 'spans' ? 'Word/syllable timing (JSON: text, startMs, endMs, unit)' : e.key,
                      ),
                      minLines: e.key == 'spans' ? 4 : 1,
                      maxLines: e.key == 'spans' ? 10 : 3,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t.auth.quickConnectCancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.t.discover.findNext.apply)),
        ],
      ),
    );
    try {
      if (save != true) {
        return;
      }
      final j = <String, dynamic>{
        'text': fields['text']!.text,
        'startMs': int.parse(fields['startMs']!.text),
        if (fields['endMs']!.text.trim().isNotEmpty) 'endMs': int.parse(fields['endMs']!.text),
        for (final key in ['part', 'translation', 'pronunciation'])
          if (fields[key]!.text.isNotEmpty) key: fields[key]!.text,
        'spans': jsonDecode(fields['spans']!.text),
      };
      final lines = _track.lyrics.lines.toList();
      if (index == null) {
        lines.add(LyricLine.fromJson(j));
      } else {
        lines[index] = LyricLine.fromJson(j);
      }
      lines.sort((a, b) => (a.startMs ?? 0).compareTo(b.startMs ?? 0));
      _edit(_track.withLyrics(Lyrics(synced: lines.any((l) => l.startMs != null), lines: lines), reviewed: false));
    } finally {
      for (final c in fields.values) {
        c.dispose();
      }
    }
  }

  Future<void> _note(int? index) async {
    final n = index == null ? null : _track.notes[index];
    final start = TextEditingController(text: '${n?.startMs ?? widget.session.positionMs.value}');
    final end = TextEditingController(text: '${n?.endMs ?? widget.session.positionMs.value + 500}');
    final pitch = TextEditingController(text: '${n?.midi ?? 60}'),
        part = TextEditingController(text: n?.part ?? '1'),
        text = TextEditingController(text: n?.text ?? '');
    var freestyle = n?.freestyle ?? false, golden = n?.golden ?? false;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.t.karaokeUi.referenceNote),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final pair in [
                    (start, 'Start (ms)'),
                    (end, 'End (ms)'),
                    (pitch, 'MIDI pitch'),
                    (part, 'Singer part'),
                    (text, 'Syllable'),
                  ])
                    TextField(
                      controller: pair.$1,
                      decoration: InputDecoration(labelText: pair.$2),
                    ),
                  CheckboxListTile(
                    title: Text(l10n.t.karaokeUi.freestyleNotScored),
                    value: freestyle,
                    onChanged: (v) => update(() => freestyle = v!),
                  ),
                  CheckboxListTile(
                    title: Text(l10n.t.karaokeUi.goldenNote),
                    value: golden,
                    onChanged: (v) => update(() => golden = v!),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t.auth.quickConnectCancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.t.discover.findNext.apply)),
          ],
        ),
      ),
    );
    try {
      if (save != true) {
        return;
      }
      final note = KaraokeNote.fromJson({
        'startMs': int.parse(start.text),
        'endMs': int.parse(end.text),
        'midi': double.parse(pitch.text),
        'part': part.text,
        'text': text.text,
        'freestyle': freestyle,
        'golden': golden,
      });
      final notes = _track.notes.toList();
      if (index == null) {
        notes.add(note);
      } else {
        notes[index] = note;
      }
      notes.sort((a, b) => a.startMs.compareTo(b.startMs));
      _edit(_track.withLyrics(_track.lyrics, chart: notes, reviewed: false));
    } finally {
      for (final c in [start, end, pitch, part, text]) {
        c.dispose();
      }
    }
  }

  void _tapTiming() {
    if (_tap >= _track.lyrics.lines.length) {
      return;
    }
    final lines = _track.lyrics.lines.toList(), at = widget.session.positionMs.value;
    final old = lines[_tap];
    lines[_tap] = LyricLine(
      text: old.text,
      startMs: at,
      part: old.part,
      translation: old.translation,
      pronunciation: old.pronunciation,
    );
    if (_tap > 0 && lines[_tap - 1].startMs != null && lines[_tap - 1].startMs! < at) {
      lines[_tap - 1] = LyricLine.fromJson(lines[_tap - 1].toJson()..['endMs'] = at);
    }
    _edit(_track.withLyrics(Lyrics(synced: true, lines: lines), reviewed: false));
    _tap++;
  }

  Future<void> _section(int? index) async {
    final old = index == null ? null : _track.sections[index];
    final name = TextEditingController(text: old?.name ?? 'Verse'),
        start = TextEditingController(text: '${old?.startMs ?? widget.session.positionMs.value}'),
        end = TextEditingController(text: '${old?.endMs ?? widget.session.positionMs.value + 30000}');
    var instrumental = old?.instrumental ?? false;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.t.karaokeUi.sectionTiming),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 80,
                decoration: InputDecoration(labelText: l10n.t.fileSources.name),
              ),
              TextField(
                controller: start,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l10n.t.subtitleAiUi.startMs),
              ),
              TextField(
                controller: end,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l10n.t.subtitleAiUi.endMs),
              ),
              CheckboxListTile(
                title: Text(l10n.t.karaokeUi.instrumentalIntro),
                value: instrumental,
                onChanged: (v) => update(() => instrumental = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t.auth.quickConnectCancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.t.common.save)),
          ],
        ),
      ),
    );
    try {
      if (save != true) {
        return;
      }
      final section = KaraokeSection.fromJson({
        'name': name.text,
        'startMs': int.parse(start.text),
        'endMs': int.parse(end.text),
        'instrumental': instrumental,
      });
      final sections = _track.sections.toList();
      if (index == null) {
        sections.add(section);
      } else {
        sections[index] = section;
      }
      sections.sort((a, b) => a.startMs.compareTo(b.startMs));
      _edit(
        KaraokeTrack.fromJson(
          _track.toJson()
            ..['sections'] = sections.map((v) => v.toJson()).toList()
            ..['chartReviewed'] = false,
        ),
      );
    } finally {
      name.dispose();
      start.dispose();
      end.dispose();
    }
  }

  Future<void> _importLyrics() => _run(() async {
    final choice = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'lrc', 'vtt', 'ttml'],
    );
    final path = choice?.files.single.path;
    if (path == null) {
      return;
    }
    final file = File(path);
    if (await file.length() > 8 * 1024 * 1024) {
      throw const FormatException('Lyric import too large');
    }
    final ext = path.substring(path.lastIndexOf('.'));
    final result = KaraokeFormats.parse(await file.readAsString(), ext);
    final digest = (await sha256.bind(file.openRead()).first).toString(),
        assetPath = 'originals/$digest${ext.toLowerCase()}';
    if (!_track.assets.any((a) => a.sha256 == digest)) {
      final destination = await widget.session.store.asset(_track.id, assetPath);
      await destination.parent.create(recursive: true);
      await file.copy(destination.path);
      final asset = KaraokeAsset(
        path: assetPath,
        sha256: digest,
        bytes: await destination.length(),
        kind: KaraokeAssetKind.original,
      );
      _track = KaraokeTrack.fromJson(
        _track.toJson()..['assets'] = [..._track.assets.map((a) => a.toJson()), asset.toJson()],
      );
    }
    _edit(_track.withLyrics(result.lyrics, chart: result.notes.isEmpty ? null : result.notes, reviewed: false));
    if (result.warnings.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.warnings.join('\n'))));
    }
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(l10n.t.karaokeUi.edit(value1: (_track.title).toString())),
      actions: [
        IconButton(
          tooltip: l10n.t.discover.findNext.undo,
          onPressed: _undo.isEmpty ? null : () => _restore(true),
          icon: const AppIcon(Symbols.undo_rounded),
        ),
        IconButton(
          tooltip: l10n.t.karaokeUi.redo,
          onPressed: _redo.isEmpty ? null : () => _restore(false),
          icon: const AppIcon(Symbols.redo_rounded),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final timed = _track.lyrics.lines
                      .where((l) => l.startMs != null && l.endMs != null && l.endMs! > l.startMs!)
                      .toList();
                  if (timed.isNotEmpty) {
                    await SubtitleRevisionService.saveRevision(
                      identity: SubtitleRevisionIdentity(
                        profileId: widget.session.store.profileId,
                        serverId: 'karaoke',
                        ratingKey: _track.id,
                        mediaIndex: 0,
                      ),
                      operation: 'karaoke-editor',
                      languageCode: _track.language,
                      cues: [
                        for (var i = 0; i < timed.length; i++)
                          SubtitleCue(
                            index: i + 1,
                            startMs: timed[i].startMs!,
                            endMs: timed[i].endMs!,
                            text: timed[i].text,
                          ),
                      ],
                      wordTimings: [
                        for (var i = 0; i < timed.length; i++)
                          for (final span in timed[i].spans)
                            if (span.endMs != null && span.endMs! > span.startMs)
                              SubtitleWordTiming(
                                startMs: span.startMs,
                                endMs: span.endMs!,
                                text: span.text,
                                confidence: 0,
                                unit: SubtitleWordTimingUnit.word,
                                cueIndex: i + 1,
                              ),
                      ],
                    );
                  }
                  await widget.session.addTrack(_track);
                  await widget.session.store.write('edit-${sha256.convert(utf8.encode(_track.id)).toString()}', {
                    'schema': 1,
                    'renditionId': _track.id,
                    'revisions': _undo,
                    'current': _track.toJson(),
                  });
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                }),
          child: Text(l10n.t.common.save),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) const LinearProgressIndicator(),
        Text(l10n.t.karaokeUi.originalFilesStayUnchangedReviewImportedOrGeneratedNotes),
        if (_waveform.isNotEmpty) ...[
          Text(l10n.t.karaokeUi.waveformTapToSeekDuringThisRendition, style: Theme.of(context).textTheme.titleLarge),
          ValueListenableBuilder<int>(
            valueListenable: widget.session.positionMs,
            builder: (context, position, _) => LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  final duration = widget.session.durationMs > 0 ? widget.session.durationMs : _track.durationMs;
                  if (widget.session.track?.id == _track.id &&
                      widget.session.hasPerformance &&
                      duration > 0 &&
                      constraints.maxWidth > 0) {
                    var target = (details.localPosition.dx / constraints.maxWidth * duration).round();
                    if (target < 0) {
                      target = 0;
                    }
                    if (target > duration) {
                      target = duration;
                    }
                    _run(() => widget.session.seek(target));
                  }
                },
                child: CustomPaint(
                  size: Size(constraints.maxWidth, 96),
                  painter: _WaveformLane(
                    _waveform,
                    playhead: widget.session.track?.id == _track.id && widget.session.durationMs > 0
                        ? position / widget.session.durationMs
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ] else
          Text(l10n.t.karaokeUi.generateAWaveformFromPrepareToSeeTheAudio),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(onPressed: _importLyrics, child: Text(l10n.t.karaokeUi.importLyricsUltraStar)),
            OutlinedButton(onPressed: () => _run(() => _line(null)), child: Text(l10n.t.mpvConfig.addLine)),
            OutlinedButton(onPressed: () => _run(() => _note(null)), child: Text(l10n.t.karaokeUi.addNote)),
            OutlinedButton(
              onPressed: widget.session.track?.id != _track.id
                  ? null
                  : () => _run(() async {
                      _tapTiming();
                    }),
              child: Text(l10n.t.karaokeUi.tapLine(value1: (_tap + 1).toString())),
            ),
            TextButton(onPressed: () => setState(() => _tap = 0), child: Text(l10n.t.karaokeUi.resetTapCursor)),
            for (final format in ['lrc', 'vtt'])
              OutlinedButton(
                onPressed: () => _run(() async {
                  final output = format == 'lrc'
                      ? KaraokeFormats.exportLrc(_track.lyrics)
                      : KaraokeFormats.exportVtt(_track.lyrics);
                  final path = await FilePickerService.instance.saveFile(fileName: '${_track.id}.$format');
                  if (path != null) {
                    await File(path).writeAsString(output);
                  }
                }),
                child: Text(l10n.t.karaokeUi.export(value1: (format.toUpperCase()).toString())),
              ),
          ],
        ),
        Text(l10n.t.karaokeUi.lyricOffsetMs(value1: (_track.lyricOffsetMs).toString())),
        Slider(
          min: -10000,
          max: 10000,
          divisions: 400,
          value: _track.lyricOffsetMs.toDouble().clamp(-10000, 10000),
          onChanged: (v) => setState(() => _track = _track.withLyrics(_track.lyrics, offsetMs: v.round())),
        ),
        CheckboxListTile(
          title: Text(l10n.t.karaokeUi.iAuditionedThisChartAndVerifiedTheNotesParts),
          subtitle: Text(l10n.t.karaokeUi.enablesReferenceBasedScoringForThisLocalRevision),
          value: _track.chartReviewed,
          onChanged: _track.notes.isEmpty ? null : (v) => _edit(_track.withLyrics(_track.lyrics, reviewed: v)),
        ),
        if (_track.notes.isNotEmpty) SizedBox(height: 180, child: CustomPaint(painter: _NoteLane(_track.notes))),
        Text(l10n.t.karaokeUi.sectionsAndMedleyCues, style: Theme.of(context).textTheme.titleLarge),
        OutlinedButton(
          onPressed: () => _section(null),
          child: Text(l10n.t.karaokeUi.addSectionFromCurrentPlaybackTimes),
        ),
        for (var i = 0; i < _track.sections.length; i++)
          ListTile(
            title: Text(_track.sections[i].name),
            subtitle: Text(
              '${_track.sections[i].startMs}–${_track.sections[i].endMs} ms · ${_track.sections[i].instrumental ? 'instrumental' : 'sung'}',
            ),
            onTap: () => _section(i),
            trailing: IconButton(
              onPressed: () {
                final sections = _track.sections.toList()..removeAt(i);
                _edit(KaraokeTrack.fromJson(_track.toJson()..['sections'] = sections.map((v) => v.toJson()).toList()));
              },
              icon: const AppIcon(Symbols.delete_outline_rounded),
            ),
          ),
        Text(l10n.t.fileInfo.lyrics, style: Theme.of(context).textTheme.titleLarge),
        for (var i = 0; i < _track.lyrics.lines.length; i++)
          ListTile(
            title: Text(_track.lyrics.lines[i].text),
            subtitle: Text(
              '${_track.lyrics.lines[i].startMs ?? 'untimed'} – ${_track.lyrics.lines[i].endMs ?? '?'} ms · ${_track.lyrics.lines[i].part ?? 'all'}',
            ),
            onTap: () => _run(() => _line(i)),
            trailing: IconButton(
              tooltip: l10n.t.karaokeUi.deleteLine,
              onPressed: () {
                final lines = _track.lyrics.lines.toList()..removeAt(i);
                _edit(_track.withLyrics(Lyrics(synced: _track.lyrics.synced, lines: lines), reviewed: false));
              },
              icon: const AppIcon(Symbols.delete_outline_rounded),
            ),
          ),
        Text(l10n.t.karaokeUi.referenceNotes, style: Theme.of(context).textTheme.titleLarge),
        for (var i = 0; i < _track.notes.length; i++)
          ListTile(
            title: Text(
              l10n.t.karaokeUi.midi(
                value1: (_track.notes[i].text).toString(),
                value2: (_track.notes[i].midi).toString(),
                value3: (_track.notes[i].part).toString(),
              ),
            ),
            subtitle: Text('${_track.notes[i].startMs} – ${_track.notes[i].endMs} ms'),
            onTap: () => _run(() => _note(i)),
            trailing: IconButton(
              tooltip: l10n.t.karaokeUi.deleteNote,
              onPressed: () {
                final notes = _track.notes.toList()..removeAt(i);
                _edit(_track.withLyrics(_track.lyrics, chart: notes, reviewed: false));
              },
              icon: const AppIcon(Symbols.delete_outline_rounded),
            ),
          ),
      ],
    ),
  );
}

class _NoteLane extends CustomPainter {
  _NoteLane(this.notes);
  final List<KaraokeNote> notes;
  @override
  void paint(Canvas canvas, Size size) {
    final end = notes.fold<int>(1, (v, n) => n.endMs > v ? n.endMs : v), paint = Paint();
    for (final n in notes) {
      paint.color = n.freestyle
          ? Colors.grey
          : n.part == '2'
          ? Colors.cyan
          : Colors.amber;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            n.startMs / end * size.width,
            (1 - n.midi / 127) * size.height,
            ((n.endMs - n.startMs) / end * size.width).clamp(2, size.width),
            5,
          ),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_NoteLane old) => old.notes != notes;
}

class _WaveformLane extends CustomPainter {
  _WaveformLane(this.peaks, {this.playhead});
  final List<List<double>> peaks;
  final double? playhead;
  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }
    final paint = Paint()
      ..color = Colors.lightBlueAccent
      ..strokeWidth = 1.2;
    final center = size.height / 2, width = size.width.ceil();
    for (var x = 0; x < width; x++) {
      var start = (x / width * peaks.length).floor();
      if (start < 0) {
        start = 0;
      }
      if (start >= peaks.length) {
        start = peaks.length - 1;
      }
      var end = ((x + 1) / width * peaks.length).ceil();
      if (end < start + 1) {
        end = start + 1;
      }
      if (end > peaks.length) {
        end = peaks.length;
      }
      var low = 0.0, high = 0.0;
      for (var i = start; i < end; i++) {
        low = math.min(low, peaks[i][0]).toDouble();
        high = math.max(high, peaks[i][1]).toDouble();
      }
      canvas.drawLine(Offset(x.toDouble(), center - high * center), Offset(x.toDouble(), center - low * center), paint);
    }
    if (playhead != null && playhead!.isFinite) {
      final x = (playhead!.clamp(0.0, 1.0) * size.width).toDouble();
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Colors.amber
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformLane old) => old.peaks != peaks || old.playhead != playhead;
}
