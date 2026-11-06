import 'package:flutter/widgets.dart';

import '../theme/mono_tokens.dart';
import '../services/settings_service.dart';
import 'media_card.dart';
import 'settings_builder.dart';

/// Uses the same artwork inset, caption band and corner geometry as a loaded
/// card. Fixed artwork heights belong to horizontal shelves; grids expand.
class SkeletonMediaCard extends StatelessWidget {
  const SkeletonMediaCard({super.key, this.posterHeight});

  final double? posterHeight;

  @override
  Widget build(BuildContext context) =>
      SettingsBuilder(prefs: const [SettingsService.gridSpacing], builder: _buildCard);

  Widget _buildCard(BuildContext context) {
    final gap = posterHeight != null ? 2.0 : SettingsService.instance.read(SettingsService.gridSpacing).posterTitleGap;
    final captionHeight =
        MediaCard.gridCaptionBandHeight(context, posterTitleGap: gap) - MediaCard.gridCardPadding.vertical - gap;
    final artwork = SkeletonLoader(
      borderRadius: BorderRadius.circular(tokens(context).radiusSm),
      child: const SizedBox.expand(),
    );
    return Padding(
      padding: MediaCard.gridCardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (posterHeight case final height?) SizedBox(height: height, child: artwork) else Expanded(child: artwork),
          SizedBox(height: gap),
          SizedBox(
            height: captionHeight,
            child: Column(
              children: [
                Expanded(
                  child: FractionallySizedBox(
                    heightFactor: 0.65,
                    child: SkeletonLoader(
                      borderRadius: BorderRadius.circular(tokens(context).radiusXs),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FractionallySizedBox(
                      widthFactor: 0.6,
                      heightFactor: 0.65,
                      child: SkeletonLoader(
                        borderRadius: BorderRadius.circular(tokens(context).radiusXs),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
