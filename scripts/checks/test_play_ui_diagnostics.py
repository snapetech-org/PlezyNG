#!/usr/bin/env python3
"""UI failure diagnostics may retain fixed categories, never captured content."""
import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


spec = importlib.util.spec_from_file_location(
    'qualify_review_access', Path(__file__).parents[1] / 'stores' / 'qualify_review_access.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PlayUiDiagnosticsTest(unittest.TestCase):
    def test_private_input_requires_focused_editable_dialog(self):
        tree = ET.fromstring('<hierarchy><node text="Store review access"/><node text="Activate"/>'
                             '<node class="android.widget.EditText" focused="true" text=""/></hierarchy>')
        self.assertTrue(module.review_dialog_ready(tree))
        tree[-1].set('focused', 'false')
        self.assertFalse(module.review_dialog_ready(tree))
        tree[-1].set('focused', 'true')
        tree[1].set('text', '')
        self.assertFalse(module.review_dialog_ready(tree))

    def test_aosp_errors_from_stderr_are_actionable(self):
        for stderr, expected in (
            ('ERROR: null root node returned by UiTestAutomationBridge.', 'null_root'),
            ('ERROR: could not get idle state.', 'idle_timeout'),
            ('Permission denied', 'permission_denied'),
            ('ERROR: could not create dump file', 'dump_file_error'),
        ):
            with self.subTest(stderr=stderr):
                self.assertEqual(module.accessibility_failure_reason('', stderr), expected)

    def test_arbitrary_private_content_is_never_returned(self):
        private = 'synthetic-private-review-code-do-not-retain'
        for stdout, stderr in (
            (private, private),
            ('<?xml><hierarchy><node text="' + private + '"', private),
            (private, 'ERROR: null root node ' + private),
            ('<?xml>' + private, 'Permission denied: ' + private),
        ):
            category = module.accessibility_failure_reason(stdout, stderr)
            self.assertIn(category, {'no_xml', 'malformed_xml', 'null_root', 'permission_denied'})
            self.assertNotIn(private, category)


if __name__ == '__main__':
    unittest.main()
