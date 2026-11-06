import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, rootBundle;

import '../../i18n/strings.g.dart';
import '../../widgets/focused_scroll_scaffold.dart';

/// The bundled notice remains readable before sign-in and without a TV browser.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final asset = LocaleSettings.currentLocale.languageCode == 'ko' ? 'PRIVACY.ko.md' : 'PRIVACY.md';
    return FocusedScrollScaffold(
      title: Text(t.about.privacyPolicy),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(24),
          sliver: SliverToBoxAdapter(
            child: FutureBuilder<String>(
              future: rootBundle.loadString(asset),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text('https://snape.tech/privacy/pleazyng/');
                }
                final notice = snapshot.data;
                if (notice == null) return const Center(child: CircularProgressIndicator());
                return Shortcuts(
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.arrowDown): ScrollIntent(direction: AxisDirection.down),
                    SingleActivator(LogicalKeyboardKey.arrowUp): ScrollIntent(direction: AxisDirection.up),
                    SingleActivator(LogicalKeyboardKey.pageDown): ScrollIntent(
                      direction: AxisDirection.down,
                      type: ScrollIncrementType.page,
                    ),
                    SingleActivator(LogicalKeyboardKey.pageUp): ScrollIntent(
                      direction: AxisDirection.up,
                      type: ScrollIncrementType.page,
                    ),
                  },
                  child: Focus(
                    autofocus: true,
                    child: Text(notice, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5)),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
