import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_companion_service.dart';
import '../../../services/subtitle_retimer.dart';

/// Compare recognized text to its actual decoded subtitle image. Image downloads
/// are authenticated, bounded, digest-checked and serialized. Review never
/// replaces the host's original OCR result or image evidence.
class SubtitleBitmapReviewDialog extends StatefulWidget {
  const SubtitleBitmapReviewDialog({super.key, required this.service, required this.result,
    required this.jobId, required this.mediaDigest, required this.isCurrent});
  final SubtitleCompanionService service;
  final SubtitleCompanionResult result;
  final String jobId, mediaDigest;
  final bool Function() isCurrent;
  @override
  State<SubtitleBitmapReviewDialog> createState() => _SubtitleBitmapReviewDialogState();
}

class _SubtitleBitmapReviewDialogState extends State<SubtitleBitmapReviewDialog> {
  late final _cues = List<SubtitleCue>.of(widget.result.cues);
  late final _indices = {for (var i = 0; i < _cues.length; i++) _cues[i].stableId: i};
  final _text = TextEditingController();
  final _reviewed = <String>{}, _excluded = <String>{};
  final _undo = <(int, SubtitleCue, bool, bool)>[];
  int _imageIndex = 0;
  bool _onlyUncertain = false, _loading = false, _exporting = false;
  Uint8List? _bytes;
  String? _error, _message;

  SubtitleCompanionImage get _image => widget.result.images[_imageIndex];
  bool get _current => mounted && widget.isCurrent();
  List<int> get _visible => [for (var i = 0; i < widget.result.images.length; i++)
    if (!_onlyUncertain || widget.result.images[i].requiresReview) i];

  @override
  void initState() { super.initState(); _text.text = _cues[_indices[_image.cueId]!].text; unawaited(_loadImage()); }
  @override
  void dispose() { _text.dispose(); super.dispose(); }

  Future<void> _loadImage() async {
    if (!_current) return;
    final image = _image;
    setState(() { _loading = true; _bytes = null; _error = null; });
    try {
      final bytes = await widget.service.evidenceImage(widget.jobId, image);
      if (_current && image.cueId == _image.cueId) setState(() => _bytes = bytes);
    } catch (_) { if (mounted) setState(() => _error = 'The original image could not be loaded or verified. Retry before reviewing.'); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  void _remember(int index) {
    final cue = _cues[index];
    _undo.add((index, cue, _reviewed.contains(cue.stableId), _excluded.contains(cue.stableId)));
    if (_undo.length > 100) _undo.removeAt(0);
  }

  bool _save({bool markReviewed = false}) {
    if (!_current) return false;
    final index = _indices[_image.cueId]!, cue = _cues[_indices[_image.cueId]!];
    final text = _text.text.trim();
    if (_excluded.contains(cue.stableId) && text.isEmpty) return true;
    if (text.isEmpty || text.length > 4000) { setState(() => _error = 'Enter 1–4000 characters, or exclude this cue.'); return false; }
    if (markReviewed && (_bytes == null || text == '[OCR text requires review]')) {
      setState(() => _error = 'View the image and replace the unreadable-text placeholder, or exclude this cue.');
      return false;
    }
    if (text != cue.text || markReviewed && !_reviewed.contains(cue.stableId)) {
      _remember(index);
      _cues[index] = SubtitleCue(index: cue.index, startMs: cue.startMs, endMs: cue.endMs, text: text, cueId: cue.stableId);
      if (markReviewed) _reviewed.add(cue.stableId);
      setState(() { _error = null; _message = markReviewed ? 'Image and text marked reviewed.' : 'Correction retained for the normal review.'; });
    }
    return true;
  }

  void _move(int direction) {
    if (_loading || _exporting || !_save()) return;
    final visible = _visible;
    final position = visible.indexOf(_imageIndex);
    final next = (position + direction).clamp(0, visible.length - 1).toInt();
    _select(visible[next]);
  }

  void _select(int index) {
    setState(() { _imageIndex = index; _text.text = _cues[_indices[_image.cueId]!].text; _message = null; });
    unawaited(_loadImage());
  }

  Future<void> _export() async {
    if (_loading || _exporting || !_save()) return;
    setState(() { _exporting = true; _error = null; });
    try {
      final archive = Archive();
      final included = <String>{};
      var bytes = 0;
      for (final image in widget.result.images) {
        if (!included.add(image.digest)) continue;
        if (!_current) return;
        final png = await widget.service.evidenceImage(widget.jobId, image);
        bytes += png.length;
        if (bytes > 32 * 1024 * 1024) throw const FormatException('Evidence exceeds the 32 MiB bound.');
        archive.addFile(ArchiveFile('images/${image.digest}.png', png.length, png));
      }
      Map<String, Object> cue(SubtitleCue c) => {'cueId': c.stableId, 'startMs': c.startMs, 'endMs': c.endMs, 'text': c.text};
      final manifest = utf8.encode(jsonEncode({'schema': 1, 'jobId': widget.jobId, 'mediaDigest': widget.mediaDigest,
        'language': widget.result.language, 'images': widget.result.images.map((i) => i.toJson()).toList(),
        'originalOcrCues': widget.result.cues.map(cue).toList(), 'reviewedCues': _cues.map(cue).toList(),
        'excludedCueIds': _excluded.toList(), 'imageReviewedCueIds': _reviewed.toList(), 'warnings': widget.result.warnings}));
      if (manifest.length > 24 * 1024 * 1024) throw const FormatException('Evidence manifest exceeds 24 MiB.');
      archive.addFile(ArchiveFile('manifest.json', manifest.length, manifest));
      final encoded = ZipEncoder().encode(archive);
      if (!_current) return;
      await FilePickerService.instance.saveFile(dialogTitle: 'Save bitmap images and OCR provenance', fileName: 'subtitle_ocr_evidence.zip',
        type: FileType.custom, allowedExtensions: const ['zip'], bytes: Uint8List.fromList(encoded));
      if (mounted) setState(() => _message = 'Evidence export prepared with original images and review annotations.');
    } catch (_) { if (mounted) setState(() => _error = 'The evidence archive could not be exported. Original images remain with the companion job.'); }
    finally { if (mounted) setState(() => _exporting = false); }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image, cue = _cues[_indices[_image.cueId]!];
    final visible = _visible, position = _visible.indexOf(_imageIndex);
    final busy = _loading || _exporting;
    final unresolved = widget.result.images.where((i) => i.requiresReview && !_reviewed.contains(i.cueId) && !_excluded.contains(i.cueId)).length;
    return AlertDialog(title: const Text('Review bitmap OCR against images'),
      content: SizedBox(width: 760, height: (MediaQuery.sizeOf(context).height - 200).clamp(280.0, 720.0).toDouble(),
        child: ListView(children: [
          Text('Image ${_imageIndex + 1} of ${widget.result.images.length} · $unresolved uncertain cues still need review'),
          Text('${Duration(milliseconds: cue.startMs)} → ${Duration(milliseconds: cue.endMs)} · OCR ${(image.confidence * 100).round()}% (uncalibrated)'),
          Text('${image.width} × ${image.height} at (${image.x}, ${image.y})${image.forced ? ' · forced' : ''}'),
          FilterChip(label: const Text('Uncertain images only'), selected: _onlyUncertain,
            onSelected: busy ? null : (value) {
              if (!_save()) return;
              if (value && !widget.result.images.any((i) => i.requiresReview)) return;
              setState(() => _onlyUncertain = value);
              if (!_visible.contains(_imageIndex)) _select(_visible.first);
            }),
          if (busy) const LinearProgressIndicator(),
          Container(height: 210, color: Colors.black, alignment: Alignment.center,
            child: _bytes == null ? const Text('Original RGBA subtitle image', style: TextStyle(color: Colors.white))
              : InteractiveViewer(child: Image.memory(_bytes!, fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text('Invalid image', style: TextStyle(color: Colors.white))))),
          if (_bytes == null && !_loading) TextButton(onPressed: _exporting ? null : _loadImage, child: const Text('Retry image')),
          TextField(controller: _text, minLines: 2, maxLines: 5, maxLength: 4000, enabled: !_exporting,
            decoration: const InputDecoration(labelText: 'Recognized text / correction')),
          Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: busy || _bytes == null ? null : () => _save(markReviewed: true), child: Text(_reviewed.contains(image.cueId) ? 'Reviewed' : 'Mark image and text reviewed')),
            TextButton(onPressed: busy ? null : () { _remember(_indices[image.cueId]!); setState(() {
              if (!_excluded.add(image.cueId)) _excluded.remove(image.cueId);
            }); }, child: Text(_excluded.contains(image.cueId) ? 'Restore cue' : 'Exclude cue')),
            TextButton(onPressed: busy || _undo.isEmpty ? null : () {
              final saved = _undo.removeLast();
              _cues[saved.$1] = saved.$2;
              if (saved.$3) { _reviewed.add(saved.$2.stableId); } else { _reviewed.remove(saved.$2.stableId); }
              if (saved.$4) { _excluded.add(saved.$2.stableId); } else { _excluded.remove(saved.$2.stableId); }
              _onlyUncertain = false;
              _select(widget.result.images.indexWhere((i) => i.cueId == saved.$2.stableId));
            }, child: const Text('Undo')),
          ]),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_message != null) Text(_message!),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            TextButton(onPressed: busy || position <= 0 ? null : () => _move(-1), child: const Text('Previous image')),
            TextButton(onPressed: busy || position + 1 >= visible.length ? null : () => _move(1), child: const Text('Next image')),
          ]),
        ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: busy ? null : _export, child: const Text('Export image evidence')),
        FilledButton(onPressed: busy || unresolved != 0 ? null : () {
          if (!_save()) return;
          final retained = _cues.where((c) => !_excluded.contains(c.stableId)).toList();
          if (retained.isEmpty) { setState(() => _error = 'All cues were excluded. Cancel to keep the original track.'); return; }
          Navigator.pop(context, retained);
        }, child: const Text('Continue to subtitle review'))]);
  }
}
