import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../widgets/app_icon.dart';
import '../../i18n/strings.g.dart';
import '../../models/plex/plex_playlist_access.dart';
import '../../services/plex_playlist_sharing.dart';

class PlaylistShareDialog extends StatefulWidget {
  const PlaylistShareDialog({super.key, required this.draft, required this.sharing});
  final PlexPlaylistAccessDraft draft;
  final PlexPlaylistSharing sharing;
  @override
  State<PlaylistShareDialog> createState() => _PlaylistShareDialogState();
}

class _PlaylistShareDialogState extends State<PlaylistShareDialog> {
  final _form = GlobalKey<FormState>();
  final _recipient = TextEditingController();
  bool _busy = false, _revoking = false;
  String? _error;

  List<PlexPlaylistAccessGrant> _access = const [];
  bool _loading = true, _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _loadAccess();
  }

  Future<void> _loadAccess() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final access = await widget.sharing.listAccess(widget.draft);
      if (!mounted || !widget.sharing.current) return;
      setState(() => _access = access);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(PlexPlaylistAccessGrant grant) async {
    if (_busy || _loading || !widget.sharing.current) return;
    setState(() {
      _busy = true;
      _revoking = true;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.common.delete),
          content: Text('${grant.userName}\n${widget.draft.playlist.title}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
            FilledButton(
              key: const ValueKey('playlist_revoke_confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(t.common.confirm),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true || !widget.sharing.current) return;
      await widget.sharing.revoke(widget.draft, grant);
      if (!mounted || !widget.sharing.current) return;
      setState(() => _access = _access.where((item) => !identical(item, grant)).toList());
    } catch (_) {
      if (mounted) setState(() => _error = t.musicTools.playlistSharingFailed);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _revoking = false;
        });
      }
    }
  }

  Future<void> _grant() async {
    if (_busy || _loading || !_form.currentState!.validate()) return;
    if (!widget.sharing.current) {
      setState(() => _error = t.musicTools.playlistSharingFailed);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.sharing.grant(widget.draft, _recipient.text.trim());
      if (!mounted || !widget.sharing.current) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = t.musicTools.playlistSharingFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _recipient.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(t.musicTools.playlistSharing),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.draft.playlist.title),
                const SizedBox(height: 12),
                Text(t.musicTools.playlistAccessList, style: Theme.of(context).textTheme.titleSmall),
                if (_loading)
                  const LinearProgressIndicator()
                else if (_loadFailed)
                  TextButton(onPressed: _busy ? null : _loadAccess, child: Text(t.common.retry))
                else if (_access.isEmpty)
                  Text(t.musicTools.playlistAccessNone)
                else
                  for (final grant in _access)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(grant.userName),
                      trailing: IconButton(
                        key: ValueKey('playlist_revoke_${grant.itemId}'),
                        tooltip: t.common.delete,
                        icon: const AppIcon(Symbols.person_remove_rounded),
                        onPressed: _busy ? null : () => _revoke(grant),
                      ),
                    ),

                const SizedBox(height: 12),
                Text(t.musicTools.playlistSharingHint),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('playlist_share_recipient'),
                  controller: _recipient,
                  autofocus: true,
                  enabled: !_busy,
                  maxLength: 320,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: t.musicTools.playlistRecipient),
                  validator: (value) => value == null || value.trim().isEmpty ? t.musicTools.playlistRecipient : null,
                  onFieldSubmitted: (_) => _grant(),
                ),
                if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
        FilledButton(
          key: const ValueKey('playlist_share_confirm'),
          onPressed: _busy || _loading ? null : _grant,
          child: _busy && !_revoking
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator())
              : Text(t.common.confirm),
        ),
      ],
    ),
  );
}
