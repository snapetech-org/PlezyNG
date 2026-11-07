"""Exercise real request resolution before dispatching a targeted Mac recovery."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT=Path(__file__).resolve().parents[2]


class MacRequestTests(unittest.TestCase):
    def test_public_intermediate_is_not_imported_twice_from_pkcs12_chain(self):
        workflow=yaml.safe_load((ROOT/'.github/workflows/build.yml').read_text())
        body=next(s['run'] for s in workflow['jobs']['build-macos']['steps'] if s.get('name')=='Import Code Signing Certificate')
        start=body.index('chain_fingerprints=')
        end=body.index('\nfi',start)+3
        script=body[start:end]
        for included in (False,True):
            with self.subTest(included=included),tempfile.TemporaryDirectory(prefix='pleazyng-chain-check-') as directory:
                root=Path(directory)
                security=root/'security'
                security.write_text('#!/bin/sh\nif [ "$1" = find-certificate ]; then\n  printf "%s\\n" "$TEST_CERTIFICATES"\nelse\n  echo imported >> "$TEST_IMPORT_LOG"\nfi\n')
                security.chmod(0o700)
                log=root/'imports'
                fingerprint='F16CD3C54C7F83CEA4BF1A3E6A0819C8AAA8E4A1528FD144715F350643D2DF3A'
                env={**os.environ,'PATH':str(root)+os.pathsep+os.environ['PATH'],'KEYCHAIN_PATH':'isolated.keychain',
                     'CHAIN_PATH':'public.cer','TEST_CERTIFICATES':fingerprint if included else 'OTHER_CERTIFICATE',
                     'TEST_IMPORT_LOG':str(log)}
                result=subprocess.run(['bash','-e','-u','-o','pipefail','-c',script],env=env,capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(log.exists(),not included)

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
                     'REUSE_PLATFORMS':'','REUSE_ANDROID':'','MACOS_PACKAGE_RUN':'','MACOS_COMPILATION_JOB':'128247608189',
                     'GITHUB_SHA':'a'*40,'GITHUB_OUTPUT':str(output),'GITHUB_REF':'refs/heads/main'}
                result=subprocess.run(['bash','-e','-o','pipefail','-c',script],cwd=ROOT,env=env,text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('mode=macos-validation',output.read_text())
                self.assertIn('prepare_homebrew_cask=true',output.read_text())


if __name__=='__main__':unittest.main()
