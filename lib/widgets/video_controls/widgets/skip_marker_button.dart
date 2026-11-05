import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/media_source_info.dart';
import '../../../theme/mono_tokens.dart';
import '../../app_icon.dart';
import 'player_chrome_style.dart';

class SkipMarkerButton extends StatelessWidget {
  final MediaMarker marker;
  final Duration playerDuration;
  final bool hasNextEpisode;
  final bool isAutoSkipActive;
  final bool shouldShowAutoSkip;
  final int autoSkipDelay;
  final double autoSkipProgress;
  final FocusNode focusNode;
  final VoidCallback onActivate;
  final VoidCallback onFocusDown;

  const SkipMarkerButton({
    super.key,
    required this.marker,
    required this.playerDuration,
    required this.hasNextEpisode,
    required this.isAutoSkipActive,
    required this.shouldShowAutoSkip,
    required this.autoSkipDelay,
    required this.autoSkipProgress,
    required this.focusNode,
    required this.onActivate,
    required this.onFocusDown,
  });

  @override
  Widget build(BuildContext context) {
    final isCredits = marker.isCredits;
    final creditsAtEnd =
        isCredits && playerDuration > Duration.zero && (playerDuration - marker.endTime).inMilliseconds <= 1000;
    final showNextEpisode = creditsAtEnd && hasNextEpisode;
    String baseButtonText;
    if (showNextEpisode) {
      baseButtonText = t.videoControls.nextEpisode;
    } else if (marker.isCommercial) {
      baseButtonText = t.videoControls.skipAds;
    } else if (isCredits) {
      baseButtonText = t.videoControls.skipCredits;
    } else {
      baseButtonText = t.videoControls.skipIntro;
    }

    final remainingSeconds = isAutoSkipActive && shouldShowAutoSkip
        ? (autoSkipDelay - (autoSkipProgress * autoSkipDelay)).ceil().clamp(0, autoSkipDelay)
        : 0;

    final showAutoSkipCountdown = isAutoSkipActive && shouldShowAutoSkip;
    final buttonText = showAutoSkipCountdown && remainingSeconds > 0
        ? '$baseButtonText ($remainingSeconds)'
        : baseButtonText;
    final buttonIcon = showNextEpisode ? Symbols.skip_next_rounded : Symbols.fast_forward_rounded;
    final radius = tokens(context).radiusMd;
    final accent = PlayerChromeStyle.accent(context);

    return FocusableWrapper(
      focusNode: focusNode,
      onSelect: _activate,
      borderRadius: radius,
      autoScroll: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
          onFocusDown();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _activate,
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            children: [
              Container(
                constraints: BoxConstraints(maxWidth: (MediaQuery.sizeOf(context).width - 48).clamp(0, 600)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: PlayerChromeStyle.surface,
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: accent.withValues(alpha: 0.5)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2)),
                  ],
                ),
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    Flexible(
                      child: Text(
                        buttonText,
                        style: const TextStyle(color: PlayerChromeStyle.foreground, fontSize: 16, fontWeight: .w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    AppIcon(buttonIcon, fill: 1, color: accent, size: 20),
                  ],
                ),
              ),
              if (isAutoSkipActive && shouldShowAutoSkip)
                PositionedDirectional(
                  start: radius,
                  end: radius,
                  bottom: 0,
                  child: ExcludeSemantics(
                    child: LinearProgressIndicator(
                      value: autoSkipProgress.isFinite ? autoSkipProgress.clamp(0.0, 1.0) : 0,
                      minHeight: 3,
                      color: accent,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _activate() => onActivate();
}
