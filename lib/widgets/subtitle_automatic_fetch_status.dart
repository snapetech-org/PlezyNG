import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../services/subtitle_automatic_fetch.dart';

class SubtitleAutomaticFetchStatus extends StatelessWidget {
  const SubtitleAutomaticFetchStatus({super.key, required this.controller, this.onSearchAgain});
  final SubtitleAutomaticFetch controller;
  final VoidCallback? onSearchAgain;
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: controller, builder: (context, _) {
    final copy = t.videoSettings;
    final text = switch (controller.stage) {
      SubtitleFetchStage.idle || SubtitleFetchStage.completed => null,
      SubtitleFetchStage.searching => copy.subtitleAutoSearching,
      SubtitleFetchStage.downloading => copy.subtitleAutoDownloading,
      SubtitleFetchStage.refreshing => copy.subtitleAutoRefreshing,
      SubtitleFetchStage.noMatch => copy.subtitleAutoNoMatch,
      SubtitleFetchStage.failed => copy.subtitleAutoFailed,
      SubtitleFetchStage.cancelled => copy.subtitleAutoCancelled,
      SubtitleFetchStage.expired => copy.subtitleAutoExpired,
    };
    if (text == null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.all(8), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Semantics(liveRegion: true, child: Text(text, textAlign: TextAlign.center)),
      if (controller.busy) TextButton(onPressed: controller.cancel, child: Text(copy.subtitleAutoSkip)),
      if (!controller.busy && onSearchAgain != null) TextButton(onPressed: onSearchAgain,
        child: Text(copy.subtitleAutoSearchAgain)),
    ]));
  });
}
