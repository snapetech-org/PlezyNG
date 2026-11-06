#!/usr/bin/env python3
"""Record the embedded runtime after nested-code signing, before app sealing."""

import hashlib
import json
from pathlib import Path
import sys


def finalize(app: Path) -> dict:
    path = app / "Contents/Resources/playback-notices/luajit-runtime.json"
    library = app / "Contents/Frameworks/libplezy_luajit.dylib"
    receipt = json.loads(path.read_text())
    receipt.setdefault("buildEmbeddedLibrarySha256", receipt["embeddedLibrarySha256"])
    receipt["embeddedLibrarySha256"] = hashlib.sha256(library.read_bytes()).hexdigest()
    receipt["signatureStage"] = "final nested-code signing"
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


if __name__ == "__main__":
    finalize(Path(sys.argv[1]))
