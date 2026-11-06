"""Exercise Android's declared backup policy against app data examples."""
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
XML = ROOT / "android/app/src/main/res/xml"


def excluded(policy, domain, name):
    # Root-domain paths are relative to the app's data dir; Flutter documents
    # use Context.getDir("flutter") -> app_flutter, not Context.getFilesDir().
    return any(
        entry.attrib["domain"] == domain
        and PurePosixPath(name).is_relative_to(PurePosixPath(entry.attrib["path"]))
        for entry in policy.findall("exclude")
    )


class DownloadBackupPolicyTests(unittest.TestCase):
    def test_all_backup_modes_exclude_only_regenerable_media(self):
        legacy = ET.parse(XML / "credential_backup_rules.xml").getroot()
        modern = ET.parse(XML / "credential_data_extraction_rules.xml").getroot()
        for mode, policy in [("legacy", legacy), ("cloud", modern.find("cloud-backup")),
                             ("transfer", modern.find("device-transfer"))]:
            with self.subTest(mode=mode):
                self.assertIsNotNone(policy)
                for file in ["app_flutter/downloads/Movies/title.mkv", "app_flutter/artwork/poster.jpg"]:
                    self.assertTrue(excluded(policy, "root", file), file)
                for file in ["app_flutter/preferences.json", "app_flutter/recordings/show.ts",
                             "app_flutter/bookmarks.json", "app_flutter/downloads-export/original.mkv"]:
                    self.assertFalse(excluded(policy, "root", file), file)
                self.assertFalse(excluded(policy, "database", "downloaded_media.db"))
                self.assertFalse(excluded(policy, "sharedpref", "FlutterSharedPreferences.xml"))
                self.assertTrue(excluded(policy, "sharedpref", "plezy_credentials.xml"))

    def test_manifest_uses_the_tested_policies(self):
        app = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml").getroot().find("application")
        android = "{http://schemas.android.com/apk/res/android}"
        self.assertEqual(app.attrib[android + "fullBackupContent"], "@xml/credential_backup_rules")
        self.assertEqual(app.attrib[android + "dataExtractionRules"], "@xml/credential_data_extraction_rules")


if __name__ == "__main__":
    unittest.main()
