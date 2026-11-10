import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from verify_review_records import verify


class ReviewRecordsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for folder in ('docs/localization/reviews', 'docs/localization/provenance', 'lib/i18n'):
            (self.root / folder).mkdir(parents=True)
        self.manifest = self.root / 'docs/localization/reviews/security-completion-es.json'
        self.provenance = self.root / 'docs/localization/provenance/es.json'
        self.record = {
            'schemaVersion': 1, 'locale': 'es', 'reviewedOn': '2026-11-09',
            'nativeSpeakerReviewed': False, 'sourceCommit': 'a' * 40,
            'reviewMethod': 'Assistant semantic review against the complete English message.',
            'entries': {},
        }
        self.configure('Do not upload', 'No subir')

    def write(self, path, value):
        path.write_text(json.dumps(value))

    def configure(self, source, translation):
        self.write(self.root / 'lib/i18n/en.i18n.json', {'privacy': source})
        self.write(self.root / 'lib/i18n/es.i18n.json', {'privacy': translation})
        self.write(self.provenance, {'messages': {'privacy': 'assistant-semantic-review-' + self.record['reviewedOn']}})
        self.record['entries'] = {'privacy': {
            'source': source, 'translation': translation,
            'sourceSha256': hashlib.sha256(source.encode()).hexdigest(),
            'review': 'assistant-authored-and-semantically-reviewed',
        }}
        self.write(self.manifest, self.record)

    def test_source_translation_and_provenance_cannot_drift(self):
        self.assertEqual(verify(self.root), [])
        self.write(self.root / 'lib/i18n/en.i18n.json', {'privacy': 'Upload'})
        self.assertIn('English source changed after review', verify(self.root)[0])
        self.write(self.root / 'lib/i18n/en.i18n.json', {'privacy': 'Do not upload'})
        self.write(self.root / 'lib/i18n/es.i18n.json', {'privacy': 'Subir'})
        self.assertIn('translation changed after review', verify(self.root)[0])

    def test_empty_fallback_cannot_be_approved_as_a_translation(self):
        for translation in ['', '  ', '\n\t']:
            with self.subTest(translation=translation):
                self.configure('Do not upload', translation)
                self.assertTrue(any('empty fallback' in error for error in verify(self.root)))

    def test_assistant_review_cannot_claim_native_speaker_review(self):
        for claim in [True, None, 'false', 0]:
            with self.subTest(claim=claim):
                self.record['nativeSpeakerReviewed'] = claim
                self.write(self.manifest, self.record)
                self.assertTrue(any('native-speaker claim' in error for error in verify(self.root)))

    def test_review_date_is_canonical_and_provenance_is_date_scoped(self):
        for value in ['2026-02-30', '20261109', '', None]:
            with self.subTest(value=value):
                self.record['reviewedOn'] = value
                self.write(self.manifest, self.record)
                self.assertTrue(any('invalid review date' in error for error in verify(self.root)))
        self.record['reviewedOn'] = '2026-11-10'
        self.write(self.manifest, self.record)
        self.assertTrue(any('provenance does not match review' in error for error in verify(self.root)))
        self.write(self.provenance, {'messages': {'privacy': 'assistant-semantic-review-2026-11-10'}})
        self.assertEqual(verify(self.root), [])

    def test_missing_source_identity_or_review_method_is_rejected(self):
        for key, value in [('sourceCommit', 'short'), ('sourceCommit', None),
                           ('reviewMethod', ''), ('reviewMethod', None)]:
            with self.subTest(key=key, value=value):
                original = self.record[key]
                self.record[key] = value
                self.write(self.manifest, self.record)
                self.assertTrue(any('explicit provenance' in error for error in verify(self.root)))
                self.record[key] = original

    def test_reviewed_copy_still_preserves_interpolation_and_text_safety(self):
        for source, translation in [('Hello $name', 'Hola $user'),
                                    ('$name $name', 'Hola $name'),
                                    ('Privacy', '\u202ePrivacidad'),
                                    ('Privacy', 'ZXQ123')]:
            with self.subTest(translation=translation):
                self.configure(source, translation)
                self.assertNotEqual(verify(self.root), [])

    def test_invalid_record_shape_and_locale_do_not_select_other_paths(self):
        self.write(self.manifest, [])
        self.assertTrue(any('invalid review records' in error for error in verify(self.root)))
        for locale in ['../fr', 'fr/CA', '', 'es\\other', '.']:
            with self.subTest(locale=locale):
                self.record['locale'] = locale
                self.write(self.manifest, self.record)
                self.assertTrue(any('invalid locale' in error for error in verify(self.root)))


if __name__ == '__main__':
    unittest.main()
