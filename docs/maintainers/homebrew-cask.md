# Homebrew Cask release preparation

The macOS product bundle is `Pleazyng.app`, and the release disk image is `pleazyng-macos.dmg`; the app uses the `org.snapetech.pleazyng` bundle identifier. The release workflow can produce a version-pinned Cask candidate for each stable macOS release. The candidate is generated only when `prepare_homebrew_cask` is enabled for a full release run. To validate the macOS bundle and Gatekeeper without creating a release, dispatch with action `build`, mode `macos-validation`, and `prepare_homebrew_cask` enabled; only the macOS build job runs.

## Release requirements

- The macOS app must be signed with a Developer ID Application certificate, notarized by Apple, stapled, and pass the workflow Gatekeeper assessment.
- Configure `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID` as repository or organization secrets. The ordinary release path stays optional-signing; the Homebrew option fails closed if any signing or notarization credential is missing.
- Dispatch the workflow against a stable `vMAJOR.MINOR.PATCH` tag with action `release` and mode `release`, then enable `prepare_homebrew_cask`.
- The run attaches `snapetech-pleazyng.rb` to the draft release and attests that candidate. Publish the release before submitting or installing the Cask because Homebrew must be able to fetch the versioned DMG from the public release URL.
- Verify the published `pleazyng-macos.dmg` checksum matches the `sha256` in the candidate and confirm the asset URL uses the `vMAJOR.MINOR.PATCH` release tag.

## Official Homebrew submission

Use the generated Cask as `Casks/s/snapetech-pleazyng.rb` in `Homebrew/homebrew-cask`. The `snapetech-` prefix identifies our Cask, which installs the Pleazyng bundle as `Pleazyng.app`.

Before opening a submission, review the current Homebrew Cask acceptance policy and contribution guide. New Casks must pass Gatekeeper without removing quarantine, include the required metadata and zap stanza, and pass the current audit and style checks. Homebrew may decline self-submissions that do not meet its current repository age and popularity criteria. Disclose AI assistance if the current contribution process requests it, and review all generated content yourself.

Run the checks against the generated file in a Homebrew checkout:

```sh
brew audit --cask --new Casks/s/snapetech-pleazyng.rb
brew style --cask Casks/s/snapetech-pleazyng.rb
```

Submit the reviewed Cask to the official `Homebrew/homebrew-cask` repository using its current contribution process. Do not submit the template or a candidate that points to a draft release.

## Generate locally

After a release build has been verified as signed and notarized, the candidate can also be rendered from the release checksum manifest:

```sh
python3 scripts/generate_homebrew_cask.py \
  --version 3.0.1 \
  --checksums artifacts/SHA256SUMS.txt \
  --output artifacts/homebrew/snapetech-pleazyng.rb
```

Replace the example version with the exact stable release version. The generator requires exactly one checksum entry for `pleazyng-macos.dmg` and rejects prerelease or malformed versions.

## Custom tap option

The Update Packages workflow publishes the verified candidate to `Casks/snapetech-pleazyng.rb` in `snapetech-org/homebrew-slskdn`. Configure `HOMEBREW_TAP_TOKEN` with Contents write access limited to that tap repository. Without it, the Homebrew job stays disabled and reports the missing credential; the ordinary repository token cannot write across repositories. The tap currently has no Pleazyng Cask, and no qualified signed/notarized release has been published through this path. The workflow must pass on its selected runner before automation is considered verified.

After the first qualified publication, install with `brew install --cask snapetech-org/slskdn/snapetech-pleazyng`. Keep the version and checksum pinned to a published release; do not use a moving `latest` DMG URL.

There is no `plezy` Cask entry: Pleazyng is distributed under the `snapetech-pleazyng` token. Do not add a quarantine-removal postflight. Only publish signed and notarized Pleazyng builds that pass Gatekeeper.
