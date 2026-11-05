import 'package:flutter/material.dart';
import 'app_brand.dart';

/// Square `CircularProgressIndicator(strokeWidth: 2)` sized to fit inside a
/// button or status row. The default 18×18 matches the
/// [FilledButton.icon] / [OutlinedButton.icon] icon slot; bump [size] for
/// list-row or app-bar contexts.
///
/// Centralises the `SizedBox(width:.., height:.., child:
/// CircularProgressIndicator(strokeWidth: 2))` pattern that previously
/// appeared inline in every async button.
class LoadingIndicatorBox extends StatelessWidget {
  final double size;
  const LoadingIndicatorBox({super.key, this.size = 18});

  /// Full-screen centered spinner sized to fill the remaining space inside a
  /// [CustomScrollView]. Replaces inline
  /// `SliverFillRemaining(child: Center(child: CircularProgressIndicator()))`.
  static const Widget sliver = SliverFillRemaining(child: Center(child: AppLoadingIndicator()));

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: const CircularProgressIndicator(strokeWidth: 2));
}
