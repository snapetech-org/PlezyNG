"""A signing-only replacement must not hide another platform or source failure."""
import base64
import copy
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import recover_release_platforms as recovery
import release_all_platforms as controller


class MacPackagingProofTests(unittest.TestCase):
    def setUp(self):
        self.workflow=(Path(__file__).resolve().parents[2]/'.github/workflows/build.yml').read_text()
        base={'status':'completed','event':'workflow_dispatch','head_branch':'main',
              'head_repository':{'full_name':recovery.REPOSITORY},'path':'.github/workflows/build.yml'}
        self.source={**base,'id':42,'head_sha':'a'*40,'display_title':'action:release:pool:private:tag:v3.0.3','conclusion':'failure'}
        self.native={**base,'id':43,'head_sha':'b'*40,'display_title':'action:build:pool:private','conclusion':'success'}
        self.compare={'status':'ahead','merge_base_commit':{'sha':'a'*40},'files':[{'filename':'.github/workflows/build.yml'}]}
        names=[n for n in recovery.REQUIRED_JOBS if n!='build-macos']+['build-android','Build WebOS TV package (ARMv7)']
        self.jobs=[{'id':i+1,'name':n,'status':'completed','conclusion':'success'} for i,n in enumerate(names)]
        self.jobs.extend([{'id':99,'name':'build-macos','status':'completed','conclusion':'failure'},
                          {'id':101,'name':'create-release','status':'completed','conclusion':'skipped'}])
        self.original_mac={'id':99,'steps':[{'name':'Build macOS','conclusion':'success'}]}
        names=['Recover verified native macOS compilation','Import Code Signing Certificate','Sign Application','Verify Signature',
               'Notarize Application','Verify Gatekeeper acceptance for Homebrew Cask','Sign DMG for Sparkle (EdDSA)',
               'Attest macOS DMG','Attest recovered macOS compilation provenance','Upload macOS DMG']
        self.recovered={'id':100,'name':'build-macos','conclusion':'success','steps':[{'name':n,'conclusion':'success'} for n in names]}
        self.changed_contract=False

    def prove(self):
        def api(path):
            if path.endswith('/runs/42'):return self.source
            if path.endswith('/runs/43'):return self.native
            if '/compare/' in path:return self.compare
            if '/contents/' in path:
                text=self.workflow
                if self.changed_contract and path.endswith('c'*40):text=text.replace('SUPPORTER_MODE=unlocked','SUPPORTER_MODE=iap')
                return {'content':base64.b64encode(text.encode()).decode()}
            if path.endswith('/jobs/99'):return self.original_mac
            if path.endswith('/jobs/100'):return self.recovered
            raise AssertionError(path)
        def collection(path,key):return self.jobs if '/runs/42/' in path else [self.recovered]
        with patch.object(recovery,'api',side_effect=api),patch.object(recovery,'collection',side_effect=collection),\
             patch.object(recovery,'ci_proof',return_value={'ci_run_id':23}):
            return recovery.verify_macos_packaging_recovery(42,43,'c'*40,'3.0.3')

    def test_all_original_platforms_and_qualified_mac_form_complete_proof(self):
        proof=self.prove()
        self.assertEqual(proof['rebuilt_jobs'],[])
        self.assertEqual(proof['recovered_jobs'],['build-macos'])
        self.assertIn('Build WebOS TV package (ARMv7)',proof['reused_jobs'])
        self.assertEqual(proof['android_source']['source_run_id'],42)
        self.assertEqual(proof['macos_source']['source_run_id'],43)

    def test_other_platform_failure_cannot_be_hidden(self):
        for name in ['build-ios','build-android','Build WebOS TV package (ARMv7)','Build Windows (arm64)']:
            with self.subTest(name=name):
                original=copy.deepcopy(self.jobs)
                next(j for j in self.jobs if j['name']==name)['conclusion']='failure'
                with self.assertRaises(recovery.RecoveryError):self.prove()
                self.jobs=original

    def test_source_app_must_have_compiled_successfully(self):
        self.original_mac['steps'][0]['conclusion']='failure'
        with self.assertRaisesRegex(recovery.RecoveryError,'compilation did not succeed'):self.prove()

    def test_every_recovered_mac_qualification_is_mandatory(self):
        for step in self.recovered['steps']:
            with self.subTest(step=step['name']):
                step['conclusion']='skipped'
                with self.assertRaisesRegex(recovery.RecoveryError,'lacks successful qualification'):self.prove()
                step['conclusion']='success'

    def test_compiler_setting_changes_are_rejected(self):
        self.changed_contract=True
        with self.assertRaisesRegex(recovery.RecoveryError,'compiler configuration differs'):self.prove()

    def test_native_or_application_renames_are_rejected(self):
        self.compare['files']=[{'filename':'CHANGELOG.md','previous_filename':'lib/main.dart'}]
        with self.assertRaisesRegex(recovery.RecoveryError,'application or native inputs'):self.prove()

    def test_source_publication_side_effect_is_not_ignored(self):
        self.jobs[-1]['conclusion']='success'
        with self.assertRaisesRegex(recovery.RecoveryError,'side effects'):self.prove()

    def test_incomplete_or_untrusted_mac_recovery_is_rejected(self):
        for change in [{'head_branch':'feature'},{'status':'queued'},{'conclusion':'failure'}]:
            with self.subTest(change=change):
                original=self.native.copy();self.native.update(change)
                with self.assertRaises(recovery.RecoveryError):self.prove()
                self.native=original

    def test_receipt_must_bind_old_compilation_and_new_packaging_sources(self):
        proof=self.prove()
        receipt={'compiled_source':'a'*40,'compiled_run':42,'compiled_job':99,'packaging_workflow_source':'b'*40,
                 'version':'3.0.3+162','application_inputs_unchanged':True,'compilation_reused':True,'recovered_app_tree_sha256':'d'*64}
        recovery.verify_macos_receipt(receipt,proof)
        for key,value in [('compiled_source','c'*40),('compiled_job',100),('version','3.0.4+163'),('compilation_reused',False)]:
            with self.subTest(key=key),self.assertRaises(recovery.RecoveryError):
                recovery.verify_macos_receipt({**receipt,key:value},proof)

    def test_mac_profile_cannot_omit_webos_or_swap_android(self):
        proof=self.prove()
        for options in [{'include_webos_build':False},{'android_run':999}]:
            with self.subTest(options=options),self.assertRaises(recovery.RecoveryError):
                recovery.compose_proof(proof,**options)

    def test_controller_dispatch_reuses_every_original_platform_and_signed_mac(self):
        with patch.object(controller,'verify_platform_recovery',return_value={}) as verify,\
             patch.object(controller,'matching_run',return_value=None),patch.object(controller,'active_run',return_value=None),\
             patch.object(controller,'ensure_remote_main_sha'),patch.object(controller,'dispatch',return_value={'databaseId':44}) as dispatch:
            controller.ensure_release('v3.0.3','c'*40,include_webos_release=True,execution_profile='hybrid',
                prepare_homebrew_cask=True,reuse_platform_run_id=42,reuse_android_run_id=42,reuse_macos_run_id=43)
            self.assertEqual(verify.call_args.kwargs['macos_run'],43)
            fields=dispatch.call_args.args[3]
            self.assertEqual(fields['reuse_macos_package_run_id'],'43')
            self.assertEqual(fields['reuse_android_run_id'],'42')
            self.assertEqual(fields['include_webos_build'],'true')
            self.assertEqual(fields['include_webos_release'],'true')

    def test_download_uses_replacement_mac_and_original_android_webos(self):
        proof=self.prove()
        receipt={'compiled_source':'a'*40,'compiled_run':42,'compiled_job':99,'packaging_workflow_source':'b'*40,
                 'version':'3.0.3+162','application_inputs_unchanged':True,'compilation_reused':True,'recovered_app_tree_sha256':'d'*64}
        archives={}
        for identity,files in [(1,{'macos-compilation-recovery.json':json.dumps(receipt),'pleazyng-macos.dmg':'signed-dmg'}),
                               (2,{'android.apk':'signed-apk'}),(3,{'package.ipk':'verified-ipk'})]:
            data=io.BytesIO()
            with zipfile.ZipFile(data,'w') as archive:
                for name,body in files.items():archive.writestr(name,body)
            archives[identity]=data.getvalue()
        def artifact(identity,name,run,sha):
            return {'id':identity,'name':name,'expired':False,'digest':'sha256:'+hashlib.sha256(archives[identity]).hexdigest(),
                    'workflow_run':{'id':run,'head_sha':sha}}
        original=[artifact(2,'android-apk',42,'a'*40),artifact(3,'webos-ipk',42,'a'*40)]
        native=[artifact(1,'macos-dmg',43,'b'*40)]
        def collection(path,key):return native if '/runs/43/' in path else original
        def download(command,stdout):
            stdout.write(archives[int(command[-1].split('/')[-2])])
            return SimpleNamespace(returncode=0)
        with tempfile.TemporaryDirectory(prefix='pleazyng-mac-artifact-') as directory,\
             patch.object(recovery,'ARTIFACTS',{'macos-dmg':'macos-dmg'}),\
             patch.object(recovery,'collection',side_effect=collection),patch.object(recovery.subprocess,'run',side_effect=download):
            result=recovery.download_platforms(proof,Path(directory))
            sources={item['name']:item['source_run_id'] for item in result['artifacts']}
            self.assertEqual(sources,{'macos-dmg':43,'android-apk':42,'webos-ipk':42})


if __name__=='__main__':unittest.main()
