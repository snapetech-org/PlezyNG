import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/sources/adapters/audiobookshelf_source.dart';
import 'package:plezy/sources/adapters/podcast_rss_source.dart';
import 'package:plezy/sources/podcast_directory.dart';
import 'package:plezy/sources/podcast_metadata.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

http.Response jsonResponse(Object data) =>
    http.Response(jsonEncode(data), 200, headers: const {'content-type': 'application/json'});

void main() {
  group('Podcast metadata', () {
    test(
      'plain text keeps punctuation across inline markup and spaces block elements',
      () {
        expect(podcastPlainText('A safe <b>description</b>.'), 'A safe description.');
        expect(
          podcastPlainText('<p>A safe <b>description</b>.</p><p>Next &amp; final!</p>'),
          'A safe description. Next & final!',
        );
      },
    );

    test('RFC 822 offsets and Atom timestamps describe the same instant', () {
      expect(parsePodcastDate('Fri, 30 Oct 2026 19:00:00 -0600'), DateTime.utc(2026, 10, 31, 1));
      expect(parsePodcastDate('30 Oct 26 20:00 EDT'), DateTime.utc(2026, 10, 31));
      expect(parsePodcastDate('2026-10-31T01:00:00Z'), DateTime.utc(2026, 10, 31, 1));
      expect(parsePodcastDate('31 Feb 2026 12:00:00 GMT'), isNull);
      expect(parsePodcastDate('30 Oct 2026 25:00:00 GMT'), isNull);
      expect(parsePodcastDate('30 Oct 2026 19:00:00 +1260'), isNull);
      expect(parsePodcastDate('not a date'), isNull);
    });

    test('chapter resources ignore invalid, duplicate and hidden chapters', () {
      final chapters = podcastJsonChapters({
        'chapters': [
          {'startTime': 0, 'title': ''},
          {'startTime': 20, 'title': 'Later'},
          {'startTime': 0, 'title': 'Start'},
          {'startTime': 20, 'title': 'Duplicate'},
          {'startTime': -1, 'title': 'Invalid'},
          {'startTime': 30, 'title': 'Hidden', 'toc': false},
          {'startTime': 60, 'title': 'Outside'},
        ],
      }, durationMs: 60000);
      expect(chapters.map((c) => c.title), ['Start', 'Later']);
      expect(chapters.map((c) => c.endMs), [20000, 60000]);
      expect(podcastTimestamp('01:02:03.5'), 3723500);
      expect(podcastTimestamp('01:99'), isNull);
      expect(podcastTimestamp('NaN'), isNull);
    });
  });

  group('Podcast directories', () {
    test('Apple results resolve to feeds; duplicates and HTTP feeds are omitted', () async {
      var calls = 0;
      final directory = PodcastDirectory(
        SourceTransport(
          client: MockClient((request) async {
            calls++;
            expect(request.url.host, 'itunes.apple.com');
            expect(request.url.path, '/search');
            expect(request.url.queryParameters['media'], 'podcast');
            expect(request.url.queryParameters['country'], 'CA');
            expect(request.headers.containsKey('authorization'), false);
            return jsonResponse({
              'results': [
                {
                  'collectionId': 123,
                  'collectionName': 'A show',
                  'artistName': 'Creator',
                  'feedUrl': 'https://publisher.example/feed.xml',
                  'collectionViewUrl': 'https://podcasts.apple.com/ca/podcast/a-show/id123',
                },
                {'collectionId': 124, 'collectionName': 'Duplicate', 'feedUrl': 'https://publisher.example/feed.xml'},
                {'collectionId': 125, 'collectionName': 'Insecure', 'feedUrl': 'http://publisher.example/feed.xml'},
                {'collectionId': 126, 'collectionName': 'Premium without feed'},
              ],
            });
          }),
        ),
      );
      addTearDown(directory.close);
      final result = await directory.search('A show', country: 'ca');
      expect(result.single.subscription.url.toString(), 'https://publisher.example/feed.xml');
      expect(result.single.website!.host, 'podcasts.apple.com');
      expect(await directory.search('A show', country: 'CA'), hasLength(1));
      expect(calls, 1);
    });

    test('private feed URLs and forged directory hosts never become search terms', () async {
      var calls = 0;
      final directory = PodcastDirectory(
        SourceTransport(
          client: MockClient((_) async {
            calls++;
            return jsonResponse({});
          }),
        ),
      );
      addTearDown(directory.close);
      for (final input in [
        'https://feed.example/private?token=secret',
        'https://[invalid/private?token=secret',
        'feeds.patreon.com/private?token=secret',
        'https://podcasts.apple.com.attacker.example/podcast/id123',
        'https://user:password@podcasts.apple.com/podcast/id123',
        '//feed.example/private',
      ]) {
        await expectLater(directory.search(input), throwsA(isA<SourceException>()));
      }
      expect(calls, 0);
    });

    test('Apple shared links use ID lookup without forwarding the tracking query', () async {
      final directory = PodcastDirectory(
        SourceTransport(
          client: MockClient((request) async {
            expect(request.url.path, '/lookup');
            expect(request.url.queryParameters['id'], '123');
            expect(request.url.toString(), isNot(contains('private-tag')));
            return jsonResponse({'results': []});
          }),
        ),
      );
      addTearDown(directory.close);
      await directory.search('https://podcasts.apple.com/ca/podcast/a/id123?ct=private-tag&i=42');
    });

    test('Podcast Index requires credentials and uses its authenticated public endpoint', () async {
      var calls = 0;
      final directory = PodcastDirectory(
        SourceTransport(
          client: MockClient((request) async {
            calls++;
            expect(request.url.host, 'api.podcastindex.org');
            expect(request.url.path, '/api/1.0/podcasts/trending');
            expect(request.headers['x-auth-key'], 'personal-key');
            expect(request.headers['x-auth-date'], '1000000');
            expect(request.headers['authorization'], matches(RegExp(r'^[0-9a-f]{40}$')));
            expect('${request.url} ${request.headers}', isNot(contains('personal-secret')));
            return jsonResponse({
              'status': 'true',
              'feeds': [
                {'id': 17, 'title': 'Indexed show', 'url': 'https://publisher.example/rss', 'author': 'Host'},
              ],
            });
          }),
        ),
        now: () => DateTime.fromMillisecondsSinceEpoch(1000000000, isUtc: true),
      );
      addTearDown(directory.close);
      await expectLater(
        directory.search('', provider: PodcastDirectoryProvider.podcastIndex, trending: true),
        throwsA(isA<SourceException>()),
      );
      expect(calls, 0);
      final results = await directory.search(
        '',
        provider: PodcastDirectoryProvider.podcastIndex,
        trending: true,
        apiKey: 'personal-key',
        apiSecret: 'personal-secret',
      );
      expect(results.single.website.toString(), 'https://podcastindex.org/podcast/17');
      expect(calls, 1);
    });
  });

  test(
    'RSS preserves episode identity, adds video/dates and hydrates private chapters without credential leakage',
    () async {
      var feedCalls = 0;
      final source = PodcastRssSourceAdapter(
        const FileSource(
          id: 'rss',
          profileId: 'profile',
          kind: FileSourceKind.podcastRss,
          name: 'Feed',
          endpoint: 'https://publisher.example',
        ),
        SourceTransport(
          client: MockClient((request) async {
            if (request.url.host == 'chapters.example') {
              expect(request.headers.containsKey('authorization'), false);
              expect(request.headers['accept'], contains('application/json+chapters'));
              return jsonResponse({
                'chapters': [
                  {'startTime': 0, 'title': 'Welcome'},
                  {'startTime': 20, 'title': 'Topic'},
                ],
              });
            }
            feedCalls++;
            expect(request.headers['authorization'], startsWith('Basic '));
            return http.Response('''<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
          xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Show</title><language>en</language>
          <item><guid>stable-guid</guid><title>Episode</title><pubDate>Fri, 30 Oct 2026 19:00:00 -0600</pubDate>
            <itunes:duration>60</itunes:duration><itunes:season>2</itunes:season><itunes:explicit>yes</itunes:explicit>
            <enclosure url="https://cdn.example/audio.mp3?token=private" type="audio/mpeg" length="1000"/>
            <podcast:chapters url="https://chapters.example/ch.json?token=chapter-secret" type="application/json+chapters"/>
          </item>
          <item><guid>stable-guid</guid><title>Duplicate</title><enclosure url="https://cdn.example/duplicate.mp3" type="audio/mpeg"/></item>
          <item><guid>video-guid</guid><title>Video</title><enclosure url="https://cdn.example/show.mp4" type="video/mp4"/></item>
          </channel></rss>''', 200);
          }),
        ),
        () async => {
          'feedUrl': 'https://publisher.example/private?token=feed-secret',
          'username': 'member',
          'password': 'secret',
        },
      );
      addTearDown(source.close);
      final root = await source.browse();
      expect(root.entries.single.identifiers['podcast'], 'show');
      final episodes = await source.browse(parent: 'podcast:episodes');
      expect(feedCalls, 1);
      expect(episodes.entries, hasLength(2));
      final audio = episodes.entries.first;
      expect(audio.releaseYear, 2026);
      expect(podcastPublishedAt(audio), DateTime.utc(2026, 10, 31, 1));
      expect(audio.identifiers['season'], '2');
      expect(episodes.entries.last.kind, SourceItemKind.video);
      expect((await source.hydrate(audio)).chapters.map((c) => c.title), ['Welcome', 'Topic']);
      final serialized = jsonEncode(audio.toJson());
      expect(serialized, isNot(contains('feed-secret')));
      expect(serialized, isNot(contains('chapter-secret')));
      expect(serialized, isNot(contains('https://cdn.example')));
      final lease = await source.resolve(audio.files.single);
      expect(lease.uri.queryParameters['token'], 'private');
      expect(lease.headers.containsKey('Authorization'), false);
    },
  );

  test('Audiobookshelf podcast episodes use item/episode progress, not show-wide bookmarks', () async {
    final requests = <http.Request>[];
    final podcast = {
      'id': 'show-1',
      'mediaType': 'podcast',
      'media': {
        'metadata': {'title': 'Server show', 'author': 'Host', 'explicit': false},
        'episodes': [
          for (final id in ['ep-1', 'ep-2'])
            {
              'id': id,
              'title': 'Same title',
              'publishedAt': 1793408400000,
              'audioFile': {
                'ino': id,
                'duration': 60,
                'mimeType': 'audio/mpeg',
                'metadata': {'filename': '$id.mp3', 'size': 1000, 'mtimeMs': 1},
              },
            },
        ],
      },
    };
    final source = AudiobookshelfSourceAdapter(
      const FileSource(
        id: 'abs',
        profileId: 'profile',
        kind: FileSourceKind.audiobookshelf,
        name: 'Server',
        endpoint: 'https://abs.example/',
      ),
      SourceTransport(
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['authorization'], 'Bearer private');
          if (request.url.path == '/api/libraries/pods/items') {
            return jsonResponse({
              'results': [podcast],
              'total': 1,
            });
          }
          if (request.url.path == '/api/items/show-1') return jsonResponse(podcast);
          if (request.url.path == '/api/me/progress/show-1/ep-1') {
            if (request.method == 'PATCH') {
              expect(jsonDecode(request.body)['currentTime'], 30);
              expect(jsonDecode(request.body)['duration'], 60);
              return http.Response('', 200);
            }
            return jsonResponse({'currentTime': 30, 'progress': .5, 'isFinished': false, 'lastUpdate': 100});
          }
          return http.Response('', 404);
        }),
      ),
      () async => {'token': 'private'},
    );
    addTearDown(source.close);
    final show = (await source.browse(parent: 'pods')).entries.single;
    expect(show.isFolder, true);
    final episodes = (await source.browse(parent: show.id)).entries;
    expect(episodes, hasLength(2));
    expect(episodes.first.id, isNot(episodes.last.id));
    final entry = episodes.first;
    final lease = await source.resolve(entry.files.single);
    expect(lease.uri.path, '/api/items/show-1/file/ep-1');
    expect((await source.cover(entry))!.uri.path, '/api/items/show-1/cover');
    final seed = PublicationProgress(
      entryKey: entry.key,
      edition: sourceDigest(jsonEncode(entry.audio.map((f) => f.fingerprint).toList())),
      mode: PublicationMode.listening,
      session: 'session',
    );
    final progress = (await source.readProgress(entry, seed))!;
    expect(progress.positionMs, 30000);
    expect(progress.filePositionMs, 30000);
    await source.writeProgress(entry, progress);
    expect(source.supportsAnnotations(entry), false);
    expect(await source.readAnnotations(entry, progress), isEmpty);
    expect(requests.any((request) => request.url.path.contains('bookmark')), false);
    expect((await source.hydrate(entry)).id, entry.id);
  });
}
