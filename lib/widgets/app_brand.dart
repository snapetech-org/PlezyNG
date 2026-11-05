import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../theme/mono_theme.dart';

/// Shared branding follows the actual surface, including custom app themes.
String _appearance(BuildContext context) =>
    ThemeData.estimateBrightnessForColor(Theme.of(context).colorScheme.surface) == Brightness.dark ? 'dark' : 'light';

class AppBrandMark extends StatelessWidget {
  const AppBrandMark({super.key, this.size = 80, this.decorative = false, this.monochrome = false});

  final double size;
  final bool decorative;
  final bool monochrome;

  @override
  Widget build(BuildContext context) {
    final flat = monochrome || size <= 32;
    final scheme = Theme.of(context).colorScheme;
    final paintedInk = Color.alphaBlend(scheme.onSurface, scheme.surface);
    final ink = MonoPalette.contrastRatio(paintedInk, scheme.surface) >= 4.5
        ? scheme.onSurface
        : (_appearance(context) == 'dark' ? Colors.white : Colors.black);
    return SizedBox.square(
      dimension: size,
      child: Padding(
        padding: EdgeInsets.all(size <= 32 ? 0 : size * 0.04),
        child: Image.asset(
          flat
              ? 'assets/branding/pleazyng-monochrome.png'
              : size <= 64
              ? 'assets/branding/pleazyng-compact.png'
              : 'assets/branding/pleazyng-mark-${_appearance(context)}.png',
          color: flat ? ink : null,
          colorBlendMode: flat ? BlendMode.srcIn : null,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          semanticLabel: decorative ? null : 'Pleazyng',
          excludeFromSemantics: decorative,
        ),
      ),
    );
  }
}

/// Reserved for page-level loading; inline controls keep their compact spinner.
class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: t.common.loading,
    child: ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: MediaQuery.disableAnimationsOf(context) ? 0.75 : null,
              ),
            ),
            AppBrandMark(size: size * 0.5, monochrome: true, decorative: true),
          ],
        ),
      ),
    ),
  );
}

class AppBrandWordmark extends StatelessWidget {
  const AppBrandWordmark({super.key, this.width = 220, this.height = 55});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/pleazyng-wordmark-${_appearance(context)}.png',
    width: width,
    height: height,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.medium,
    semanticLabel: 'Pleazyng',
  );
}
