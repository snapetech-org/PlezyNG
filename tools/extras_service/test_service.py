"""Offline contract tests: no provider credentials or live traffic required."""
import copy
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

from service import Cache, Discovery, BoundedServer, handler_for, load_registry, fetch_json

CHANNEL = 'UC' + 'a' * 22
VIDEO = '12345678901'
OTHER = 'abcdefghijk'
PARENT = 'movie/tmdb:120'


def video(key=VIDEO, channel=CHANNEL):
    return {'id': key, 'snippet': {'title': 'Production featurette', 'channelId': channel,
        'channelTitle': 'Studio', 'defaultAudioLanguage': 'en'},
        'status': {'privacyStatus': 'public', 'uploadStatus': 'processed'},
        'contentDetails': {'duration': 'PT12M34S'}}


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.registry = Path(self.directory.name) / 'registry.json'
        self.data = {'version': 1, 'publishers': [{'id': CHANNEL, 'name': 'Studio',
            'evidenceUrl': 'https://studio.example/channel'}], 'associations': []}
        self.cache = Cache(':memory:')
        self.addCleanup(self.cache.db.close)
        self.calls = []
        self.videos = [video()]
        self.catalog = [{'key': VIDEO, 'site': 'YouTube', 'type': 'Featurette'}]
        self.find = [{'id': 120}]

    def fetch(self, url, headers=None):
        self.calls.append(url)
        if '/find/' in url:
            return {'movie_results': self.find}
        if 'api.themoviedb.org' in url:
            return {'id': 120, 'title': 'Fellowship', 'videos': {'results': self.catalog}, 'results': self.catalog}
        if '/search?' in url:
            return {'items': [{'id': {'videoId': OTHER}}]}
        return {'items': self.videos}

    def discovery(self, tmdb='tmdb-token', youtube='youtube-key'):
        self.registry.write_text(json.dumps(self.data))
        return Discovery(self.registry, self.cache, tmdb, youtube, fetch=self.fetch)

    def request(self, discovery, **kwargs):
        return discovery.discover({'identities': [PARENT], 'language': 'en', 'region': 'CA', **kwargs})

    def reviewed(self):
        return {'videoId': VIDEO, 'parents': [PARENT], 'kind': 'effects',
            'reviewedBy': 'test reviewer', 'evidenceUrl': 'https://studio.example/film',
            'publisherId': CHANNEL}

    def test_exact_catalog_plus_publisher_admits(self):
        result = self.request(self.discovery())
        item = result['entries'][0]
        self.assertEqual(item['parents'], [PARENT])
        self.assertEqual(item['durationSeconds'], 754)
        self.assertFalse(item['spoilerSafe'])
        self.assertFalse(item['analysisAllowed'])

    def test_unknown_publisher_rejected_even_for_catalog_association(self):
        self.videos = [video(channel='UC' + 'b' * 22)]
        self.assertEqual(self.request(self.discovery())['entries'], [])

    def test_official_publisher_does_not_admit_unrelated_search_hit(self):
        self.videos.append(video(OTHER))
        result = self.request(self.discovery(), expand=True)
        self.assertEqual([e['id'] for e in result['entries']], ['youtube:' + VIDEO])
        self.assertEqual(self.cache.review_queue(), [{'url': 'https://www.youtube.com/watch?v=' + OTHER,
            'proposedParent': PARENT}])

    def test_client_candidates_cannot_claim_review_or_association(self):
        self.catalog = []
        result = self.request(self.discovery(), candidates=[{'id': VIDEO, 'reviewedAssociation': True}])
        self.assertEqual(result['entries'], [])

    def test_reviewed_link_works_without_catalog_token(self):
        self.data['associations'] = [self.reviewed()]
        self.assertEqual(len(self.request(self.discovery(tmdb=''))['entries']), 1)

    def test_reviewed_uploader_binding_rejects_substitution(self):
        self.data['associations'] = [self.reviewed()]
        self.videos = [video(channel='UC' + 'b' * 22)]
        self.assertEqual(self.request(self.discovery())['entries'], [])

    def test_missing_provider_credentials_leave_empty_partial(self):
        self.data['associations'] = [self.reviewed()]
        result = self.request(self.discovery(youtube=''))
        self.assertEqual(result['entries'], [])
        self.assertTrue(result['partial'])

    def test_region_age_private_and_deleted_results_are_excluded(self):
        for transform in [lambda v: v['status'].update(privacyStatus='private'),
                          lambda v: v['contentDetails'].update(regionRestriction={'blocked': ['CA']}),
                          lambda v: v['contentDetails'].update(regionRestriction={'allowed': ['US']}),
                          lambda v: v['contentDetails'].update(contentRating={'ytRating': 'ytAgeRestricted'})]:
            v = video(); transform(v)
            d = self.discovery()
            self.assertIsNone(d.normalize(v, {VIDEO: {'parents': [PARENT], 'kind': 'effects', 'catalogAssociated': True}}, 'CA', False))
        self.videos = []
        self.assertEqual(self.request(self.discovery())['entries'], [])

    def test_review_requires_exact_scope_and_transcript_permission(self):
        for extra in [{'scope': 'franchise'}, {'scope': 'unknown'}, {'passages': [{'text': 'x'}]}, {'parents': ['a title']}]:
            self.data['associations'] = [{**self.reviewed(), **extra}]
            with self.assertRaises(ValueError): self.discovery()

    def test_duplicate_registry_entries_are_rejected(self):
        self.data['associations'] = [self.reviewed(), self.reviewed()]
        with self.assertRaises(ValueError): self.discovery()

    def test_exact_imdb_resolution_returns_verified_alias(self):
        result = self.request(self.discovery(), identities=['movie/imdb:tt0120737'])
        self.assertEqual(result['entries'][0]['parents'], ['movie/imdb:tt0120737', PARENT])

    def test_ambiguous_external_ids_do_not_fall_back_to_title_search(self):
        self.find = [{'id': 120}, {'id': 121}]
        result = self.request(self.discovery(), identities=['movie/imdb:tt0120737'])
        self.assertEqual(result['entries'], [])
        self.assertEqual(len(self.calls), 1)

    def test_conflicting_canonical_ids_are_rejected(self):
        self.assertEqual(self.request(self.discovery(), identities=[PARENT, 'movie/tmdb:121'])['entries'], [])
        self.assertEqual(self.calls, [])

    def test_cache_keys_include_region_language_registry_and_scope(self):
        d = self.discovery()
        self.request(d); before = len(self.calls); self.request(d)
        self.assertEqual(len(self.calls), before)
        self.request(d, region='US'); self.assertGreater(len(self.calls), before)
        before = len(self.calls); self.request(d, language='fr'); self.assertGreater(len(self.calls), before)
        before = len(self.calls); self.request(d, expand=True); self.assertGreater(len(self.calls), before)

    def test_cache_ttl_and_weighted_budget(self):
        self.cache.put('x', {'ok': True})
        with patch('service.time.time', return_value=10**12): self.assertIsNone(self.cache.get('x'))
        self.assertTrue(self.cache.consume('yt', 101, 100))
        self.assertTrue(self.cache.consume('yt', 101))
        self.assertFalse(self.cache.consume('yt', 101))

    def test_provider_errors_return_partial_not_unverified_candidates(self):
        d = self.discovery()
        d.fetch = lambda *args, **kwargs: (_ for _ in ()).throw(ValueError('provider failed'))
        self.assertEqual(self.request(d), {'version': 1, 'entries': [], 'partial': True})

    def test_fetch_rejects_user_controlled_destinations(self):
        for url in ['http://api.themoviedb.org/x', 'https://127.0.0.1/x', 'https://example.com/x']:
            with self.assertRaises(ValueError): fetch_json(url)

    def test_http_auth_path_body_and_discovery_contract(self):
        server = BoundedServer(('127.0.0.1', 0), handler_for(self.discovery(), 'a' * 24))
        worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        url = f'http://127.0.0.1:{server.server_port}/v1/discover'
        req = urllib.request.Request(url, data=b'{}')
        with self.assertRaises(urllib.error.HTTPError) as caught: urllib.request.urlopen(req)
        self.assertEqual(caught.exception.code, 401)
        req = urllib.request.Request(url, data=json.dumps({'identities': [PARENT]}).encode(),
            headers={'Authorization': 'Bearer ' + 'a' * 24})
        with urllib.request.urlopen(req) as response:
            self.assertEqual(response.headers['Cache-Control'], 'no-store')
            self.assertEqual(len(json.load(response)['entries']), 1)
        req = urllib.request.Request(url, data=b'{bad', headers={'Authorization': 'Bearer ' + 'a' * 24})
        with self.assertRaises(urllib.error.HTTPError) as caught: urllib.request.urlopen(req)
        self.assertEqual(caught.exception.code, 400)

    def test_bundled_registry_is_valid_and_has_no_invented_transcripts(self):
        publishers, links = load_registry(Path(__file__).with_name('registry.json'))
        self.assertGreaterEqual(len(publishers), 2)
        self.assertEqual(len(links), 2)
        self.assertTrue(all(not link.get('analysisAllowed') and not link.get('passages') for link in links.values()))


if __name__ == '__main__': unittest.main()
