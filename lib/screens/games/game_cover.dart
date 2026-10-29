import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../games/game_artwork.dart';
import '../../games/game_models.dart';
import '../../widgets/app_icon.dart';

/// Uses the same bounded profile-owned artwork cache as the library cards.
class GameCover extends StatefulWidget {
  const GameCover({
    super.key,
    required this.game,
    required this.artwork,
    this.host,
    this.steamAppId,
    this.cacheWidth = 360,
  });
  final StreamGame game;
  final GameArtworkLoader artwork;
  final GameHost? host;
  final int? steamAppId;
  final int cacheWidth;
  @override
  State<GameCover> createState() => _GameCoverState();
}

class _GameCoverState extends State<GameCover> {
  late Future<Uint8List?> _cover = _load();
  Future<Uint8List?> _load() => widget.steamAppId != null
      ? widget.artwork.loadSteam(widget.steamAppId!)
      : widget.host != null
      ? widget.artwork.load(widget.host!, widget.game)
      : Future.value();
  @override
  void didUpdateWidget(GameCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.key != widget.game.key ||
        oldWidget.host?.address != widget.host?.address ||
        oldWidget.host?.port != widget.host?.port ||
        oldWidget.steamAppId != widget.steamAppId ||
        oldWidget.artwork != widget.artwork) {
      _cover = _load();
    }
  }

  Widget _placeholder(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(
      child: AppIcon(Symbols.sports_esports_rounded, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: FutureBuilder<Uint8List?>(
      future: _cover,
      builder: (context, snapshot) => snapshot.data == null
          ? _placeholder(context)
          : Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              cacheWidth: widget.cacheWidth,
              excludeFromSemantics: true,
              errorBuilder: (context, _, _) => _placeholder(context),
            ),
    ),
  );
}
