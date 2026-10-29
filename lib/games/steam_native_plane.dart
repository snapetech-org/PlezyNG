import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Aperture for a native Steam video plane below the platform's Flutter UI.
/// Geometry and visibility follow the rendered surface, including its retained
/// Offstage owner. Input and accessibility remain in the ordinary Flutter tree.
class SteamNativePlane extends LeafRenderObjectWidget {
  const SteamNativePlane({super.key, required this.enabled, required this.onRect});
  final bool enabled;
  final ValueChanged<Map<String, int>> onRect;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SteamPlaneRender(enabled, MediaQuery.devicePixelRatioOf(context), onRect);

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) {
    (renderObject as _SteamPlaneRender).update(enabled, MediaQuery.devicePixelRatioOf(context), onRect);
  }
}

class _SteamPlaneRender extends RenderBox {
  _SteamPlaneRender(this.enabled, this.dpr, this.onRect);
  bool enabled;
  double dpr;
  ValueChanged<Map<String, int>> onRect;
  bool _scheduled = false;

  void update(bool value, double ratio, ValueChanged<Map<String, int>> callback) {
    enabled = value;
    dpr = ratio;
    onRect = callback;
    markNeedsPaint();
    _scheduleRect();
  }

  void _scheduleRect() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!attached || !hasSize) return;
      RenderObject? ancestor = parent;
      while (ancestor != null) {
        if (ancestor is RenderOffstage && ancestor.offstage) {
          _hide();
          return;
        }
        ancestor = ancestor.parent;
      }
      final rect = MatrixUtils.transformRect(getTransformTo(null), Offset.zero & size);
      if (!rect.isFinite || size.isEmpty) {
        _hide();
        return;
      }
      final left = (rect.left * dpr).floor(), top = (rect.top * dpr).floor();
      onRect({
        'x': left,
        'y': top,
        'width': (rect.right * dpr).ceil() - left,
        'height': (rect.bottom * dpr).ceil() - top,
        'scale': dpr.ceil().clamp(1, 8),
      });
    });
  }

  void _hide() => onRect({'x': 0, 'y': 0, 'width': 0, 'height': 0, 'scale': 1});

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scheduleRect();
  }

  @override
  void detach() {
    _hide();
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    _scheduleRect();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _scheduleRect();
    if (enabled) context.canvas.drawRect(offset & size, Paint()..blendMode = BlendMode.clear);
  }
}
