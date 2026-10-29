import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../games/steam_families_client.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/pending_auth_dialog.dart';

class SteamFamiliesDialog extends StatefulWidget {
  const SteamFamiliesDialog({
    super.key,
    required this.client,
    required this.appId,
    required this.isCurrent,
    required this.retired,
  });
  final SteamFamiliesClient client;
  final int appId;
  final bool Function() isCurrent;
  final Future<void> retired;
  @override
  State<SteamFamiliesDialog> createState() => _SteamFamiliesDialogState();
}

class _SteamFamiliesDialogState extends State<SteamFamiliesDialog> {
  final _name = TextEditingController(), _target = TextEditingController();
  final _cancelled = Completer<void>();
  SteamFamilyState? _state;
  SteamFamilyReview? _review;
  String? _editing, _message;
  int _role = 2;
  bool _busy = false, _acknowledged = false;
  bool get current => mounted && !_cancelled.isCompleted && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.retired.then((_) {
        _retire();
        if (mounted) {
          final route = ModalRoute.of(context);
          if (route != null && route.isActive) Navigator.of(context).removeRoute(route);
        }
      }),
    );
  }

  void _retire() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    unawaited(widget.client.retire());
  }

  @override
  void dispose() {
    _retire();
    _name.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (!current || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (_) {
      if (current) {
        setState(() {
          _review = null;
          _message = t.games.familyRefreshRequired;
        });
      }
    } finally {
      if (current) setState(() => _busy = false);
    }
  }

  Future<void> _authorize() => _perform(() async {
    await widget.client.start();
    if (current) setState(() {});
    while (current && !widget.client.authorized) {
      await Future.any([Future<void>.delayed(const Duration(seconds: 5)), _cancelled.future]);
      if (!current) return;
      await widget.client.poll();
      if (current) setState(() {});
    }
    if (current) await _readState();
  });
  Future<void> _readState() async {
    final state = await widget.client.state();
    if (current) {
      setState(() {
        _state = state;
        _review = null;
        _editing = null;
      });
    }
  }

  void _edit(String action) {
    if (!current || _busy) return;
    setState(() {
      _editing = action;
      _name.text = action == 'rename' ? _state?.name ?? '' : '';
      _target.clear();
      _role = 2;
      _message = null;
    });
  }

  Future<void> _prepare(SteamFamilyChange change) => _perform(() async {
    final review = await widget.client.review(change);
    if (current) {
      setState(() {
        _review = review;
        _state = review.state;
        _editing = null;
        _acknowledged = false;
      });
    }
  });
  Future<void> _commit() => _perform(() async {
    final review = _review;
    if (review == null || !_acknowledged) return;
    setState(() => _review = null);
    final needsSteam = await widget.client.commit(review);
    if (!current) return;
    await _readState();
    if (current) setState(() => _message = needsSteam ? t.games.familyNeedsSteam : t.games.familySubmitted);
  });
  String _label(String action) => switch (action) {
    'create' => t.games.familyCreate,
    'rename' => t.games.familyRename,
    'invite' => t.games.familyInvite,
    'cancelInvite' => t.games.familyCancelInvite,
    'resendInvite' => t.games.familyResendInvite,
    'remove' => t.games.familyRemove,
    'leave' => t.games.familyLeave,
    'delete' => t.games.familyDelete,
    'restore' => t.games.familyRestore,
    'join' => t.games.familyJoin,
    'preferredLender' => t.games.familyPreferredLender,
    _ => t.common.confirm,
  };
  String _roleName(int role) => role == 1 ? t.games.familyAdult : t.games.familyChild;
  Widget _button(String label, VoidCallback? action, {bool autofocus = false}) => FocusableButton(
    onPressed: action,
    autofocus: autofocus,
    child: TextButton(onPressed: action, child: Text(label)),
  );
  Widget _member(SteamFamilyMember member, {bool pending = false}) => FocusableListTile(
    leading: AppIcon(member.role == 1 ? Symbols.person_rounded : Symbols.child_care_rounded),
    title: Text(member.steamId),
    subtitle: Text(_roleName(member.role)),
    trailing: _busy || (pending && !_state!.adult)
        ? null
        : AppMenuButton<String>(
            adaptiveSheet: true,
            tooltip: '${t.common.options}: ${member.steamId}',
            icon: const AppIcon(Symbols.more_vert_rounded),
            entriesBuilder: (_) => [
              if (_state!.adult)
                AppMenuItem(
                  value: pending ? 'cancelInvite' : 'remove',
                  label: _label(pending ? 'cancelInvite' : 'remove'),
                  icon: Symbols.person_remove_rounded,
                ),
              if (pending && _state!.adult)
                AppMenuItem(value: 'resendInvite', label: t.games.familyResendInvite, icon: Symbols.send_rounded),
              if (!pending && widget.appId > 0)
                AppMenuItem(
                  value: 'preferredLender',
                  label: t.games.familyPreferredLender,
                  icon: Symbols.sports_esports_rounded,
                ),
            ],
            onSelected: (action) => _prepare(
              SteamFamilyChange(
                action,
                steamId: member.steamId,
                appId: action == 'preferredLender' ? widget.appId : null,
              ),
            ),
          ),
  );
  @override
  Widget build(BuildContext context) {
    final challenge = widget.client.challenge;
    if (challenge != null && !widget.client.authorized && _message == null) {
      return PendingAuthDialog(
        title: t.games.familyAuthorize,
        body: t.games.familyScanHelp,
        url: challenge.toString(),
        openLabel: t.games.openInSteam,
        onCancel: _retire,
        children: [Text(widget.client.steamId)],
      );
    }
    final state = _state, review = _review;
    final editing = _editing;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const AppIcon(Symbols.family_restroom_rounded),
                  const SizedBox(width: 12),
                  Expanded(child: Text(t.games.steamFamilies, style: Theme.of(context).textTheme.titleLarge)),
                ],
              ),
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              Flexible(
                child: ListView(
                  // Start each new review/editor/error at its heading. Retaining
                  // the prior scroll offset can hide a live error at large text.
                  key: ValueKey(_message != null ? 'message' : (review != null ? 'review' : editing ?? 'state')),
                  shrinkWrap: true,
                  children: [
                    if (_message case final message?)
                      Semantics(
                        liveRegion: true,
                        child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(message)),
                      ),
                    if (!widget.client.authorized) ...[
                      Text(t.games.familyAuthorizeHelp),
                      Text(widget.client.steamId),
                      if (widget.client.expires == null) _button(t.games.familyAuthorize, _busy ? null : _authorize),
                    ] else if (review != null) ...[
                      Text(_label(review.change.action), style: Theme.of(context).textTheme.titleMedium),
                      Text(isolateDisplayText(review.state.name)),
                      if (review.change.name case final name?) Text(isolateDisplayText(name)),
                      if (review.change.steamId case final id?) Text('${t.games.familySteamId}: $id'),
                      if (review.change.familyId case final id?) Text(id),
                      if (review.change.role case final role?) Text(_roleName(role)),
                      if (review.change.appId case final app?) Text('Steam AppID: $app'),
                      Text(t.games.familyReviewHelp),
                      FocusableSwitchListTile(
                        value: _acknowledged,
                        title: Text(t.games.familyAcknowledge),
                        onChanged: _busy ? null : (value) => setState(() => _acknowledged = value),
                      ),
                      Wrap(
                        children: [
                          _button(
                            t.common.cancel,
                            _busy ? null : () => setState(() => _review = null),
                            autofocus: true,
                          ),
                          _button(t.common.confirm, _busy || !_acknowledged ? null : _commit),
                        ],
                      ),
                    ] else if (editing != null) ...[
                      Text(_label(editing), style: Theme.of(context).textTheme.titleMedium),
                      if (editing == 'invite') ...[
                        TextField(
                          controller: _target,
                          decoration: InputDecoration(labelText: t.games.familySteamId),
                          maxLength: 17,
                          keyboardType: TextInputType.number,
                        ),
                        DropdownButtonFormField<int>(
                          initialValue: _role,
                          decoration: InputDecoration(labelText: t.games.familyRole),
                          items: [
                            for (final role in [2, 1]) DropdownMenuItem(value: role, child: Text(_roleName(role))),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) {
                                  if (value != null) setState(() => _role = value);
                                },
                        ),
                      ] else
                        TextField(
                          controller: _name,
                          decoration: InputDecoration(labelText: t.games.familyName),
                          maxLength: 64,
                        ),
                      Wrap(
                        children: [
                          _button(t.common.cancel, _busy ? null : () => setState(() => _editing = null)),
                          _button(
                            t.games.familyReview,
                            _busy
                                ? null
                                : () => _prepare(
                                    SteamFamilyChange(
                                      editing,
                                      name: editing == 'invite' ? null : _name.text.trim(),
                                      steamId: editing == 'invite' ? _target.text.trim() : null,
                                      role: editing == 'invite' ? _role : null,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ] else if (state != null) ...[
                      Text(
                        state.familyId == null ? t.games.familyNoFamily : isolateDisplayText(state.name),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (state.cooldownSeconds > 0)
                        Text(t.games.familyCooldown(days: (state.cooldownSeconds / 86400).ceil())),
                      if (state.familyId == null) ...[
                        if (state.cooldownSeconds == 0)
                          _button(t.games.familyCreate, _busy ? null : () => _edit('create')),
                        if (state.canRestore)
                          _button(
                            t.games.familyRestore,
                            _busy ? null : () => _prepare(const SteamFamilyChange('restore')),
                          ),
                        if (state.invitations.isNotEmpty) Text(t.games.familyInvitations),
                        for (final invitation in state.invitations)
                          FocusableListTile(
                            title: Text(invitation.familyId),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${invitation.inviter} · ${_roleName(invitation.role)}'),
                                if (invitation.awaiting)
                                  Text(t.games.familyNeedsSteam)
                                else
                                  _button(
                                    t.games.familyJoin,
                                    _busy
                                        ? null
                                        : () => _prepare(SteamFamilyChange('join', familyId: invitation.familyId)),
                                  ),
                              ],
                            ),
                          ),
                      ] else ...[
                        for (final member in state.members)
                          if (member.steamId == widget.client.steamId)
                            ListTile(title: Text(member.steamId), subtitle: Text(_roleName(member.role)))
                          else
                            _member(member),
                        if (state.pending.isNotEmpty) ...[
                          const Divider(),
                          Text(t.games.familyPendingInvites),
                          for (final invite in state.pending) _member(invite, pending: true),
                        ],
                        if (state.adult)
                          Wrap(
                            children: [
                              _button(t.games.familyRename, _busy ? null : () => _edit('rename')),
                              if (state.freeSpots > 0)
                                _button(t.games.familyInvite, _busy ? null : () => _edit('invite')),
                              _button(
                                t.games.familyLeave,
                                _busy ? null : () => _prepare(const SteamFamilyChange('leave')),
                              ),
                              if (state.members.length == 1 && state.pending.isEmpty)
                                _button(
                                  t.games.familyDelete,
                                  _busy ? null : () => _prepare(const SteamFamilyChange('delete')),
                                ),
                            ],
                          ),
                      ],
                    ],
                  ],
                ),
              ),
              const Divider(),
              Wrap(
                children: [
                  _button(t.common.close, () => Navigator.of(context).pop()),
                  if (widget.client.authorized) _button(t.common.refresh, _busy ? null : () => _perform(_readState)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
