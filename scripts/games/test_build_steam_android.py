"""ELF acceptance tests; real NDK builds are recorded separately."""
import unittest

import build_steam_android as android


class AndroidReceiverArtifactTests(unittest.TestCase):
    ELF = """  Machine: AArch64
  LOAD 0x000000 0x00000000 0x00000000 0x1000 0x1000 R E 0x4000
  10: 00001000 24 FUNC GLOBAL DEFAULT 12 JNI_OnLoad
  11: 00001024 24 FUNC GLOBAL DEFAULT 12 Java_receiver_create
"""
    EXPORTS = {"JNI_OnLoad", "Java_receiver_create"}

    def test_valid_64_bit_exports_and_alignment(self):
        android.inspect_elf(self.ELF, "arm64-v8a", self.EXPORTS)

    def test_wrong_machine_and_empty_loads_fail(self):
        with self.assertRaisesRegex(ValueError, "machine"):
            android.inspect_elf(self.ELF, "x86_64", self.EXPORTS)
        with self.assertRaisesRegex(ValueError, "alignment"):
            android.inspect_elf(self.ELF.replace("LOAD", "NOTE"), "arm64-v8a", self.EXPORTS)

    def test_64_bit_requires_16k_while_32_bit_preserves_4k_support(self):
        smaller = self.ELF.replace("0x4000", "0x1000")
        with self.assertRaisesRegex(ValueError, "16384"):
            android.inspect_elf(smaller, "arm64-v8a", self.EXPORTS)
        android.inspect_elf(smaller.replace("AArch64", "ARM"), "armeabi-v7a", self.EXPORTS)

    def test_undefined_or_hidden_symbol_does_not_satisfy_jni_export(self):
        for modified in (self.ELF.replace("DEFAULT 12", "DEFAULT UND"), self.ELF.replace("GLOBAL", "LOCAL"),
                         self.ELF.replace("DEFAULT", "HIDDEN")):
            with self.assertRaisesRegex(ValueError, "exported methods"):
                android.inspect_elf(modified, "arm64-v8a", self.EXPORTS)

    def test_runtime_paths_and_text_relocations_fail(self):
        for tag in ("RPATH", "RUNPATH", "TEXTREL"):
            with self.assertRaisesRegex(ValueError, "text relocations"):
                android.inspect_elf(self.ELF + f" 0x01 ({tag}) 0\n", "arm64-v8a", self.EXPORTS)


if __name__ == "__main__":
    unittest.main()
