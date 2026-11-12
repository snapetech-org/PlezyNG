import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/sources/adapters/podcast_rss_source.dart';
import 'package:plezy/sources/podcast_transcript.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

void main() {
  test('private archives paginate, preserve enclosure identity and survive adapter restart', () async {
    final sealed = <String, String>{};
    var serial = 0;
    Future<String> protect(String value) async {
      final key = 'enc:v2:fixture-${serial++}';
      sealed[key] = value;
      return key;
    }

    Future<String?> reveal(String value) async => sealed[value];
    var rootReads = 0;
    SourceTransport transport() => SourceTransport(
      client: MockClient((request) async {
        if (request.url.path == '/feed') {
          rootReads++;
          return http.Response(
            '<rss xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Show</title>'
            '<atom:link rel="prev-archive" href="https://publisher.example/archive?token=private"/>'
            '${List.generate(300, (i) => '<item><guid>new-$i</guid><title>Episode $i</title><enclosure url="https://cdn.example/$i.mp3" type="audio/mpeg" length="100"/></item>').join()}'
            '</channel></rss>',
            200,
          );
        }
        expect(request.url.path, '/archive');
        return http.Response(
          '<rss><channel><title>Show</title><item><guid>old</guid><title>Old</title>'
          '<enclosure url="https://cdn.example/old.mp3?token=secret" type="audio/mpeg" length="100"/>'
          '</item></channel></rss>',
          200,
        );
      }),
    );
    const source = FileSource(
      id: 'feed',
      profileId: 'profile',
      kind: FileSourceKind.podcastRss,
      name: 'Show',
      endpoint: 'https://publisher.example',
    );
    PodcastRssSourceAdapter adapter() => PodcastRssSourceAdapter(
      source,
      transport(),
      () async => {'feedUrl': 'https://publisher.example/feed'},
      protect: protect,
      reveal: reveal,
    );
    final first = adapter();
    final page1 = await first.browse(parent: 'podcast:episodes');
    final page2 = await first.browse(parent: 'podcast:episodes', cursor: page1.next);
    final archive = await first.browse(parent: 'podcast:episodes', cursor: page2.next);
    expect(page1.entries.length, 250);
    expect(page2.entries.length, 50);
    expect(rootReads, 1);
    expect(archive.entries.single.title, 'Old');
    final serialized = jsonEncode(archive.entries.single.toJson());
    expect(serialized, isNot(contains('token=private')));
    expect(serialized, isNot(contains('token=secret')));
    final file = archive.entries.single.files.single;
    first.close();
    final restarted = adapter();
    final restored = PublicationFile.fromJson(file.toJson());
    expect((await restarted.resolve(restored)).uri.queryParameters['token'], 'secret');
    expect((await restarted.hydrate(archive.entries.single)).files.single.fingerprint, file.fingerprint);
    restarted.close();
  });
  test('timed transcript formats retain searchable text and cue timing', () {
    final vtt = PodcastTranscript.parse('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v Speaker>Hello</v>\n', 'text/vtt');
    expect(vtt.cues.single.startMs, 1000);
    expect(vtt.cues.single.text, 'Hello');
    expect(PodcastTranscript.fromJson(vtt.toJson()).cues.single.id, vtt.cues.single.id);
    final json = PodcastTranscript.parse(
      '{"segments":[{"startTime":1,"endTime":2,"speaker":"A","body":"Hello"}]}',
      'application/json',
    );
    expect(json.cues.single.text, 'A: Hello');
    final restoredJson = PodcastTranscript.fromJson(json.toJson());
    expect(restoredJson.cues.single.endMs, 2000);
    expect(restoredJson.cues.single.id, json.cues.single.id);
  });

  test('legacy cached transcript cues receive stable IDs during migration', () {
    final legacy = {
      'text': 'hello',
      'cues': [
        {'start': 1000, 'end': 2000, 'text': 'hello'},
      ],
    };
    final first = PodcastTranscript.fromJson(legacy);
    final second = PodcastTranscript.fromJson(legacy);

    expect(first.cues.single.id, second.cues.single.id);
    expect(PodcastTranscript.fromJson(first.toJson()).cues.single.id, first.cues.single.id);
  });
  test('HTML transcripts remain inert text and long text is not cut to description size', () {
    final body = '<p>${List.filled(10000, 'word').join(' ')}</p><script>execute()</script>';
    final transcript = PodcastTranscript.parse(body, 'text/html');
    expect(transcript.text.length, greaterThan(8000));
    expect(transcript.text, isNot(contains('execute()')));
  });
}
