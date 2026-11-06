#!/usr/bin/env bash
# Shared by release packaging and CI's package smoke build.
set -euo pipefail

bundle="${1:?usage: prepare-bundle-launcher.sh BUNDLE_DIRECTORY}"
packaging="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$bundle/pleazyng" ]]; then
    echo "Missing Pleazyng executable in release bundle: $bundle" >&2
    exit 1
fi
install -m755 "$packaging/pleazyng.sh" "$bundle/pleazyng.sh"
