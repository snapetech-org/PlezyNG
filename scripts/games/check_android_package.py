#!/usr/bin/env python3
"""Verify the Steam receiver in a final APK/AAB, without claiming device acceptance."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

from build_steam_android import ABIS, ROOT, inspect_elf, write_report

# Public NDK platform libraries used by the receiver. All other DT_NEEDED
# entries must be shipped beside it, including libc++_shared.so.
SYSTEM_LIBRARIES = frozenset({
    "libandroid.so", "liblog.so", "libmediandk.so", "libvulkan.so",
    "libc.so", "libm.so", "libdl.so", "libz.so", "libEGL.so", "libGLESv2.so",
})
MAX_LIBRARY_BYTES = 256 * 1024 * 1024


def check_package(package: Path, abis: set[str], readelf: Path,
                  zipalign: Path | None, *, disabled: bool = False) -> dict:
    if package.suffix not in (".apk", ".aab"):
        raise ValueError("Expected an APK or AAB")
    if not abis or not abis <= ABIS.keys():
        raise ValueError("Specify the exact expected application ABI set")
    is_apk = package.suffix == ".apk"
    prefix = "lib/" if is_apk else "base/lib/"
    source = (ROOT / "android/steam/src/main/java/org/snapetech/plezyng/games/steam/NativeSteam.java").read_text()
    methods = re.findall(r"\bstatic\s+native\s+[\w\[\]]+\s+(\w+)\s*\(", source)
    if not methods:
        raise ValueError("NativeSteam contract is empty")
    exports = {"JNI_OnLoad", *("Java_org_snapetech_plezyng_games_steam_NativeSteam_" + name for name in methods)}
    artifacts = []
    with zipfile.ZipFile(package) as archive, tempfile.TemporaryDirectory(prefix="steam-package-") as temporary:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise ValueError("Package contains duplicate ZIP entries")
        receivers = {name for name in names if name.endswith("/libplezy_steam.so")}
        expected = set() if disabled else {f"{prefix}{abi}/libplezy_steam.so" for abi in abis}
        if receivers != expected:
            raise ValueError(f"Receiver entries differ: missing={sorted(expected - receivers)}, unexpected={sorted(receivers - expected)}")
        # Flutter's engine determines which ABIs the application can actually run.
        engines = {name for name in names if name.endswith("/libflutter.so")}
        if engines != {f"{prefix}{abi}/libflutter.so" for abi in abis}:
            raise ValueError("Flutter engine ABI set does not match expected application ABIs")
        for name in sorted(receivers):
            entry = archive.getinfo(name)
            if entry.flag_bits & 1 or not 0 < entry.file_size <= MAX_LIBRARY_BYTES:
                raise ValueError("Encrypted, empty or oversized receiver library")
            abi = name.split("/")[-2]
            binary = Path(temporary) / "libplezy_steam.so"
            # Never extract archive-supplied paths into the filesystem.
            data = archive.read(entry)
            binary.write_bytes(data)
            detail = subprocess.check_output([
                str(readelf), "--wide", "--file-header", "--program-headers",
                "--dynamic", "--dyn-syms", str(binary)], text=True)
            inspect_elf(detail, abi, exports)
            needed = set(re.findall(r"\(NEEDED\).*\[([^\]]+)\]", detail))
            for library in needed - SYSTEM_LIBRARIES:
                if "/" in library or "\\" in library or f"{prefix}{abi}/{library}" not in names:
                    raise ValueError(f"Missing packaged runtime dependency for {abi}: {library}")
                dependency = archive.getinfo(f"{prefix}{abi}/{library}")
                if dependency.file_size == 0 or dependency.flag_bits & 1:
                    raise ValueError(f"Invalid packaged runtime dependency: {library}")
            artifacts.append({"abi": abi, "file": name, "sha256": hashlib.sha256(data).hexdigest(),
                              "bytes": len(data), "jniExportsChecked": len(exports),
                              "needed": sorted(needed)})
    if is_apk:
        if zipalign is None:
            raise ValueError("APK verification requires Android build-tools zipalign")
        subprocess.run([str(zipalign), "-c", "-P", "16", "4", str(package)], check=True)
    # Stream the package hash: release bundles can be much larger than a library.
    digest = hashlib.sha256()
    with package.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"schema": 1, "status": "passed", "package": package.name,
            "sha256": digest.hexdigest(), "embeddedEnabled": not disabled,
            "expectedAbis": sorted(abis), "artifacts": artifacts,
            "apkAlignmentChecked": is_apk, "deviceTested": False,
            "signatureVerified": False, "bundleGeneratedApksChecked": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--abi", choices=ABIS, action="append", required=True)
    parser.add_argument("--readelf", type=Path, required=True)
    parser.add_argument("--zipalign", type=Path)
    parser.add_argument("--disabled", action="store_true")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = {"schema": 1, "status": "running", "deviceTested": False}
    write_report(args.report, report)
    try:
        report = check_package(args.package, set(args.abi), args.readelf, args.zipalign, disabled=args.disabled)
    except Exception as error:
        report.update(status="failed", error=str(error))
        raise
    finally:
        write_report(args.report, report)


if __name__ == "__main__":
    main()
