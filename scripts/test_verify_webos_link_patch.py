import unittest
from verify_webos_link_patch import ANCHOR, LINK, equivalent


class WebosLinkProofTests(unittest.TestCase):
    def test_only_the_existing_interface_link_can_be_added(self):
        before = 'project(runner LANGUAGES CXX)\n' + ANCHOR + '\nadd_subdirectory(native)\n'
        after = before.replace(ANCHOR, ANCHOR + LINK)
        self.assertTrue(equivalent(before, before))
        self.assertTrue(equivalent(before, after))
        for changed in (after + '\nset(CMAKE_CXX_FLAGS changed)\n',
                        after.replace('PRIVATE flutter', 'PRIVATE different'),
                        after.replace('add_subdirectory(native)', 'add_subdirectory(other)'),
                        after + LINK):
            with self.subTest(changed=changed):
                self.assertFalse(equivalent(before, changed))
        self.assertFalse(equivalent(after, before), 'The required link cannot be removed during reuse')


if __name__ == '__main__':
    unittest.main()
