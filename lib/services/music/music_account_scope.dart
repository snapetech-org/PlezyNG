import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../media/media_server_client.dart';
import '../plex_client.dart';
import '../jellyfin_client.dart';

abstract interface class MusicHistoryAccountClient {
  String? get musicHistoryAccountIdentity;
}

String? musicHistoryAccountScope(MediaServerClient client) {
  String? identity;
  if (client is MusicHistoryAccountClient) {
    identity = (client as MusicHistoryAccountClient).musicHistoryAccountIdentity;
  } else if (client is PlexClient) {
    final account = client.plexAccountId, user = client.plexMusicUserIdentifier;
    if (account == null || account.isEmpty || user == null || user.isEmpty) return null;
    identity = jsonEncode(['plex', client.serverId.value, account, user]);
  } else if (client is JellyfinClient) {
    final connection = client.connection;
    if (connection.userId.isEmpty) return null;
    identity = jsonEncode([client.backend.name, connection.serverMachineId, connection.userId]);
  }
  if (identity == null || identity.isEmpty) return null;
  return sha256.convert(utf8.encode(identity)).toString();
}

/// Stable, credential-free identity for a music user's pending writes and
/// generated downloads. A server alone can host several distinct accounts.
String musicAccountScope(MediaServerClient client) {
  final server = client.cacheServerId;
  if (client is! PlexClient) return server;
  final account = client.plexAccountId;
  final token = client.config.token;
  final owner = account == null || account.isEmpty ? 'direct' : 'plex:$account';
  final user = client.plexMusicUserIdentifier;
  if (account != null && account.isNotEmpty && user != null && user.isNotEmpty) {
    return '$server|$owner:user:${sha256.convert(utf8.encode(user))}';
  }
  // A Plex Home connection can bind several users under one account ID. The
  // active server credential distinguishes them without persisting the token.
  if (token == null) return '$server|$owner:anonymous';
  return '$server|$owner:${sha256.convert(utf8.encode(token))}';
}
