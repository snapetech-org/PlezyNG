import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/music/music_prompt_playlist.dart';
import '../../test_helpers/music_experience_fakes.dart';

void main() {
  MusicPromptProvider provider(http.Client client) => MusicPromptProvider(
    endpoint: Uri.parse('https://provider.example/v1/chat/completions'),
    model: 'model',
    apiKey: 'key',
    client: client,
  );
  test('no consent means no outbound request', () async {
    var calls = 0;
    final p = provider(
      MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(p.close);
    await expectLater(p.generate('ambient', consent: false), throwsStateError);
    expect(calls, 0);
  });
  test('provider request disables redirects and sends only prompt and model', () async {
    final p = provider(
      MockClient((req) async {
        expect(req.followRedirects, isFalse);
        expect(req.headers['Authorization'], 'Bearer key');
        final body = jsonDecode(req.body) as Map;
        expect(body.keys, unorderedEquals(['model', 'messages']));
        expect(body['messages'][1]['content'], 'ambient');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': '{"tracks":[{"title":"Song","artist":"Artist","id":"foreign","url":"https://attacker"}]}',
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(p.close);
    final rows = await p.generate('ambient', consent: true);
    expect(rows.single.title, 'Song');
  });
  test('redirect and oversized provider responses fail closed', () async {
    final redirect = provider(
      MockClient((_) async => http.Response('', 302, headers: {'location': 'https://other.example'})),
    );
    addTearDown(redirect.close);
    await expectLater(redirect.generate('x', consent: true), throwsStateError);
    final large = provider(MockClient((_) async => http.Response('x' * (512 * 1024 + 1), 200)));
    addTearDown(large.close);
    await expectLater(large.generate('x', consent: true), throwsFormatException);
  });
  test('response validation deduplicates names and rejects malformed shape', () {
    final rows = MusicPromptProvider.parse(
      '{"tracks":[{"title":" Song ","artist":"Artist"},{"title":"song","artist":"artist"}]}',
    );
    expect(rows, hasLength(1));
    expect(() => MusicPromptProvider.parse('{"tracks":[{"title":"x"}]}'), throwsFormatException);
    expect(
      () => MusicPromptProvider.parse(
        jsonEncode({
          'tracks': List.generate(101, (_) => {'title': 'x', 'artist': 'y'}),
        }),
      ),
      throwsFormatException,
    );
  });
  test('catalog resolution preserves ambiguity and rejects mismatches or hidden sources', () async {
    final client = ExperienceClient()
      ..rows = [
        musicTrack('Song', album: 'one'),
        musicTrack('Song', server: 'foreign'),
        musicTrack('other-title'),
        musicTrack('Song', artist: 'Wrong artist'),
        musicTrack('Song', album: 'two').copyWith(id: 'edition2'),
      ];
    final result = await resolveMusicProposals([const MusicProposal(title: ' song ', artist: 'Artist')], [client]);
    expect(result.single.ambiguous, isTrue);
    expect(result.single.candidates, hasLength(2));
    final hidden = await resolveMusicProposals(
      [const MusicProposal(title: 'song', artist: 'Artist')],
      [client],
      visible: (_) => false,
    );
    expect(hidden.single.candidates, isEmpty);
  });
  test('plain HTTP or credential-bearing provider URLs are rejected', () {
    for (final url in [
      'http://provider.example',
      'https://user:pass@provider.example',
      'https://provider.example?key=secret',
    ]) {
      expect(() => MusicPromptProvider(endpoint: Uri.parse(url), model: 'm', apiKey: ''), throwsArgumentError);
    }
  });
  test('resolver rechecks all earlier matches when account scope changes', () async {
    final client = ExperienceClient()..rows = [musicTrack('Song')];
    var checks = 0;
    final result = await resolveMusicProposals(
      [const MusicProposal(title: 'Song', artist: 'Artist')],
      [client],
      current: (_) => ++checks < 3,
    );
    expect(client.searches, ['Song']);
    expect(result.single.candidates, isEmpty);
  });
}
