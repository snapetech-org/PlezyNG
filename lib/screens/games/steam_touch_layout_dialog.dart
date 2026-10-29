import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../games/steam_touch_layout.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/app_icon.dart';
import 'steam_touch_controls.dart';

/// Editing never sends input. Drag and semantic/keyboard sliders share the
/// same bounds and collision checks. Save is explicit; cancel is side-effect free.
class SteamTouchLayoutDialog extends StatefulWidget {
  const SteamTouchLayoutDialog({super.key, required this.initial, this.swapSides = false});
  final SteamTouchLayout initial;
  final bool swapSides;
  @override
  State<SteamTouchLayoutDialog> createState() => _SteamTouchLayoutDialogState();
}

class _SteamTouchLayoutDialogState extends State<SteamTouchLayoutDialog> {
  late SteamTouchLayout _layout = widget.initial;
  String _selected = 'leftStick';
  bool _blocked = false, _positionControls = false;
  Size? _size;
  Offset? _drag;

  void _move(Offset normalized) {
    final size = _size;
    if (size == null || !SteamTouchLayout.fits(size)) return;
    final positions = _layout.resolve(size, swapSides: widget.swapSides);
    positions[_selected] = Offset(normalized.dx.clamp(0.0, 1.0), normalized.dy.clamp(0.0, 1.0));
    final valid = SteamTouchLayout.valid(positions, size);
    setState(() {
      _blocked = !valid;
      if (valid) _layout = _layout.replace(size, positions);
    });
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(child: Text(t.games.touchLayout, style: Theme.of(context).textTheme.titleLarge)),
                IconButton(
                  tooltip: t.common.reset,
                  onPressed: () => setState(() {
                    _layout = SteamTouchLayout();
                    _blocked = false;
                  }),
                  icon: const AppIcon(Symbols.restart_alt_rounded),
                ),
                IconButton(
                  tooltip: t.games.touchLayoutPosition,
                  isSelected: _positionControls,
                  onPressed: () => setState(() => _positionControls = !_positionControls),
                  icon: const AppIcon(Symbols.tune_rounded),
                ),
                IconButton(
                  tooltip: t.common.cancel,
                  onPressed: () => Navigator.pop(context),
                  icon: const AppIcon(Symbols.close_rounded),
                ),
                IconButton(
                  tooltip: t.common.save,
                  onPressed: () => Navigator.pop(context, _layout),
                  icon: const AppIcon(Symbols.check_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _size = constraints.biggest;
                final size = _size!;
                if (!SteamTouchLayout.fits(size)) return Center(child: Text(t.games.touchResizeHint));
                final positions = _layout.resolve(size, swapSides: widget.swapSides);
                return Stack(
                  children: [
                    ExcludeSemantics(
                      child: IgnorePointer(
                        child: SteamTouchControls(
                          layout: _layout,
                          swapSides: widget.swapSides,
                          onButton: (_, _) {},
                          onStick: (_, _) {},
                          onRelease: () {},
                        ),
                      ),
                    ),
                    for (final key in SteamTouchLayout.controls)
                      Positioned(
                        left: SteamTouchLayout.position(positions[key]!, size, key).dx,
                        top: SteamTouchLayout.position(positions[key]!, size, key).dy,
                        child: Semantics(
                          label: steamTouchControlLabel(key),
                          button: true,
                          selected: key == _selected,
                          onTap: () => setState(() => _selected = key),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => _selected = key),
                            onPanStart: (_) {
                              setState(() => _selected = key);
                              _drag = SteamTouchLayout.position(positions[key]!, size, key);
                            },
                            onPanUpdate: (event) {
                              _drag = (_drag ?? SteamTouchLayout.position(positions[key]!, size, key)) + event.delta;
                              _move(SteamTouchLayout.normalize(_drag!, size, key));
                            },
                            onPanEnd: (_) => _drag = null,
                            onPanCancel: () => _drag = null,
                            child: Container(
                              key: ValueKey('edit-$key'),
                              width: SteamTouchLayout.extent(key),
                              height: SteamTouchLayout.extent(key),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(24),
                                border: key == _selected
                                    ? Border.all(color: Theme.of(context).colorScheme.primary, width: 3)
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_positionControls)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Material(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: _controls(size),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
  Widget _controls(Size size) => ConstrainedBox(
    constraints: BoxConstraints(maxHeight: size.height * .6),
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: LayoutBuilder(
        builder: (context, _) {
          final enabled = SteamTouchLayout.fits(size);
          final point = enabled ? _layout.resolve(size, swapSides: widget.swapSides)[_selected]! : Offset.zero;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: _blocked,
                child: Text(_blocked ? t.games.touchLayoutCollision : t.games.touchLayoutHelp),
              ),
              DropdownButton<String>(
                isExpanded: true,
                itemHeight: null,
                value: _selected,
                items: [
                  for (final key in SteamTouchLayout.controls)
                    DropdownMenuItem(value: key, child: Text(steamTouchControlLabel(key))),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _selected = value);
                },
              ),
              for (final horizontal in [true, false])
                Row(
                  children: [
                    Text(horizontal ? t.games.touchLayoutHorizontal : t.games.touchLayoutVertical),
                    Expanded(
                      child: MergeSemantics(
                        child: Semantics(
                          label:
                              '${steamTouchControlLabel(_selected)}, '
                              '${horizontal ? t.games.touchLayoutHorizontal : t.games.touchLayoutVertical}',
                          child: Slider(
                            value: horizontal ? point.dx : point.dy,
                            divisions: 100,
                            semanticFormatterCallback: (value) => '${(value * 100).round()}%',
                            onChanged: !enabled
                                ? null
                                : (value) => _move(horizontal ? Offset(value, point.dy) : Offset(point.dx, value)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    ),
  );
}
