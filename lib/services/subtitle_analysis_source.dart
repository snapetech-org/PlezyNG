import 'dart:async';
import 'dart:io';

import '../mpv/mpv.dart';
import 'subtitle_discovery_service.dart';

/// Renewable source access is owned by its source transport. The decoder sees
/// only a local file or a short-lived loopback gateway capability, never server
/// cookies, signed upstream URLs or a durable copy of those credentials.
class SubtitleAnalysisSource {
  const SubtitleAnalysisSource({required this.uri, required this.identity,
    required this.isCurrent, required this.close});
  final Uri uri;
  final String identity;
  final bool Function() isCurrent;
  final Future<void> Function() close;
  static Future<SubtitleAnalysisSource> localPlayer(Player player, bool Function() current) async {
    final path = SubtitleDiscoveryService.localMediaPath(await player.getProperty('path'));
    if (path == null) throw UnsupportedError('This player does not expose an owned local analysis source.');
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || !current()) throw StateError('Media changed or local file unavailable.');
    return SubtitleAnalysisSource(uri: file.uri, identity: '$path:${stat.size}:${stat.modified.microsecondsSinceEpoch}',
      isCurrent: current, close: () async {});
  }
}
