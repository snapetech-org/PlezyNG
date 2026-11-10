import 'package:material_symbols_icons/symbols.dart';
import '../../widgets/app_icon.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_playback_service.dart';
import '../../services/music/music_audio_policy.dart';

/// Simplified presentation only. It never creates a second player, changes
/// the queue, starts playback on entry, or overrides vehicle restrictions.
class MusicDrivingScreen extends StatelessWidget {
  const MusicDrivingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicPlaybackService>();
    final track = music.currentTrack;
    Widget control(IconData icon, String label, Future<void> Function() action, {bool primary = false}) =>
        IconButton.filledTonal(
          tooltip: label,
          iconSize: primary ? 72 : 56,
          padding: const EdgeInsets.all(20),
          onPressed: track == null ? null : action,
          icon: AppIcon(icon),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(t.musicExperience.driving),
        leading: IconButton(
          tooltip: t.musicExperience.exitDriving,
          icon: const AppIcon(Symbols.close_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    track?.displayTitle ?? t.musicExperience.ready,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  track?.trackArtistTitle ?? '',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 20,
                  runSpacing: 16,
                  children: [
                    control(Symbols.skip_previous_rounded, t.music.previousTrack, music.previous),
                    control(
                      music.isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                      music.isPlaying ? t.common.pause : t.common.play,
                      music.togglePlayPause,
                      primary: true,
                    ),
                    control(Symbols.skip_next_rounded, t.music.nextTrack, music.next),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> openMusicDriving(BuildContext context) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const MusicDrivingScreen()));

Future<void> showMusicSignalPath(BuildContext context) async {
  final music = context.read<MusicPlaybackService>();
  final path = music is MusicSignalPathService ? (music as MusicSignalPathService).signalPath : null;
  final output = music is MusicAudioControls
      ? (music as MusicAudioControls).inspectAudioOutput()
      : Future.value(<String, String>{});
  final s = t.musicExperience;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.signalPath, style: Theme.of(context).textTheme.titleLarge),
            if (path != null) ...[
              ListTile(title: Text(s.source), subtitle: Text('${path.offline ? s.local : s.network} · ${path.method}')),
              ListTile(title: Text(s.codec), subtitle: Text(path.codec ?? s.unknown)),
              ListTile(title: Text(s.channels), subtitle: Text(path.channels?.toString() ?? s.unknown)),
              ListTile(title: Text(s.engine), subtitle: Text(path.engine)),
              ListTile(
                title: Text(s.processing),
                subtitle: Text(
                  [
                    '${s.normalization}: ${path.normalization ? s.on : s.off}',
                    '${s.equalizer}: ${path.equalizer ? s.on : s.off}',
                    '${s.fades}: ${path.fades ? s.on : s.off}',
                  ].join('\n'),
                ),
              ),
            ],
            Text(s.outputUnknown),
            FutureBuilder<Map<String, String>>(
              future: output,
              builder: (context, snapshot) {
                final values = snapshot.data ?? const <String, String>{};
                return Column(
                  children: [
                    if (values['audio-params/samplerate'] case final rate?)
                      ListTile(title: Text('${s.source} · ${t.fileInfo.sampleRate}'), subtitle: Text('$rate Hz')),
                    if (values['audio-out-params/samplerate'] case final rate?)
                      ListTile(
                        title: Text('${t.videoSettings.audioOutput} · ${t.fileInfo.sampleRate}'),
                        subtitle: Text('$rate Hz'),
                      ),
                    if (values['audio-out-params/channel-count'] case final count?)
                      ListTile(title: Text('${t.videoSettings.audioOutput} · ${s.channels}'), subtitle: Text(count)),
                    if (values['audio-out-params/format'] case final format?)
                      ListTile(title: Text(t.fileInfo.codec), subtitle: Text(format)),
                    if (values['audio-device'] case final device?)
                      ListTile(title: Text(t.videoSettings.audioOutput), subtitle: Text(device)),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}
