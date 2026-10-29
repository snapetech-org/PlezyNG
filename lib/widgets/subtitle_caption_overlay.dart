import 'dart:async';
import 'package:flutter/material.dart';

import '../mpv/mpv.dart';
import 'subtitle_pane_policy.dart';
import '../services/settings_service.dart';
import '../services/subtitle_overlay_service.dart';
import '../services/subtitle_retimer.dart';
import '../services/subtitle_playback_transcription_service.dart';

/// Screen-safe Flutter overlay. Native PiP/Cast surfaces do not include this
/// widget; callers hide it while the video is presented on those surfaces.
class SubtitleCaptionOverlay extends StatefulWidget {
  const SubtitleCaptionOverlay({super.key, required this.player, this.bottomInset = 0});
  final Player player;
  final double bottomInset;
  @override
  State<SubtitleCaptionOverlay> createState() => _SubtitleCaptionOverlayState();
}

class _SubtitleCaptionOverlayState extends State<SubtitleCaptionOverlay> {
  Timer? _timer;
  final Map<String, double> _placementCache = {};
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }
  @override
  void dispose() { _timer?.cancel(); super.dispose(); }
  Color _color(String text, Color fallback) => RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text)
      ? Color(0xff000000 | int.parse(text.substring(1), radix: 16)) : fallback;
  @override
  Widget build(BuildContext context) {
    final policy = SubtitlePanePolicy.of(context);
    final player = widget.player;
    if (policy?.visible == false || player.disposed) return const SizedBox.shrink();
    final session = SubtitleOverlayService.forPlayer(player);
    final live = SubtitlePlaybackTranscriptionService.instance;
    final caption = live.isForPlayer(player) ? live.liveCaption.value : null;
    final settings = SettingsService.instance;
    final position = player.currentPosition.inMilliseconds;
    final tracks = session.lanes.whereType<SubtitleOverlayTrack>().where((track) {
      try { return session.current && track.isCurrent(); } catch (_) { return false; }
    }).toList();
    if (tracks.isEmpty && caption == null) return const SizedBox.shrink();
    return IgnorePointer(child: SafeArea(child: LayoutBuilder(builder: (context, constraints) {
      final scale = (constraints.maxHeight / 720).clamp(.5, 2.0);
      final visible = tracks.where((track) => track.at(position).isNotEmpty).toList();
      final laneY = <SubtitleOverlayTrack, double>{};
      final authored = [for (final track in visible) for (final cue in track.at(position))
        if (track.regions[cue.stableId] case final Rect region) region];
      final occupied = <Rect>[];
      for (var lane = 0; lane < visible.length; lane++) {
        final track = visible[lane];
        var y = track.position;
        if (lane > 0 && (y - laneY[visible[0]]!).abs() < .22) y = (laneY[visible[0]]! - .25).clamp(.08, .92);
        final cues = track.at(position).where((cue) => !track.regions.containsKey(cue.stableId)).take(policy == null ? 8 : 2).toList();
        y = _place(track, cues, y, constraints.maxWidth, (constraints.maxHeight - widget.bottomInset).clamp(1.0, double.infinity).toDouble(), scale, [...authored, ...occupied]);
        laneY[track] = y;
        if (cues.isNotEmpty) occupied.add(Rect.fromLTWH(track.margin, (y - .10).clamp(0, .8), 1 - 2 * track.margin, .2));
      }
      return Stack(children: [
        if (session.coverRegion case final Rect region) Positioned(
          left: region.left * constraints.maxWidth, top: region.top * constraints.maxHeight,
          width: region.width * constraints.maxWidth, height: region.height * constraints.maxHeight,
          child: const ColoredBox(color: Colors.black)),
        for (final track in visible) for (final cue in track.at(position))
          if (track.regions[cue.stableId] case final Rect region)
            Positioned(left: region.left * constraints.maxWidth, top: region.top * constraints.maxHeight,
              width: region.width * constraints.maxWidth, height: region.height * constraints.maxHeight,
              child: Center(child: _line(TextSpan(children: track.spans(cue, position)), track.fontSize * scale,
                track.color, track.outline, track.outlineWidth * scale, track.backgroundOpacity,
                bold: track.bold, italic: track.italic, track: track))),
        for (var lane = 0; lane < visible.length; lane++) Builder(builder: (_) {
          final track = visible[lane];
          final y = laneY[track]!;
          return Positioned.fill(bottom: widget.bottomInset, child: Align(alignment: Alignment(0, y * 2 - 1),
            child: Padding(padding: EdgeInsets.symmetric(horizontal: constraints.maxWidth * track.margin),
              child: Column(mainAxisSize: MainAxisSize.min, children: track.at(position).where((cue) => !track.regions.containsKey(cue.stableId)).take(policy == null ? 8 : 2).map((cue) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: _line(TextSpan(children: track.spans(cue, position)), track.fontSize * scale,
                  track.color, track.outline, track.outlineWidth * scale, track.backgroundOpacity,
                  bold: track.bold, italic: track.italic, track: track),
              )).toList()))));
        }),
        if (caption != null) Positioned.fill(bottom: widget.bottomInset, child: Align(
          alignment: const Alignment(0, -.75), child: Padding(padding: const EdgeInsets.all(16),
            child: _line(TextSpan(text: caption.text), settings.read(SettingsService.subtitleFontSize) * scale,
              _color(settings.read(SettingsService.subtitleTextColor), Colors.white),
              _color(settings.read(SettingsService.subtitleBorderColor), Colors.black),
              settings.read(SettingsService.subtitleBorderSize) * scale,
              settings.read(SettingsService.subtitleBackgroundOpacity) / 100,
              bold: settings.read(SettingsService.subtitleBold), italic: settings.read(SettingsService.subtitleItalic))))),
      ]);
    })));
  }

  double _place(SubtitleOverlayTrack track, List<SubtitleCue> cues, double preferred,
      double width, double height, double scale, List<Rect> blocked) {
    if (cues.isEmpty) return preferred;
    final obstacles = [...blocked, if (track.avoidObjects) for (final cue in cues) ...?track.avoidRegions[cue.stableId]];
    if (obstacles.isEmpty) return preferred;
    final key = '${identityHashCode(track)}:${cues.map((c) => c.stableId).join(',')}:$width:$height:$preferred:'
        '${track.fontSize}:${track.fontFamily}:${track.bold}:${track.italic}:${track.margin}:${MediaQuery.textScalerOf(context).scale(1)}:$obstacles';
    final cached = _placementCache[key];
    if (cached != null) return cached;
    var pixels = 0.0;
    for (final cue in cues) {
      final painter = TextPainter(text: TextSpan(text: SubtitleOverlayTrack.plain(cue.text),
        style: TextStyle(fontSize: track.fontSize * scale, fontFamily: track.fontFamily == 'System' ? null : track.fontFamily,
          fontWeight: track.bold ? FontWeight.bold : FontWeight.w500, fontStyle: track.italic ? FontStyle.italic : FontStyle.normal, height: 1.25)),
        textDirection: _direction(cue.text), textScaler: MediaQuery.textScalerOf(context), maxLines: SubtitlePanePolicy.of(context) == null ? 6 : 3)
        ..layout(maxWidth: (width * (1 - 2 * track.margin) - 16).clamp(1.0, double.infinity).toDouble());
      pixels += painter.height + 12; painter.dispose();
    }
    final h = (pixels / height).clamp(.04, .85);
    var best = preferred, bestScore = double.infinity;
    for (final y in [preferred, .06, .18, .38, .62, .82, .94]) {
      final rectangle = Rect.fromLTWH(track.margin, y * (1 - h), 1 - 2 * track.margin, h);
      var score = (y - preferred).abs() * .002;
      for (final obstacle in obstacles) {
        final overlap = rectangle.intersect(obstacle.inflate(.015));
        if (!overlap.isEmpty) score += overlap.width * overlap.height;
      }
      if (score < bestScore) { bestScore = score; best = y; }
    }
    if (_placementCache.length >= 128) _placementCache.clear();
    _placementCache[key] = best;
    return best;
  }

  TextDirection _direction(String text) {
    for (final rune in text.runes) {
      if (!RegExp(r'\p{L}', unicode: true).hasMatch(String.fromCharCode(rune))) continue;
      return rune >= 0x590 && rune <= 0x8ff || rune >= 0xfb1d && rune <= 0xfdff || rune >= 0xfe70 && rune <= 0xfeff
          ? TextDirection.rtl : TextDirection.ltr;
    }
    return TextDirection.ltr;
  }

  Widget _line(InlineSpan content, double size, Color color, Color outline,
      double border, double opacity, {bool bold = false, bool italic = false, SubtitleOverlayTrack? track}) {
    final direction = _direction(content.toPlainText());
    final style = TextStyle(fontSize: size, fontFamily: track == null || track.fontFamily == 'System' ? null : track.fontFamily, fontFamilyFallback: const ['Noto Sans', 'Noto Sans Arabic', 'Noto Sans Hebrew', 'Noto Sans CJK SC'], fontWeight: bold ? FontWeight.bold : FontWeight.w500,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal, color: color, height: 1.25);
    return DecoratedBox(decoration: BoxDecoration(color: (track?.backgroundColor ?? Colors.black).withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(4)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Stack(children: [
        if (border > 0) ExcludeSemantics(child: Text.rich(content, textDirection: direction, textAlign: track?.alignment ?? TextAlign.center,
          style: style.copyWith(foreground: Paint()..style = PaintingStyle.stroke..strokeWidth = border * 2..color = outline),
          maxLines: SubtitlePanePolicy.of(context) == null ? 6 : 3, overflow: TextOverflow.ellipsis)),
        Text.rich(content, textDirection: direction, textAlign: track?.alignment ?? TextAlign.center, style: style, maxLines: SubtitlePanePolicy.of(context) == null ? 6 : 3, overflow: TextOverflow.ellipsis),
      ])));
  }
}
