import 'dart:async';
import 'package:flutter/material.dart';

import '../mpv/mpv.dart';
import '../mpv/font_loader.dart';
import '../mpv/player/player_media_session_identity.dart';
import '../services/subtitle_viewport.dart';
import 'subtitle_pane_policy.dart';
import 'subtitle_vertical_text.dart';
import '../services/settings_service.dart';
import '../services/subtitle_overlay_service.dart';
import '../services/subtitle_retimer.dart';
import '../services/subtitle_playback_transcription_service.dart';
import '../services/subtitle_frame_export.dart';

/// Screen-safe Flutter overlay. Native PiP/Cast surfaces do not include this
/// widget; callers hide it while the video is presented on those surfaces.
class SubtitleCaptionOverlay extends StatefulWidget {
  const SubtitleCaptionOverlay({super.key, required this.player, this.bottomInset = 0, this.fitMode = 0, this.zoom = 1,
    this.audioOnly = false});
  final Player player;
  final double bottomInset;
  final int fitMode;
  final double zoom;
  final bool audioOnly;
  @override
  State<SubtitleCaptionOverlay> createState() => _SubtitleCaptionOverlayState();
}

class _SubtitleCaptionOverlayState extends State<SubtitleCaptionOverlay> {
  Timer? _timer;
  final _captureKey = GlobalKey();
  Size? _displaySize;
  Player? _geometryPlayer;
  int? _geometryGeneration;
  int? _generation(Player player) => player is PlayerMediaSessionIdentity ? player.mediaSessionGeneration : null;
  bool _readingGeometry = false;
  int _geometryTicks = 0;

  Future<void> _refreshGeometry() async {
    if (widget.audioOnly || _readingGeometry || widget.player.disposed) return;
    final player = widget.player;
    final generation = _generation(player);
    if (generation == null) return;
    _readingGeometry = true;
    try {
      final dimensions = await Future.wait([player.getProperty('dwidth'), player.getProperty('dheight')])
        .timeout(const Duration(seconds: 2));
      final width = double.tryParse(dimensions[0] ?? ''), height = double.tryParse(dimensions[1] ?? '');
      if (!mounted || widget.audioOnly || widget.player != player || _generation(player) != generation) return;
      _geometryPlayer = player;
      _geometryGeneration = generation;
      _displaySize = width != null && height != null && width.isFinite && height.isFinite &&
          width > 0 && height > 0 && width <= 65536 && height <= 65536 ? Size(width, height) : null;
      setState(() {});
    } catch (_) { if (mounted) { _displaySize = null; _geometryPlayer = null; _geometryGeneration = null; } }
    finally { _readingGeometry = false; }
  }
  final Map<String, double> _placementCache = {};
  @override
  void initState() {
    super.initState();
    _registerCapture();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) {
        if (++_geometryTicks % 20 == 0) unawaited(_refreshGeometry());
        setState(() {});
      }
    });
    unawaited(_refreshGeometry());
    unawaited(SubtitleFontLoader.loadOverlayFonts().then((_) {
      if (mounted) { _placementCache.clear(); setState(() {}); }
    }, onError: (Object _) { /* Keep system fallback if an asset is unavailable. */ }));
  }
  void _registerCapture() {
    if (widget.audioOnly) return;
    final player = widget.player;
    SubtitleFrameExport.register(player, _captureKey, () => mounted && identical(widget.player, player) &&
        SubtitlePanePolicy.of(context)?.visible != false);
  }
  @override
  void didUpdateWidget(covariant SubtitleCaptionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player) || oldWidget.audioOnly != widget.audioOnly) {
      SubtitleFrameExport.unregister(oldWidget.player, _captureKey);
      _displaySize = null; _geometryPlayer = null; _geometryGeneration = null;
      _placementCache.clear();
      _registerCapture();
      unawaited(_refreshGeometry());
    }
  }
  @override
  void dispose() {
    SubtitleFrameExport.unregister(widget.player, _captureKey);
    _timer?.cancel(); super.dispose();
  }
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
    return RepaintBoundary(key: _captureKey, child: IgnorePointer(child: LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size.isEmpty || !size.width.isFinite || !size.height.isFinite) return const SizedBox.shrink();
      final viewport = SubtitleViewport.layout(size,
        displaySize: _geometryPlayer == player && _geometryGeneration == _generation(player) ? _displaySize : null,
        fitMode: widget.fitMode, zoom: widget.zoom);
      final padding = MediaQuery.paddingOf(context);
      final safe = Rect.fromLTRB(padding.left, padding.top,
        (size.width - padding.right).clamp(padding.left + 1, double.infinity).toDouble(),
        (size.height - padding.bottom - widget.bottomInset).clamp(padding.top + 1, double.infinity).toDouble());
      final scale = (size.height / 720).clamp(.5, 2.0);
      final visible = tracks.where((track) => track.at(position).isNotEmpty).toList();
      final areas = <SubtitleOverlayTrack, Rect>{};
      final laneY = <SubtitleOverlayTrack, double>{};
      final authored = <Rect>[for (final track in visible) for (final cue in track.at(position))
        if (track.regions[cue.stableId] case final Rect region)
          if (viewport.imageRegion(region) case final Rect mapped) mapped];
      final occupied = <Rect>[];
      for (final track in visible) {
        final area = viewport.textArea(safeBounds: safe, videoAnchored: track.videoAnchored, overscan: track.overscan);
        areas[track] = area;
        final cues = track.at(position).where((cue) => !track.regions.containsKey(cue.stableId) || viewport.frame == null)
            .take(policy == null ? 8 : 2).toList();
        final blocked = <Rect>[...authored, ...occupied,
          if (track.avoidObjects) for (final cue in cues) for (final region in track.avoidRegions[cue.stableId] ?? const <Rect>[])
            if (viewport.imageRegion(region) case final Rect mapped) mapped];
        final y = _place(track, cues, track.position, area.width, area.height, scale,
            blocked.map((r) => SubtitleViewport.inArea(r, area)).toList());
        laneY[track] = y;
        if (cues.isNotEmpty) occupied.add(Rect.fromLTWH(area.left + area.width * track.margin,
          area.top + area.height * (y - .10).clamp(0, .8), area.width * (1 - 2 * track.margin), area.height * .2));
      }
      return ClipRect(child: Stack(children: [
        if (session.coverRegion case final Rect region)
          if (viewport.imageRegion(region) case final Rect mapped)
            Positioned.fromRect(rect: mapped, child: const ColoredBox(color: Colors.black)),
        for (final track in visible) for (final cue in track.at(position))
          if (track.regions[cue.stableId] case final Rect region)
            if (viewport.imageRegion(region) case final Rect mapped)
              Positioned.fromRect(rect: mapped, child: ClipRect(child: Center(
                child: _line(TextSpan(children: track.spans(cue, position)), track.fontSize * scale,
                  track.color, track.outline, track.outlineWidth * scale, track.backgroundOpacity,
                  bold: track.bold, italic: track.italic, track: track, heightLimit: mapped.height)))),
        for (final track in visible) Positioned.fromRect(rect: areas[track]!,
          child: Align(alignment: Alignment(0, laneY[track]! * 2 - 1),
            child: Padding(padding: EdgeInsets.symmetric(horizontal: areas[track]!.width * track.margin),
              child: Column(mainAxisSize: MainAxisSize.min, children: track.at(position)
                .where((cue) => !track.regions.containsKey(cue.stableId) || viewport.frame == null)
                .take(policy == null ? 8 : 2).map((cue) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: _line(TextSpan(children: track.spans(cue, position)), track.fontSize * scale,
                    track.color, track.outline, track.outlineWidth * scale, track.backgroundOpacity,
                    bold: track.bold, italic: track.italic, track: track, heightLimit: areas[track]!.height * .65),
                )).toList())))),
        if (caption != null) Positioned.fromRect(rect: safe, child: Align(
          alignment: const Alignment(0, -.75), child: Padding(padding: const EdgeInsets.all(16),
            child: _line(TextSpan(text: caption.provisional ? '… ${caption.text}' : caption.text), settings.read(SettingsService.subtitleFontSize) * scale,
              _color(settings.read(SettingsService.subtitleTextColor), Colors.white),
              _color(settings.read(SettingsService.subtitleBorderColor), Colors.black),
              settings.read(SettingsService.subtitleBorderSize) * scale,
              settings.read(SettingsService.subtitleBackgroundOpacity) / 100,
              bold: settings.read(SettingsService.subtitleBold), italic: caption.provisional || settings.read(SettingsService.subtitleItalic))))),
      ]));
    })));
  }

  double _place(SubtitleOverlayTrack track, List<SubtitleCue> cues, double preferred,
      double width, double height, double scale, List<Rect> blocked) {
    if (cues.isEmpty) return preferred;
    final obstacles = blocked;
    if (obstacles.isEmpty) return preferred;
    final key = '${identityHashCode(track)}:${cues.map((c) => c.stableId).join(',')}:$width:$height:$preferred:'
        '${track.fontSize}:${track.fontFamily}:${track.bold}:${track.italic}:${track.margin}:${track.ruby}:${track.writingMode}:${MediaQuery.textScalerOf(context).scale(1)}:$obstacles';
    final cached = _placementCache[key];
    if (cached != null) return cached;
    var pixels = 0.0;
    for (final cue in cues) {
      final painter = TextPainter(text: TextSpan(text: SubtitleOverlayTrack.plain(cue.text),
        style: TextStyle(fontSize: track.fontSize * scale, fontFamily: track.renderedFontFamily, fontFamilyFallback: SubtitleOverlayTrack.fallbackFonts,
          fontWeight: track.bold ? FontWeight.bold : FontWeight.w500, fontStyle: track.italic ? FontStyle.italic : FontStyle.normal, height: 1.25)),
        textDirection: _direction(cue.text), textScaler: MediaQuery.textScalerOf(context), maxLines: SubtitlePanePolicy.of(context) == null ? 6 : 3)
        ..layout(maxWidth: (width * (1 - 2 * track.margin) - 16).clamp(1.0, double.infinity).toDouble());
      // Reserve reading-line headroom in the avoidance estimate. Actual ruby
      // pairs are laid out by Flutter inline children at the same text scale.
      pixels += track.writingMode == 'horizontal'
          ? painter.height * (track.ruby && cue.text.toLowerCase().contains('<ruby') ? 1.65 : 1) + 12
          : height * .65;
      painter.dispose();
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
      double border, double opacity, {bool bold = false, bool italic = false, SubtitleOverlayTrack? track, double? heightLimit}) {
    final direction = _direction(content.toPlainText());
    final style = TextStyle(fontSize: size, fontFamily: track == null ? SubtitleFontLoader.overlayFamily : track.renderedFontFamily, fontFamilyFallback: SubtitleOverlayTrack.fallbackFonts, fontWeight: bold ? FontWeight.bold : FontWeight.w500,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal, color: color, height: 1.25);
    if (track != null && track.writingMode != 'horizontal') {
      return DecoratedBox(decoration: BoxDecoration(color: track.backgroundColor.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(4)), child: Padding(padding: const EdgeInsets.all(6),
          child: ConstrainedBox(constraints: BoxConstraints(maxHeight: heightLimit ?? MediaQuery.sizeOf(context).height * .65),
            child: SubtitleVerticalText(text: content.toPlainText(), style: style,
              rightToLeft: track.writingMode == 'vertical-rl', outline: outline, outlineWidth: border,
              maximumColumns: SubtitlePanePolicy.of(context) == null ? 6 : 3))));
    }
    Widget layer(TextStyle paintStyle) => DefaultTextStyle(style: paintStyle, child: Text.rich(content,
      textDirection: direction, textAlign: track?.alignment ?? TextAlign.center, style: paintStyle,
      maxLines: SubtitlePanePolicy.of(context) == null ? 6 : 3, overflow: TextOverflow.ellipsis));
    return DecoratedBox(decoration: BoxDecoration(color: (track?.backgroundColor ?? Colors.black).withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(4)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Stack(children: [
        if (border > 0) ExcludeSemantics(child: layer(style.copyWith(foreground:
          Paint()..style = PaintingStyle.stroke..strokeWidth = border * 2..color = outline))),
        layer(style),
      ])));
  }
}
