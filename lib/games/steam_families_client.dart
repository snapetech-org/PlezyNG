import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../services/plezy_server.dart';
import '../utils/platform_http_client_stub.dart'
    if (dart.library.io) '../utils/platform_http_client_io.dart'
    as platform;

final _familySecret = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _familyId = RegExp(r'^[1-9][0-9]{0,19}$');
final _steamId = RegExp(r'^[0-9]{17}$');

class SteamFamiliesUnavailable implements Exception {
  const SteamFamiliesUnavailable({this.refreshRequired = false});
  final bool refreshRequired;
  @override
  String toString() => 'Steam Families unavailable';
}

String _id(Object? value, {bool steam = false}) {
  if (value is! String || !(steam ? _steamId : _familyId).hasMatch(value)) {
    throw const SteamFamiliesUnavailable();
  }
  return value;
}

int _count(Object? value, int maximum) {
  if (value is! int || value < 0 || value > maximum) throw const SteamFamiliesUnavailable();
  return value;
}

class SteamFamilyMember {
  const SteamFamilyMember(this.steamId, this.role);
  final String steamId;
  final int role;
  factory SteamFamilyMember.parse(Map<String, dynamic> value) {
    final role = _count(value['role'], 2);
    if (role == 0) throw const SteamFamiliesUnavailable();
    return SteamFamilyMember(_id(value['steamid'], steam: true), role);
  }
}

class SteamFamilyInvite {
  const SteamFamilyInvite(this.familyId, this.inviter, this.role, this.awaiting);
  final String familyId, inviter;
  final int role;
  final bool awaiting;
  factory SteamFamilyInvite.parse(Map<String, dynamic> value) {
    final role = _count(value['role'], 2);
    if (role == 0 || value['awaiting_2fa'] is! bool) throw const SteamFamiliesUnavailable();
    return SteamFamilyInvite(
      _id(value['family_groupid']),
      _id(value['inviter_steamid'], steam: true),
      role,
      value['awaiting_2fa'] == true,
    );
  }
}

List<T> _list<T>(Object? value, int maximum, T Function(Map<String, dynamic>) parse) {
  if (value == null) return [];
  if (value is! List || value.length > maximum) throw const SteamFamiliesUnavailable();
  return value
      .map((entry) {
        if (entry is! Map<String, dynamic>) throw const SteamFamiliesUnavailable();
        return parse(entry);
      })
      .toList(growable: false);
}

class SteamFamilyState {
  SteamFamilyState(Map<String, dynamic> value) {
    final group = value['family_group'];
    if (group is! Map<String, dynamic> || value['is_not_member_of_any_group'] is! bool) {
      throw const SteamFamiliesUnavailable();
    }
    final absent = value['is_not_member_of_any_group'] == true;
    familyId = absent ? null : _id(value['family_groupid']);
    name = group['name'] is String ? group['name'] as String : '';
    if (name.length > 256) throw const SteamFamiliesUnavailable();
    role = _count(value['role'], 2);
    cooldownSeconds = _count(value['cooldown_seconds_remaining'], 0xffffffff);
    freeSpots = _count(group['free_spots'], 6);
    canRestore = absent && value['can_undelete_last_joined_family'] == true;
    members = _list(group['members'], 6, SteamFamilyMember.parse);
    pending = _list(group['pending_invites'], 6, SteamFamilyMember.parse);
    invitations = _list(value['pending_group_invites'], 32, SteamFamilyInvite.parse);
  }
  late final String? familyId;
  late final String name;
  late final int role, cooldownSeconds, freeSpots;
  late final bool canRestore;
  late final List<SteamFamilyMember> members, pending;
  late final List<SteamFamilyInvite> invitations;
  bool get adult => familyId != null && role == 1;
}

class SteamFamilyChange {
  const SteamFamilyChange(this.action, {this.name, this.steamId, this.familyId, this.role, this.appId});
  final String action;
  final String? name, steamId, familyId;
  final int? role, appId;
  Map<String, dynamic> toJson() => {
    'action': action,
    if (name != null) 'name': name,
    if (steamId != null) 'steamId': steamId,
    if (familyId != null) 'familyId': familyId,
    if (role != null) 'role': role,
    if (appId != null) 'appId': appId,
  };
}

class SteamFamilyReview {
  const SteamFamilyReview(this.ticket, this.change, this.state);
  final String ticket;
  final SteamFamilyChange change;
  final SteamFamilyState state;
}

/// Holds only a Plezy session capability. Upstream Steam credentials never
/// leave the server. No disk persistence, redirects or automatic mutation retry.
class SteamFamiliesClient {
  SteamFamiliesClient({required this.catalog, required this.steamId, http.Client? httpClient, Uri? baseUri})
    : _http = httpClient ?? platform.createPlatformClient(),
      _base = baseUri ?? Uri.parse(plezyServerBaseUrl);
  final String catalog, steamId;
  final http.Client _http;
  final Uri _base;
  final _aborts = <Completer<void>>{};
  String? _session;
  Uri? challenge;
  DateTime? expires;
  bool authorized = false, _disposed = false;
  Future<void>? _retirement;

  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> body, {
    bool retiring = false,
    bool optional = false,
  }) async {
    if ((!retiring && _disposed) ||
        !_familySecret.hasMatch(catalog) ||
        !_steamId.hasMatch(steamId) ||
        _base.scheme != 'https' ||
        _base.host.isEmpty ||
        _base.userInfo.isNotEmpty ||
        _base.hasQuery ||
        _base.hasFragment) {
      throw const SteamFamiliesUnavailable();
    }
    final abort = Completer<void>();
    void stop() {
      if (!abort.isCompleted) abort.complete();
    }

    final request =
        http.AbortableRequest(
            'POST',
            _base.replace(path: '${_base.path.replaceFirst(RegExp(r'/$'), '')}/auth/steam/families'),
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $catalog'
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode({...body, if (_session != null) 'session': _session});
    if (!retiring) _aborts.add(abort);
    try {
      return await (() async {
        final response = await _http.send(request);
        if (optional && (response.statusCode == 404 || response.statusCode == 501 || response.statusCode == 503)) {
          return <String, dynamic>{'available': false};
        }
        if (response.statusCode != 200 && response.statusCode != 204) {
          throw SteamFamiliesUnavailable(refreshRequired: response.statusCode == 409);
        }
        if ((response.contentLength ?? 0) > 128 * 1024) throw const SteamFamiliesUnavailable();
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (chunk.length > 128 * 1024 - bytes.length) throw const SteamFamiliesUnavailable();
          bytes.add(chunk);
        }
        if (!retiring && _disposed) throw const SteamFamiliesUnavailable();
        if (response.statusCode == 204) return <String, dynamic>{};
        final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (decoded is! Map<String, dynamic>) throw const SteamFamiliesUnavailable();
        return decoded;
      })().timeout(
        retiring ? const Duration(seconds: 5) : const Duration(seconds: 35),
        onTimeout: () {
          stop();
          throw const SteamFamiliesUnavailable(refreshRequired: true);
        },
      );
    } on SteamFamiliesUnavailable {
      rethrow;
    } catch (_) {
      throw const SteamFamiliesUnavailable(refreshRequired: true);
    } finally {
      _aborts.remove(abort);
      stop();
    }
  }

  Future<bool> available() async =>
      (await _request({'operation': 'capabilities'}, optional: true))['available'] == true;
  void _authorization(Map<String, dynamic> body) {
    if (body['steamId'] != steamId || body['pollSeconds'] != 5) throw const SteamFamiliesUnavailable();
    expires = DateTime.fromMillisecondsSinceEpoch(_count(body['expires'], 253402300799) * 1000, isUtc: true);
    final raw = body['challenge'];
    if (raw is! String) throw const SteamFamiliesUnavailable();
    if (raw.isEmpty && body['authorized'] == true) {
      challenge = null;
      authorized = true;
      return;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.authority != 's.team' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length != 3 ||
        uri.pathSegments[0] != 'q' ||
        !_familyId.hasMatch(uri.pathSegments[1]) ||
        !_familyId.hasMatch(uri.pathSegments[2])) {
      throw const SteamFamiliesUnavailable();
    }
    challenge = uri;
  }

  Future<void> start() async {
    if (_session != null) throw const SteamFamiliesUnavailable();
    final body = await _request({'operation': 'start', 'consent': true});
    final session = body['session'];
    if (session is! String || !_familySecret.hasMatch(session)) throw const SteamFamiliesUnavailable();
    _session = session;
    _authorization(body);
  }

  Future<bool> poll() async {
    if (_session == null || authorized) throw const SteamFamiliesUnavailable();
    if (expires == null || !DateTime.now().isBefore(expires!)) throw const SteamFamiliesUnavailable();
    _authorization(await _request({'operation': 'poll'}));
    return authorized;
  }

  Future<SteamFamilyState> state() async {
    if (!authorized) throw const SteamFamiliesUnavailable();
    final body = await _request({'operation': 'state'});
    if (body['steamId'] != steamId || body['state'] is! Map<String, dynamic>) throw const SteamFamiliesUnavailable();
    return SteamFamilyState(body['state'] as Map<String, dynamic>);
  }

  Future<SteamFamilyReview> review(SteamFamilyChange change) async {
    if (!authorized) throw const SteamFamiliesUnavailable();
    final body = await _request({'operation': 'review', 'change': change.toJson()});
    final ticket = body['review'], returned = body['change'], state = body['state'];
    final expected = change.toJson();
    if (ticket is! String ||
        !_familySecret.hasMatch(ticket) ||
        state is! Map<String, dynamic> ||
        returned is! Map<String, dynamic> ||
        returned.length != expected.length ||
        expected.entries.any((e) => returned[e.key] != e.value)) {
      throw const SteamFamiliesUnavailable();
    }
    return SteamFamilyReview(ticket, change, SteamFamilyState(state));
  }

  Future<bool> commit(SteamFamilyReview review) async {
    if (!authorized || !_familySecret.hasMatch(review.ticket)) throw const SteamFamiliesUnavailable();
    final body = await _request({'operation': 'commit', 'review': review.ticket});
    if (body['submitted'] != true || body['steamConfirmationRequired'] is! bool) {
      throw const SteamFamiliesUnavailable(refreshRequired: true);
    }
    return body['steamConfirmationRequired'] == true;
  }

  Future<void> retire() => _retirement ??= _retire();
  Future<void> _retire() async {
    _disposed = true;
    authorized = false;
    challenge = null;
    for (final abort in _aborts.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    try {
      if (_session != null) await _request({'operation': 'close'}, retiring: true);
    } catch (_) {
      /* Bounded server expiry remains in force. */
    } finally {
      _session = null;
      _http.close();
    }
  }
}
