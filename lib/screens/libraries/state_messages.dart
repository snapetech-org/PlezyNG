import 'package:flutter/material.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../theme/mono_tokens.dart';
import '../../widgets/app_brand.dart';

/// Base widget for displaying state messages (empty, error, etc.)
/// Provides a consistent UI pattern for showing icons, messages, and actions
class StateMessageWidget extends StatelessWidget {
  /// The main message/title to display
  final String message;

  /// Optional subtitle/description below the message
  final String? subtitle;

  /// Optional icon to display above the message
  final IconData? icon;

  /// Optional size for the icon (default: 64)
  final double iconSize;

  final Color? iconColor;

  final Color? textColor;

  final Color? subtitleColor;

  final VoidCallback? onAction;

  final String? actionLabel;

  /// Optional icon for the action button
  final IconData? actionIcon;
  final FocusNode? actionFocusNode;
  final VoidCallback? onActionNavigateUp;
  final VoidCallback? onActionNavigateLeft;
  final VoidCallback? onActionBack;

  /// Whether the action button should request focus when it appears.
  final bool actionAutofocus;

  /// Whether the action button uses a background focus indicator.
  final bool actionUseBackgroundFocus;
  final bool showBrand;

  const StateMessageWidget({
    super.key,
    required this.message,
    this.subtitle,
    this.icon,
    this.iconSize = 64,
    this.iconColor,
    this.textColor,
    this.subtitleColor,
    this.onAction,
    this.actionLabel,
    this.actionFocusNode,
    this.onActionNavigateUp,
    this.onActionNavigateLeft,
    this.onActionBack,
    this.actionIcon,
    this.actionAutofocus = false,
    this.actionUseBackgroundFocus = false,
    this.showBrand = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appearance = theme.extension<MonoTokens>();
    final textMuted = appearance?.textMuted ?? theme.colorScheme.onSurfaceVariant;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisAlignment: .center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null || showBrand) ...[
                SizedBox.square(
                  dimension: iconSize + 16,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (icon == null)
                        AppBrandMark(size: iconSize, decorative: true, monochrome: true)
                      else
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: (iconColor ?? theme.colorScheme.primary).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(appearance?.radiusLg ?? 20),
                          ),
                          child: AppIcon(icon, fill: 0, weight: 500, size: iconSize, color: iconColor ?? textMuted),
                        ),
                      if (showBrand && icon != null)
                        PositionedDirectional(
                          end: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.scaffoldBackgroundColor,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Padding(
                              padding: EdgeInsets.all(2),
                              child: AppBrandMark(size: 20, decorative: true),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(color: textColor ?? theme.colorScheme.onSurface),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: subtitleColor ?? textMuted),
                ),
              ],
              if (onAction != null && actionLabel != null) ...[
                const SizedBox(height: 24),
                FocusableButton(
                  focusNode: actionFocusNode,
                  onNavigateUp: onActionNavigateUp,
                  onNavigateLeft: onActionNavigateLeft,
                  onBack: onActionBack,
                  onPressed: onAction,
                  autofocus: actionAutofocus,
                  useBackgroundFocus: actionUseBackgroundFocus,
                  child: FilledButton.icon(
                    onPressed: onAction,
                    icon: AppIcon(actionIcon ?? Symbols.refresh_rounded, fill: 1),
                    label: Text(actionLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A reusable widget for displaying empty states throughout the app
class EmptyStateWidget extends StatelessWidget {
  /// The message to display
  final String message;

  /// Optional subtitle/description below the message
  final String? subtitle;

  /// Optional icon to display above the message
  final IconData? icon;

  final double iconSize;

  final VoidCallback? onAction;

  /// Optional label for the action button
  final String? actionLabel;

  /// Optional icon for the action button (defaults to a generic add icon)
  final IconData? actionIcon;
  final FocusNode? actionFocusNode;
  final VoidCallback? onActionNavigateUp;
  final VoidCallback? onActionNavigateLeft;
  final VoidCallback? onActionBack;

  const EmptyStateWidget({
    super.key,
    required this.message,
    this.subtitle,
    this.icon,
    this.iconSize = 64,
    this.onAction,
    this.actionLabel,
    this.actionIcon,
    this.actionFocusNode,
    this.onActionNavigateUp,
    this.onActionNavigateLeft,
    this.onActionBack,
  });

  @override
  Widget build(BuildContext context) {
    return StateMessageWidget(
      message: message,
      showBrand: true,
      subtitle: subtitle,
      icon: icon,
      iconSize: iconSize,
      onAction: onAction,
      actionLabel: actionLabel,
      actionIcon: actionIcon ?? Symbols.add_rounded,
      actionFocusNode: actionFocusNode,
      onActionNavigateUp: onActionNavigateUp,
      onActionNavigateLeft: onActionNavigateLeft,
      onActionBack: onActionBack,
    );
  }
}

/// A reusable widget for displaying error states throughout the app
class ErrorStateWidget extends StatelessWidget {
  final String message;

  /// Optional icon to display above the message
  final IconData? icon;

  /// Optional callback for retry action
  final VoidCallback? onRetry;

  /// Whether the retry action should request focus when it appears.
  final bool actionAutofocus;

  /// Whether the retry action uses a background focus indicator.
  final bool actionUseBackgroundFocus;

  /// Optional label for the retry button
  final String? retryLabel;
  final FocusNode? actionFocusNode;
  final VoidCallback? onActionNavigateUp;
  final VoidCallback? onActionNavigateLeft;
  final VoidCallback? onActionBack;

  const ErrorStateWidget({
    super.key,
    required this.message,
    this.icon,
    this.onRetry,
    this.retryLabel,
    this.actionFocusNode,
    this.onActionNavigateUp,
    this.onActionNavigateLeft,
    this.onActionBack,
    this.actionAutofocus = false,
    this.actionUseBackgroundFocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return StateMessageWidget(
      message: message,
      icon: icon,
      iconColor: Theme.of(context).colorScheme.error,
      textColor: Theme.of(context).colorScheme.error,
      onAction: onRetry,
      actionLabel: retryLabel ?? t.common.retry,
      actionIcon: Symbols.refresh_rounded,
      actionFocusNode: actionFocusNode,
      onActionNavigateUp: onActionNavigateUp,
      onActionNavigateLeft: onActionNavigateLeft,
      onActionBack: onActionBack,
      actionAutofocus: actionAutofocus,
      actionUseBackgroundFocus: actionUseBackgroundFocus,
    );
  }
}
