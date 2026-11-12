import '../i18n/strings.g.dart' as l10n;
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_icon.dart';
import '../media/lyrics.dart';
import '../mpv/video.dart';
import 'karaoke_analysis.dart';
import 'cdg_decoder.dart';
import 'karaoke_models.dart';
import 'karaoke_session.dart';
import 'karaoke_strings.dart';

class KaraokeStage extends StatefulWidget {
  const KaraokeStage({super.key, required this.session});
  final KaraokeSession session;
  @override
  State<KaraokeStage> createState() => _KaraokeStageState();
}

class _KaraokeStageState extends State<KaraokeStage> {
  String? _id;
  CdgDecoder? _cdg;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(KaraokeStage old) {
    super.didUpdateWidget(old);
    _load();
  }

  Future<void> _load() async {
    final song = widget.session.track;
    if (song?.id == _id) {
      return;
    }
    _id = song?.id;
    _cdg = null;
    final asset = song?.assets.where((a) => a.kind == KaraokeAssetKind.cdg).firstOrNull;
    if (song == null || asset == null) {
      return;
    }
    try {
      final file = await widget.session.store.asset(song.id, asset.path);
      if (await file.length() > 64 * 1024 * 1024) {
        throw const FormatException('CD+G exceeds renderer limit');
      }
      final decoder = CdgDecoder(await file.readAsBytes());
      if (mounted && _id == song.id) {
        setState(() => _cdg = decoder);
      }
    } catch (e) {
      widget.session.report(e);
    }
  }

  Future<void> _correctAnalysis(KaraokeTrack track) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.session.loadAnalysis(track.id);
    if (!mounted) return;
    final current = widget.session.analysis[track.id];
    final key = TextEditingController(text: current?['key']?.toString() ?? '');
    final bpm = TextEditingController(text: current?['bpm']?.toString() ?? '');
    final chords = TextEditingController(text: KaraokeAnalysis.chordLines(current));
    try {
      final corrections = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialogContext) {
          String? validationError;
          return StatefulBuilder(
            builder: (dialogContext, updateDialog) => AlertDialog(
              title: Text(l10n.t.karaokeUi.correctAnalysis),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l10n.t.karaokeUi.analysisCorrectionsDoNotCertifyScoring),
                      const SizedBox(height: 16),
                      TextField(
                        controller: key,
                        maxLength: 32,
                        decoration: InputDecoration(labelText: l10n.t.karaokeUi.analysisKey),
                      ),
                      TextField(
                        controller: bpm,
                        maxLength: 7,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: l10n.t.karaokeUi.analysisTempoBpm),
                      ),
                      TextField(
                        controller: chords,
                        minLines: 3,
                        maxLines: 8,
                        maxLength: 2 * 1024 * 1024,
                        decoration: InputDecoration(labelText: l10n.t.karaokeUi.chordTimeline),
                      ),
                      if (validationError != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            validationError!,
                            style: TextStyle(color: Theme.of(dialogContext).colorScheme.error),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(l10n.t.common.cancel)),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, <String, dynamic>{}),
                  child: Text(l10n.t.karaokeUi.useAnalysisEstimates),
                ),
                FilledButton(
                  onPressed: () {
                    try {
                      Navigator.pop(
                        dialogContext,
                        KaraokeAnalysis.correctionsFromFields(key: key.text, bpm: bpm.text, chords: chords.text),
                      );
                    } catch (error) {
                      updateDialog(() => validationError = error.toString());
                    }
                  },
                  child: Text(l10n.t.common.save),
                ),
              ],
            ),
          );
        },
      );
      if (corrections == null || !mounted) return;
      await widget.session.saveAnalysisCorrections(track.id, corrections);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      key.dispose();
      bpm.dispose();
      chords.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session, song = s.track;
    return ColoredBox(
      color: Color(s.stageColor),
      child: ValueListenableBuilder<int>(
        valueListenable: s.positionMs,
        builder: (context, position, _) {
          final time = position + (song?.lyricOffsetMs ?? 0) + s.displayOffsetMs;
          if (song != null) {
            unawaited(s.loadAnalysis(song.id));
          }
          final analysis = s.analysis[song?.id];
          final chord = (analysis?['chords'] as List? ?? const [])
              .whereType<Map>()
              .where((c) => (c['startMs'] as int? ?? 1 << 30) <= position)
              .lastOrNull;
          return LayoutBuilder(
            builder: (context, constraints) {
              final font = (constraints.maxWidth / 23).clamp(22.0, 64.0) * s.stageTextScale;
              final lyrics = song?.lyrics;
              final active = <LyricLine>[], next = <LyricLine>[];
              if (lyrics?.synced == true) {
                for (var i = 0; i < lyrics!.lines.length; i++) {
                  final line = lyrics.lines[i], start = line.startMs;
                  if (start == null) {
                    continue;
                  }
                  final following = lyrics.lines
                      .skip(i + 1)
                      .where((l) => l.part == line.part && l.startMs != null)
                      .firstOrNull;
                  final end = line.endMs ?? following?.startMs ?? s.durationMs;
                  if (start <= time && end > time) {
                    active.add(line);
                  }
                  if (start > time && next.length < 2) {
                    next.add(line);
                  }
                }
              }
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (s.videoPlayer case final player?) Video(player: player),
                  if (_cdg != null)
                    Center(
                      child: CdgView(decoder: _cdg!, positionMs: time),
                    ),
                  if (s.videoPlayer != null && lyrics?.isEmpty == false) const ColoredBox(color: Color(0x66000000)),
                  if (song != null && s.mode == KaraokeMode.host)
                    Align(
                      alignment: Alignment.topRight,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: IconButton.filledTonal(
                            tooltip: l10n.t.karaokeUi.correctAnalysis,
                            onPressed: () => _correctAnalysis(song),
                            icon: const AppIcon(Symbols.tune_rounded),
                          ),
                        ),
                      ),
                    ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          if (s.banner.isNotEmpty)
                            Text(
                              s.banner,
                              style: TextStyle(color: Colors.white, fontSize: font * .4),
                              maxLines: 2,
                              textAlign: TextAlign.center,
                            ),
                          Text(
                            song == null ? karaokeText(context, 'upNext') : '${song.title} · ${song.artist}',
                            style: TextStyle(color: Colors.white70, fontSize: font * .42),
                            maxLines: 2,
                            textAlign: TextAlign.center,
                          ),
                          Expanded(
                            child: Center(
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (song == null)
                                      Text(
                                        s.playing
                                            ? 'Instrumental interlude'
                                            : s.rotation.isEmpty
                                            ? karaokeText(context, 'noQueue')
                                            : s.catalog[s.rotation.first.trackId]?.title ?? '',
                                        style: TextStyle(color: Colors.white, fontSize: font),
                                        textAlign: TextAlign.center,
                                      ),
                                    if (song != null &&
                                        lyrics?.isEmpty == true &&
                                        _cdg == null &&
                                        s.videoPlayer == null)
                                      Text(
                                        karaokeText(context, 'noLyrics'),
                                        style: TextStyle(color: Colors.white70, fontSize: font * .65),
                                        textAlign: TextAlign.center,
                                      ),
                                    if (lyrics?.synced == false && lyrics?.isEmpty == false) ...[
                                      Text(
                                        karaokeText(context, 'untimed'),
                                        style: const TextStyle(color: Colors.white70),
                                      ),
                                      Text(
                                        lyrics!.lines.map((l) => l.text).join('\n'),
                                        style: TextStyle(color: Colors.white, fontSize: font * .7),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                    if (active.isEmpty && next.isNotEmpty && next.first.startMs! - time > 1000)
                                      Text(
                                        '${karaokeText(context, 'countIn')} · ${((next.first.startMs! - time) / 1000).ceil()}',
                                        style: TextStyle(color: Colors.white, fontSize: font * .65),
                                      ),
                                    for (final line in active.take(4)) _StageLine(line: line, time: time, font: font),
                                    for (final line in next.take(active.length > 1 ? 1 : 2))
                                      Padding(
                                        padding: const EdgeInsets.only(top: 16),
                                        child: Text(
                                          '${line.part == null ? '' : '${line.part} · '}${line.text}',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: Colors.white60, fontSize: font * .65),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (song != null && analysis != null)
                            Text(
                              l10n.t.karaokeUi.bpmEstimated(
                                value1: (analysis['key'] ?? 'Key estimate').toString(),
                                value2: ((analysis['bpm'] as num?)?.round() ?? '—').toString(),
                                value3: (chord?['chord'] ?? '').toString(),
                              ),
                              style: const TextStyle(color: Colors.white70),
                            ),
                          if (song != null && s.durationMs > 0)
                            Semantics(
                              label: '${position ~/ 1000} / ${s.durationMs ~/ 1000}',
                              child: LinearProgressIndicator(
                                value: (position / s.durationMs).clamp(0, 1),
                                color: Colors.amber,
                                backgroundColor: Colors.white24,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _StageLine extends StatelessWidget {
  const _StageLine({required this.line, required this.time, required this.font});
  final LyricLine line;
  final int time;
  final double font;
  @override
  Widget build(BuildContext context) {
    Color colorForPart(String? part) {
      if (part == null || part == '1') return Colors.amberAccent;
      if (part == '2') return Colors.cyanAccent;
      const additional = [Colors.lightGreenAccent, Colors.purpleAccent, Colors.orangeAccent, Colors.pinkAccent];
      var hash = 0;
      for (final unit in part.codeUnits) {
        hash = (hash * 31 + unit) & 0x7fffffff;
      }
      return additional[hash % additional.length];
    }

    final linePart = line.part?.trim().isNotEmpty == true ? line.part : null;
    final color = colorForPart(linePart);
    final style = TextStyle(fontSize: font, fontWeight: FontWeight.w700, color: Colors.white, height: 1.3);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Semantics(
        label: [
          linePart,
          line.text,
          ...line.spans
              .where((span) => span.part?.trim().isNotEmpty == true && span.part != linePart)
              .map((span) => '${span.part} ${span.text}'),
          ...line.spans.map((span) => span.pronunciation).whereType<String>(),
        ].where((value) => value?.trim().isNotEmpty ?? false).join(' '),
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (linePart != null)
                Text(
                  linePart,
                  style: TextStyle(color: color, fontSize: font * .4),
                ),
              if (line.spans.isEmpty)
                Text(
                  line.text,
                  style: style.copyWith(color: color),
                  textAlign: TextAlign.center,
                )
              else
                Text.rich(
                  TextSpan(
                    children: line.spans.map((span) {
                      final end = span.endMs;
                      final progress = end == null
                          ? (time >= span.startMs ? 1.0 : 0.0)
                          : ((time - span.startMs) / math.max(1, end - span.startMs)).clamp(0.0, 1.0);
                      // Whole source spans preserve grapheme clusters, whitespace and bidi
                      // shaping. Opacity expresses within-span progress without splitting.
                      final spanPart = span.part?.trim().isNotEmpty == true ? span.part : linePart;
                      final spanColor = colorForPart(spanPart);
                      final lyricStyle = style.copyWith(color: Color.lerp(Colors.white54, spanColor, progress));
                      final reading = span.pronunciation;
                      final partLabel = spanPart != null && spanPart != linePart;
                      if ((reading == null || reading.trim().isEmpty) && !partLabel) {
                        return TextSpan(text: span.text, style: lyricStyle);
                      }
                      return WidgetSpan(
                        alignment: PlaceholderAlignment.bottom,
                        baseline: TextBaseline.alphabetic,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (partLabel)
                              Text(
                                spanPart,
                                style: style.copyWith(fontSize: font * .36, color: spanColor, height: 1),
                              ),
                            if (reading != null && reading.trim().isNotEmpty)
                              Text(
                                reading,
                                style: style.copyWith(fontSize: font * .32, color: Colors.white70, height: 1),
                              ),
                            Text(span.text, style: lyricStyle),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                  textAlign: TextAlign.center,
                ),
              if (line.pronunciation != null &&
                  !line.spans.any((span) => span.pronunciation?.trim().isNotEmpty ?? false))
                Text(
                  line.pronunciation!,
                  textAlign: TextAlign.center,
                  style: style.copyWith(fontSize: font * .5, color: Colors.white70),
                ),
              if (line.translation != null)
                Text(
                  line.translation!,
                  textAlign: TextAlign.center,
                  style: style.copyWith(fontSize: font * .5, color: Colors.white70),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
