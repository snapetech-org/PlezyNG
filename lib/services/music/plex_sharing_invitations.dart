import '../../models/plex/plex_source_invitation.dart';
import '../plex_auth_service.dart';
import '../plex_client.dart';
import 'music_account_scope.dart';

/// Account-qualified decisions. Pending sources never enter playback.
class PlexSharingInvitations {
  PlexSharingInvitations({required this.client, required this.auth, required this.isCurrent})
    : _authentication = client.authenticationSessionId,
      _account = musicAccountScope(client),
      _token = client.plexAccountToken;
  final PlexClient client;
  final PlexAuthService auth;
  final bool Function() isCurrent;
  final Object _authentication;
  final String _account;
  final String? _token;
  List<PlexSourceInvitation>? _entries;
  int _generation = 0;
  bool _busy = false;
  bool get current =>
      isCurrent() &&
      !client.isOfflineMode &&
      _token?.isNotEmpty == true &&
      _token == client.plexAccountToken &&
      identical(_authentication, client.authenticationSessionId) &&
      _account == musicAccountScope(client);

  Future<List<PlexSourceInvitation>> refresh() async {
    if (!current || _busy) throw StateError('Invitation catalog unavailable');
    final generation = ++_generation;
    _entries = null;
    final rows = await auth.getPendingSourceInvitations(
      authToken: _token!,
      isCurrent: () => current && generation == _generation,
    );
    if (!current || generation != _generation) throw StateError('Invitation catalog changed');
    return _entries = rows;
  }

  Future<void> respond(PlexSourceInvitation invitation, {required bool accept}) async {
    if (!current || _busy || _entries?.any((entry) => identical(entry, invitation)) != true) {
      throw StateError('Invitation decision expired');
    }
    _busy = true;
    _entries = null;
    final generation = ++_generation;
    try {
      await auth.respondToSourceInvitation(
        authToken: _token!,
        invitation: invitation,
        accept: accept,
        isCurrent: () => current && generation == _generation,
      );
    } finally {
      _busy = false;
    }
  }
}
