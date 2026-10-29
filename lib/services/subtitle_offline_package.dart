import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../mpv/mpv.dart';
import 'subtitle_font_store.dart';
import 'subtitle_native_handoff_service.dart';
import 'subtitle_overlay_service.dart';

/// Explicit portable text snapshot with the selected imported font, its
/// supplied license and exact byte accounting. Not a full ASS/bitmap package.
abstract final class SubtitleOfflinePackage {
  static Future<({Uint8List bytes, int clipped, int fontBytes})> create(Player player, SubtitleOverlayTrack track) async {
    final snapshot = SubtitleNativeHandoffService.export(player, track);
    final session = SubtitleOverlayService.forPlayer(player);
    final family = track.fontFamily;
    final appearance = track.appearance();
    final offset = player.timelineOffset.inMilliseconds;
    final delay = track.delayMs;
    bool current() => !player.disposed && session.current && track.isCurrent() && session.lanes.contains(track) &&
        track.fontFamily == family && track.delayMs == delay && player.timelineOffset.inMilliseconds == offset;
    final store = SubtitleFontStore.instance;
    await store.initialize();
    if (!current()) throw StateError('The subtitle snapshot changed while preparing its package.');
    final entries = <String, Uint8List>{'captions.srt': snapshot.bytes};
    final font = store.findFamily(family);
    var fontBytes = 0;
    if (font != null) {
      final bytes = await store.verifiedBytes(font);
      entries['fonts/${font.digest}.otf'] = bytes;
      if (font.license.isNotEmpty) entries['fonts/${font.digest}.license.txt'] = Uint8List.fromList(utf8.encode(font.license));
      fontBytes = bytes.length;
    }
    final manifest = {
      'schema': 1, 'type': 'plezy-subtitle-offline-text', 'clock': 'opened-media-part',
      'subtitleDelayBakedIn': true, 'clippedAtPartStart': snapshot.clipped,
      'appearance': appearance, 'appearanceAppliedBySrt': false,
      'font': font?.toJson(), 'fontBytes': fontBytes,
      'externalFontRequirement': font == null ? family : null,
      'files': [for (final entry in entries.entries) {'path': entry.key, 'bytes': entry.value.length,
        'sha256': sha256.convert(entry.value).toString()}],
      'contentBytes': entries.values.fold<int>(0, (sum, bytes) => sum + bytes.length),
    };
    entries['manifest.json'] = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)));
    entries['README.txt'] = Uint8List.fromList(utf8.encode(
      'PlezyNG offline subtitle text snapshot\n\n'
      'captions.srt uses the opened media part clock and already includes the lane delay. '
      'Do not apply that delay again. Cues before the part were omitted or clipped.\n'
      'SRT retains text and timing; appearance, ruby readings, signs and original word timing are not preserved by SRT. '
      'The manifest records the requested appearance but other players need their own style settings.\n'
      'Only the selected explicitly imported font is included. Bundled and system font families remain an external requirement. '
      'A receiver may use its own fallback and must not automatically install fonts from this archive. '
      'Use fonts according to their license; supplied attribution is retained next to the font.\n'
      'This package contains no media URL, server credentials or automatic playback selection.\n'));
    final total = entries.values.fold<int>(0, (sum, bytes) => sum + bytes.length);
    if (total > 24 * 1024 * 1024) throw const FormatException('The offline text/font package exceeds 24 MiB.');
    final bytes = await compute(_encode, entries);
    if (!current()) throw StateError('The subtitle snapshot changed before export completed.');
    return (bytes: bytes, clipped: snapshot.clipped, fontBytes: fontBytes);
  }

  static Uint8List _encode(Map<String, Uint8List> entries) {
    final archive = Archive();
    for (final entry in entries.entries) { archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value)); }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}
