#!/usr/bin/env python3
"""Install the shared repository policy for all Gradle builds in this job."""

import os
import re
import tempfile
from pathlib import Path


POLICY = Path(__file__).with_name("gradle") / "plezyng-maven-mirror.init.gradle"


def configure_ci_watching(gradle_home: Path) -> Path:
    """Avoid duplicate watches on Flutter's included build in ephemeral CI."""
    target = gradle_home / "gradle.properties"
    if gradle_home.is_symlink() or target.is_symlink() or (target.exists() and not target.is_file()):
        raise RuntimeError("Refusing an unexpected Gradle properties path.")
    if target.exists() and target.stat().st_uid != os.geteuid():
        raise RuntimeError("The existing Gradle properties belong to another user.")
    contents = target.read_text() if target.exists() else ""
    contents = re.sub(r"(?m)^[ \t]*org\.gradle\.vfs\.watch(?:[ \t]*[=:][ \t]*|[ \t]+)[^\r\n]*(?:\r?\n|$)", "", contents)
    contents = contents.rstrip("\r\n") + "\norg.gradle.vfs.watch=false\n"
    gradle_home.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=gradle_home, prefix=".pleazyng-properties-", delete=False) as output:
            temporary = Path(output.name)
            output.write(contents.encode())
        temporary.chmod(0o600)
        temporary.replace(target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return target


def install(gradle_home: Path) -> Path:
    init_dir = gradle_home / "init.d"
    if gradle_home.is_symlink() or init_dir.is_symlink():
        raise RuntimeError("Refusing to replace a symlinked Gradle init directory.")
    init_dir.mkdir(parents=True, exist_ok=True)
    target = init_dir / POLICY.name
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise RuntimeError("Refusing to replace an unexpected Gradle policy path.")
    if target.exists() and target.stat().st_uid != os.geteuid():
        raise RuntimeError("The existing Gradle policy belongs to another user.")
    contents = POLICY.read_bytes()
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=init_dir, prefix=".pleazyng-mirror-", delete=False) as output:
            temporary = Path(output.name)
            output.write(contents)
        temporary.chmod(0o600)
        temporary.replace(target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return target


if __name__ == "__main__":
    root = Path(os.environ.get("GRADLE_USER_HOME", str(Path.home() / ".gradle"))).expanduser()
    print(f"Installed Gradle Maven Central mirror policy: {install(root)}")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        configure_ci_watching(root)
        print("Disabled Gradle file-system watching for the ephemeral CI build.")
