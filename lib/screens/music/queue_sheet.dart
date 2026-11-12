import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_action_bar.dart';
import '../../focus/input_mode_tracker.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../services/music/music_playback_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/bottom_sheet_page_scaffold.dart';
import '../../widgets/music/repeat_mode.dart';
import '../../widgets/music/track_row.dart';
import '../../widgets/overlay_sheet.dart';

/// Open the play-queue sheet. The caller's screen must have an
/// [OverlaySheetHost] ancestor (all now-playing layouts do) so TV back
/// handling stays centralized in the host.
Future<void> showQueueSheet(BuildContext context) {
  return OverlaySheetController.of(context).show<void>(showDragHandle: true, builder: (_) => const QueueSheet());
}

/// Filters browse the authoritative queue without creating a new session.
enum MusicQueueSection { all, backTo, upNext }

/// Explicit navigation through played and upcoming occurrences.
class QueueSheet extends StatefulWidget {
  const QueueSheet({super.key});

  @override
  State<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<QueueSheet> {
  MusicQueueSection _section = MusicQueueSection.all;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final service = context.watch<MusicPlaybackService>();
    final colorScheme = Theme.of(context).colorScheme;

    return BottomSheetPageScaffold(
      title: t.music.queue,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text(
                  t.music.trackCount(n: service.queue.length),
                  style: TextStyle(fontSize: 13, color: tk.textMuted),
                ),
                FocusableActionBar(
                  actions: [
                    FocusableAction(
                      icon: Symbols.shuffle_rounded,
                      iconColor: service.shuffled ? colorScheme.primary : tk.textMuted,
                      iconSize: 20,
                      tooltip: t.common.shuffle,
                      onPressed: service.toggleShuffle,
                    ),
                    FocusableAction(
                      icon: repeatModeIcon(service.repeatMode),
                      iconColor: service.repeatMode == MusicRepeatMode.off ? tk.textMuted : colorScheme.primary,
                      iconSize: 20,
                      tooltip: repeatModeLabel(service.repeatMode),
                      onPressed: () => service.setRepeatMode(nextRepeatMode(service.repeatMode)),
                    ),
                    FocusableAction(
                      icon: Symbols.clear_all_rounded,
                      iconColor: tk.textMuted,
                      iconSize: 20,
                      tooltip: t.music.clearQueue,
                      onPressed: service.clearUpcoming,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final section in MusicQueueSection.values)
                  ChoiceChip(
                    label: Text(switch (section) {
                      MusicQueueSection.all => t.libraries.all,
                      MusicQueueSection.backTo => t.music.backTo,
                      MusicQueueSection.upNext => t.music.upNext,
                    }),
                    selected: _section == section,
                    onSelected: (_) => setState(() => _section = section),
                  ),
              ],
            ),
          ),
          Flexible(
            child: QueueList(key: ValueKey(_section), autofocusCurrent: true, section: _section),
          ),
        ],
      ),
    );
  }
}

/// The queue body: the full play queue in playback order — history, the
/// current track (equalizer row, dimmed rows above are already played),
/// then upcoming — YouTube-Music style. Opens scrolled so the current track
/// sits at the top, and follows track changes while the user is near the
/// playback position. Reused verbatim by the desktop now-playing layout as
/// an inline panel.
///
/// Touch: long-press drag to reorder (delayed drag listener — TrackRow's
/// context menu is disabled here so the gesture arena stays clean), swipe to
/// remove, tap to jump. D-pad: rows are focusable, SELECT jumps, RIGHT
/// reaches a dedicated remove button; reordering is intentionally not
/// offered on TV. With [autofocusCurrent] (the sheet) initial focus lands on
/// the current track's row instead of the first history row.
class QueueList extends StatefulWidget {
  /// Land initial d-pad/keyboard focus on the current track's row,
  /// overriding the overlay host's focus-first-descendant default. The
  /// inline desktop panel keeps this off so building the now-playing screen
  /// never steals focus.
  final bool autofocusCurrent;

  final MusicQueueSection section;

  const QueueList({super.key, this.autofocusCurrent = false, this.section = MusicQueueSection.all});

  @override
  State<QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<QueueList> {
  ScrollController? _scrollController;
  Timer? _focusDelay;
  final _currentRowFocusNode = FocusNode(debugLabel: 'QueueCurrentRowFocus');
  int _lastCurrentIndex = -1;
  double _rowHeight = TrackRow.height;
  int? _renderedSession;
  List<MediaItem> _renderedQueue = [];
  List<MediaItem>? _sourceQueue;
  List<Object> _rowKeys = [];

  void _reconcileRows(List<MediaItem> queue, int session) {
    if (_renderedSession == session && identical(_sourceQueue, queue)) return;
    _sourceQueue = queue;
    final available = HashMap<MediaItem, Queue<Object>>.identity();
    if (_renderedSession == session) {
      for (var i = 0; i < _renderedQueue.length; i++) {
        (available[_renderedQueue[i]] ??= Queue<Object>()).add(_rowKeys[i]);
      }
    }
    _rowKeys = [
      for (final item in queue)
        if (available[item]?.isNotEmpty == true) available[item]!.removeFirst() else Object(),
    ];
    _renderedQueue = List.of(queue);
    _renderedSession = session;
  }

  // A row can remain on screen between a notification and the next frame.
  // Its captured index must never edit a replacement queue.
  bool _matches(MusicPlaybackService service, List<MediaItem> expected, int session) {
    if (!mounted || service.queueSessionRevision != session) return false;
    final actual = service.queue;
    if (identical(actual, expected) && identical(_sourceQueue, expected)) return true;
    if (actual.length != expected.length || _renderedQueue.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (!identical(actual[i], expected[i]) || !identical(_renderedQueue[i], expected[i])) return false;
    }
    return true;
  }

  void _remove(MusicPlaybackService service, List<MediaItem> queue, int session, int index) {
    if (!_matches(service, queue, session)) return;
    // Retire the exact occurrence key before notifying. Removing the first
    // of identical objects must not keep a dismissed widget mounted.
    setState(() {
      _sourceQueue = null;
      _renderedQueue.removeAt(index);
      _rowKeys.removeAt(index);
    });
    service.removeAt(index);
  }

  /// Content offset that puts the row at [index] at the top of the viewport
  /// (its top gap scrolled away, the list's own padding still visible).
  /// Rows are fixed-extent, so this is exact — the shared
  /// measure-the-first-item scroll helper can't be used because only the
  /// first row lacks a leading gap.
  double _rowOffset(int index, double gap) => index * (_rowHeight + gap);

  @override
  void initState() {
    super.initState();
    if (widget.autofocusCurrent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusDelay = Timer(Duration.zero, () {
          if (!mounted || !InputModeTracker.isKeyboardMode(context, listen: false)) return;
          // Schedule after the overlay host's _autoFocus second callback so
          // we override its focus-first-descendant default.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_currentRowFocusNode.context != null) _currentRowFocusNode.requestFocus();
          });
        });
      });
    }
  }

  @override
  void dispose() {
    _focusDelay?.cancel();
    _scrollController?.dispose();
    _currentRowFocusNode.dispose();
    super.dispose();
  }

  /// Keep the current track at the top while playback advances, but only
  /// when the list is still parked where the previous track was anchored —
  /// once the user scrolls away to browse, moving rows under their pointer
  /// invites mis-taps on remove/jump.
  void _followCurrentTrack(int currentIndex, double gap) {
    if (currentIndex == _lastCurrentIndex) return;
    final fromIndex = _lastCurrentIndex;
    _lastCurrentIndex = currentIndex;
    // First build: the initial scroll offset already targets the row.
    if (fromIndex < 0 || currentIndex < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _scrollController;
      if (!mounted || controller == null || !controller.hasClients) return;
      final position = controller.position;
      final anchor = _rowOffset(fromIndex, gap).clamp(0.0, position.maxScrollExtent);
      if ((anchor - position.pixels).abs() > (_rowHeight + gap) * 1.5) return;
      final target = _rowOffset(currentIndex, gap).clamp(0.0, position.maxScrollExtent);
      unawaited(controller.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut));
    });
  }

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final service = context.watch<MusicPlaybackService>();
    _rowHeight = TrackRow.heightFor(context);
    final queue = service.queue;
    final currentIndex = service.currentIndex;

    final session = service.queueSessionRevision;
    _reconcileRows(queue, session);
    final start = widget.section == MusicQueueSection.upNext ? (currentIndex + 1).clamp(0, queue.length) : 0;
    final end = widget.section == MusicQueueSection.backTo ? currentIndex.clamp(0, queue.length) : queue.length;
    final count = end - start;

    if (count == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Text(t.messages.noItemsAvailable, style: TextStyle(fontSize: 13, color: tk.textMuted)),
      );
    }

    final visibleCurrent = (currentIndex - start).clamp(0, count - 1);
    _scrollController ??= ScrollController(initialScrollOffset: _rowOffset(visibleCurrent, tk.groupGap));
    if (widget.section == MusicQueueSection.all) _followCurrentTrack(visibleCurrent, tk.groupGap);

    final allowTouchEditing = !PlatformDetector.isTV();

    return ReorderableListView.builder(
      scrollController: _scrollController,
      shrinkWrap: true,
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.all(12),
      itemCount: count,
      // onReorderItem already adjusts newIndex for the removal.
      onReorderItem: (oldIndex, newIndex) {
        if (oldIndex == newIndex || !_matches(service, queue, session)) return;
        final from = start + oldIndex, to = start + newIndex;
        final item = _renderedQueue.removeAt(from), key = _rowKeys.removeAt(from);
        _renderedQueue.insert(to, item);
        _rowKeys.insert(to, key);
        service.reorder(from, to);
      },
      itemBuilder: (context, visibleIndex) {
        final index = start + visibleIndex;
        final item = queue[index];
        final rowKey = _rowKeys[index];
        final isCurrent = index == currentIndex;

        Widget row = TrackRow(
          item: item,
          showArtist: true,
          isFirst: visibleIndex == 0,
          isLast: visibleIndex == count - 1,
          enableContextMenu: false,
          isCurrent: isCurrent,
          dimmed: index < currentIndex,
          showTrackNumber: false,
          focusNode: isCurrent ? _currentRowFocusNode : null,
          trailingIcon: Symbols.close_rounded,
          onTrailingTap: () => _remove(service, queue, session, index),
          onTap: () {
            if (_matches(service, queue, session)) unawaited(service.jumpTo(index));
          },
        );

        if (allowTouchEditing) {
          row = ReorderableDelayedDragStartListener(index: visibleIndex, child: row);
          row = Dismissible(
            key: ValueKey(rowKey),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: AlignmentDirectional.centerEnd,
              padding: const EdgeInsetsDirectional.only(end: 20),
              color: Colors.red,
              child: const AppIcon(Symbols.delete_rounded, fill: 1, color: Colors.white, size: 20),
            ),
            onDismissed: (_) => _remove(service, queue, session, index),
            child: row,
          );
        }

        return Padding(
          key: ValueKey(rowKey),
          padding: EdgeInsetsDirectional.only(top: visibleIndex == 0 ? 0 : tk.groupGap),
          child: row,
        );
      },
    );
  }
}
