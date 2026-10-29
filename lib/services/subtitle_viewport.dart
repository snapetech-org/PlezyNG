import 'dart:ui';
import 'dart:math' as math;

/// The same centered contain/cover/stretch and zoom transform as video playback.
/// Coordinates are logical pixels in the full player pane, before safe insets.
/// A null frame means the backend has not supplied a trustworthy display size.
final class SubtitleViewport {
  const SubtitleViewport(this.bounds, this.frame);
  final Rect bounds;
  final Rect? frame;

  factory SubtitleViewport.layout(Size pane, {required Size? displaySize,
      int fitMode = 0, double zoom = 1}) {
    final bounds = Offset.zero & pane;
    if (pane.isEmpty || !pane.width.isFinite || !pane.height.isFinite || displaySize == null ||
        displaySize.isEmpty || !displaySize.width.isFinite || !displaySize.height.isFinite) {
      return SubtitleViewport(bounds, null);
    }
    final scale = zoom.isFinite ? zoom.clamp(.5, 2.0).toDouble() : 1.0;
    final widthRatio = pane.width / displaySize.width, heightRatio = pane.height / displaySize.height;
    final fit = fitMode == 1 ? math.max(widthRatio, heightRatio) : math.min(widthRatio, heightRatio);
    final size = fitMode == 2 ? pane * scale : displaySize * (fit * scale);
    return SubtitleViewport(bounds, Rect.fromCenter(center: bounds.center, width: size.width, height: size.height));
  }

  Rect? imageRegion(Rect normalized) {
    final video = frame;
    if (video == null) return null;
    return Rect.fromLTWH(video.left + normalized.left * video.width, video.top + normalized.top * video.height,
      normalized.width * video.width, normalized.height * video.height);
  }

  Rect textArea({required Rect safeBounds, required bool videoAnchored, required double overscan}) {
    var area = videoAnchored && frame != null ? safeBounds.intersect(frame!) : safeBounds;
    if (area.isEmpty) area = safeBounds;
    final inset = overscan.isFinite ? overscan.clamp(0.0, .15).toDouble() : 0.0;
    return Rect.fromLTWH(area.left + area.width * inset, area.top + area.height * inset,
      area.width * (1 - 2 * inset), area.height * (1 - 2 * inset));
  }

  static Rect inArea(Rect pixels, Rect area) => Rect.fromLTWH((pixels.left - area.left) / area.width,
    (pixels.top - area.top) / area.height, pixels.width / area.width, pixels.height / area.height);
}
