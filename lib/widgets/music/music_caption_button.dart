import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../profiles/active_profile_provider.dart';
import '../../services/driver_distraction.dart';
import '../../services/music/music_playback_service.dart';
import '../../services/subtitle_analysis_source.dart';
import '../../services/subtitle_revision_service.dart';
import '../overlay_sheet.dart';
import '../video_controls/sheets/subtitle_ai_sheet.dart';

/// Borrows the queue owner's player. Closing this sheet never stops music.
class MusicCaptionButton extends StatelessWidget {
  const MusicCaptionButton({super.key, required this.service, this.color});
  final MusicPlaybackService service;
  final Color? color;

  Future<void> _open(BuildContext context, MusicSubtitleAccess access) async {
    final profiles = context.read<ActiveProfileProvider>();
    final profile = profiles.activeId;
    bool current() => access.isCurrent() && profiles.activeId == profile && automotivePlaybackAllowedNow();
    if (profile == null || !current()) return;
    Future<SubtitleAnalysisSource> openSource() async {
      if (!current()) throw StateError('The music track or profile changed.');
      final source = await access.openAnalysisSource();
      if (!current() || !source.isCurrent()) {
        await source.close();
        throw StateError('The music track or profile changed.');
      }
      return SubtitleAnalysisSource(uri: source.uri, identity: source.identity,
        durationMs: source.durationMs, timelineOffsetMs: source.timelineOffsetMs,
        isCurrent: () => current() && source.isCurrent(), close: source.close);
    }
    await OverlaySheetController.showAdaptive<void>(context, isScrollControlled: true,
      builder: (_) => SubtitleAiSheet(player: access.player, mediaIndex: access.mediaIndex,
        mediaTitle: access.item.title, sourceLabel: 'Music library', appOverlayOnly: true,
        revisionIdentity: SubtitleRevisionIdentity(profileId: profile,
          serverId: access.item.serverId ?? 'music-library',
          ratingKey: 'music:${access.item.id}:${access.sourceIdentity}', mediaIndex: access.mediaIndex,
          mediaTitle: access.item.title, sourceLabel: 'Music library'),
        isRevisionIdentityCurrent: current, openAnalysisSource: openSource));
  }

  @override
  Widget build(BuildContext context) {
    final owner = service;
    final access = owner is MusicSubtitleService ? owner.subtitleAccess : null;
    if (access == null || !automotivePlaybackAllowedNow()) return const SizedBox.shrink();
    void open() => unawaited(_open(context, access));
    return FocusableButton(autoScroll: false, onPressed: open,
      child: IconButton(tooltip: t.videoControls.subtitleCueTools, onPressed: open,
        icon: Icon(Icons.subtitles_outlined, color: color)));
  }
}
