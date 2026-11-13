import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import 'mal/mal_constants.dart';
import '../../utils/abortable_http_request.dart';
import '../../games/steam_game_activity.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_http_client_stub.dart'
    if (dart.library.io) '../../utils/platform_http_client_io.dart'
    as platform;
import '../plezy_server.dart';
import 'tracker_constants.dart';

/// Client for OAuth handoffs. MAL uses the first-party code-only broker: the
/// app generates and retains its PKCE verifier, then exchanges the code
/// directly with MAL. Other server-exchanged providers require a relay URL
/// explicitly configured by the user.
class OAuthProxyClient {
  /// Base URL of the explicitly configured user-hosted relay.
  static String get baseUrl => plezyServerBaseUrl;

  final http.Client _http;
  final String? _relayBaseUrl;
  String get _baseUrl => _relayBaseUrl == null ? baseUrl : requirePleazyngServiceUrl(_relayBaseUrl);

  OAuthProxyClient({http.Client? httpClient, this._relayBaseUrl})
    : _http = httpClient ?? platform.createPlatformClient();

  void dispose() => _http.close();

  /// POST /auth/start — register a new session. Returns a handle including the
  /// URL to display as a QR code for the phone scan.
  Future<OAuthProxyStart> start(String service) async {
    if (service == 'mal') return _startMalCodeHandoff();
    final res = await sendAbortableHttpRequest(
      _http,
      'POST',
      Uri.parse('$_baseUrl/auth/start'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'service': service}),
      timeout: TrackerConstants.authRequestTimeout,
      operation: 'OAuth proxy start',
    );
    if (res.statusCode != 200) {
      throw OAuthProxyException('OAuth proxy start failed: HTTP ${res.statusCode}');
    }
    final body = json.decode(res.body) as Map<String, dynamic>;
    return OAuthProxyStart(session: body['session'] as String, url: body['url'] as String);
  }

  Future<OAuthProxyStart> _startMalCodeHandoff() async {
    final random = Random.secure();
    final verifier = base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
    final response = await sendAbortableHttpRequest(
      _http,
      'POST',
      Uri.parse('$pleazyngOAuthBrokerBaseUrl/auth/pkce/start'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'service': 'mal'}),
      timeout: TrackerConstants.authRequestTimeout,
      operation: 'MAL authorization handoff start',
    );
    if (response.statusCode != 200) {
      throw OAuthProxyException('MAL authorization handoff failed: HTTP ${response.statusCode}');
    }
    final body = json.decode(response.body) as Map<String, dynamic>;
    final rawUrl = body['url'];
    final session = body['session'];
    if (rawUrl is! String || session is! String || session.isEmpty) {
      throw const OAuthProxyException('MAL authorization handoff returned an invalid response');
    }
    final authorize = Uri.tryParse(rawUrl);
    if (authorize == null ||
        authorize.scheme != 'https' ||
        authorize.host != 'myanimelist.net' ||
        authorize.path != '/v1/oauth2/authorize' ||
        authorize.queryParameters['response_type'] != 'code' ||
        authorize.queryParameters['client_id'] != MalConstants.clientId ||
        authorize.queryParameters['redirect_uri'] != pleazyngMalCallbackUrl ||
        authorize.queryParameters['state'] == null ||
        authorize.queryParameters['state']!.isEmpty ||
        authorize.queryParameters.containsKey('code_challenge') ||
        authorize.queryParameters.containsKey('code_challenge_method')) {
      throw const OAuthProxyException('MAL authorization handoff returned an invalid URL');
    }
    final url = authorize.replace(
      queryParameters: {...authorize.queryParameters, 'code_challenge': verifier, 'code_challenge_method': 'plain'},
    );
    return OAuthProxyStart(session: session, url: url.toString(), codeVerifier: verifier);
  }

  /// Read-only refresh capability issued after verified Steam OpenID. It is
  /// sent in a header, never a URL, and cannot choose a different SteamID.
  Future<OAuthProxyResult> refreshSteamCatalog(String credential) async {
    final response = await sendAbortableHttpRequest(
      _http,
      'POST',
      Uri.parse('$_baseUrl/auth/steam/library'),
      headers: {'Authorization': 'Bearer $credential'},
      timeout: TrackerConstants.authRequestTimeout,
      operation: 'Steam catalog refresh',
    );
    if (response.statusCode == 401 || response.statusCode == 404) throw const SteamCatalogRelinkRequired();
    if (response.statusCode != 200 || response.bodyBytes.length > 2 * 1024 * 1024) {
      throw const OAuthProxyException('Steam catalog refresh unavailable');
    }
    final body = json.decode(response.body) as Map<String, dynamic>;
    final rawGames = body['steamGames'];
    return OAuthProxyResult(
      accessToken: '',
      steamId: body['steamId'] as String?,
      steamLibraryAvailable: body['steamLibraryAvailable'] == true,
      steamCatalogTruncated: body['steamCatalogTruncated'] == true,
      steamGames: rawGames is List
          ? rawGames.take(2000).whereType<Map>().map((g) => Map<String, dynamic>.from(g)).toList()
          : const [],
    );
  }

  Future<void> revokeSteamCatalog(String credential) async {
    await sendAbortableHttpRequest(
      _http,
      'DELETE',
      Uri.parse('$_baseUrl/auth/steam/library'),
      headers: {'Authorization': 'Bearer $credential'},
      timeout: const Duration(seconds: 5),
      operation: 'Steam catalog unlink',
    );
  }

  Future<SteamGameActivity> steamGameActivity(
    String credential, {
    required int appId,
    required String steamId,
    bool includeFriends = false,
  }) async {
    if (appId < 1 || appId > 0xffffffff) throw const OAuthProxyException('Invalid Steam game');
    final response = await sendAbortableHttpRequest(
      _http,
      'POST',
      Uri.parse('$_baseUrl/auth/steam/game'),
      headers: {'Authorization': 'Bearer $credential', 'Content-Type': 'application/json'},
      body: json.encode({'appId': appId, 'includeFriends': includeFriends}),
      timeout: TrackerConstants.authRequestTimeout,
      operation: 'Steam game activity',
    );
    if (response.statusCode == 401 || response.statusCode == 404) throw const SteamCatalogRelinkRequired();
    if (response.statusCode != 200 || response.bodyBytes.length > 2 * 1024 * 1024) {
      throw const OAuthProxyException('Steam activity unavailable');
    }
    return SteamGameActivity.fromJson(
      json.decode(response.body) as Map<String, dynamic>,
      appId: appId,
      steamId: steamId,
    );
  }

  /// Long-poll the user relay with its legacy query capability, or send the
  /// first-party MAL broker capability in Authorization to keep it out of URLs.
  ///
  /// Returns null if [shouldCancel] flips true between iterations or [onCancel]
  /// completes mid-request. Throws [OAuthProxyException] on unrecoverable errors
  /// (session gone, upstream failure). The server holds each request for up to
  /// 50 s; 204 responses are retried transparently, and 429 responses are
  /// retried until the session's own lifetime expires.
  Future<OAuthProxyResult?> poll(
    String session, {
    String? codeVerifier,
    bool Function()? shouldCancel,
    Future<void>? onCancel,
  }) async {
    final pollBaseUrl = codeVerifier == null ? _baseUrl : pleazyngOAuthBrokerBaseUrl;
    final pollUri = Uri.parse('$pollBaseUrl/auth/result');
    final uri = codeVerifier == null
        ? pollUri.replace(queryParameters: {...pollUri.queryParameters, 'session': session})
        : pollUri;
    final deadline = clock.now().add(TrackerConstants.oauthProxySessionTimeout);
    final cancelSentinel = Object();
    // Subscribe to onCancel once; reusing this derived future avoids
    // accumulating a fresh listener per loop iteration.
    final cancelFuture = onCancel?.then((_) => cancelSentinel);
    while (true) {
      if (shouldCancel?.call() ?? false) return null;

      final Object? raced;
      try {
        raced = await Future.any<Object?>([
          sendAbortableHttpRequest(
            _http,
            'GET',
            uri,
            headers: codeVerifier == null ? null : {'Authorization': 'Bearer $session'},
            timeout: TrackerConstants.oauthProxyPollTimeout,
            abortTrigger: onCancel,
            operation: 'OAuth proxy poll',
          ),
          ?cancelFuture,
        ]);
      } on TimeoutException {
        continue;
      } catch (e) {
        appLogger.d('oauth proxy: poll transient error', error: e);
        await Future<void>.delayed(TrackerConstants.oauthProxyRetryDelay);
        continue;
      }

      if (identical(raced, cancelSentinel)) return null;
      final res = raced as http.Response;

      if (res.statusCode == 204) continue; // server-side timeout, retry
      if (res.statusCode == 410) {
        throw const OAuthProxyException('Session expired or already used');
      }
      if (res.statusCode == 429 && clock.now().isBefore(deadline)) {
        // Rate limiting is transient while the relay session is alive: honor
        // the server's suggested pause when present, otherwise resume on the
        // normal retry tick. Past the deadline the 429 falls through below.
        final retryAfter = int.tryParse(res.headers['retry-after'] ?? '');
        final delay = retryAfter != null && retryAfter > 0
            ? Duration(seconds: retryAfter)
            : TrackerConstants.oauthProxyRetryDelay;
        await Future.any<Object?>([Future<void>.delayed(delay), ?cancelFuture]);
        continue;
      }
      if (res.statusCode != 200) {
        throw OAuthProxyException('OAuth proxy poll failed: HTTP ${res.statusCode}');
      }
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (body['error'] != null) {
        final err = body['error'];
        if (err == 'access_denied') return null; // user cancelled in browser
        final category = switch (err) {
          'missing_code' => 'missing authorization code',
          'exchange_failed' => 'token exchange failed',
          _ => 'upstream authorization failed',
        };
        throw OAuthProxyException('OAuth proxy failed: $category');
      }
      if (codeVerifier != null) {
        final code = body['authorizationCode'];
        if (code is! String || code.isEmpty || code.length > 4096) {
          throw const OAuthProxyException('OAuth broker returned an invalid authorization code');
        }
        return OAuthProxyResult(authorizationCode: code, codeVerifier: codeVerifier);
      }
      final rawGames = body['steamGames'];
      final steamGames = rawGames is List
          ? rawGames.whereType<Map>().take(2000).map((row) => Map<String, dynamic>.from(row)).toList(growable: false)
          : const <Map<String, dynamic>>[];
      final accessToken = body['accessToken'];
      final steamId = body['steamId'] as String?;
      if (accessToken is! String && steamId == null) {
        throw const OAuthProxyException('OAuth proxy returned an invalid result');
      }
      return OAuthProxyResult(
        accessToken: accessToken is String ? accessToken : '',
        refreshToken: body['refreshToken'] as String?,
        expiresIn: (body['expiresIn'] as num?)?.toInt(),
        steamId: steamId,
        steamCloudToken:
            body['steamCloudToken'] is String &&
                RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(body['steamCloudToken'] as String)
            ? body['steamCloudToken'] as String
            : null,
        steamCatalogToken:
            body['steamCatalogToken'] is String &&
                RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(body['steamCatalogToken'] as String)
            ? body['steamCatalogToken'] as String
            : null,
        steamLibraryAvailable: body['steamLibraryAvailable'] == true,
        steamCatalogTruncated: body['steamCatalogTruncated'] == true,
        steamGames: steamGames,
      );
    }
  }
}

class OAuthProxyStart {
  /// Opaque session token. Include in subsequent polls.
  final String session;

  /// URL to render as a QR code and open in a browser. The phone scans it,
  /// triggering the upstream OAuth flow.
  final String url;

  /// In-memory only. MAL's first-party code broker never receives this value.
  final String? codeVerifier;

  const OAuthProxyStart({required this.session, required this.url, this.codeVerifier});
}

class OAuthProxyResult {
  final String accessToken;
  final String? refreshToken;
  final int? expiresIn;
  final String? steamId;
  final String? steamCatalogToken;
  final String? steamCloudToken;
  final bool steamLibraryAvailable;
  final bool steamCatalogTruncated;
  final List<Map<String, dynamic>> steamGames;
  final String? authorizationCode;
  final String? codeVerifier;

  const OAuthProxyResult({
    this.accessToken = '',
    this.refreshToken,
    this.expiresIn,
    this.steamId,
    this.steamCatalogToken,
    this.steamCloudToken,
    this.steamLibraryAvailable = false,
    this.steamCatalogTruncated = false,
    this.steamGames = const [],
    this.authorizationCode,
    this.codeVerifier,
  });
}

class OAuthProxyException implements Exception {
  final String message;
  const OAuthProxyException(this.message);
  @override
  String toString() => 'OAuthProxyException: $message';
}

class SteamCatalogRelinkRequired implements Exception {
  const SteamCatalogRelinkRequired();
}
