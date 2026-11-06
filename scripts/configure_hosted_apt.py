#!/usr/bin/env python3
"""Use official HTTPS Ubuntu archives on disposable GitHub-hosted machines."""

import json
from pathlib import Path
import re
import subprocess
import sys


def configure(root: Path, environment: str, architecture: str) -> dict:
    if environment != "github-hosted":
        return {"environment": environment, "changedSources": [], "privateSourcesPreserved": True}
    archive = ("https://ports.ubuntu.com/ubuntu-ports" if architecture == "arm64"
               else "https://archive.ubuntu.com/ubuntu")
    apt = root / "etc/apt"
    sources = {apt / "sources.list"}
    for pattern in ("sources.list.d/*.list", "sources.list.d/*.sources", "apt-mirrors*.txt"):
        sources.update(apt.glob(pattern))
    changed = []
    for path in sorted(sources):
        if not path.is_file():
            continue
        original = path.read_text()
        updated = re.sub(r"https?://azure\.archive\.ubuntu\.com/ubuntu(?=/|\s|$)", archive, original)
        updated = re.sub(r"http://((?:archive|security)\.ubuntu\.com/ubuntu|ports\.ubuntu\.com/ubuntu-ports)(?=/|\s|$)", r"https://\1", updated)
        if updated != original:
            path.write_text(updated)
            changed.append(str(path.relative_to(root)))
    config = apt / "apt.conf.d/99pleazyng-hosted-network"
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n')
    return {"environment": environment, "architecture": architecture, "changedSources": changed,
            "networkConfig": str(config.relative_to(root))}


if __name__ == "__main__":
    environment = sys.argv[1]
    architecture = (subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip()
                    if environment == "github-hosted" else "")
    print(json.dumps(configure(Path("/"), environment, architecture)))
