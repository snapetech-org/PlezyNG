import '../../media/media_item.dart';

/// Server-authored stations retain their original names and opaque local keys.
/// Only the client that issued a row may open it; this is not a stream URL.
class ServerMusicRadio {
  const ServerMusicRadio({required this.serverId, required this.libraryId, required this.key, required this.title});
  final String serverId, libraryId, key, title;
}

abstract interface class ServerMusicRadioClient {
  Future<List<ServerMusicRadio>> serverMusicRadios(String libraryId);
  bool serverMusicRadioCurrent(ServerMusicRadio radio);
  Future<List<MediaItem>> serverMusicRadioTracks(ServerMusicRadio radio, {int limit = 100});
}

/// Refuse credentials, remote routes and keys outside the requested library.
/// Metadata stations are authorized by their containing library hub.
bool validServerMusicRadioKey(String key, String libraryId) {
  if (!key.startsWith('/') || key.length > 4096 || key.contains(r'\') || key.codeUnits.any((c) => c < 32 || c == 127)) {
    return false;
  }
  final uri = Uri.tryParse(key);
  if (uri == null || uri.hasScheme || uri.hasAuthority || uri.hasFragment) return false;
  final parts = uri.pathSegments;
  if (parts.length < 4 ||
      parts.first != 'library' ||
      !const {'sections', 'metadata'}.contains(parts[1]) ||
      parts[2].isEmpty ||
      !const {'station', 'stations'}.contains(parts[3]) ||
      parts.any(
        (part) =>
            part == '.' ||
            part == '..' ||
            part.contains('/') ||
            part.contains(r'\') ||
            part.codeUnits.any((c) => c < 32 || c == 127),
      ) ||
      RegExp(r'(^|/)\.{1,2}(/|$)').hasMatch(key.split('?').first) ||
      parts[1] == 'sections' && parts[2] != libraryId) {
    return false;
  }
  for (final entry in uri.queryParametersAll.entries) {
    if (entry.key.toLowerCase() != 'type' || entry.value.length != 1 || entry.value.single != '10') return false;
  }
  return true;
}
