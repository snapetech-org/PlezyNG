import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/standalone_video_metadata_client.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

void main() {
  test('metadata lookup sends only the cleaned filename query and selected catalog ID', () async {
    final requests = <http.Request>[];
    final client = StandaloneVideoMetadataClient(
      transport: SourceTransport(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('[]', 200);
        }),
      ),
    );
    addTearDown(client.close);
    const entry = SourceEntry(
      sourceId: 'private-source-id',
      id: 'private-entry-id',
      title: 'PRIVATE_ENTRY_TITLE',
      kind: SourceItemKind.video,
      files: [
        PublicationFile(
          id: 'private-file-id',
          name: '/private/account/PRIVATE_SOURCE_TOKEN/Only.Me.2021.mkv',
          mimeType: 'video/x-matroska',
        ),
      ],
      identifiers: {'tmdb': '12345', 'secret': 'PRIVATE_NFO_CANARY'},
    );

    expect(await client.identify(entry), isNull);
    expect(requests, hasLength(2));
    expect(requests.first.url.path, '/search/tmdb/12345');
    expect(requests.last.url.path, '/search/movie,show');
    expect(requests.last.url.queryParameters['query'], 'Only Me');
    expect(requests.last.url.queryParameters['year'], '2021');
    expect(requests.every((request) => request.method == 'GET' && request.body.isEmpty), isTrue);
    final outbound = requests.map((request) => '${request.url} ${request.headers}').join('\n');
    for (final privateValue in [
      '/private/account',
      'PRIVATE_SOURCE_TOKEN',
      'PRIVATE_ENTRY_TITLE',
      'private-source-id',
      'private-entry-id',
      'private-file-id',
      'PRIVATE_NFO_CANARY',
    ]) {
      expect(outbound, isNot(contains(privateValue)));
    }
  });
}
