#!/usr/bin/env python3
"""Run the credential-free extras service suite in the shared CI guard lane."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

if __name__ == "__main__":
    suite = unittest.defaultTestLoader.discover(
        str(ROOT / "tools" / "extras_service"), pattern="test_*.py"
    )
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
