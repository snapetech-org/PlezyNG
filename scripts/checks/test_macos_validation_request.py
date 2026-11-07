"""Exercise real request resolution before dispatching a targeted Mac recovery."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT=Path(__file__).resolve().parents[2]


class MacRequestTests(unittest.TestCase):
    def test_signed_mac_validation_and_recovery_accept_both_profiles(self):
        workflow=yaml.safe_load((ROOT/'.github/workflows/build.yml').read_text())
        version=subprocess.check_output(['python3',str(ROOT/'scripts/pubspec_version.py'),str(ROOT/'pubspec.yaml')],text=True).strip().split('+',1)[0]
        script=next(s['run'] for s in workflow['jobs']['validate-trusted-ref']['steps'] if s.get('name')=='Resolve release request')
        for profile in ('private','hybrid'):
            with self.subTest(profile=profile),tempfile.TemporaryDirectory(prefix='pleazyng-mac-request-') as directory:
                output=Path(directory)/'outputs'
                env={**os.environ,'ACTION_INPUT':'build','RUNNER_POOL_INPUT':'private','EXECUTION_PROFILE_INPUT':profile,
                     'MODE_INPUT':'macos-validation','BUILD_VERSION_INPUT':version,'REF_TYPE':'branch','REF_NAME':'main',
                     'INCLUDE_WEBOS_BUILD_INPUT':'true','INCLUDE_WEBOS_RELEASE_INPUT':'true','INCLUDE_TIZEN_BUILD_INPUT':'true',
                     'INCLUDE_APPLE_STORE_BUILD_INPUT':'false','PREPARE_HOMEBREW_CASK_INPUT':'true','SUBTITLE_GPU_BACKEND_INPUT':'cpu',
                     'REUSE_PLATFORMS':'','REUSE_ANDROID':'','MACOS_COMPILATION_JOB':'128247608189',
                     'GITHUB_SHA':'a'*40,'GITHUB_OUTPUT':str(output),'GITHUB_REF':'refs/heads/main'}
                result=subprocess.run(['bash','-e','-o','pipefail','-c',script],cwd=ROOT,env=env,text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('mode=macos-validation',output.read_text())
                self.assertIn('prepare_homebrew_cask=true',output.read_text())


if __name__=='__main__':unittest.main()
