import unittest
from verify_webos_link_patch import ANCHOR, LINK, WORKER_ANCHOR, ATOMIC_LINKS, equivalent


class WebosLinkProofTests(unittest.TestCase):
    def test_only_exact_static_atomic_links_can_be_added_at_worker_targets(self):
        before = ANCHOR + LINK + WORKER_ANCHOR + 'install(TARGETS plezy_retro LIBRARY DESTINATION lib)\n'
        after = before.replace(WORKER_ANCHOR, WORKER_ANCHOR + ATOMIC_LINKS)
        self.assertTrue(equivalent(before, after))
        self.assertTrue(equivalent(after, after))
        for changed in (after.replace('atomic', 'other'), after + ATOMIC_LINKS,
                        after.replace('PRIVATE "-Wl,-Bstatic" atomic', 'PRIVATE atomic'),
                        after + 'add_compile_options(-march=armv6)\n', before):
            with self.subTest(changed=changed):
                self.assertFalse(equivalent(after, changed))
        self.assertFalse(equivalent(before, after.replace('LIBRARY DESTINATION lib', 'LIBRARY DESTINATION other')))

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
