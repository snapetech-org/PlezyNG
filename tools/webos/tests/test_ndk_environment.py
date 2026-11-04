import os
import struct
import tempfile
import unittest
from pathlib import Path

from tools.webos.ndk_environment import EnvironmentError, _hash_file


def _path_slot(value: bytes) -> bytes:
    slot_size = 0x1000
    if len(value) + 1 > slot_size:
        raise ValueError("test path does not fit in an ELF path slot")
    return value + b"\0" + b"\0" * (slot_size - len(value) - 1)


def _fake_elf(
    root: Path, *, code_byte: bytes = b"A", outside_root: bool = False
) -> bytes:
    names = b"\0.interp\0.gccrelocprefix\0.shstrtab\0"
    interp_offset = 0x100
    reloc_prefix_offset = interp_offset + 0x1000
    reloc_prefix_size = 0x2000
    names_offset = reloc_prefix_offset + reloc_prefix_size
    section_header_offset = (names_offset + len(names) + 7) & ~7
    section_header_size = 64
    contents = bytearray(section_header_offset + 4 * section_header_size)

    interpreter = (
        str(root).encode()
        + b"/sysroots/x86_64-starfishsdk-linux/lib/ld-linux-x86-64.so.2"
    )
    reloc_prefixes = (
        _path_slot(b"/usr/lib/")
        + _path_slot(
            str(root).encode()
            + b"/sysroots/x86_64-starfishsdk-linux/usr/lib/"
        )
    )
    contents[interp_offset : interp_offset + 0x1000] = _path_slot(interpreter)
    contents[
        reloc_prefix_offset : reloc_prefix_offset + reloc_prefix_size
    ] = reloc_prefixes
    contents[names_offset : names_offset + len(names)] = names
    contents[0x80 : 0x80 + len(code_byte)] = code_byte
    if outside_root:
        root_bytes = str(root).encode()
        contents[0x90 : 0x90 + len(root_bytes)] = root_bytes

    ident = b"\x7fELF" + bytes((2, 1, 1)) + b"\0" * 9
    header = struct.pack(
        "<HHIQQQIHHHHHH",
        2,
        62,
        1,
        0,
        64,
        section_header_offset,
        0,
        64,
        56,
        1,
        section_header_size,
        4,
        3,
    )
    program_header = struct.pack(
        "<IIQQQQQQ",
        3,
        4,
        interp_offset,
        0x400000 + interp_offset,
        0,
        0x1000,
        0x1000,
        1,
    )
    contents[:16] = ident
    contents[16 : 16 + len(header)] = header
    contents[64 : 64 + len(program_header)] = program_header

    section_headers = (
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (
            names.index(b".interp"),
            1,
            2,
            0x400100,
            interp_offset,
            0x1000,
            0,
            0,
            1,
            0,
        ),
        (
            names.index(b".gccrelocprefix"),
            1,
            2,
            0x401100,
            reloc_prefix_offset,
            reloc_prefix_size,
            0,
            0,
            1,
            0,
        ),
        (
            names.index(b".shstrtab"),
            3,
            0,
            0,
            names_offset,
            len(names),
            0,
            0,
            1,
            0,
        ),
    )
    for index, section in enumerate(section_headers):
        packed = struct.pack("<IIQQQQIIQQ", *section)
        offset = section_header_offset + index * section_header_size
        contents[offset : offset + section_header_size] = packed
    return bytes(contents)


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
                tool.write_bytes(_fake_elf(root))
                digests.append(
                    _hash_file(
                        root,
                        "sysroots/x86_64/usr/bin/arm-ld",
                        normalize_root=True,
                    )
                )

            self.assertEqual(digests[0], digests[1])

    def test_text_fragments_still_normalize_installer_roots(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ["PLEZY_WEBOS_TEST_TMP"]) as temporary:
            parent = Path(temporary)
            roots = (parent / "ndk-a", parent / "a-much-longer-ndk-install-root")
            digests = []
            for root in roots:
                root.mkdir()
                fragment = root / "sysroots/x86_64/environment-setup.d/file.sh"
                fragment.parent.mkdir(parents=True)
                fragment.write_text(f"prefix={root}/sysroots/lib\n", encoding="utf-8")
                digests.append(
                    _hash_file(
                        root,
                        "sysroots/x86_64/environment-setup.d/file.sh",
                        normalize_root=True,
                    )
                )

            self.assertEqual(digests[0], digests[1])

    def test_elf_root_normalization_rejects_paths_outside_fixed_slots(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ["PLEZY_WEBOS_TEST_TMP"]) as temporary:
            root = Path(temporary)
            tool = root / "tool"
            tool.write_bytes(_fake_elf(root, outside_root=True))

            with self.assertRaisesRegex(EnvironmentError, "outside fixed-size path sections"):
                _hash_file(root, "tool", normalize_root=True)

    def test_elf_root_normalization_preserves_non_path_data(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ["PLEZY_WEBOS_TEST_TMP"]) as temporary:
            root = Path(temporary)
            tool = root / "tool"
            tool.write_bytes(_fake_elf(root, code_byte=b"A"))
            original = _hash_file(root, "tool", normalize_root=True)
            tool.write_bytes(_fake_elf(root, code_byte=b"B"))

            self.assertNotEqual(original, _hash_file(root, "tool", normalize_root=True))

    def test_normalized_hash_requires_an_embedded_install_root(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ["PLEZY_WEBOS_TEST_TMP"]) as temporary:
            root = Path(temporary)
            tool = root / "tool"
            tool.write_bytes(b"vendor binary without a relocation path")

            with self.assertRaisesRegex(
                EnvironmentError, "does not reference its installation root"
            ):
                _hash_file(root, "tool", normalize_root=True)


if __name__ == "__main__":
    unittest.main()
