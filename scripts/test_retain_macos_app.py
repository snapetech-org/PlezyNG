import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import retain_macos_app as cache


class CompilationCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='pleazyng-compilation-cache-')
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name)
        self.home=self.root/'home';self.home.mkdir()
        self.runner=self.root/'runner-temp';self.runner.mkdir()
        self.app=self.runner/'build/Pleazyng.app'
        (self.app/'Contents').mkdir(parents=True)
        (self.app/'Contents/binary').write_bytes(b'compiled application')
        self.environment={'RUNNER_TEMP':str(self.runner),'GITHUB_RUN_ID':'42','GITHUB_RUN_ATTEMPT':'2',
                          'GITHUB_SHA':'a'*40,'GITHUB_OUTPUT':str(self.root/'outputs')}
        self.inventory={'total_count':1,'jobs':[{'id':99,'name':'build-macos','status':'in_progress','head_sha':'a'*40,'run_attempt':2}]}

    def capture(self):
        def clone(command,check):
            self.assertEqual(command[:2],['/bin/cp','-cR'])
            shutil.copytree(command[2],command[3])
        with patch.dict(os.environ,self.environment),patch.object(cache.sys,'platform','darwin'),\
             patch.object(cache.Path,'home',return_value=self.home),patch.object(cache,'api',return_value=self.inventory),\
             patch.object(cache.subprocess,'run',side_effect=clone):
            cache.capture(self.app)
        return self.home/'Library/Caches/pleazyng-retained-builds/42-99-attempt2'

    def test_verified_cache_preserves_source_and_success_cleanup_is_exact(self):
        snapshot=self.capture()
        record=json.loads((snapshot/'retention.json').read_text())
        self.assertEqual(record['tree_sha256'],cache.tree_digest(self.app))
        self.assertEqual((snapshot/'Pleazyng.app/Contents/binary').read_bytes(),b'compiled application')
        with patch.dict(os.environ,self.environment),patch.object(cache.Path,'home',return_value=self.home):
            cache.discard(snapshot)
        self.assertFalse(snapshot.exists())
        self.assertEqual((self.app/'Contents/binary').read_bytes(),b'compiled application')

    def test_another_job_cannot_remove_retained_evidence(self):
        snapshot=self.capture()
        with patch.dict(os.environ,{**self.environment,'GITHUB_RUN_ID':'43'}),\
             patch.object(cache.Path,'home',return_value=self.home),self.assertRaises(ValueError):
            cache.discard(snapshot)
        self.assertTrue((snapshot/'retention.json').is_file())

    def test_missing_or_ambiguous_current_job_never_creates_a_snapshot(self):
        self.inventory['jobs']*=2;self.inventory['total_count']=2
        with self.assertRaisesRegex(ValueError,'missing or ambiguous'):
            self.capture()
        self.assertTrue(self.app.is_dir())


if __name__=='__main__':unittest.main()
