#!/usr/bin/env python3
"""Fetch the pinned Linux libmpv prefix named by mpv-build.lock.json.

Reads artifacts.linux for this machine's architecture, downloads the asset,
verifies its SHA-256 against the lock before a single byte is extracted, then
untars the self-relocating prefix tree into --dest. Shared by build.yml,
ci.yml, and local packaging builds so the contract lives in one place.
"""

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from maestro.safe_http import safe_urlopen
except ModuleNotFoundError:
    from scripts.maestro.safe_http import safe_urlopen

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = ROOT / "mpv-build.lock.json"
DOWNLOAD_CHUNK_SIZE = 1024 * 1024


def configure_shared_client_sdk(prefix: Path) -> None:
    """Expose the shipped shared client API without producer-only build SDKs.

    mpv's private pkg-config graph includes its Lua headers, shader compiler
    and generated Wayland protocols. Those build-time dependencies are not
    part of libmpv's public opaque-handle API or this shared-only SDK.
    Runtime DT_NEEDED dependencies are still verified and bundled separately.
    """
    candidates = list(prefix.glob('lib/**/pkgconfig/mpv.pc'))
    if len(candidates) != 1:
        raise ValueError('expected exactly one shared libmpv client pkg-config file')
    pc = candidates[0]
    lines = []
    found_libs = False
    for line in pc.read_text().splitlines():
        if line.startswith(('Requires.private:', 'Libs.private:')):
            continue
        if line.startswith('Libs:'):
            line = 'Libs: -L${libdir} -lmpv -Wl,-rpath-link,${prefix}/lib -Wl,-rpath-link,${libdir}'
            found_libs = True
        lines.append(line)
    if not found_libs:
        raise ValueError('shared libmpv client SDK has no library declaration')
    pc.write_text('\n'.join(lines) + '\n')


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Download and verify the locked Linux libmpv prefix."
    )
    parser.add_argument(
        "--lock",
        type=Path,
        default=DEFAULT_LOCK,
        help="path to mpv-build.lock.json (default: the repository lock)",
    )
    parser.add_argument(
        "--dest",
        type=Path,
        default=Path("libmpv-prefix"),
        help="directory to extract the prefix tree into (default: libmpv-prefix)",
    )
    args = parser.parse_args()

    if shutil.which("zstd") is None:
        print(
            "Error: zstd is required to extract the libmpv archive "
            "(install it, e.g. apt-get install zstd)",
            file=sys.stderr,
        )
        return 1

    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    group = lock["artifacts"]["linux"]
    machine = platform.machine()
    entry = group["assets"].get(machine)
    if entry is None:
        print(
            f"Error: {args.lock}: no linux asset for {machine!r} "
            f"(locked: {', '.join(sorted(group['assets']))})",
            file=sys.stderr,
        )
        return 1

    url = f"{group['assetBase']}/{entry['asset']}"
    print(f"fetching {url}", flush=True)
    digest = hashlib.sha256()
    with tempfile.NamedTemporaryFile(suffix=".tar.zst") as archive:
        if url.startswith("https://github.com/snapetech-org/mpv-build/releases/download/"):
            from prepare_native_downloads import prepare_github_url
            prepare_github_url(url, entry["checksum"], Path(archive.name), Path.home() / ".cache/pleazyng-native-downloads")
            with open(archive.name, "rb") as response:
                while chunk := response.read(DOWNLOAD_CHUNK_SIZE):
                    digest.update(chunk)
        else:
            with safe_urlopen(url) as response:
                while chunk := response.read(DOWNLOAD_CHUNK_SIZE):
                    digest.update(chunk)
                    archive.write(chunk)
        archive.flush()
        if digest.hexdigest() != entry["checksum"]:
            print(
                f"Error: {entry['asset']}: SHA-256 {digest.hexdigest()} does not match "
                f"locked {entry['checksum']}",
                file=sys.stderr,
            )
            return 1

        args.dest.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["tar", "--zstd", "-xf", archive.name, "-C", str(args.dest)],
            check=True,
        )
    configure_shared_client_sdk(args.dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
