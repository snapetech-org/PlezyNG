"""Install the locked Rust manager in a new disposable webOS job directory.

No image-provided rustup, shared toolchain cache, shell profile, or sudo required.
The compiler and target remain independently pinned by milkrustBuild.
"""

import hashlib
import json
import os
import platform
from pathlib import Path
import re
import subprocess
import sys
import urllib.request


LOCK = Path(__file__).with_name("compatibility.json")


def download(url, destination):
    with urllib.request.urlopen(url, timeout=120) as response:
        with destination.open("xb") as output:
            size = 0
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > 64 * 1024 * 1024:
                    raise ValueError("Rust installer exceeds the 64 MiB limit")
                output.write(chunk)


def bootstrap(task_root, lock_path=LOCK):
    root = Path(task_root)
    if root.is_symlink() or not root.is_dir() or root != root.resolve():
        raise ValueError("Rust bootstrap requires an existing real absolute task directory")
    if (platform.system(), platform.machine()) != ("Linux", "x86_64"):
        raise ValueError("The locked Rust bootstrap requires Linux x86_64")
    lock = json.loads(Path(lock_path).read_text())["rustupBootstrap"]
    version, host, checksum = lock["version"], lock["host"], lock["sha256"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or host != "x86_64-unknown-linux-gnu":
        raise ValueError("Invalid Rust bootstrap version or host lock")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("Invalid Rust bootstrap SHA-256 lock")
    # Exclusive creation rejects stale outputs and symlinks, including broken ones.
    installer_dir = root / "rustup-bootstrap"
    installer_dir.mkdir(mode=0o700)
    rustup_home, cargo_home = root / "rustup-home", root / "cargo-home"
    rustup_home.mkdir(mode=0o700)
    cargo_home.mkdir(mode=0o700)
    installer = installer_dir / "rustup-init"
    download(f"https://static.rust-lang.org/rustup/archive/{version}/{host}/rustup-init", installer)
    if hashlib.sha256(installer.read_bytes()).hexdigest() != checksum:
        raise ValueError("Rust installer SHA-256 differs from the committed lock")
    installer.chmod(0o700)
    env = os.environ.copy()
    env.update(RUSTUP_HOME=str(rustup_home), CARGO_HOME=str(cargo_home))
    subprocess.run(
        [str(installer), "-y", "--no-modify-path", "--profile", "minimal",
         "--default-toolchain", "none"],
        env=env, check=True, stdout=sys.stderr,
    )
    rustup = cargo_home / "bin" / "rustup"
    result = subprocess.run(
        [str(rustup), "--version"], env=env, check=True,
        capture_output=True, text=True,
    )
    if not result.stdout.startswith(f"rustup {version} "):
        raise ValueError("Installed Rust manager differs from the committed version")
    return rustup


if __name__ == "__main__":
    print(bootstrap(sys.argv[1]))
