import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bootstrap_copr_el10 import REQUIRED, enable_targets


class CoprBootstrapTests(unittest.TestCase):
    def test_preserves_all_existing_targets_and_edits_only_chroots(self):
        client = Mock()
        existing = {'fedora-43-x86_64', 'fedora-rawhide-aarch64', 'custom-1-x86_64'}
        client.project_proxy.get.side_effect = [
            {'chroot_repos': dict.fromkeys(existing)}, {'chroot_repos': dict.fromkeys(existing | REQUIRED)}]
        result = enable_targets(client, REQUIRED)
        client.project_proxy.edit.assert_called_once_with('slskdn', 'pleazyng', chroots=sorted(existing | REQUIRED))
        client.build_proxy.assert_not_called()
        self.assertFalse(result['build_submitted'])
        self.assertFalse(result['native_qualified'])

    def test_repeat_bootstrap_is_read_only(self):
        client = Mock()
        client.project_proxy.get.return_value = {'chroot_repos': dict.fromkeys(REQUIRED)}
        self.assertEqual(enable_targets(client, REQUIRED)['added'], [])
        client.project_proxy.edit.assert_not_called()

    def test_missing_capacity_or_ambiguous_project_refuses_changes(self):
        client = Mock()
        with self.assertRaisesRegex(ValueError, 'both required'):
            enable_targets(client, {'epel-10-x86_64'})
        client.project_proxy.get.assert_not_called()
        client.project_proxy.get.return_value = {'chroot_repos': {}}
        with self.assertRaisesRegex(ValueError, 'no targets'):
            enable_targets(client, REQUIRED)
        client.project_proxy.edit.assert_not_called()

    def test_missing_post_mutation_target_fails_verification(self):
        client = Mock()
        client.project_proxy.get.return_value = {'chroot_repos': {'fedora-43-x86_64': ''}}
        with self.assertRaisesRegex(ValueError, 'verification failed'):
            enable_targets(client, REQUIRED)
