import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../games/steam_input_profile.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/focusable_list_tile.dart';

class SteamInputDialog extends StatefulWidget {
  const SteamInputDialog({
    super.key,
    required this.initial,
    required this.players,
    required this.apply,
    required this.isCurrent,
  }) : assert(players >= 1 && players <= 4);
  final SteamInputProfile initial;
  final int players;
  final Future<void> Function(SteamInputProfile) apply;
  final bool Function() isCurrent;
  @override
  State<SteamInputDialog> createState() => _SteamInputDialogState();
}

class _SteamInputDialogState extends State<SteamInputDialog> {
  late SteamInputProfile _profile = widget.initial;
  int _seat = 0;
  bool _busy = false, _failed = false;
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<String> get _buttons => [
    'A',
    'B',
    'X',
    'Y',
    t.games.padBack,
    t.games.padGuide,
    t.games.padStart,
    t.games.padLeftStick,
    t.games.padRightStick,
    t.games.padLeftBumper,
    t.games.padRightBumper,
    t.games.padUp,
    t.games.padDown,
    t.games.padLeft,
    t.games.padRight,
  ];

  void _change(int index, int value) {
    if (!_busy && widget.isCurrent()) setState(() => _profile = _profile.change(_seat, index, value));
  }

  Future<void> _save() async {
    if (_busy || !widget.isCurrent()) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.apply(_profile);
      if (mounted && widget.isCurrent()) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
        if (_scroll.hasClients) _scroll.jumpTo(0);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final values = _profile.seats[_seat];
    final labels = _buttons;
    final axes = [t.games.padLeftX, t.games.padLeftY, t.games.padRightX, t.games.padRightY];
    return AlertDialog(
      title: Text(t.games.controllerLayout),
      content: SizedBox(
        width: 520,
        height: MediaQuery.sizeOf(context).height * .62,
        child: ListView(
          controller: _scroll,
          children: [
            Text(t.games.controllerLayoutHelp),
            if (_failed)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(t.games.controllerLayoutFailed),
                ),
              ),
            AppMenuButton<int>(
              enabled: !_busy,
              entriesBuilder: (_) => [
                for (var i = 0; i < widget.players; i++)
                  AppMenuItem(
                    value: i,
                    label: t.games.controllerPlayer(number: i + 1),
                    selected: i == _seat,
                  ),
              ],
              onSelected: (value) => setState(() => _seat = value),
              child: FocusableListTile(
                title: Text(t.games.controllerPlayer(number: _seat + 1)),
                leading: const AppIcon(Symbols.sports_esports_rounded),
              ),
            ),
            for (var i = 0; i < 15; i++)
              AppMenuButton<int>(
                enabled: !_busy,
                entriesBuilder: (_) => [
                  AppMenuItem(value: -1, label: t.games.padDisabled, selected: values[i + 1] == -1),
                  for (var target = 0; target < 15; target++)
                    AppMenuItem(value: target, label: labels[target], selected: values[i + 1] == target),
                ],
                onSelected: (target) => _change(i + 1, target),
                child: FocusableListTile(
                  title: Text(labels[i]),
                  subtitle: Text(values[i + 1] < 0 ? t.games.padDisabled : labels[values[i + 1]]),
                  trailing: const AppIcon(Symbols.chevron_right_rounded),
                ),
              ),
            for (var i = 0; i < 4; i++)
              SwitchListTile(
                title: Text(t.games.invertAxis(axis: axes[i])),
                value: values[18] & (1 << i) != 0,
                onChanged: _busy ? null : (_) => _change(18, values[18] ^ (1 << i)),
              ),
            SwitchListTile(
              title: Text(t.games.swapSticks),
              value: values[18] & 16 != 0,
              onChanged: _busy ? null : (_) => _change(18, values[18] ^ 16),
            ),
            SwitchListTile(
              title: Text(t.games.swapTriggers),
              value: values[18] & 32 != 0,
              onChanged: _busy ? null : (_) => _change(18, values[18] ^ 32),
            ),
            for (final index in [16, 17]) ...[
              Text(index == 16 ? t.games.stickDeadzone : t.games.triggerDeadzone),
              Slider(
                value: values[index].toDouble(),
                min: 0,
                max: 8192,
                divisions: 25,
                label: '${(values[index] / 32767 * 100).round()}%',
                semanticFormatterCallback: (value) => '${(value / 32767 * 100).round()}%',
                onChanged: _busy ? null : (value) => _change(index, value.round()),
              ),
            ],
            TextButton(
              onPressed: _busy ? null : () => setState(() => _profile = _profile.resetSeat(_seat)),
              child: Text(t.common.reset),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
        FilledButton(onPressed: _busy ? null : _save, child: Text(t.common.save)),
      ],
    );
  }
}
