// Documentation-only composition: real widgets, simulated state, attributed still.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/widgets/video_controls/video_control_button.dart';
import 'package:plezy/widgets/video_controls/widgets/video_timeline_bar.dart';
import 'package:plezy/widgets/video_controls/widgets/volume_control.dart';
import '../../test/appearance/appearance_fixtures.dart';

class PlayerMockup extends StatefulWidget {
  const PlayerMockup({super.key});

  @override
  State<PlayerMockup> createState() => _PlayerMockupState();
}

class _PlayerMockupState extends State<PlayerMockup> {
  final player = _StillPlayer();
  late final volume = VideoVolumeController(player: player, settings: SettingsService.instance, initialVolume: 60);

  @override
  void dispose() {
    volume.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(File('tools/store-assets/fixtures/caminandes-frame.jpg').readAsBytesSync(), fit: BoxFit.cover),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xB3000000), Color(0x18000000), Color(0xE6000000)],
              stops: [0, .45, 1],
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: Row(
                  children: [
                    VideoControlButton(icon: Symbols.arrow_back_rounded, tooltip: 'Back', onPressed: () {}),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Text(
                        'Caminandes: Gran Dillama',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
                      ),
                    ),
                    VideoControlButton(icon: Symbols.tune_rounded, tooltip: 'Playback settings', onPressed: () {}),
                    VideoControlButton(icon: Symbols.subtitles_rounded, tooltip: 'Subtitles', onPressed: () {}),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(color: Color(0x66000000), shape: BoxShape.circle),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: VideoControlButton(
                        icon: Symbols.play_arrow_rounded,
                        iconSize: 56,
                        tooltip: 'Play',
                        onPressed: () {},
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: VideoTimelineBar(
                  player: player,
                  chapters: const [],
                  chaptersLoaded: true,
                  onSeek: (_) {},
                  onSeekEnd: (_) {},
                  horizontalLayout: false,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Row(
                  children: [
                    VideoControlButton(icon: Symbols.skip_previous_rounded, tooltip: 'Previous', onPressed: () {}),
                    VideoControlButton(icon: Symbols.play_arrow_rounded, tooltip: 'Play', onPressed: () {}),
                    VideoControlButton(icon: Symbols.skip_next_rounded, tooltip: 'Next', onPressed: () {}),
                    VolumeControl(volumeController: volume),
                    const Spacer(),
                    VideoControlButton(
                      icon: Symbols.subtitles_rounded,
                      tooltip: 'Subtitles',
                      isActive: true,
                      onPressed: () {},
                    ),
                    VideoControlButton(icon: Symbols.fullscreen_rounded, tooltip: 'Fullscreen', onPressed: () {}),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _StillPlayer extends AppearanceFakePlayer {
  @override
  PlayerState get state =>
      PlayerState(volume: 60, position: const Duration(seconds: 30), duration: const Duration(seconds: 146));
}
