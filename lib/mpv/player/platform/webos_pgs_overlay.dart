import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../media/pgs_subtitles.dart';
import '../../../utils/app_logger.dart';

List<PgsRaster> _rasterizePgs(PgsCue cue) => cue.rasterize(premultiplied: true);

/// App-owned subtitle images above the native video plane. No video encoding.
class WebOSPgsOverlay extends StatelessWidget {
  final ValueListenable<PgsCue?> cue;
  const WebOSPgsOverlay({super.key, required this.cue});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ValueListenableBuilder<PgsCue?>(
      valueListenable: cue,
      builder: (context, value, _) => value == null ? const SizedBox.shrink() : _PgsImages(cue: value),
    ),
  );
}

class _PgsImages extends StatefulWidget {
  final PgsCue cue;
  const _PgsImages({required this.cue});

  @override
  State<_PgsImages> createState() => _PgsImagesState();
}

class _PgsImagesState extends State<_PgsImages> {
  List<({PgsRaster raster, ui.Image image})> _images = const [];
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PgsImages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cue, widget.cue)) _load();
  }

  void _clearImages() {
    for (final frame in _images) {
      frame.image.dispose();
    }
    _images = const [];
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _clearImages();
    final loaded = <({PgsRaster raster, ui.Image image})>[];
    try {
      final rasters = await compute(_rasterizePgs, widget.cue);
      for (final raster in rasters) {
        if (!mounted || generation != _generation) return;
        final buffer = await ui.ImmutableBuffer.fromUint8List(raster.rgba);
        ui.ImageDescriptor? descriptor;
        ui.Codec? codec;
        try {
          descriptor = ui.ImageDescriptor.raw(
            buffer,
            width: raster.width,
            height: raster.height,
            pixelFormat: ui.PixelFormat.rgba8888,
          );
          codec = await descriptor.instantiateCodec();
          final frame = await codec.getNextFrame();
          loaded.add((raster: raster, image: frame.image));
        } finally {
          codec?.dispose();
          descriptor?.dispose();
          buffer.dispose();
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _images = List.of(loaded);
        loaded.clear();
      });
    } catch (error, stackTrace) {
      appLogger.w('PGS subtitle image could not be rendered', error: error, stackTrace: stackTrace);
    } finally {
      for (final frame in loaded) {
        frame.image.dispose();
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _clearImages();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.contain,
    child: SizedBox(
      width: widget.cue.width.toDouble(),
      height: widget.cue.height.toDouble(),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (final frame in _images)
            Positioned(
              left: frame.raster.x.toDouble(),
              top: frame.raster.y.toDouble(),
              width: frame.raster.width.toDouble(),
              height: frame.raster.height.toDouble(),
              child: RawImage(image: frame.image, filterQuality: FilterQuality.low),
            ),
        ],
      ),
    ),
  );
}
