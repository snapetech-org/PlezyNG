"""Run the Apple Fastlane DSL against in-memory App Store Connect stubs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUBY = shutil.which('ruby')
HARNESS = r'''
require 'json'
$lanes = {}
def default_platform(*); end
def platform(*); yield; end
def desc(*); end
def lane(name, &block); $lanes[name] = block; end

module FastlaneCore
  class IpaFileAnalyser
    def self.fetch_info_plist_file(_path)
      JSON.parse(File.read(ENV.fetch('FIXTURE_PLIST')))
    end
  end
end

module Spaceship
  module ConnectAPI
    App = Struct.new(:id, :bundle_id)
    BuildRecord = Struct.new(:id, :app_id, :bundle_id, :app_version, :version,
                             :platform, :processing_state, :uploaded_date)
    class << self
      attr_accessor :token
      def get_app(app_id:)
        [App.new(app_id, 'org.snapetech.pleazyng')]
      end
    end
    class Build
      def self.all(**query)
        return [] if ENV.fetch('BUILD_MODE') == 'absent' && !File.exist?(ENV.fetch('UPLOAD_MARKER'))
        [BuildRecord.new('asc-build-1', query.fetch(:app_id), 'org.snapetech.pleazyng',
                         query.fetch(:version), query.fetch(:build_number),
                         query.fetch(:platform), 'VALID', '2026-11-11T00:00:00Z')]
      end
    end
  end
end

Token = Struct.new(:expired?)
def app_store_connect_api_key(**_options)
  Spaceship::ConnectAPI.token = Token.new(false)
  { key_id: 'fixture' }
end
def upload_to_app_store(**options)
  File.write(ENV.fetch('UPLOAD_MARKER'), JSON.generate(options))
end

load ARGV.fetch(0)
$lanes.fetch(:upload_appstore_build).call
'''


@unittest.skipUnless(RUBY, 'Ruby is required for the Fastlane DSL test')
class AppleStoreLaneTest(unittest.TestCase):
    def run_lane(self, mode):
        with tempfile.TemporaryDirectory(prefix='apple-store-lane-', dir=ROOT) as temporary:
            directory = Path(temporary)
            ipa = directory / 'signed.ipa'
            ipa.write_bytes(b'signed fixture bytes')
            plist = directory / 'Info.json'
            plist.write_text(json.dumps({
                'CFBundleIdentifier': 'org.snapetech.pleazyng',
                'CFBundleShortVersionString': '3.0.31',
                'CFBundleVersion': '190', 'DTPlatformName': 'iphoneos',
            }))
            receipt = directory / 'receipt.json'
            marker = directory / 'upload.json'
            env = {
                'PATH': os.environ.get('PATH', ''), 'FIXTURE_PLIST': str(plist),
                'APPLE_IPA_PATH': str(ipa), 'APPLE_STORE_PLATFORM': 'ios',
                'APPLE_RELEASE_TAG': 'v3.0.31', 'APPLE_PROCESSING_RECEIPT_PATH': str(receipt),
                'APPLE_API_KEY_ID': 'fixture', 'APPLE_API_ISSUER_ID': 'fixture',
                'APPLE_API_PRIVATE_KEY': 'fixture', 'GITHUB_RUN_ID': '123',
                'GITHUB_RUN_ATTEMPT': '2', 'BUILD_MODE': mode, 'UPLOAD_MARKER': str(marker),
            }
            result = subprocess.run([RUBY, '-e', HARNESS, str(ROOT / 'fastlane/Fastfile')],
                                    capture_output=True, text=True, env=env, cwd=ROOT)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(receipt.read_text()), json.loads(marker.read_text()) if marker.exists() else None

    def test_existing_exact_valid_build_skips_transport_and_emits_receipt(self):
        receipt, upload = self.run_lane('valid')
        self.assertIsNone(upload)
        self.assertEqual(receipt['processing_state'], 'VALID')
        self.assertEqual(receipt['marketing_version'], '3.0.31')
        self.assertEqual(receipt['build_number'], '190')
        self.assertEqual(receipt['asc_linkage'], 'existing_version_build_identity')

    def test_absent_build_uploads_without_review_then_checks_processing(self):
        receipt, upload = self.run_lane('absent')
        self.assertEqual(upload['app_identifier'], 'org.snapetech.pleazyng')
        self.assertIs(upload['submit_for_review'], False)
        self.assertIs(upload['skip_app_version_update'], True)
        self.assertEqual(receipt['asc_linkage'], 'transported_this_run')


if __name__ == '__main__':
    unittest.main()
