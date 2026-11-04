import hashlib
import os
import tempfile
import unittest
from pathlib import Path

from tools.webos.ndk_environment import EnvironmentError, _hash_file


class NdkEnvironmentTests(unittest.TestCase):
    def test_hash_normalizes_different_installer_roots(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ["PLEZY_WEBOS_TEST_TMP"]) as temporary:
            parent = Path(temporary)
            roots = (parent / "ndk-a", parent / "a-much-longer-ndk-install-root")
            digests = []
            for root in roots:
                root.mkdir()
                tool = root / "sysroots/x86_64/usr/bin/arm-ld"
                tool.parent.mkdir(parents=True)
                tool.write_bytes(b"\x7fELF" + str(root).encode() + b"/sysroots/lib/ld.so.2\0")
                digests.append(_hash_file(root, "sysroots/x86_64/usr/bin/arm-ld", normalize_root=True))

            expected = hashlib.sha256(b"\x7fELF${WEBOS_NDK_ROOT}/sysroots/lib/ld.so.2\0").hexdigest()
            self.assertEqual(digests, [expected, expected])

    def test_normalized_hash_requires_an_embedded_install_root(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ["PLEZY_WEBOS_TEST_TMP"]) as temporary:
            root = Path(temporary)
            tool = root / "tool"
            tool.write_bytes(b"vendor binary without a relocation path")

            with self.assertRaisesRegex(EnvironmentError, "does not reference its installation root"):
                _hash_file(root, "tool", normalize_root=True)


if __name__ == "__main__":
    unittest.main()
