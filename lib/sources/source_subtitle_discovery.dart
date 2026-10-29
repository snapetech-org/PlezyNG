import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'content_access.dart';
import 'source_models.dart';
import 'source_transport.dart';

class SourceSubtitleCandidate {
  const SourceSubtitleCandidate(this.file, this.folder);
  final PublicationFile file;
  final String folder;
}
class SourceSubtitleListing {
  const SourceSubtitleListing(this.candidates, this.limited);
  final List<SourceSubtitleCandidate> candidates;
  final bool limited;
}

/// All listing, renewal and file reads use the selected source's existing
/// adapter. No guessed filename URL probes or credential copies enter storage.
abstract final class SourceSubtitleDiscovery {
  static String _match(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
  static Future<SourceSubtitleListing> discover(SourceAdapter adapter, SourceEntry item, PublicationFile media,
      bool Function() current) async {
    if (!adapter.supportsSubtitleBrowse) throw const SourceException(SourceFailure.unsupported);
    final stem = _match(p.basenameWithoutExtension(media.name));
    final folders = <(String?, int)>[(item.parentId, 0)];
    final visited = <String>{}, files = <String>{};
    final results = <SourceSubtitleCandidate>[];
    final linked = await adapter.linkedSubtitles(item, media).timeout(const Duration(seconds: 12));
    if (!current()) throw const SourceException(SourceFailure.cancelled);
    for (final file in linked.take(128)) {
      if (isSourceTextSubtitle(file.name) && !file.streamOnly && !file.sampleOnly &&
          (file.size == null || file.size! > 0 && file.size! <= 5 * 1024 * 1024) && files.add(file.id)) {
        results.add(SourceSubtitleCandidate(file, 'Linked by source metadata'));
      }
    }
    if (stem.length < 2) return SourceSubtitleListing(List.unmodifiable(results), linked.length > 128);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var pages = 0, rows = 0, limited = false;
    for (var f = 0; f < folders.length && !limited; f++) {
      final (folder, depth) = folders[f];
      if (!visited.add(folder ?? '')) continue;
      String? cursor;
      final cursors = <String>{};
      do {
        if (!current()) throw const SourceException(SourceFailure.cancelled);
        if (++pages > 50 || DateTime.now().isAfter(deadline)) { limited = true; break; }
        final page = await adapter.browseSubtitleFiles(parent: folder, cursor: cursor).timeout(const Duration(seconds: 12));
        if (!current()) throw const SourceException(SourceFailure.cancelled);
        for (final entry in page.entries) {
          if (++rows > 10000 || results.length >= 128) { limited = true; break; }
          if (entry.isFolder && depth == 0 && folders.length < 16 &&
              const {'subs', 'subtitles', 'captions'}.contains(entry.title.toLowerCase())) folders.add((entry.id, 1));
          for (final file in entry.files) {
            if (!isSourceTextSubtitle(file.name) || file.streamOnly || file.sampleOnly ||
                file.size != null && (file.size! <= 0 || file.size! > 5 * 1024 * 1024)) continue;
            final name = _match(p.basenameWithoutExtension(file.name));
            if ((name == stem || name.startsWith('$stem ')) && files.add(file.id)) {
              results.add(SourceSubtitleCandidate(file, depth == 0 ? 'Media folder' : 'Subtitle folder'));
            }
          }
        }
        cursor = page.next;
        if (cursor != null && !cursors.add(cursor)) { limited = true; break; }
      } while (!limited && cursor != null);
    }
    results.sort((a, b) => a.file.name.toLowerCase().compareTo(b.file.name.toLowerCase()));
    return SourceSubtitleListing(List.unmodifiable(results), limited);
  }

  static Future<List<int>> read(SourceAdapter adapter, PublicationFile file, bool Function() current) async {
    if (!current() || !isSourceTextSubtitle(file.name) || file.sampleOnly || file.streamOnly) {
      throw const SourceException(SourceFailure.permission);
    }
    final gateway = SourceStreamGateway(valid: current), client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = await gateway.register(adapter, file);
      final request = await client.getUrl(uri); request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 || response.contentLength > 5 * 1024 * 1024) throw const SourceException(SourceFailure.invalidData);
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        if (!current()) throw const SourceException(SourceFailure.cancelled);
        if (bytes.length + chunk.length > 5 * 1024 * 1024) throw const SourceException(SourceFailure.invalidData);
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty || file.size != null && bytes.length != file.size) throw const SourceException(SourceFailure.conflict);
      return bytes;
    } finally { client.close(force: true); await gateway.close(); }
  }
}
