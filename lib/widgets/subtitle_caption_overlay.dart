import 'dart:async';
import 'package:flutter/material.dart';

import '../mpv/mpv.dart';
import 'subtitle_pane_policy.dart';
import '../services/settings_service.dart';
import '../services/subtitle_overlay_service.dart';
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
                bold: track.bold, italic: track.italic))),
        for (var lane = 0; lane < visible.length; lane++) Builder(builder: (_) {
          final track = visible[lane];
          var y = track.position;
          // Stable lane separation; no per-frame face guesses or animation.
          if (lane > 0 && (y - visible[0].position).abs() < .22) y = (visible[0].position - .25).clamp(.08, .92);
          return Positioned.fill(bottom: widget.bottomInset, child: Align(alignment: Alignment(0, y * 2 - 1),
            child: Padding(padding: EdgeInsets.symmetric(horizontal: constraints.maxWidth * track.margin),
              child: Column(mainAxisSize: MainAxisSize.min, children: track.at(position).where((cue) => !track.regions.containsKey(cue.stableId)).take(policy == null ? 8 : 2).map((cue) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: _line(TextSpan(children: track.spans(cue, position)), track.fontSize * scale,
                  track.color, track.outline, track.outlineWidth * scale, track.backgroundOpacity,
                  bold: track.bold, italic: track.italic),
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

  Widget _line(InlineSpan content, double size, Color color, Color outline,
      double border, double opacity, {bool bold = false, bool italic = false}) {
    var direction = TextDirection.ltr;
    for (final rune in content.toPlainText().runes) {
      final character = String.fromCharCode(rune);
      if (!RegExp(r'\p{L}', unicode: true).hasMatch(character)) continue;
      if (rune >= 0x590 && rune <= 0x8ff || rune >= 0xfb1d && rune <= 0xfdff || rune >= 0xfe70 && rune <= 0xfeff) direction = TextDirection.rtl;
      break;
    }
    final style = TextStyle(fontSize: size, fontFamilyFallback: const ['Noto Sans', 'Noto Sans Arabic', 'Noto Sans Hebrew', 'Noto Sans CJK SC'], fontWeight: bold ? FontWeight.bold : FontWeight.w500,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal, color: color, height: 1.25);
    return DecoratedBox(decoration: BoxDecoration(color: Colors.black.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(4)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Stack(children: [
        if (border > 0) ExcludeSemantics(child: Text.rich(content, textDirection: direction, textAlign: TextAlign.center,
          style: style.copyWith(foreground: Paint()..style = PaintingStyle.stroke..strokeWidth = border * 2..color = outline),
          maxLines: SubtitlePanePolicy.of(context) == null ? 6 : 3, overflow: TextOverflow.ellipsis)),
        Text.rich(content, textDirection: direction, textAlign: TextAlign.center, style: style, maxLines: SubtitlePanePolicy.of(context) == null ? 6 : 3, overflow: TextOverflow.ellipsis),
      ])));
  }
}
