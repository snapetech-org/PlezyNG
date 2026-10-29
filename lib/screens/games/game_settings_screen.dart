import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../games/steam_internet_tunnel.dart';
import '../../games/steam_stream_preferences.dart';
import '../../i18n/strings.g.dart';
import '../../services/settings_service.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/settings_section.dart';
import '../../widgets/setting_tile.dart';
import '../settings/settings_utils.dart' show DialogOption;
import 'game_presentation.dart';

class GameSettingsScreen extends StatelessWidget {
  const GameSettingsScreen({super.key, required this.profileId, required this.onChooseFolder});
  final String profileId;
  final VoidCallback onChooseFolder;
  @override
  Widget build(BuildContext context) => !PlatformDetector.supportsEmbeddedGameStreaming()
      ? FocusedScrollScaffold(
          title: Text(t.games.streamSettings),
          slivers: [
            SliverToBoxAdapter(
              child: GameNotice(title: t.games.browseOnlyTitle, message: t.games.browseOnlyHelp),
            ),
          ],
        )
      : _streamingSettings(context);

  Widget _streamingSettings(BuildContext context) => FocusedScrollScaffold(
    title: Text(t.games.streamSettings),
    focusableAppBarActions: true,
    slivers: [
      SliverToBoxAdapter(
        child: SettingsGroup(
          title: t.games.streamingGroup,
          children: [
            if (PlatformDetector.supportsEmbeddedGameStreaming()) ...[
              SettingSelectionTile<SteamStreamQuality>(
                pref: SettingsService.steamQualityForProfile(profileId),
                icon: Symbols.tune_rounded,
                title: t.games.streamQuality,
                subtitleBuilder: _qualityLabel,
                description: t.games.streamQualityHelp,
                options: [
                  for (final quality in SteamStreamQuality.values)
                    DialogOption(
                      value: quality,
                      title: _qualityLabel(quality),
                      subtitle: '${quality.height}p · ${quality.fps} fps · ${quality.bitrateKbps ~/ 1000} Mbps',
                    ),
                ],
              ),
              SettingSelectionTile<SteamStreamCodec>(
                pref: SettingsService.steamCodecForProfile(profileId),
                icon: Symbols.movie_rounded,
                title: t.games.streamCodec,
                subtitleBuilder: (codec) => codec == SteamStreamCodec.automatic ? t.games.codecAutomatic : 'H.264',
                description: t.games.streamCodecHelp,
                options: [
                  DialogOption(value: SteamStreamCodec.automatic, title: t.games.codecAutomatic),
                  const DialogOption(value: SteamStreamCodec.h264, title: 'H.264'),
                ],
              ),
              SettingSelectionTile<SteamStreamAudio>(
                pref: SettingsService.steamAudioForProfile(profileId),
                icon: Symbols.surround_sound_rounded,
                title: t.games.streamAudio,
                subtitleBuilder: _audioLabel,
                description: t.games.streamAudioHelp,
                options: [
                  for (final audio in SteamStreamAudio.values) DialogOption(value: audio, title: _audioLabel(audio)),
                ],
              ),
            ],
          ],
        ),
      ),

      SliverToBoxAdapter(
        child: SettingsGroup(
          title: t.games.controllerSettings,
          children: [
            if (PlatformDetector.supportsEmbeddedGameStreaming())
              SettingSelectionTile<int>(
                pref: SettingsService.steamControllerCountForProfile(profileId),
                icon: Symbols.sports_esports_rounded,
                title: t.games.controllerSeats,
                subtitleBuilder: (count) => '$count',
                description: t.games.controllerSeatsHelp,
                options: [for (var count = 1; count <= 4; count++) DialogOption(value: count, title: '$count')],
              ),
            SettingSwitchTile(
              pref: SettingsService.gameTouchControlsForProfile(profileId),
              icon: Symbols.touch_app_rounded,
              title: t.games.touchControls,
              subtitle: t.games.touchDescription,
            ),
            if (PlatformDetector.supportsEmbeddedGameStreaming()) ...[
              SettingSwitchTile(
                pref: SettingsService.steamControllerRumbleForProfile(profileId),
                icon: Symbols.vibration_rounded,
                title: t.games.controllerRumble,
                subtitle: t.games.controllerRumbleHelp,
              ),
              SettingSwitchTile(
                pref: SettingsService.steamMotionControllerForProfile(profileId),
                icon: Symbols.screen_rotation_rounded,
                title: t.games.motionController,
                subtitle: t.games.motionControllerHelp,
              ),
              SettingSelectionTile<int>(
                pref: SettingsService.steamTouchOpacityForProfile(profileId),
                icon: Symbols.opacity_rounded,
                title: t.games.touchOpacity,
                subtitleBuilder: (value) => '$value%',
                description: t.games.touchAppearanceHelp,
                options: [
                  for (final value in [50, 65, 85, 100]) DialogOption(value: value, title: '$value%'),
                ],
              ),
              SettingSwitchTile(
                pref: SettingsService.steamSwapTouchSidesForProfile(profileId),
                icon: Symbols.swap_horiz_rounded,
                title: t.games.swapTouchSides,
                subtitle: t.games.touchAppearanceHelp,
              ),
            ],
            Padding(padding: const EdgeInsets.all(16), child: Text(t.games.touchSetupHint)),
            if (PlatformDetector.supportsEmbeddedGameStreaming())
              SettingSwitchTile(
                pref: SettingsService.allowGameSessionControlForProfile(profileId),
                icon: Symbols.phonelink_rounded,
                title: t.games.allowSessionControl,
                subtitle: t.games.allowSessionControlHelp,
              ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: SettingsGroup(
          title: t.games.advancedStreaming,
          children: [
            Padding(padding: const EdgeInsets.all(16), child: Text(t.games.advancedStreamingHelp)),
            if (steamRelayUri() != null)
              SettingSwitchTile(
                pref: SettingsService.steamInternetForProfile(profileId),
                icon: Symbols.public_rounded,
                title: t.games.internetStreaming,
                subtitle: t.games.internetStreamingHelp,
              ),
            if ({
              TargetPlatform.android,
              TargetPlatform.iOS,
              TargetPlatform.macOS,
              TargetPlatform.linux,
              TargetPlatform.windows,
            }.contains(defaultTargetPlatform))
              SettingSwitchTile(
                pref: SettingsService.gamePyrowaveForProfile(profileId),
                icon: Symbols.speed_rounded,
                title: t.games.steamBetaTitle,
                subtitle: t.games.steamBetaDescription,
              )
            else
              Padding(padding: const EdgeInsets.all(16), child: Text(t.games.steamBetaDescription)),
          ],
        ),
      ),
      if (PlatformDetector.isDesktopOS())
        SliverToBoxAdapter(
          child: SettingsGroup(
            title: t.games.shareLibrary,
            children: [
              SettingSwitchTile(
                pref: SettingsService.shareSteamInventoryForProfile(profileId),
                icon: Symbols.library_books_rounded,
                title: t.games.shareLibrary,
                subtitle: t.games.shareLibraryHelp,
              ),
              SettingSwitchTile(
                pref: SettingsService.allowSteamActionsForProfile(profileId),
                icon: Symbols.security_rounded,
                title: t.games.allowHostActions,
                subtitle: t.games.allowHostActionsHelp,
              ),
              if ({TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS}.contains(defaultTargetPlatform))
                SettingSwitchTile(
                  pref: SettingsService.allowSteamCloudSettingsForProfile(profileId),
                  icon: Symbols.cloud_sync_rounded,
                  title: t.games.allowCloudSettings,
                  subtitle: t.games.allowCloudSettingsHelp,
                ),
              SettingSwitchTile(
                pref: SettingsService.allowSteamInstallForProfile(profileId),
                icon: Symbols.download_rounded,
                title: t.games.allowHostInstall,
                subtitle: t.games.allowHostInstallHelp,
              ),
              FocusableListTile(
                leading: const AppIcon(Symbols.folder_rounded),
                title: Text(t.games.steamInstallFolder),
                subtitle: Text(
                  SettingsService.instance.read(SettingsService.steamInstallRootForProfile(profileId)) ??
                      t.games.automaticFolder,
                ),
                onTap: onChooseFolder,
              ),
            ],
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ],
  );
  String _audioLabel(SteamStreamAudio audio) => switch (audio) {
    SteamStreamAudio.stereo => t.games.audioStereo,
    SteamStreamAudio.quad => t.games.audioQuad,
    SteamStreamAudio.surround51 => t.games.audioSurround51,
  };

  String _qualityLabel(SteamStreamQuality quality) => switch (quality) {
    SteamStreamQuality.balanced => t.games.qualityBalanced,
    SteamStreamQuality.reducedBandwidth => t.games.qualityReducedBandwidth,
    SteamStreamQuality.sharperPicture => t.games.qualitySharperPicture,
    SteamStreamQuality.reducedFrameRate => t.games.qualityReducedFrameRate,
    SteamStreamQuality.ultraHd => t.games.qualityUltraHd,
    SteamStreamQuality.highRefresh => t.games.qualityHighRefresh,
  };
}
