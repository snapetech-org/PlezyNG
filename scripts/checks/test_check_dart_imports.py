import unittest

from check_dart_imports import directive_uris, missing_targets, relative_directives


class DartImportTests(unittest.TestCase):
    def test_conditional_imports_exports_and_parts(self):
        source = """/* /* nested */ header */
library player;
import 'dart:io';
import 'stub.dart' if (dart.library.io) 'native.dart';
export 'api.dart';
part 'generated.g.dart';
class Player {}
"""
        self.assertEqual(relative_directives(source), ['stub.dart', 'native.dart', 'api.dart', 'generated.g.dart'])

    def test_strings_and_comments_cannot_inject_directives(self):
        source = """// import 'missing.dart';
import r'../real.dart';
const example = "import 'missing.dart';";
"""
        self.assertEqual(relative_directives(source), ['../real.dart'])

    def test_package_uris_include_conditional_directives_but_not_examples(self):
        source = """/* import 'package:ignored/a.dart'; */
import 'dart:io';
export 'stub.dart' if (dart.library.io) r'package:pdfrx/pdfrx.dart';
const example = "import 'package:ignored/b.dart';";
"""
        self.assertEqual(directive_uris(source), ['dart:io', 'stub.dart', 'package:pdfrx/pdfrx.dart'])

    def test_normalized_paths_resolve_against_the_repository(self):
        source = "import '../../i18n/strings.g.dart';"
        tracked = {'lib/screens/settings/page.dart', 'lib/i18n/strings.g.dart'}
        self.assertEqual(missing_targets('lib/screens/settings/page.dart', source, tracked), [])
        broken = source.replace('../../', '../../../../')
        self.assertEqual(missing_targets('lib/screens/settings/page.dart', broken, tracked)[0]['target'], '../i18n/strings.g.dart')


if __name__ == '__main__':
    unittest.main()
