import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_kind.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_account_scope.dart';
import '../../services/music/music_home_pins.dart';
import '../../services/music/music_playback_service.dart';
import '../../utils/music_navigation.dart';
import '../../utils/snackbar_helper.dart';
import '../app_icon.dart';

/// Pins retain navigation identity only; opening re-authorizes metadata under
/// the current profile. Library and connection changes invalidate visible rows.
class MusicPinsShelf extends StatefulWidget {
  const MusicPinsShelf({super.key, this.editing = false});
  final bool editing;
  @override
  State<MusicPinsShelf> createState() => _MusicPinsShelfState();
}

class _MusicPinsShelfState extends State<MusicPinsShelf> {
  MusicHomePins? _pins;
  String? _signature;
  Future<List<MusicHomePin>>? _future;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pins = context.read<MusicExperience>().pins;
    final libraries = context.watch<LibrariesProvider?>();
    final hidden = context.watch<HiddenLibrariesProvider?>();
    final servers = context.watch<MultiServerProvider?>();
    final signature = [
      libraries?.libraries.map((library) => '${library.globalKey}:${library.hidden}').join('|'),
      hidden?.hiddenLibraryKeys.join('|'),
      servers?.serverManager.visibleOnlineClients.values
          .map(
            (client) =>
                '${client.serverId}:${identityHashCode(client.authenticationSessionId)}:${musicAccountScope(client)}',
          )
          .join('|'),
    ].join(';');
    if (!identical(pins, _pins)) {
      _pins?.removeListener(_changed);
      _pins = pins..addListener(_changed);
      _future = pins.load();
    }
    if (_signature != signature) {
      _signature = signature;
      _future = pins.load();
    }
  }

  void _changed() {
    if (!mounted) return;
    final future = _pins!.load();
    setState(() {
      _future = future;
    });
  }

  Future<void> _mutate(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.musicExperience.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(MusicHomePin pin) async {
    await _mutate(() async {
      final experience = context.read<MusicExperience>();
      final music = experience.music;
      final intent = pin.item.kind == MediaKind.track ? music.beginPlayIntent() : null;
      final item = await experience.pins.resolve(pin);
      if (!mounted || !identical(_pins, experience.pins) || !experience.store.active) return;
      final client = experience.clientFor(item);
      if (client == null || musicAccountScope(client) != pin.account) return;
      switch (item.kind) {
        case MediaKind.artist:
          await navigateToArtist(context, item);
        case MediaKind.album:
          await navigateToAlbum(context, item);
        case MediaKind.track:
          if (!music.isPlayIntentCurrent(intent!)) return;
          await music.playFromList(
            tracks: [item],
            playContext: MusicPlayContext(title: t.musicTools.pins, kind: MusicPlayContextKind.tracks),
          );
        default:
          return;
      }
    });
  }

  Widget _row(MusicHomePin pin) => ListTile(
    key: ValueKey(pin.id),
    leading: widget.editing
        ? IconButton(
            tooltip: t.musicTools.unpin,
            icon: const AppIcon(Symbols.keep_off_rounded),
            onPressed: _busy ? null : () => unawaited(_mutate(() => _pins!.remove(pin))),
          )
        : AppIcon(switch (pin.item.kind) {
            MediaKind.artist => Symbols.artist_rounded,
            MediaKind.album => Symbols.album_rounded,
            _ => Symbols.music_note_rounded,
          }),
    title: Text(pin.item.displayTitle),
    subtitle: Text(switch (pin.item.kind) {
      MediaKind.artist => t.common.mediaKind.artist,
      MediaKind.album => t.common.mediaKind.album,
      _ => t.common.mediaKind.track,
    }),
    onTap: widget.editing || _busy ? null : () => unawaited(_open(pin)),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MusicHomePin>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) return const LinearProgressIndicator();
      final pins = snapshot.data ?? const [];
      if (snapshot.hasError) return TextButton(onPressed: _changed, child: Text(t.common.retry));
      if (pins.isEmpty) {
        return Padding(padding: const EdgeInsets.all(16), child: Text(t.messages.noResultsFound));
      }
      if (!widget.editing) return Column(children: pins.map(_row).toList());
      return ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        onReorderItem: (from, to) {
          if (_busy) return;
          final reordered = List<MusicHomePin>.of(pins);
          reordered.insert(to, reordered.removeAt(from));
          unawaited(_mutate(() => _pins!.reorder(reordered)));
        },
        children: pins.map(_row).toList(),
      );
    },
  );

  @override
  void dispose() {
    _pins?.removeListener(_changed);
    super.dispose();
  }
}
