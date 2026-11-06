import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/trackers/device_code.dart';
import 'package:plezy/services/trackers/oauth_proxy_client.dart';
import 'package:plezy/services/trackers/trakt/trakt_auth_service.dart';
import 'package:plezy/services/trackers/trakt/trakt_constants.dart';

void main() {
  test('browser authorization uses owned relay PKCE and returns refreshable session', () async {
    final requests = <http.Request>[];
    final service = TraktBrowserAuthService(
      proxy: OAuthProxyClient(
        relayBaseUrl: 'https://relay.example',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/auth/start') {
            expect(json.decode(request.body), {'service': 'trakt'});
            return http.Response(
              json.encode({
                'session': 'poll-capability',
                'url': 'https://relay.example/auth/trakt?state=browser-state',
              }),
              200,
            );
          }
          expect(request.url.path, '/auth/result');
          expect(request.url.queryParameters['session'], 'poll-capability');
          return http.Response(
            json.encode({'accessToken': 'access', 'refreshToken': 'refresh', 'expiresIn': 3600}),
            200,
          );
        }),
      ),
    );
    OAuthProxyStart? displayed;
    final result = await service.authorize(onCodeReady: (start) => displayed = start);
    expect(displayed?.url, startsWith('https://relay.example/auth/trakt'));
    expect(result?.accessToken, 'access');
    expect(result?.refreshToken, 'refresh');
    expect(requests, hasLength(2));
    expect(requests.every((request) => !request.body.contains('client_secret')), isTrue);
    service.dispose();
  });

  test('device authorization identifies the public client without a secret', () async {
    http.Request? captured;
    final service = TraktAuthService(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          json.encode({
            'device_code': 'device-code',
            'user_code': 'USER-CODE',
            'verification_url': 'https://trakt.tv/activate',
            'expires_in': 600,
            'interval': 5,
          }),
          200,
        );
      }),
    );

    final code = await service.createDeviceCode();

    expect(code.deviceCode, 'device-code');
    expect(captured?.url.path, '/oauth/device/code');
    expect(json.decode(captured!.body), {'client_id': TraktConstants.clientId});
    service.dispose();
  });

  test('device-code polling does not send a client secret', () async {
    http.Request? captured;
    final service = TraktAuthService(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('authorization pending', 400);
      }),
    );

    final result = await service.probe(
      const DeviceCode(
        deviceCode: 'device-code',
        userCode: 'USER-CODE',
        verificationUrl: 'https://trakt.tv/activate',
        expiresIn: 600,
        interval: 5,
      ),
    );

    expect(result, isA<DevicePollPending>());
    expect(captured?.url.path, '/oauth/device/token');
    expect(json.decode(captured!.body), {'code': 'device-code', 'client_id': TraktConstants.clientId});
    service.dispose();
  });
}
