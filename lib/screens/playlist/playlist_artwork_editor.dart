import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_playlist.dart';
import '../../media/media_server_client.dart';
import '../../services/file_picker_service.dart';
import '../../utils/error_message_utils.dart';
import '../../utils/media_image_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/optimized_media_image.dart';

/// The owning detail route supplies the account/authentication lease.
class PlaylistArtworkEditor extends StatefulWidget {
  const PlaylistArtworkEditor({super.key, required this.playlist, required this.client, required this.isCurrent});
  final MediaPlaylist playlist;
  final MediaServerClient client;
  final bool Function() isCurrent;

  @override
  State<PlaylistArtworkEditor> createState() => _PlaylistArtworkEditorState();
}

class _PlaylistArtworkEditorState extends State<PlaylistArtworkEditor> {
  List<PlaylistArtworkOption>? _options;
  bool _busy = false;
  String? _error;

  PlaylistArtworkClient get _client => widget.client as PlaylistArtworkClient;
  bool _current() => mounted && widget.isCurrent();
  void _requireCurrent() {
    if (!_current()) throw StateError('Playlist artwork source changed');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _options = null;
    });
    try {
      _requireCurrent();
      final options = await _client.fetchPlaylistArtwork(widget.playlist, isCurrent: _current);
      _requireCurrent();
      setState(() => _options = options);
    } catch (error, stack) {
      if (mounted) setState(() => _error = localizedLoadErrorMessage(error, stack, context: widget.playlist.title));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply(Future<MediaPlaylist?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _requireCurrent();
      final result = await action();
      _requireCurrent();
      if (!mounted) return;
      if (result != null) Navigator.of(context).pop(result);
    } catch (error, stack) {
      if (mounted) setState(() => _error = localizedLoadErrorMessage(error, stack, context: widget.playlist.title));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<MediaPlaylist?> _upload() async {
    final picked = await FilePickerService.instance.pickFiles(type: FileType.image, withData: false);
    _requireCurrent();
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.single;
    const maxBytes = PlaylistArtworkClient.maxUploadBytes;
    if (file.size <= 0 || file.size > maxBytes) throw const FormatException('Image exceeds upload limit');
    Uint8List bytes;
    if (file.bytes != null) {
      if (file.bytes!.length > maxBytes) throw const FormatException('Image exceeds upload limit');
      bytes = file.bytes!;
    } else {
      final path = file.path;
      if (path == null) throw const FormatException('Missing image data');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in File(path).openRead(0, maxBytes + 1)) {
        _requireCurrent();
        builder.add(chunk);
        if (builder.length > maxBytes) throw const FormatException('Image exceeds upload limit');
      }
      bytes = builder.takeBytes();
    }
    _requireCurrent();
    if (bytes.isEmpty) throw const FormatException('Missing image data');
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width <= 0 ||
            descriptor.height <= 0 ||
            descriptor.width > 16384 ||
            descriptor.height > 16384 ||
            descriptor.width * descriptor.height > 64000000) {
          throw const FormatException('Image dimensions exceed upload limit');
        }
        _requireCurrent();
        // Header metadata alone can accept a truncated/corrupt image. Decode
        // only a tiny first-frame presentation before handing original bytes
        // to the server.
        final codec = await descriptor.instantiateCodec(targetWidth: 1, targetHeight: 1);
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
    _requireCurrent();
    return _client.updatePlaylistArtwork(playlist: widget.playlist, bytes: bytes, isCurrent: _current);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(t.metadataEdit.selectPoster),
      content: SizedBox(
        width: 500,
        height: 380,
        child: Column(
          children: [
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_error != null && _options == null)
              TextButton(onPressed: _busy ? null : _load, child: Text(t.common.retry)),
            Expanded(
              child: _options == null
                  ? _busy
                        ? const Center(child: CircularProgressIndicator())
                        : const SizedBox.shrink()
                  : _options!.isEmpty
                  ? Center(child: Text(t.metadataEdit.noArtworkAvailable))
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemCount: _options!.length,
                      itemBuilder: (context, index) {
                        final option = _options![index];
                        final VoidCallback? select = _busy
                            ? null
                            : () => _apply(
                                () => _client.updatePlaylistArtwork(
                                  playlist: widget.playlist,
                                  artworkKey: option.key,
                                  isCurrent: _current,
                                ),
                              );
                        return FocusableWrapper(
                          key: ValueKey('playlist_artwork_$index'),
                          semanticLabel: option.selected
                              ? t.metadataEdit.selectedArtworkOption(index: index + 1)
                              : t.metadataEdit.artworkOption(index: index + 1),
                          canRequestFocus: !_busy,
                          onSelect: select,
                          child: GestureDetector(
                            onTap: select,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                OptimizedMediaImage(
                                  client: _current() ? widget.client : null,
                                  imagePath: option.thumbnailPath,
                                  imageType: ImageType.square,
                                  fit: BoxFit.cover,
                                ),
                                if (option.selected)
                                  const Align(
                                    alignment: Alignment.bottomRight,
                                    child: AppIcon(Symbols.check_circle_rounded),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Text(t.metadataEdit.imageUploadLimits),
          ],
        ),
      ),
      actions: [
        if (_busy) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        TextButton(
          key: const ValueKey('playlist_artwork_upload'),
          onPressed: _busy ? null : () => _apply(_upload),
          child: Text(t.metadataEdit.uploadFile),
        ),
        TextButton(
          key: const ValueKey('playlist_artwork_reset'),
          onPressed: _busy
              ? null
              : () => _apply(
                  () => _client.updatePlaylistArtwork(playlist: widget.playlist, reset: true, isCurrent: _current),
                ),
          child: Text(t.common.reset),
        ),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
      ],
    ),
  );
}
