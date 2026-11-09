import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/sources/source_transport.dart';

class _PendingClient extends http.BaseClient {
  final response = Completer<http.StreamedResponse>();
  Future<void>? abort;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    abort = (request as http.AbortableRequest).abortTrigger;
    return response.future;
  }
}

void main() {
  test('header timeout aborts transport and cancels an ignored late response', () async {
    final client = _PendingClient();
    final transport = SourceTransport(client: client, requestTimeout: const Duration(milliseconds: 10));
    addTearDown(transport.close);
    await expectLater(transport.send('GET', Uri.parse('https://source.test')), throwsA(isA<TimeoutException>()));
    await client.abort;
    var cancelled = false;
    final body = StreamController<List<int>>(onCancel: () => cancelled = true);
    client.response.complete(http.StreamedResponse(body.stream, 200));
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    await body.close();
  });

  test('cancelled error bodies and unclaimed responses release their streams', () async {
    for (final consume in [true, false]) {
      var cancelled = false;
      final body = StreamController<List<int>>(onCancel: () => cancelled = true);
      final transport = SourceTransport(
        requestTimeout: const Duration(milliseconds: 10),
        client: MockClient.streaming((_, _) async => http.StreamedResponse(body.stream, 503)),
      );
      final response = await transport.send('GET', Uri.parse('https://source.test'));
      if (consume) await response.stream.listen(null).cancel();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(cancelled, isTrue);
      transport.close();
      await body.close();
    }
  });
}
