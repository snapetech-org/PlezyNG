import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('recovery',Path(__file__).with_name('recover_macos_app.py'))
recovery=importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class CompilationRecoveryTests(unittest.TestCase):
    def test_workflow_compile_settings_are_part_of_recovery_contract(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/build.yml').read_text()
        original = recovery.build_contract(workflow)
        changed = recovery.build_contract(workflow.replace('--dart-define=SUPPORTER_MODE=unlocked', '--dart-define=SUPPORTER_MODE=iap'))
        self.assertNotEqual(original, changed)

    def compare(self, files, **values):
        return dict(status='ahead',merge_base_commit={'sha':'a'*40},files=files,**values)

    def test_packaging_only_changes_are_accepted(self):
        recovery.product_equivalence(self.compare([{'filename':'.github/workflows/build.yml'}]),'a'*40)

    def test_application_native_or_renamed_inputs_are_rejected(self):
        for change in [{'filename':'lib/main.dart'},{'filename':'mpv-build.lock.json'},
                       {'filename':'.github/workflows/build.yml','previous_filename':'lib/main.dart'}]:
            with self.subTest(change=change),self.assertRaises(ValueError):
                recovery.product_equivalence(self.compare([change]),'a'*40)

    def test_incomplete_or_unrelated_comparisons_are_rejected(self):
        for comparison in [{'status':'ahead'},self.compare([{}]*300),
                           {'status':'ahead','files':[],'merge_base_commit':{'sha':'b'*40}}]:
            with self.subTest(comparison=str(comparison)[:100]),self.assertRaises(ValueError):
                recovery.product_equivalence(comparison,'a'*40)


if __name__=='__main__':unittest.main()
