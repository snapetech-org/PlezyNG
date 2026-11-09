#!/usr/bin/env bash
# Single source of truth for workflow/script guards, shared by CI and
# scripts/ci_checks.sh. Regression tests use a glob so new test_checkers are
# picked up automatically; checkers requiring Bun or built packages run in
# their owning jobs as well.
set -euo pipefail
shopt -s nullglob

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 tools/webos/verify_package.py --project-metadata
webos_test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/pleazyng-webos-package-tests.XXXXXXXX")"
if PLEZY_WEBOS_TEST_TMP="$webos_test_tmp" python3 -m unittest discover -s tools/webos/tests; then
  rmdir "$webos_test_tmp" || echo "Retained WebOS test scratch: $webos_test_tmp"
else
  echo "Retained WebOS test scratch after failure: $webos_test_tmp" >&2
  exit 1
fi

for checker in \
  scripts/checks/check_rebrand.py \
  scripts/checks/check_deep_link_schemes.py \
  scripts/checks/check_capability_manifest.py \
  scripts/checks/check_build_workflow.py \
  scripts/checks/check_apple_spm_locks.py \
  scripts/checks/check_tvos_test_wiring.py \
  scripts/checks/check_shrinker_rules.py \
  scripts/checks/verify_runtime_inputs.py \
  scripts/checks/check_workflow_security.py \
  scripts/checks/check_workflow_action_pins.py \
  scripts/checks/check_container_image_pins.py \
  scripts/checks/check_update_packages_workflow.py \
  scripts/checks/check_linux_package_deps.py \
  scripts/checks/check_windows_installer.py; do
  python3 "$checker"
done

for guard_test in scripts/test_*.py scripts/*/test_*.py tools/dv-engine/test_apple_runtime.py; do
  # This compiles and executes the native descriptor worker against libretro
  # headers provisioned by its dedicated workflow; it is not a unit guard.
  if [[ "$guard_test" == "scripts/games/test_romm_descriptor_worker.py" ]]; then
    continue
  fi
  PYTHONPATH="$ROOT_DIR:$ROOT_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" python3 "$guard_test"
done
