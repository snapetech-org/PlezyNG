#!/usr/bin/env python3
"""Guard the release-tag flow in update-packages.yml against regressions."""

from pathlib import Path
import re
import sys

from workflow_yaml import job_block


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/update-packages.yml"
text = WORKFLOW.read_text(encoding="utf-8")
errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def job(name: str) -> str:
    block = job_block(text, name)
    require(bool(block), f"missing {name} job")
    return block


require(
    re.search(
        r"(?ms)^  workflow_dispatch:\n    inputs:\n.*?^      release_tag:\n"
        r".*?^        required: true$",
        text,
    )
    is not None,
    "workflow_dispatch must require release_tag",
)
require("github.ref_name" not in text, "release tags must never fall back to a branch")
require(
    text.count("github.event.release.tag_name") == 1,
    "only the resolver may read the release event tag",
)

resolver = job("resolve-release")
require("gh release view \"$REQUESTED_TAG\"" in resolver, "resolver must validate the tag")
require("--json tagName,isDraft,isPrerelease,publishedAt" in resolver, "resolver must require a published release")
require('if [ "$IS_PRERELEASE" != "false" ]; then' in resolver, "resolver must reject a pre-release tag")
require(
    "tag: ${{ steps.release.outputs.tag }}" in resolver,
    "resolver must expose one validated tag output",
)

homebrew = job("update-homebrew")
require(
    'hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" pleazyng-macos.dmg' in homebrew
    and 'codesign --verify --deep --strict' in homebrew
    and 'identifier "org.snapetech.pleazyng"' in homebrew
    and 'xcrun stapler validate "$app"' in homebrew
    and 'spctl --assess --type execute --verbose "$app"' in homebrew,
    "Homebrew must verify the mounted app signature, stapled ticket and Gatekeeper acceptance",
)
require(
    'verify_release_attestation.py" snapetech-pleazyng.rb' in homebrew
    and 'verify_release_attestation.py" SHA256SUMS.txt' in homebrew
    and '--repository-output "$RUNNER_TEMP/cask-publisher-repository.txt"' in homebrew
    and '--publisher-repository-file "$RUNNER_TEMP/cask-publisher-repository.txt"' in homebrew,
    "Homebrew must verify both artifacts and preserve their verified publisher identity",
)
require(
    "repository: snapetech-org/homebrew-pleazyng" in homebrew,
    "Homebrew publisher must target the dedicated Pleazyng tap",
)
require("update-appcast-branch:" not in text, "legacy appcast branch publishing must stay retired")
require("refs/heads/appcast" not in text, "updater feeds must not recreate a mutable branch")
require(
    "update-winget:" not in text,
    "the inherited upstream WinGet publisher must stay removed",
)
for stale_upstream in ("WINGET_TOKEN", "edde746.Plezy", "winget-releaser"):
    require(
        stale_upstream not in text,
        f"obsolete upstream package reference remains: {stale_upstream}",
    )
for name, block in (
    ("update-homebrew", homebrew),
):
    require("needs: resolve-release" in block, f"{name} must depend on the resolver")
require(
    "homebrew_enabled: ${{ steps.release.outputs.homebrew_enabled }}" in resolver
    and "if: needs.resolve-release.outputs.homebrew_enabled == 'true'" in homebrew,
    "Homebrew Cask updates must wait for Developer ID signing and notarization credentials",
)

for name, block in (
    ("resolve-release", resolver),
    ("update-homebrew", homebrew),
):
    require(
        re.search(r"(?m)^    permissions:", block) is not None,
        f"{name} must declare its GITHUB_TOKEN permissions",
    )
resolved_output = "${{ needs.resolve-release.outputs.tag }}"
require(f"RELEASE_TAG: {resolved_output}" in homebrew, "Homebrew must use the resolved tag")
require(
    re.search(r'gh release download "\$RELEASE_TAG"\s+--repo "\$GITHUB_REPOSITORY"', homebrew) is not None,
    "Homebrew must download from this repository",
)
require(
    "pleazyng-macos.dmg" in homebrew and "plezyng-macos.dmg" not in homebrew and "plezy-macos.dmg" not in homebrew,
    "Homebrew must download the exact DMG filename published by build.yml",
)
require(
    "github.com/edde746/plezy" not in text,
    "package workflow must not target upstream releases",
)
require(
    re.search(r'git commit -m "[^"\n]*\$RELEASE_TAG[^"\n]*"', homebrew) is not None,
    "Homebrew commit text must include the resolved tag",
)

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)

print("update-packages workflow release-tag checks passed")
