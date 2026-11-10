import json
from pathlib import Path
import tempfile
import unittest

from verify_review_records import verify


class ReviewRecordsTest(unittest.TestCase):
    def test_source_translation_and_provenance_cannot_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for folder in ('docs/localization/reviews', 'docs/localization/provenance', 'lib/i18n'):
                (root / folder).mkdir(parents=True)
            (root / 'lib/i18n/en.i18n.json').write_text(json.dumps({'privacy': 'Do not upload'}))
            (root / 'lib/i18n/es.i18n.json').write_text(json.dumps({'privacy': 'No subir'}))
            (root / 'docs/localization/provenance/es.json').write_text(json.dumps({
                'messages': {'privacy': 'assistant-semantic-review-2026-11-09'},
            }))
            import hashlib
            source = 'Do not upload'
            entry = {'source': source, 'translation': 'No subir',
                     'sourceSha256': hashlib.sha256(source.encode()).hexdigest(),
                     'review': 'assistant-authored-and-semantically-reviewed'}
            manifest = root / 'docs/localization/reviews/security-completion-es.json'
            manifest.write_text(json.dumps({'schemaVersion': 1, 'locale': 'es', 'entries': {'privacy': entry}}))
            self.assertEqual(verify(root), [])
            (root / 'lib/i18n/en.i18n.json').write_text(json.dumps({'privacy': 'Upload'}))
            self.assertIn('English source changed after review', verify(root)[0])
            (root / 'lib/i18n/en.i18n.json').write_text(json.dumps({'privacy': source}))
            (root / 'lib/i18n/es.i18n.json').write_text(json.dumps({'privacy': 'Subir'}))
            self.assertIn('translation changed after review', verify(root)[0])
