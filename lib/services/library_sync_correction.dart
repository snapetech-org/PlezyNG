import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../media/media_item.dart';
import '../media/media_source_info.dart';
import '../media/media_version.dart';
import '../mpv/mpv.dart';
import 'scoped_player_prefs.dart';
import 'settings_service.dart';

/// Metadata identity for the file actually opened, never a signed playback URL
/// or an episode-series key. This is deliberately not a media-content hash.
class LibrarySyncSource {
  LibrarySyncSource._(this.digest, this.audioStreamId, this.transcoding);
  final String digest;
  final int? audioStreamId;
  final bool transcoding;

  static LibrarySyncSource? from({required MediaItem item, required MediaSourceInfo? info,
      required List<MediaVersion> versions, required int mediaIndex,
      required bool transcoding, int? audioStreamId}) {
    if (item.serverId == null || item.serverId!.isEmpty || item.id.isEmpty || info == null ||
        mediaIndex < 0 || mediaIndex >= versions.length) return null;
    final version = versions[mediaIndex];
    if (version.id.isEmpty || version.parts.isEmpty) return null;
    final partIndex = info.partIndex ?? (version.parts.length == 1 ? 0 : -1);
    if (partIndex < 0 || partIndex >= version.parts.length) return null;
    final part = version.parts[partIndex];
    if (part.id.isEmpty || (info.partId != null && part.id != '${info.partId}') ||
        (info.mediaSourceId != null && info.mediaSourceId != version.id)) return null;
    if (transcoding && audioStreamId == null) return null;
    return LibrarySyncSource._(digestOf([
      'library-file-v1', item.serverId, item.id, version.id, part.id, partIndex,
      part.file, part.sizeBytes, part.durationMs, part.container, version.name,
      version.width, version.height, version.videoCodec,
      // Source-catalog changes invalidate a correction even if a server reuses
      // a native stream number for a replacement audio/subtitle track.
      [for (final row in info.audioTracks) [row.id, row.index, row.codec,
        row.languageCode, row.title, row.channels, row.external]],
      [for (final row in info.subtitleTracks) [row.id, row.index, row.codec,
        row.languageCode, row.title, row.forced, row.external,
        row.key == null ? null : transportIdentity(row.key!)]],
    ]), audioStreamId, transcoding);
  }

  static String digestOf(Object? value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

  /// Tokens, query strings, fragments and URL user-info never enter a key.
  /// A remote sidecar replaced in-place without changed catalog metadata cannot
  /// be detected from this representation identity alone.
  static Object transportIdentity(String value) {
    final uri = Uri.tryParse(value);
    return uri == null ? value : [uri.scheme, uri.host, uri.port, uri.path];
  }

  static Object? audio(AudioTrack? value) => value == null || const ['auto', 'no'].contains(value.id)
      ? null : [value.id, value.language, value.title, value.codec, value.channels];
  static Object? subtitle(SubtitleTrack? value) => value == null || const ['auto', 'no'].contains(value.id)
      ? null : [value.id.startsWith('external:') ? 'external' : value.id,
        value.language, value.title, value.codec, value.isForced, value.isExternal,
        value.isContainer, value.uri == null ? null : transportIdentity(value.uri!)];

  String selectionStamp(Player player) => digestOf([
    player.playerType, audio(player.state.track.audio), subtitle(player.state.track.subtitle),
    subtitle(player.state.track.secondarySubtitle),
    [for (final row in player.state.tracks.audio) audio(row)],
    [for (final row in player.state.tracks.subtitle) subtitle(row)],
  ]);

  String? key(Player player, String property) {
    final selectedAudio = audio(player.state.track.audio);
    if (selectedAudio == null) return null;
    final selectedSubtitle = property == 'secondary-sub-delay'
        ? subtitle(player.state.track.secondarySubtitle) : subtitle(player.state.track.subtitle);
    if (property != 'audio-delay' && selectedSubtitle == null) return null;
    return digestOf(['library-correction-v1', digest, player.playerType, transcoding,
      transcoding ? audioStreamId : null, selectedAudio, property,
      // The complete audio catalog prevents reused/renumbered native IDs from
      // silently matching another stream. Subtitle lanes remain independent.
      [for (final row in player.state.tracks.audio) audio(row)],
      if (property != 'audio-delay') selectedSubtitle,
      if (property != 'audio-delay') [for (final row in player.state.tracks.subtitle) subtitle(row)],
    ]);
  }
}

class LibrarySyncValue {
  const LibrarySyncValue({required this.delayMs, this.rate = 1});
  final int delayMs;
  final double rate;
  static LibrarySyncValue? decode(Object? value) {
    if (value is! Map || value['delayMs'] is! int || value['rate'] is! num) return null;
    final delay = value['delayMs'] as int, rate = (value['rate'] as num).toDouble();
    if (delay < ScopedPlayerPrefs.minimumSyncOffsetMs || delay > ScopedPlayerPrefs.maximumSyncOffsetMs ||
        !rate.isFinite || rate < ScopedPlayerPrefs.minimumSubtitleSyncRate ||
        rate > ScopedPlayerPrefs.maximumSubtitleSyncRate) return null;
    return LibrarySyncValue(delayMs: delay, rate: rate);
  }
}

/// Explicit exact-copy overrides. Existing global/library/title preferences
/// remain intact and are the fallback when there is no matching record.
abstract final class LibrarySyncCorrections {
  static Future<void> _writes = Future.value();
  static StringPref _pref(String profile) => StringPref(
      'library_sync_corrections_v1_${LibrarySyncSource.digestOf(profile)}');
  static Map<String, dynamic> _read(String profile) {
    try {
      final text = SettingsService.instance.read(_pref(profile));
      if (utf8.encode(text).length > 262144) return {};
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic> || value['schema'] != 1 || value['values'] is! Map ||
          (value['values'] as Map).length > 300) return {};
      return Map<String, dynamic>.from(value['values'] as Map);
    } catch (_) { return {}; }
  }
  static LibrarySyncValue? read(String profile, String key) => LibrarySyncValue.decode(_read(profile)[key]);

  static Future<void> write(String profile, String key, LibrarySyncValue? value,
      {required void Function() checkCurrent}) {
    final next = _writes.then((_) async {
      checkCurrent();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key) || (value != null &&
          LibrarySyncValue.decode({'delayMs': value.delayMs, 'rate': value.rate}) == null)) {
        throw const FormatException('Invalid saved playback timing.');
      }
      final values = _read(profile);
      if (value == null) { values.remove(key); }
      else { values[key] = {'delayMs': value.delayMs, 'rate': value.rate,
        'savedAtMs': DateTime.now().millisecondsSinceEpoch}; }
      final entries = values.entries.toList()..sort((a, b) {
        int time(Object? v) => v is Map && v['savedAtMs'] is int ? v['savedAtMs'] as int : 0;
        return time(b.value).compareTo(time(a.value));
      });
      final text = jsonEncode({'schema': 1, 'values': Map.fromEntries(entries.take(300))});
      if (utf8.encode(text).length > 262144) throw StateError('Saved timing exceeds its storage limit.');
      await SettingsService.instance.write(_pref(profile), text, checkCurrent: checkCurrent);
      checkCurrent();
    });
    _writes = next.catchError((Object _) {});
    return next;
  }
}
