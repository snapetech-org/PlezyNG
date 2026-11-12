import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import '../../i18n/strings.g.dart';
import '../../models/plex/plex_source_invitation.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/plex_sharing_invitations.dart';
import '../../widgets/app_icon.dart';

class MusicSharingInvitationsScreen extends StatefulWidget {
  const MusicSharingInvitationsScreen({super.key, required this.catalog});
  final PlexSharingInvitations catalog;
  @override
  State<MusicSharingInvitationsScreen> createState() => _MusicSharingInvitationsScreenState();
}

class _MusicSharingInvitationsScreenState extends State<MusicSharingInvitationsScreen> {
  List<PlexSourceInvitation> _entries = [];
  Object _generation = Object();
  bool _loading = false, _deciding = false, _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool keepError = false}) async {
    if (!widget.catalog.current) return;
    final generation = _generation = Object();
    setState(() {
      _loading = true;
      _entries = [];
      _failed = keepError;
    });
    try {
      final entries = await widget.catalog.refresh();
      if (mounted && identical(generation, _generation) && widget.catalog.current) {
        setState(() => _entries = entries);
      }
    } catch (_) {
      if (mounted && identical(generation, _generation) && widget.catalog.current) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted && identical(generation, _generation)) setState(() => _loading = false);
    }
  }

  Future<void> _respond(PlexSourceInvitation invitation, {required bool accept}) async {
    final generation = _generation;
    if (_loading || _deciding || !widget.catalog.current) return;
    setState(() => _deciding = true);
    var attempted = false, failed = false;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(accept ? t.musicTools.sharingInvitationAccept : t.musicTools.sharingInvitationReject),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  accept
                      ? t.musicTools.sharingAcceptConfirm(owner: invitation.ownerName)
                      : t.musicTools.sharingDeclineConfirm(owner: invitation.ownerName),
                ),
                const SizedBox(height: 12),
                Text(t.musicTools.sharingInvitationHint),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(accept ? t.musicTools.sharingInvitationAccept : t.musicTools.sharingInvitationReject),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || !identical(generation, _generation) || !widget.catalog.current) return;
      attempted = true;
      await widget.catalog.respond(invitation, accept: accept);
    } catch (_) {
      failed = true;
    } finally {
      if (mounted && identical(generation, _generation)) {
        setState(() => _deciding = false);
        if (attempted && widget.catalog.current) await _load(keepError: failed);
      }
    }
  }

  @override
  void dispose() {
    _generation = Object();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Retired profile/server leases must hide pending decisions immediately.
    context.watch<ActiveProfileProvider?>();
    context.watch<MultiServerProvider?>();
    final current = widget.catalog.current;
    final busy = _loading || _deciding || !current;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.musicTools.sharingInvitationsTitle),
        actions: [
          IconButton(
            tooltip: t.common.refresh,
            icon: const AppIcon(Symbols.refresh_rounded),
            onPressed: busy ? null : _load,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(t.musicTools.sharingInvitationHint),
          if (_loading) const LinearProgressIndicator(),
          if (_failed || !current)
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(t.musicExperience.error)),
          if (current && !_loading && !_failed && _entries.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Text(t.musicTools.noSharingInvitations)),
          if (current)
            for (final invitation in _entries)
              Card(
                key: ValueKey(invitation.id),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(invitation.ownerName, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton(
                            onPressed: busy ? null : () => _respond(invitation, accept: true),
                            child: Text(t.musicTools.sharingInvitationAccept),
                          ),
                          TextButton(
                            onPressed: busy ? null : () => _respond(invitation, accept: false),
                            child: Text(t.musicTools.sharingInvitationReject),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
