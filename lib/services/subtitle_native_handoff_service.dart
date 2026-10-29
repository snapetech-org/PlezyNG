import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../mpv/mpv.dart';
import '../mpv/player/player_media_session_identity.dart';
import 'player_sync_offsets.dart';
import 'subtitle_overlay_service.dart';
import 'subtitle_retimer.dart';
import 'subtitle_sync_service.dart';

/// Explicit snapshot handoff to an existing native text renderer. The file is
/// on the opened part's clock; subtitle delay is baked exactly once. No claim
/// that a given native PiP/compositor also includes that renderer is implied.
abstract final class SubtitleNativeHandoffService {
  static final Expando<_NativeSubtitleFiles> _owners = Expando();

  static ({Uint8List bytes, int clipped}) export(Player player, SubtitleOverlayTrack track) {
    if (track.positionToSourceMs != null) throw UnsupportedError('A moving live timeline cannot be attached as a fixed native subtitle file');
    final session = SubtitleOverlayService.forPlayer(player);
    if (!session.current || !track.isCurrent() || !session.lanes.contains(track)) {
      throw StateError('The selected subtitle session changed');
    }
    final offset = player.timelineOffset.inMilliseconds;
    final cues = <SubtitleCue>[];
    var clipped = 0;
    for (final cue in track.cues) {
      final start = cue.startMs + track.delayMs - offset;
      final end = cue.endMs + track.delayMs - offset;
      if (start < 0) clipped++;
      if (end <= 0) continue;
      final text = SubtitleOverlayTrack.plain(cue.text).replaceAll(RegExp(r'\r\n?'), '\n')
          .replaceAll(RegExp(r'\n\s*\n'), '\n').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      if (text.trim().isEmpty) continue;
      cues.add(SubtitleCue(index: cues.length + 1, startMs: start < 0 ? 0 : start,
        endMs: end, text: text, cueId: cue.stableId));
    }
    if (cues.isEmpty) throw const FormatException('No captions fall within the opened media part');
    final bytes = SubtitleSyncService.writeSrt(cues);
    if (bytes.length > 5 * 1024 * 1024) throw const FormatException('Native subtitle snapshot exceeds 5 MiB');
    return (bytes: Uint8List.fromList(bytes), clipped: clipped);
  }

  static Future<void> attach(Player player, SubtitleOverlayTrack track, {required bool allowClipping}) async {
    if (!player.supportedLocalSubtitleExtensions.contains('srt')) throw UnsupportedError('This renderer cannot import SRT');
    final session = SubtitleOverlayService.forPlayer(player);
    final snapshot = export(player, track);
    if (snapshot.clipped > 0 && !allowClipping) throw StateError('Confirm clipping at the opened part boundary first');
    bool current() {
      try { return session.current && track.isCurrent() && session.lanes.contains(track); }
      catch (_) { return false; }
    }
    var owner = _owners[player];
    if (owner == null || !owner.mediaCurrent) {
      if (owner != null) unawaited(owner.close());
      owner = _NativeSubtitleFiles(session);
      _owners[player] = owner;
    }
    if (owner.busy || owner.files.length >= 8) throw StateError('Native snapshot limit reached for this media session');
    owner.busy = true;
    File? file;
    final offsets = PlayerSyncOffsets.of(player);
    final previousDelay = offsets.subtitleMs, previousRate = offsets.subtitleRate;
    var changedTiming = false, attached = false;
    try {
      final directory = Directory(p.join((await getTemporaryDirectory()).path, 'plezy_subtitle_handoff'));
      await directory.create(recursive: true);
      if (!current()) throw StateError('Playback changed');
      file = File(p.join(directory.path, '${const Uuid().v4()}.srt'));
      await file.writeAsBytes(snapshot.bytes, flush: true);
      if (!current()) throw StateError('Playback changed');
      changedTiming = true;
      if (player.playerType == 'mpv') await player.setProperty(PlayerSyncOffsets.subtitleRateProperty, '1');
      await player.setProperty(PlayerSyncOffsets.subtitleProperty, '0');
      if (!current()) throw StateError('Playback changed');
      await player.command(['sub-add', file.path, 'select']);
      attached = true;
      if (!current()) throw StateError('Playback changed');
      offsets.recordSubtitleRate(1);
      offsets.recordApplied(PlayerSyncOffsets.subtitleProperty, 0);
      owner.files.add(file);
      file = null;
      final lane = session.lanes.indexOf(track);
      if (lane >= 0) session.lanes[lane] = null;
      session.changed();
    } catch (_) {
      if (changedTiming && current()) {
        try {
          if (player.playerType == 'mpv') await player.setProperty(PlayerSyncOffsets.subtitleRateProperty, '$previousRate');
          await player.setProperty(PlayerSyncOffsets.subtitleProperty, '${previousDelay / 1000}');
        } catch (_) {}
      }
      // A command can finish just as the profile/audio changes. Retain a file
      // already handed to the renderer until the media session releases it.
      if (attached && file != null && owner.mediaCurrent) { owner.files.add(file); file = null; }
      rethrow;
    } finally {
      if (file != null) { try { await file.delete(); } catch (_) {} }
      owner.busy = false;
    }
  }
}

class _NativeSubtitleFiles {
  _NativeSubtitleFiles(this.session)
      : generation = session.player is PlayerMediaSessionIdentity ? (session.player as PlayerMediaSessionIdentity).mediaSessionGeneration : null {
    timer = Timer.periodic(const Duration(seconds: 2), (_) { if (!mediaCurrent && !busy) unawaited(close()); });
  }
  final SubtitleOverlaySession session;
  final int? generation;
  bool get mediaCurrent => !session.player.disposed && (generation == null ||
      (session.player as PlayerMediaSessionIdentity).mediaSessionGeneration == generation);
  final List<File> files = [];
  Timer? timer;
  bool busy = false;
  Future<void> close() async {
    timer?.cancel(); timer = null;
    final expired = List<File>.of(files); files.clear();
    for (final file in expired) { try { await file.delete(); } catch (_) {} }
  }
}
