import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'file_picker_service.dart';

/// Mobile file_picker writes supplied bytes; desktop returns only a path.
/// Keep subtitle export success behind the actual write on every platform.
final class SubtitleArtifactExport {
  static Future<String?> saveFile({
    String? dialogTitle, required String fileName, required Uint8List bytes,
    FileType type = FileType.custom, List<String>? allowedExtensions,
  }) async {
    if (bytes.isEmpty || bytes.length > 256 * 1024 * 1024) {
      throw const FormatException('Subtitle export exceeds its 256 MiB bound.');
    }
    final selected = await FilePickerService.instance.saveFile(dialogTitle: dialogTitle,
      fileName: fileName, bytes: bytes, type: type, allowedExtensions: allowedExtensions);
    if (selected == null || selected.isEmpty) return null;
    if (Platform.isAndroid || Platform.isIOS) return selected;
    final extension = p.extension(selected).replaceFirst(RegExp(r'^\.'), '').toLowerCase();
    if (!p.isAbsolute(selected) || allowedExtensions != null &&
        !allowedExtensions.map((value) => value.toLowerCase()).contains(extension)) {
      throw const FormatException('Choose an absolute file path with the requested export extension.');
    }
    final target = File(selected);
    final typeAtPath = await FileSystemEntity.type(selected, followLinks: false);
    if (typeAtPath != FileSystemEntityType.notFound && typeAtPath != FileSystemEntityType.file) {
      throw const FormatException('The export destination must be a regular file.');
    }
    final original = await target.stat();
    final temporary = await target.parent.createTemp('.plezy-subtitle-export-');
    final staged = File(p.join(temporary.path, 'output'));
    final backup = File(p.join(temporary.path, 'previous'));
    var movedPrevious = false, installed = false;
    try {
      await staged.writeAsBytes(bytes, flush: true);
      final latestType = await FileSystemEntity.type(selected, followLinks: false);
      final latest = await target.stat();
      if (latestType != typeAtPath || latest.size != original.size || latest.modified != original.modified ||
          latest.changed != original.changed) throw StateError('The export destination changed while saving.');
      if (await target.exists()) {
        await target.rename(backup.path);
        movedPrevious = true;
      }
      await staged.rename(target.path);
      installed = true;
      return selected;
    } catch (_) {
      if (movedPrevious && !installed && !await target.exists()) await backup.rename(target.path);
      rethrow;
    } finally {
      // A failed rollback must keep the previous file recoverable.
      if (installed || !movedPrevious || !await backup.exists()) {
        try { await temporary.delete(recursive: true); } on Object { /* OS cleanup can retry. */ }
      }
    }
  }
}
