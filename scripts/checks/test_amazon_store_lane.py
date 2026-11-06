"""Execute the Fastlane DSL with a local upload stub; never contact a store."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUBY = shutil.which('ruby')
HARNESS = '''
require 'json'
$lanes = {}
def default_platform(*); end
def platform(*); yield; end
def desc(*); end
def lane(name, &block); $lanes[name] = block; end
def upload_to_amazon_appstore(**options); puts JSON.generate(options); end
load ARGV.fetch(0)
$lanes.fetch(:publish_amazon_appstore).call
'''


@unittest.skipUnless(RUBY, 'Ruby is required for the Fastlane DSL test')
class AmazonStoreLaneTest(unittest.TestCase):
    def run_lane(self, app_id):
        environment = {
            'PATH': os.environ.get('PATH', ''),
            'AMAZON_APK_PATH': '/fixture/pleazyng-amazon-firetv.apk',
            'AMAZON_CLIENT_ID': 'fixture-client',
            'AMAZON_CLIENT_SECRET': 'fixture-not-a-real-secret',
        }
        if app_id is not None:
            environment['AMAZON_APPSTORE_APP_ID'] = app_id
        return subprocess.run([RUBY, '-e', HARNESS, str(ROOT / 'fastlane/Fastfile')],
                              capture_output=True, text=True, env=environment)

    def test_upload_targets_amazon_record_and_preserves_console_listing(self):
        app_id = 'amzn1.devportal.mobileapp.' + 'a' * 32
        result = self.run_lane(app_id)
        self.assertEqual(result.returncode, 0, result.stderr)
        options = json.loads(result.stdout)
        self.assertEqual(options['package_name'], app_id)
        for key in ('skip_upload_metadata', 'skip_upload_changelogs', 'skip_upload_images',
                    'skip_upload_screenshots', 'changes_not_sent_for_review'):
            self.assertIs(options[key], True)
        self.assertEqual(options['overwrite_upload_mode'], 'reuse')

    def test_android_package_name_is_rejected_before_upload(self):
        result = self.run_lane('org.snapetech.pleazyng')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('Amazon console App ID', result.stderr)

    def test_missing_record_id_is_not_guessed(self):
        result = self.run_lane(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('AMAZON_APPSTORE_APP_ID', result.stderr)


if __name__ == '__main__':
    unittest.main()
