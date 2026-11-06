import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from PIL import Image, ImageDraw

SCRIPT = Path(__file__).with_name('package_previews.py')
FIXTURE = SCRIPT.parent / 'fixtures/caminandes-frame.jpg'


class PreviewPackagingTests(unittest.TestCase):
    def package(self, image, name, *, presentation=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        inputs = root / 'input'
        inputs.mkdir()
        image.save(inputs / name)
        output = root / 'output'
        result = subprocess.run([sys.executable, str(SCRIPT), '--input', str(inputs),
                                 '--output', str(output), '--source-sha', 'a' * 40] + (['--presentation'] if presentation else []),
                                capture_output=True, text=True)
        return result, output

    def test_blank_player_with_visible_control_is_rejected(self):
        image = Image.new('RGB', (800, 450), '#0b1118')
        ImageDraw.Draw(image).polygon([(380, 200), (380, 240), (420, 220)], fill='white')
        result, output = self.package(image, 'phone-player-mockup-preview.png')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('empty video area', result.stderr)
        self.assertFalse((output / 'manifest.json').exists())

    def test_nonblank_mockup_carries_attribution_and_no_decoder_claim(self):
        with Image.open(FIXTURE) as image:
            result, output = self.package(image.convert('RGB'), 'phone-player-mockup-preview.png')
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((output / 'manifest.json').read_text())
        self.assertFalse(manifest['store_upload_eligible'])
        self.assertFalse(manifest['video_decoding_performed'])
        self.assertEqual(manifest['sample_frame']['license'], 'CC BY-SA 3.0')
        self.assertTrue((output / manifest['sample_frame']['attribution']).is_file())
        self.assertIn('not native playback', (output / 'README.txt').read_text())

    def test_presentation_export_preserves_pixels_and_provenance_without_footer(self):
        with Image.open(FIXTURE) as source:
            original = source.convert('RGB')
            result, output = self.package(original, 'phone-player-mockup-preview.png', presentation=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        with Image.open(output / 'phone-player-mockup-preview.png') as exported:
            self.assertEqual(exported.size, original.size)
            self.assertEqual(exported.tobytes(), original.tobytes())
        manifest = json.loads((output / 'manifest.json').read_text())
        self.assertFalse(manifest['visible_labels'])
        self.assertFalse(manifest['video_decoding_performed'])
        self.assertFalse(manifest['store_upload_eligible'])
        self.assertTrue((output / 'ATTRIBUTION.md').exists())

    def test_non_video_panel_can_have_an_intentionally_plain_background(self):
        result, output = self.package(Image.new('RGB', (800, 450), '#0b1118'),
                                      'desktop-appearance-dark-preview.png')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((output / 'contact-sheet.jpg').is_file())


if __name__ == '__main__':
    unittest.main()
