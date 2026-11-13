"""Regression checks for AUR pkgver and pkgrel updates."""

from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import update_aur_pkgbuild_version as updater


class AurPkgbuildVersionTests(unittest.TestCase):
    def write_recipe(self, text: str) -> Path:
        temporary = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False)
        self.addCleanup(Path(temporary.name).unlink, missing_ok=True)
        with temporary:
            temporary.write(text)
        return Path(temporary.name)

    def test_new_version_resets_pkgrel(self) -> None:
        recipe = self.write_recipe("pkgver=3.0.33\npkgrel=3\n")

        changed = updater.update_pkgbuild_version(recipe, "3.0.34")

        self.assertTrue(changed)
        self.assertEqual(recipe.read_text(), "pkgver=3.0.34\npkgrel=1\n")

    def test_same_version_preserves_maintainer_pkgrel_bump(self) -> None:
        recipe = self.write_recipe("pkgver=3.0.34\npkgrel=4\n")

        changed = updater.update_pkgbuild_version(recipe, "3.0.34")

        self.assertFalse(changed)
        self.assertEqual(recipe.read_text(), "pkgver=3.0.34\npkgrel=4\n")

    def test_rejects_invalid_or_ambiguous_recipe_without_modifying_it(self) -> None:
        for text, version in (
            ("pkgver=3.0.33\npkgrel=3\n", "3.0.34-1"),
            ("pkgver=3.0.33\npkgver=3.0.32\npkgrel=3\n", "3.0.34"),
            ("pkgver=3.0.33\npkgrel=3\npkgrel=2\n", "3.0.34"),
        ):
            with self.subTest(text=text, version=version):
                recipe = self.write_recipe(text)

                with self.assertRaises(updater.PkgbuildError):
                    updater.update_pkgbuild_version(recipe, version)

                self.assertEqual(recipe.read_text(), text)

    def test_publisher_uses_the_tested_version_updater(self) -> None:
        workflow = (ROOT / ".github/workflows/publish-aur.yml").read_text(encoding="utf-8")

        self.assertIn(
            'python3 scripts/update_aur_pkgbuild_version.py "$aur_repo/PKGBUILD" "$RELEASE_VERSION"',
            workflow,
        )


if __name__ == "__main__":
    unittest.main()
