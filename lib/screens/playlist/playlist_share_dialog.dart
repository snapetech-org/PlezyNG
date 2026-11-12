import 'package:flutter/material.dart';
import '../../i18n/strings.g.dart';
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
  bool _busy = false;
  String? _error;

  Future<void> _grant() async {
    if (_busy || !_form.currentState!.validate()) return;
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
          onPressed: _busy ? null : _grant,
          child: _busy
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator())
              : Text(t.common.confirm),
        ),
      ],
    ),
  );
}
