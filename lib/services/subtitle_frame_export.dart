import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../mpv/mpv.dart';
import 'subtitle_overlay_service.dart';

class _CaptionSurface {
  _CaptionSurface(this.key, this.current);
  final GlobalKey key;
  final bool Function() current;
}

/// Captures the actual caption widget, including ruby/vertical text and both
/// visible lanes. HDR/high-bit-depth frames remain byte-for-byte native images
/// in a layered package instead of being silently quantized through Flutter.
abstract final class SubtitleFrameExport {
  static final Expando<_CaptionSurface> _surfaces = Expando();
  static final Expando<bool> _busy = Expando();
  static void register(Player player, GlobalKey key, bool Function() current) =>
      _surfaces[player] = _CaptionSurface(key, current);
  static void unregister(Player player, GlobalKey key) {
    if (_surfaces[player]?.key == key) _surfaces[player] = null;
  }

  static Future<({Uint8List bytes, String extension, bool layered})> capture(Player player) async {
    if (player.playerType != 'mpv' || player.disposed || player.state.playing || _busy[player] == true) {
      throw StateError('Pause MPV playback before exporting a caption frame');
    }
    final surface = _surfaces[player], session = SubtitleOverlayService.forPlayer(player);
    if (surface == null || !surface.current()) throw StateError('This player has no visible app caption surface');
    final time = player.currentPosition, offset = player.timelineOffset;
    String signature() => jsonEncode([for (final track in session.lanes) track == null ? null :
      [identityHashCode(track), track.delayMs, track.appearance()], session.coverRegion?.toString()]);
    final selection = signature();
    final primary = player.state.track.subtitle?.id, secondary = player.state.track.secondarySubtitle?.id;
    bool current() => !player.disposed && !player.state.playing && player.currentPosition == time &&
        player.timelineOffset == offset && session.current && surface.current() && signature() == selection &&
        player.state.track.subtitle?.id == primary && player.state.track.secondarySubtitle?.id == secondary;
    _busy[player] = true;
    Directory? temporary;
    ui.Image? overlay, base, combined;
    ui.Codec? codec;
    ui.Picture? picture;
    try {
      final gamma = await player.getProperty('video-params/gamma');
      final primaries = await player.getProperty('video-params/primaries');
      if (!current()) throw StateError('Playback changed');
      temporary = await (await getTemporaryDirectory()).createTemp('subtitle_frame_');
      final path = '${temporary.path}/native.png';
      // Window coordinates match the video output viewport, including native
      // subtitle selection. No renderer property or track is temporarily changed.
      await player.command(['screenshot-to-file', path, 'window']);
      if (!current()) throw StateError('Playback changed during native capture');
      final file = File(path);
      if (!await file.exists() || await file.length() > 64 * 1024 * 1024) throw StateError('Native screenshot is missing or too large');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        if (builder.length + chunk.length > 64 * 1024 * 1024) throw const FormatException('Screenshot byte limit');
        builder.add(chunk);
      }
      final native = builder.takeBytes();
      if (native.length < 33 || !const [137, 80, 78, 71, 13, 10, 26, 10].asMap().entries.every((e) => native[e.key] == e.value) ||
          String.fromCharCodes(native.sublist(12, 16)) != 'IHDR') throw const FormatException('Native output was not PNG');
      final header = ByteData.sublistView(native);
      final width = header.getUint32(16), height = header.getUint32(20), depth = native[24];
      if (width < 1 || height < 1 || width > 8192 || height > 8192 || width * height > 16777216) {
        throw const FormatException('Screenshot pixel limit');
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!current()) throw StateError('Playback changed before caption capture');
      final render = surface.key.currentContext?.findRenderObject();
      if (render is! RenderRepaintBoundary || !render.hasSize || render.debugNeedsPaint ||
          render.size.isEmpty || (render.size.aspectRatio / (width / height) - 1).abs() > .005) {
        throw StateError('Native output and caption viewport do not match');
      }
      overlay = await render.toImage(pixelRatio: width / render.size.width);
      if ((overlay.width - width).abs() > 1 || (overlay.height - height).abs() > 1) throw StateError('Caption capture geometry changed');
      final layerData = await overlay.toByteData(format: ui.ImageByteFormat.png);
      if (layerData == null) throw StateError('Caption layer could not be encoded');
      final layer = layerData.buffer.asUint8List(layerData.offsetInBytes, layerData.lengthInBytes);
      final knownSdr = const {'srgb', 'bt.1886', 'bt.709', 'gamma2.2', 'gamma2.4'}.contains(gamma) &&
          const {'bt.709', 'bt.601-625', 'bt.601-525'}.contains(primaries) && depth == 8;
      if (!current()) throw StateError('Caption selection changed');
      if (knownSdr) {
        codec = await ui.instantiateImageCodec(native);
        base = (await codec.getNextFrame()).image;
        final recorder = ui.PictureRecorder(), canvas = Canvas(recorder);
        canvas.drawImage(base, Offset.zero, Paint());
        canvas.drawImageRect(overlay, Rect.fromLTWH(0, 0, overlay.width.toDouble(), overlay.height.toDouble()),
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint());
        picture = recorder.endRecording();
        combined = await picture.toImage(width, height);
        final data = await combined.toByteData(format: ui.ImageByteFormat.png);
        if (data == null || !current()) throw StateError('Caption export was interrupted');
        return (bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), extension: 'png', layered: false);
      }
      final files = <String, Uint8List>{'native-frame.png': native, 'caption-layer-srgb.png': layer};
      final manifest = {'schema': 1, 'type': 'plezyng.caption-frame.layers', 'width': width, 'height': height,
        'positionMs': time.inMilliseconds, 'nativeBitDepth': depth,
        'sourceTransfer': gamma, 'sourcePrimaries': primaries,
        'nativeFrameUnmodified': true, 'captionLayerTransfer': 'srgb', 'captionLayerAlpha': 'straight',
        'composition': 'Convert both layers into the destination linear-light color space before alpha compositing. '
          'The native frame keeps MPV output metadata. Caption reference white must be chosen by the output compositor.',
        'nativeTrackSelectionIncluded': true, 'appVisibleLanesIncluded': true,
        'files': [for (final entry in files.entries) {'path': entry.key, 'bytes': entry.value.length,
          'sha256': sha256.convert(entry.value).toString()}]};
      files['manifest.json'] = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)));
      files['README.txt'] = Uint8List.fromList(utf8.encode(
        'Native video and selected native subtitles are in native-frame.png. Their encoded bytes and color metadata are unchanged. '
        'Visible app captions and their cover band are in the same-size transparent sRGB layer. '
        'This is a layered image, not a flattened HDR composite. Use a color-managed compositor and select caption reference white. '
        'Unknown/wide-gamut/high-bit-depth output uses this package to preserve the native image.'));
      final bytes = await compute(_encodeLayers, files);
      if (!current()) throw StateError('Caption selection changed during export');
      return (bytes: bytes, extension: 'zip', layered: true);
    } finally {
      overlay?.dispose(); base?.dispose(); combined?.dispose(); codec?.dispose(); picture?.dispose();
      if (temporary != null) { try { await temporary.delete(recursive: true); } catch (_) {} }
      _busy[player] = false;
    }
  }

  static Uint8List _encodeLayers(Map<String, Uint8List> files) {
    final archive = Archive();
    for (final entry in files.entries) { archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value)); }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}
