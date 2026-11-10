import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../media/media_server_client.dart';
import '../plex_client.dart';

/// Stable, credential-free identity for a music user's pending writes and
/// generated downloads. A server alone can host several distinct accounts.
String musicAccountScope(MediaServerClient client) {
  final server = client.cacheServerId;
  if (client is! PlexClient) return server;
  final account = client.plexAccountId;
  if (account != null && account.isNotEmpty) return '$server|plex:$account';
  final token = client.config.token;
  if (token == null) return '$server|plex:anonymous';
  return '$server|direct:${sha256.convert(utf8.encode(token))}';
}
