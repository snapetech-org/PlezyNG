import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../utils/abortable_http_request.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/platform_http_client_stub.dart'
    if (dart.library.io) '../../../utils/platform_http_client_io.dart'
    as platform;
import '../oauth_proxy_client.dart';
import '../oauth_proxy_auth_service.dart';
import '../tracker_constants.dart';
import '../tracker_exceptions.dart';
import '../tracker_session.dart';
import '../../plezy_server.dart';
import 'mal_constants.dart';

/// MyAnimeList authentication.
///
/// The first-party handoff returns only a one-time authorization code. PKCE is
/// generated on this device and the code is exchanged directly with MAL, so
/// the handoff service never receives the verifier or tokens.
class MalAuthService extends OAuthProxyAuthServiceBase {
  /// MAL returns these for a terminally-invalid grant (revoked/expired refresh
  /// token); anything else (5xx, network) is transient and must not log out.
  static const Set<int> _permanentRefreshFailureStatuses = {400, 401, 403};

  final http.Client _http;

  MalAuthService({super.proxy, http.Client? httpClient}) : _http = httpClient ?? platform.createPlatformClient();

  @override
  String get service => 'mal';

  @override
  TrackerSession buildSession(OAuthProxyResult result) =>
      TrackerSession.fromOAuthProxyResult(TrackerService.mal, result);

  @override
  Future<TrackerSession?> authorize({
    required void Function(OAuthProxyStart) onCodeReady,
    bool Function()? shouldCancel,
    Future<void>? onCancel,
  }) async {
    final start = await proxy.start(service);
    onCodeReady(start);
    final result = await proxy.poll(
      start.session,
      codeVerifier: start.codeVerifier,
      shouldCancel: shouldCancel,
      onCancel: onCancel,
    );
    if (result == null) return null;
    final code = result.authorizationCode;
    final verifier = result.codeVerifier;
    if (code == null || verifier == null) {
      throw const OAuthProxyException('MAL authorization handoff returned an invalid result');
    }
    final response = await sendAbortableHttpRequest(
      _http,
      'POST',
      Uri.parse(MalConstants.tokenUrl),
      body: {
        'client_id': MalConstants.clientId,
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': pleazyngMalCallbackUrl,
        'code_verifier': verifier,
      },
      timeout: TrackerConstants.authRequestTimeout,
      operation: 'MAL authorization code exchange',
    );
    if (response.statusCode != 200) {
      appLogger.w('MAL: authorization code exchange failed (HTTP ${response.statusCode})');
      throw TrackerAuthException(
        service: TrackerService.mal,
        message: 'Authorization code exchange failed: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        isPermanent: _permanentRefreshFailureStatuses.contains(response.statusCode),
      );
    }
    return TrackerSession.fromTokenResponse(TrackerService.mal, json.decode(response.body) as Map<String, dynamic>);
  }

  @override
  void dispose() {
    super.dispose();
    _http.close();
  }

  Future<TrackerSession> refresh(TrackerSession current) async {
    final res = await sendAbortableHttpRequest(
      _http,
      'POST',
      Uri.parse(MalConstants.tokenUrl),
      body: {
        'client_id': MalConstants.clientId,
        'grant_type': 'refresh_token',
        'refresh_token': current.requireRefreshToken(TrackerService.mal),
      },
      timeout: TrackerConstants.refreshTimeout,
      operation: 'MAL token refresh',
    );

    if (res.statusCode != 200) {
      appLogger.w('MAL: refresh failed (HTTP ${res.statusCode})');
      throw TrackerAuthException(
        service: TrackerService.mal,
        message: 'Refresh failed: HTTP ${res.statusCode}',
        statusCode: res.statusCode,
        isPermanent: _permanentRefreshFailureStatuses.contains(res.statusCode),
      );
    }
    final fresh = TrackerSession.fromTokenResponse(TrackerService.mal, json.decode(res.body) as Map<String, dynamic>);
    return fresh.copyWith(username: current.username);
  }
}
