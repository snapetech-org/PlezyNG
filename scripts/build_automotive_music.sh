#!/usr/bin/env bash
# Build the independent host-rendered AAOS media APK from the shared app.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export ORG_GRADLE_PROJECT_pleazyngAutomotiveMedia=true
exec flutter build apk "$@"
