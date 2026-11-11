# Apple Store signing

The existing Apple Distribution identity is usable. Native macOS qualification imported the configured PKCS12, verified the private key against its certificate, signed a small executable and passed strict signature verification. No certificate was issued or revoked. The final [native preflight](https://github.com/snapetech-org/pleazyng/actions/runs/42169674435) also passed all three new profiles and both actual projects’ signing bindings; its [bounded report](qualification/apple-signing-20261105.json) is retained. This checks signing material, not a complete app archive, App Store processing or purchase behavior.

The original PKCS12 required a compatible SHA1/3DES re-encoding for Security.framework. The isolated keychain also needs the checksum-pinned official Apple WWDR G3 intermediate and membership in the user keychain search list. `scripts/apple_signing_material.py` provides the same verified context for the preflight and release jobs, restores the original search list, deletes its keychain and removes task-owned temporary material. It never changes the default keychain or system trust.

## Required secrets

- `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `TVOS_PROVISIONING_PROFILE_BASE64`
- `TVOS_TOPSHELF_PROVISIONING_PROFILE_BASE64`

Profiles must name `org.snapetech.pleazyng` for iOS/tvOS and `org.snapetech.pleazyng.TopShelfExtension` for Top Shelf, the correct platform, the imported certificate, and `group.org.snapetech.pleazyng`. Expired, development, ad-hoc, enterprise, other-team and old-bundle profiles fail validation. The old PlezyNG profiles are preserved for dependency review.

`apple-signing-preflight.yml` is manual, restricted to main and runs on hosted native macOS. Its artifact contains only bounded public certificate/profile fields. It checks the actual three profile bindings and the selected Release target settings. Do not upload keys, PKCS12 files, profile payloads or private working directories as artifacts.

## Store archive path

Keep `include_apple_store_build=true` for the first coordinated signed qualification run. The unsigned developer IPA remains separate. `build_apple_store_archive.py` imports the signing identity in a scoped context, validates and temporarily installs profiles, applies distinct manual Release signing settings to Runner and TopShelfExtension, archives and exports with an explicit profile map. It restores the original project bytes and removes only profiles it created. Existing installed profiles are preserved. iOS Store compilation explicitly selects trial/IAP mode and disables the direct-download update check; tvOS's native AOT build already selects IAP mode.

The helper's public receipt records archive/export completion separately from purchase and application qualification. Run the exact intended release revision through the existing coordinated full build; do not dispatch a duplicate matrix just for these secrets. A signed IPA must still process in App Store Connect and pass actual device, StoreKit purchase/restore, reviewer-access and screenshot checks. `APPLE_STORE_UPLOAD_READY` stays false until that signed-build/upload path is verified. Upload automation is separate from TestFlight tester invitations and App Review submission.

App Store Connect API credentials remain required for uploads. Mac direct Developer ID signing uses its separate `MACOS_CERTIFICATE_*` secrets. A Mac App Store sandbox package is still a separate implementation and qualification task.

The explicit `publish-app-stores.yml` Apple lanes inspect the checksum-verified,
attested IPA's bundle, platform, marketing version, and build number before
upload. They target the existing App Store Connect app ID `6826955231`, reuse
an already valid exact version/build without a duplicate upload, and wait up to
15 minutes for a new upload to reach `VALID`. `FAILED`, `INVALID`, duplicate,
or mismatched records fail closed. The workflow retains a public processing
receipt with the release IPA hash and GitHub run identity. App Store Connect
does not expose an IPA hash for an already existing build, so that receipt
marks reused builds as a version/build identity match. Upload success and
processing do not create a matching draft version, invite TestFlight users,
or submit App Review.
