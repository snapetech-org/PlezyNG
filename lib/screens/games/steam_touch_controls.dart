import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../games/steam_touch_layout.dart';
import '../../widgets/app_icon.dart';

/// Touch assistance for player one. Platform adapters merge it independently
/// of physical controllers; removing this overlay releases assistance only.
class SteamTouchControls extends StatefulWidget {
  const SteamTouchControls({
    super.key,
    required this.onButton,
    required this.onStick,
    required this.onRelease,
    this.swapSides = false,
    this.layout,
  });
  final void Function(String, bool) onButton;
  final void Function(String, Offset) onStick;
  final VoidCallback onRelease;
  final bool swapSides;
  final SteamTouchLayout? layout;

  @override
  State<SteamTouchControls> createState() => _SteamTouchControlsState();
}

class _SteamTouchControlsState extends State<SteamTouchControls> {
  @override
  void dispose() {
    widget.onRelease();
    super.dispose();
  }

  Widget _button(String name, String label, {IconData? icon, String? semantics}) => _HeldButton(
    key: ValueKey(name),
    label: semantics ?? label,
    onChanged: (down) => widget.onButton(name, down),
    child: icon == null ? Text(label) : AppIcon(icon),
  );

  Widget _stick(bool left) => _Stick(
    key: ValueKey(left ? 'leftStick' : 'rightStick'),
    label: left ? t.games.leftStick : t.games.rightStick,
    marker: left ? 'L' : 'R',
    onChanged: (offset) => widget.onStick(left ? 'leftStick' : 'rightStick', offset),
    onClick: (down) => widget.onButton(left ? 'leftStick' : 'rightStick', down),
  );

  Widget _control(String key) {
    if (key == 'leftStick' || key == 'rightStick') return _stick(key == 'leftStick');
    final icon = switch (key) {
      'dpadUp' => Symbols.arrow_upward_rounded,
      'dpadDown' => Symbols.arrow_downward_rounded,
      'dpadLeft' => Symbols.arrow_back_rounded,
      'dpadRight' => Symbols.arrow_forward_rounded,
      'select' => Symbols.tab_rounded,
      'start' => Symbols.menu_rounded,
      'mode' => Symbols.home_rounded,
      _ => null,
    };
    final short =
        {'leftBumper': 'LB', 'leftTrigger': 'LT', 'rightBumper': 'RB', 'rightTrigger': 'RT'}[key] ?? key.toUpperCase();
    return _button(key, short, icon: icon, semantics: steamTouchControlLabel(key));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (!SteamTouchLayout.fits(size)) {
        return Align(
          alignment: Alignment.bottomCenter,
          child: IgnorePointer(
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(t.games.touchResizeHint, textAlign: TextAlign.center),
              ),
            ),
          ),
        );
      }
      final positions = (widget.layout ?? SteamTouchLayout()).resolve(size, swapSides: widget.swapSides);
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            for (final key in SteamTouchLayout.controls)
              Positioned(
                left: SteamTouchLayout.position(positions[key]!, size, key).dx,
                top: SteamTouchLayout.position(positions[key]!, size, key).dy,
                child: _control(key),
              ),
          ],
        ),
      );
    },
  );
}

class _HeldButton extends StatefulWidget {
  const _HeldButton({super.key, required this.label, required this.child, required this.onChanged});
  final String label;
  final Widget child;
  final ValueChanged<bool> onChanged;
  @override
  State<_HeldButton> createState() => _HeldButtonState();
}

class _HeldButtonState extends State<_HeldButton> {
  final _pointers = <int>{};
  Timer? _pulse;
  bool _semanticPress = false, _down = false;
  void _update() {
    if (!mounted) return; // A captured pointer can finish after this overlay retires.
    final down = _pointers.isNotEmpty || _semanticPress;
    if (down == _down) return;
    setState(() => _down = down);
    widget.onChanged(down);
  }

  void _activate() {
    if (!mounted) return;
    _pulse?.cancel();
    _semanticPress = true;
    _update();
    _pulse = Timer(const Duration(milliseconds: 100), () {
      _semanticPress = false;
      _update();
    });
  }

  @override
  void dispose() {
    _pulse?.cancel();
    if (_down) widget.onChanged(false);
    _down = false;
    _pointers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.label,
      onTap: _activate,
      child: ExcludeSemantics(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            _pointers.add(event.pointer);
            _update();
          },
          onPointerUp: (event) {
            _pointers.remove(event.pointer);
            _update();
          },
          onPointerCancel: (event) {
            _pointers.remove(event.pointer);
            _update();
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _down ? colors.primary : colors.surfaceContainerHighest,
              border: Border.all(color: _down ? colors.primary : colors.onSurfaceVariant),
              borderRadius: BorderRadius.circular(24),
            ),
            alignment: Alignment.center,
            child: IconTheme.merge(
              data: IconThemeData(color: _down ? colors.onPrimary : colors.onSurface),
              child: DefaultTextStyle(
                style: Theme.of(
                  context,
                ).textTheme.labelLarge!.copyWith(color: _down ? colors.onPrimary : colors.onSurface),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Stick extends StatefulWidget {
  const _Stick({super.key, required this.label, required this.marker, required this.onChanged, required this.onClick});
  final String label, marker;
  final ValueChanged<Offset> onChanged;
  final ValueChanged<bool> onClick;
  @override
  State<_Stick> createState() => _StickState();
}

class _StickState extends State<_Stick> {
  int? _pointer;
  Offset _offset = Offset.zero;
  Timer? _clickTimer;
  void _click() {
    if (!mounted) return;
    _clickTimer?.cancel();
    widget.onClick(true);
    _clickTimer = Timer(const Duration(milliseconds: 100), () {
      _clickTimer = null;
      widget.onClick(false);
    });
  }

  void _move(Offset position) {
    var offset = (position - const Offset(44, 44)) / 32;
    if (offset.distance > 1) offset /= offset.distance;
    setState(() => _offset = offset);
    widget.onChanged(offset);
  }

  void _release() {
    _pointer = null;
    setState(() => _offset = Offset.zero);
    widget.onChanged(Offset.zero);
  }

  @override
  void dispose() {
    if (_clickTimer != null) {
      _clickTimer!.cancel();
      widget.onClick(false);
    }
    if (_pointer != null) widget.onChanged(Offset.zero);
    _pointer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.label,
      hint: t.games.touchStickHint,
      excludeSemantics: true,
      onTap: _click,
      child: GestureDetector(
        onDoubleTap: _click,
        excludeFromSemantics: true,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (_pointer == null) {
              _pointer = event.pointer;
              _move(event.localPosition);
            }
          },
          onPointerMove: (event) {
            if (_pointer == event.pointer) _move(event.localPosition);
          },
          onPointerUp: (event) {
            if (_pointer == event.pointer) _release();
          },
          onPointerCancel: (event) {
            if (_pointer == event.pointer) _release();
          },
          child: Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.surfaceContainerHighest,
              border: Border.all(color: colors.onSurfaceVariant),
            ),
            child: Center(
              child: Transform.translate(
                offset: _offset * 24,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: colors.primary),
                  alignment: Alignment.center,
                  child: Text(widget.marker, style: TextStyle(color: colors.onPrimary)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String steamTouchControlLabel(String key) => switch (key) {
  'leftStick' => t.games.leftStick,
  'rightStick' => t.games.rightStick,
  'leftBumper' => t.games.touchLeftBumper,
  'rightBumper' => t.games.touchRightBumper,
  'leftTrigger' => t.games.touchLeftTrigger,
  'rightTrigger' => t.games.touchRightTrigger,
  'dpadUp' => t.games.touchDpadUp,
  'dpadDown' => t.games.touchDpadDown,
  'dpadLeft' => t.games.touchDpadLeft,
  'dpadRight' => t.games.touchDpadRight,
  'select' => t.games.touchViewButton,
  'start' => t.games.touchMenuButton,
  'mode' => t.games.steamOverlay,
  _ => key.toUpperCase(),
};
