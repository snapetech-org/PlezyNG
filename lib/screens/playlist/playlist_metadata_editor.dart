import 'package:flutter/material.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_playlist.dart';
import '../../media/media_server_client.dart';
import '../../utils/error_message_utils.dart';

/// Edits only presentation fields. The caller owns the account and route lease.
class PlaylistMetadataEditor extends StatefulWidget {
  const PlaylistMetadataEditor({super.key, required this.playlist, required this.client, required this.isCurrent});
  final MediaPlaylist playlist;
  final PlaylistMetadataClient client;
  final bool Function() isCurrent;

  @override
  State<PlaylistMetadataEditor> createState() => _PlaylistMetadataEditorState();
}

class _PlaylistMetadataEditorState extends State<PlaylistMetadataEditor> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.playlist.title);
  late final _summary = TextEditingController(text: widget.playlist.summary ?? '');
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final title = _title.text.trim();
    final summary = _summary.text;
    final changedTitle = title != widget.playlist.title;
    final changedSummary = summary != (widget.playlist.summary ?? '');
    if (!changedTitle && !changedSummary) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!widget.isCurrent()) throw StateError('Playlist source changed');
      final updated = await widget.client.updatePlaylistMetadata(
        playlist: widget.playlist,
        title: changedTitle ? title : null,
        summary: changedSummary ? summary : null,
        isCurrent: () => mounted && widget.isCurrent(),
      );
      if (!mounted) return;
      if (!widget.isCurrent()) throw StateError('Playlist source changed');
      Navigator.of(context).pop(updated);
    } catch (error, stack) {
      if (mounted) setState(() => _error = localizedLoadErrorMessage(error, stack, context: widget.playlist.title));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _summary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(t.common.edit),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('playlist_metadata_title'),
                  controller: _title,
                  autofocus: true,
                  enabled: !_saving,
                  maxLength: 255,
                  decoration: InputDecoration(labelText: t.playlists.playlistName),
                  validator: (value) => value == null || value.trim().isEmpty ? t.playlists.enterPlaylistName : null,
                  onFieldSubmitted: (_) => _save(),
                ),
                TextFormField(
                  key: const ValueKey('playlist_metadata_summary'),
                  controller: _summary,
                  enabled: !_saving,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 10000,
                  decoration: InputDecoration(labelText: t.metadataEdit.summary),
                ),
                if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
        FilledButton(
          key: const ValueKey('playlist_metadata_save'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.common.save),
        ),
      ],
    ),
  );
}
