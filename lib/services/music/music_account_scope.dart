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
  final token = client.config.token;
  final owner = account == null || account.isEmpty ? 'direct' : 'plex:$account';
  // A Plex Home connection can bind several users under one account ID. The
  // active server credential distinguishes them without persisting the token.
  if (token == null) return '$server|$owner:anonymous';
  return '$server|$owner:${sha256.convert(utf8.encode(token))}';
}
