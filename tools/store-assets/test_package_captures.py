import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from PIL import Image
from package_captures import package_captures


class CapturePackageTest(unittest.TestCase):
    def capture(self, directory, name, color, *, size=(400, 700), source_sha='a' * 40):
        image = directory / (name + '.png')
        Image.new('RGBA', size, color).save(image)
        receipt = {
            'kind': 'phone-emulator', 'capture': image.name,
            'capture_sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
            'dimensions': list(size), 'source_sha': source_sha, 'apk_sha256': 'b' * 64,
        }
        (directory / (name + '.json')).write_text(json.dumps(receipt))
        return image

    def test_export_removes_opaque_alpha_without_changing_pixels(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.capture(root, 'phone-home', '#123456')
            self.capture(root, 'phone-detail', '#234567')
            archive = package_captures(root, root / 'export', 'google-play-phone')
            self.assertTrue(archive.is_file())
            with Image.open(source) as original, Image.open(root / 'export/google-play-phone/phone-home.png') as exported:
                self.assertEqual(exported.mode, 'RGB')
                self.assertEqual(original.convert('RGB').tobytes(), exported.tobytes())

    def test_modified_capture_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = self.capture(root, 'home', 'red')
            self.capture(root, 'detail', 'green')
            image.write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                package_captures(root, root / 'export', 'google-play-phone')

    def test_tall_phone_image_is_not_cropped_to_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.capture(root, 'home', 'red', size=(400, 900))
            self.capture(root, 'detail', 'green')
            with self.assertRaisesRegex(ValueError, 'dimensions'):
                package_captures(root, root / 'export', 'google-play-phone')

    def test_transparent_image_is_not_composited(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.capture(root, 'home', (0, 0, 0, 0))
            self.capture(root, 'detail', 'green')
            with self.assertRaisesRegex(ValueError, 'opaque'):
                package_captures(root, root / 'export', 'google-play-phone')

    def test_mixed_builds_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.capture(root, 'home', 'red')
            self.capture(root, 'detail', 'green', source_sha='c' * 40)
            with self.assertRaisesRegex(ValueError, 'different app builds'):
                package_captures(root, root / 'export', 'google-play-phone')


if __name__ == '__main__':
    unittest.main()
