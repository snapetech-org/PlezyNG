import unittest

try:
    from check_tvos_startup_result import IDENTIFIER, validate
except ModuleNotFoundError:
    from scripts.checks.check_tvos_startup_result import IDENTIFIER, validate


class TvosStartupResultTests(unittest.TestCase):
    def test_positive_native_case_is_required(self):
        case = {'nodeType': 'Test Case', 'nodeIdentifier': IDENTIFIER, 'result': 'Passed'}
        validate({'testNodes': [{'children': [case]}]})
        for result in ('Failed', 'Skipped', 'Expected Failure'):
            with self.subTest(result=result), self.assertRaises(ValueError):
                validate({'testNodes': [case | {'result': result}]})
        with self.assertRaises(ValueError):
            validate({'testNodes': []})
        with self.assertRaises(ValueError):
            validate({'testNodes': [case, case | {'result': 'Failed'}]})


if __name__ == '__main__':
    unittest.main()
