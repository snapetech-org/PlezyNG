import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../focus/focusable_button.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/app_icon.dart';
import 'game_presentation.dart';

/// Same source identity and theme as Games, including in a small workspace pane.
class GameStreamStatus extends StatelessWidget {
  const GameStreamStatus({
    super.key,
    required this.state,
    required this.gameName,
    required this.computerName,
    required this.onReconnect,
    required this.onDisconnect,
  });
  final String state, gameName, computerName;
  final VoidCallback onReconnect, onDisconnect;
  @override
  Widget build(BuildContext context) {
    final recoverable = state == 'failed' || state == 'disconnected';
    final label = switch (state) {
      'failed' => t.games.disconnected,
      'disconnected' => t.games.disconnected,
      'disconnecting' => t.games.disconnecting,
      'reconnecting' => t.games.reconnecting,
      _ => t.games.connecting,
    };
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SteamSourceBadge(),
                const SizedBox(height: 20),
                Text(
                  isolateDisplayText(gameName),
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(isolateDisplayText(computerName), textAlign: TextAlign.center),
                const SizedBox(height: 20),
                ExcludeSemantics(
                  child: AppIcon(recoverable ? Symbols.wifi_off_rounded : Symbols.cast_rounded, size: 32),
                ),
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                ),
                const SizedBox(height: 8),
                Text(recoverable ? t.games.streamRecoveryHelp : t.games.streamConnectHelp, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (recoverable)
                      FocusableButton(
                        onPressed: onReconnect,
                        useBackgroundFocus: true,
                        child: FilledButton.icon(
                          onPressed: onReconnect,
                          icon: const AppIcon(Symbols.refresh_rounded),
                          label: Text(t.games.reconnect),
                        ),
                      ),
                    if (!recoverable && state != 'disconnecting')
                      FocusableButton(
                        onPressed: onDisconnect,
                        child: OutlinedButton(onPressed: onDisconnect, child: Text(t.games.disconnect)),
                      ),
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
