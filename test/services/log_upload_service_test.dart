import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/log_upload_service.dart';
import 'package:plezy/utils/log_redaction_manager.dart';
import 'package:plezy/utils/media_server_http_client.dart';

void main() {
  tearDown(LogRedactionManager.clearTrackedValues);

  test('reapplies diagnostic redaction at the upload boundary', () async {
    const credential = 'upload-boundary-canary-token';
    LogRedactionManager.registerToken(credential);
    String? uploadedBody;
    final client = MediaServerHttpClient(
      client: MockClient((request) async {
        uploadedBody = request.body;
        return http.Response('{"id":"opaque-capability"}', 200, headers: {'content-type': 'application/json'});
      }),
    );

    final id = await uploadDiagnosticText(
      'Authorization: Bearer $credential',
      client: client,
      serviceBaseUrl: 'https://pleazyng-api.snape.tech',
    );

    expect(id, 'opaque-capability');
    expect(uploadedBody, isNot(contains(credential)));
    expect(uploadedBody, contains('[REDACTED_TOKEN]'));
  });
}
