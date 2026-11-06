import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../profiles/active_profile_provider.dart';
import '../providers/multi_server_provider.dart';
import '../widgets/app_icon.dart';
import '../widgets/optimized_media_image.dart';
import 'extras_labels.dart';
import 'extras_models.dart';
import 'extras_playback.dart';
import 'extras_screen.dart';
import 'extras_session.dart';
import 'extras_store.dart';

/// Capture identity once. Neither late discovery nor an open playback route
/// may acquire the permissions of a newly selected profile.
ExtrasSession createExtrasSession(
  BuildContext context,
  ExtrasSubject subject, {
  List<MediaItem> library = const [],
  List<ExtraEntry> catalog = const [],
  bool Function()? isCurrent,
}) {
  final profiles = context.read<ActiveProfileProvider?>();
  final profileId = profiles?.activeId;
  return ExtrasSession(
    subject: subject,
    store: ExtrasStore(profileId ?? 'unbound'),
    library: library,
    catalog: catalog,
    isCurrent: () =>
        profileId != null &&
        profiles?.activeId == profileId &&
        profiles?.isBinding != true &&
        (isCurrent?.call() ?? true),
  );
}

bool extrasRestricted(BuildContext context) => context.read<ActiveProfileProvider?>()?.active?.plexRestricted ?? true;

/// Display-only identities never carry a server token, stream, or library ID.
MediaItem extraDisplayItem(ExtraEntry entry) => MediaItem(
  id: 'extra:${entry.id}',
  backend: MediaBackend.plex,
  kind: MediaKind.clip,
  title: entry.title,
  parentTitle: extraSourceLabel(entry),
);

class ExtraCard extends StatelessWidget {
  const ExtraCard({
    super.key,
    required this.session,
    required this.entry,
    required this.width,
    required this.height,
    this.interactive = true,
  });
  final ExtrasSession session;
  final ExtraEntry entry;
  final double width, height;
  final bool interactive;
  @override
  Widget build(BuildContext context) {
    const placeholder = Center(child: AppIcon(Symbols.movie_filter_rounded, size: 40));
    final native = session.nativeItem(entry);
    final serverId = serverIdOrNull(native?.serverId);
    final client = serverId == null ? null : context.read<MultiServerProvider?>()?.getClientForServer(serverId);
    final image = native != null && !session.subject.offline
        ? OptimizedMediaImage.thumb(
            client: client,
            imagePath: native.thumbPath,
            width: width,
            height: height,
            fit: BoxFit.cover,
          )
        : entry.thumbnailUrl != null && !session.subject.offline && !session.subject.restricted
        ? Image.network(
            entry.thumbnailUrl!,
            fit: BoxFit.cover,
            width: width,
            height: height,
            cacheWidth: 640,
            errorBuilder: (_, _, _) => placeholder,
          )
        : placeholder;
    final content = SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: image),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xF2000000)],
                  stops: [0.1, 1],
                ),
              ),
            ),
            PositionedDirectional(
              start: 12,
              end: 12,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white),
                  ),
                  Text(
                    '${extraKindLabel(entry.kind)} · ${extraSourceLabel(entry)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      label: '${entry.title}, ${extraKindLabel(entry.kind)}, ${extraSourceLabel(entry)}',
      button: true,
      excludeSemantics: true,
      child: interactive
          ? InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => unawaited(playExtra(context, session, entry)),
              onLongPress: () => unawaited(openExtras(context, session)),
              child: content,
            )
          : content,
    );
  }
}

/// One bounded shelf, using the same admission rules as the full browser.
class ExtrasShelf extends StatelessWidget {
  const ExtrasShelf({super.key, required this.session});
  final ExtrasSession session;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final entries = session.preview;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            children: [
              Text(t.bonusExtras.title, style: Theme.of(context).textTheme.titleLarge),
              TextButton(
                onPressed: () => unawaited(openExtras(context, session)),
                child: Text(entries.isEmpty ? t.bonusExtras.title : t.bonusExtras.seeAll),
              ),
            ],
          ),
          if (entries.isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth < 400 ? 240.0 : 280.0;
                final height = 160.0 + (MediaQuery.textScalerOf(context).scale(30) - 30).clamp(0, 100);
                return SizedBox(
                  height: height,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) =>
                        ExtraCard(session: session, entry: entries[index], width: width, height: height),
                  ),
                );
              },
            ),
        ],
      );
    },
  );
}
