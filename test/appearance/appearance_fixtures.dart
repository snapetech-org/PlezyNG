import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/models/download_models.dart';
import '../test_helpers/download_fixtures.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/focus/locked_hub_controller.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/screens/auth_screen.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:plezy/widgets/hero_hub_section.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:plezy/widgets/settings_page.dart';
import 'package:plezy/widgets/settings_section.dart';
import 'package:plezy/widgets/video_controls/video_control_button.dart';
import 'package:plezy/widgets/video_controls/widgets/skip_marker_button.dart';
import 'package:plezy/widgets/video_controls/widgets/video_timeline_bar.dart';
import 'package:plezy/widgets/video_controls/widgets/volume_control.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/player_streams.dart';
import '../test_helpers/profile_navigation.dart';

enum AppearanceScene { home, detail, settings, player, login }

final appearanceMovie = testMediaItem(
  id: 'appearance_movie',
  backend: MediaBackend.jellyfin,
  title: 'The Last Observatory',
  year: 2026,
  contentRating: 'PG',
  summary: 'An astronomer returns to a remote observatory to discover a message hidden among the stars.',
  genres: ['Adventure', 'Mystery'],
);

Widget appearanceApp({
  required Widget child,
  MonoPalette palette = MonoPalette.dark,
  double textScale = 1,
  TextDirection direction = TextDirection.ltr,
  bool loadFonts = false,
  TargetPlatform platform = TargetPlatform.android,
}) {
  var theme = monoTheme(palette).copyWith(platform: platform);
  if (loadFonts) {
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'Appearance Sans'),
      appBarTheme: theme.appBarTheme.copyWith(
        titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Appearance Sans'),
      ),
    );
  }
  return TranslationProvider(
    child: InputModeTracker(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: true),
          child: Directionality(textDirection: direction, child: child!),
        ),
        home: ChangeNotifierProvider<DownloadProvider>(
          create: (_) => AppearanceDownloads(),
          child: withProfileNavigationScope(child: child),
        ),
      ),
    ),
  );
}

Widget appearanceScene(AppearanceScene scene) => switch (scene) {
  AppearanceScene.home => Scaffold(
    body: ListView(
      children: [
        HeroHubSection(
          hub: MediaHub(
            id: 'featured',
            title: 'Featured',
            type: 'movie',
            items: [appearanceMovie],
            heroAutoSlide: false,
          ),
          showBackdrop: false,
          onVerticalNavigation: (_) => false,
        ),
        HubSection(
          hub: MediaHub(
            id: 'recent',
            title: 'Recently added',
            type: 'movie',
            items: [
              for (var i = 0; i < 6; i++)
                testMediaItem(id: 'film_$i', title: 'A journey beyond the horizon $i', year: 2026),
            ],
          ),
          focusMemory: HubFocusMemory(),
          icon: Symbols.video_library_rounded,
        ),
      ],
    ),
  ),
  AppearanceScene.detail => MediaDetailScreen(metadata: appearanceMovie),
  AppearanceScene.settings => SettingsPage(
    title: const Text('Appearance'),
    children: [
      SettingsGroup(
        title: 'Interface',
        children: [
          FocusableListTile(
            leading: const AppIcon(Symbols.palette_rounded),
            title: const Text('Colour theme'),
            subtitle: const Text('Follow the device appearance'),
            trailing: const AppIcon(Symbols.chevron_right_rounded),
            onTap: () {},
          ),
          FocusableSwitchListTile(
            secondary: const AppIcon(Symbols.motion_photos_off_rounded),
            title: const Text('Reduce motion'),
            subtitle: const Text('Use still transitions and loading indicators'),
            value: true,
            onChanged: (_) {},
          ),
          FocusableSwitchListTile(
            secondary: const AppIcon(Symbols.text_increase_rounded),
            title: const Text('Larger text'),
            subtitle: const Text('Keep labels and controls easy to read'),
            value: false,
            onChanged: (_) {},
          ),
        ],
      ),
      SettingsGroup(
        title: 'Preview',
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () {},
                  icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1, weight: 600),
                  label: const Text('Play'),
                ),
                OutlinedButton.icon(
                  onPressed: () {},
                  icon: const AppIcon(Symbols.add_rounded),
                  label: const Text('My list'),
                ),
                TextButton(onPressed: () {}, child: const Text('Reset')),
              ],
            ),
          ),
        ],
      ),
    ],
  ),
  AppearanceScene.player => const AppearancePlayer(),
  AppearanceScene.login => const AuthScreen(initializeServices: false),
};

class AppearancePlayer extends StatefulWidget {
  const AppearancePlayer({super.key});
  @override
  State<AppearancePlayer> createState() => _AppearancePlayerState();
}

class _AppearancePlayerState extends State<AppearancePlayer> {
  final player = AppearanceFakePlayer();
  final skipFocus = FocusNode();
  late final volume = VideoVolumeController(player: player, settings: SettingsService.instance, initialVolume: 60);
  @override
  void dispose() {
    volume.dispose();
    skipFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0B1118),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('The Last Observatory', style: TextStyle(color: Colors.white, fontSize: 20)),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: SkipMarkerButton(
                      marker: MediaMarker(id: 1, type: 'intro', startTimeOffset: 0, endTimeOffset: 90000),
                      playerDuration: const Duration(minutes: 110),
                      hasNextEpisode: false,
                      isAutoSkipActive: true,
                      shouldShowAutoSkip: true,
                      autoSkipDelay: 5,
                      autoSkipProgress: .4,
                      focusNode: skipFocus,
                      onActivate: () {},
                      onFocusDown: () {},
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
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
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      VideoControlButton(icon: Symbols.play_arrow_rounded, onPressed: () {}, tooltip: 'Play'),
                      VolumeControl(volumeController: volume),
                      VideoControlButton(
                        icon: Symbols.subtitles_rounded,
                        isActive: true,
                        onPressed: () {},
                        tooltip: 'Subtitles',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class AppearanceFakePlayer implements Player {
  final _streams = emptyPlayerStreams();
  @override
  PlayerState get state =>
      PlayerState(volume: 60, position: const Duration(minutes: 27), duration: const Duration(minutes: 110));
  @override
  PlayerStreams get streams => _streams;
  @override
  Future<void> setVolume(double value) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class AppearanceDownloads extends NoSyncRulesDownloadProvider {
  @override
  DownloadProgress? getProgress(String globalKey) => null;
  @override
  bool isQueueing(String globalKey) => false;
  @override
  bool isDownloaded(String globalKey) => false;
}
