# Pleazyng release channels

Live account migration is in progress. See [the dated channel migration receipt](pleazyng-channel-migration.json) for verified new records, API access and pending steps. The older readiness snapshots below describe their audit dates and do not prove current publication readiness.

This is the release support boundary for the Pleazyng client and its separate relay service. A client platform or package channel is active when the manual release workflow creates the package and attaches it to a GitHub Release, or when a named publisher workflow submits that release's package.

## Release trigger and order

`.github/workflows/build.yml` is manually dispatched with `action=release`, `runner_pool=private`, and `execution_profile=hybrid` from `main`. The hybrid profile uses compatible GitHub-hosted Linux, Android, Tizen, Windows x64, and native Windows ARM64 runners; Apple and storage-constrained WebOS jobs use private ephemeral JIT. `runner_pool=private` is the broker route for those constrained jobs and does not make the whole workflow private-only. Tag pushes do not start builds. The version tag must match `pubspec.yaml`, and manually dispatched CI must pass on the exact `main` SHA first. An existing immutable tag may be reused only when it is an ancestor of `main` and all intervening changes are allowlisted release infrastructure, tests, changelog, or maintainer documentation. The release workflow builds every platform and checks the assembled assets; `--publish-github-only` publishes only the GitHub Release, while `--publish` also dispatches configured downstream channels.

Push and pull-request CI runs checks; it does not build release packages or publish images. The only package build dispatch is **Pleazyng Release**. With `--publish`, the orchestrator explicitly dispatches configured appcast, Chocolatey, WinGet, Snap Store, AUR, COPR, PPA, relay-container, and app-store upload workflows after the release is published. Discord announcements run automatically for published stable releases, including `--publish-github-only`. Google Play uploads go to the internal draft track; Apple and Amazon uploads do not submit builds for review. Missing credentials or store identities remain skipped and are recorded in the release receipt.

## Client packages on GitHub Releases

| Platform | Architectures | GitHub Release assets |
| --- | --- | --- |
| Windows | x64 and native arm64 for 3.0.0 | x64 Inno Setup installer and portable `.7z`, Chocolatey `.nupkg`, and x64 WinGet manifest bundle. The native `windows-11-arm` runner produces `plezy-windows-arm64-portable.zip`. A Microsoft Store `.msixbundle` is added when the Partner Center package identity is configured. |
| macOS | x64, arm64 | Universal DMG and Sparkle appcast; the Homebrew cask is updated after publication. Developer ID signing and notarization are optional. |
| Linux | x64, arm64 | Portable `.tar.gz`, Debian `.deb`, RPM `.rpm`, Arch `.pkg.tar.zst`, Flatpak bundle, and Snap package for each architecture; an x64 AppImage is also attached. |
| Android | arm64-v8a, armeabi-v7a, x86_64 | Split APK archives. A Play `.aab` and Amazon Fire TV APK are attached when the Android release key is configured. |
| iOS | arm64 | Unsigned developer `.ipa` for inspection; signed App Store `.ipa` is opt-in with `include_apple_store_build=true`. |
| tvOS | arm64 | Unsigned developer `.ipa` for inspection; signed App Store `.ipa` is opt-in with `include_apple_store_build=true`. |
| Samsung Tizen TV | ARM | Development-signed tester `.tpk` is attached for qualification and handoff; it needs TV-specific re-signing and does not claim Seller Office approval or publication. |

Every binary/package release asset is listed in `SHA256SUMS.txt`. Build artifacts are covered by GitHub build-provenance attestations; the release checksum list and WinGet manifest bundle are attested during release assembly.

The Android APKs use the configured release key when all Android signing secrets are set. Without that keystore, the workflow falls back to its CI debug key, so those APKs support clean installs but cannot be relied on for in-place upgrades. The store-specific Android artifacts are omitted unless release signing is available. The iOS/tvOS developer IPAs are unsigned and cannot be installed as ordinary store or device builds.

There is no 32-bit x86 desktop package. Android `armeabi-v7a` is the 32-bit ARM target. The Flatpak files are bundles attached to GitHub Releases, not a Flathub publication. The `.msixbundle` is for [Partner Center submission](https://learn.microsoft.com/en-us/windows/apps/publish/); Microsoft signs the package after certification. It is not emitted until the fork's Store package identity is configured. Its version is `<major>.<minor>.<patch>.0`, so each Store release must increment the semantic version; Microsoft reserves the fourth field.

## Fork identity and compatibility

The Android application ID, Apple bundle IDs, Flatpak ID, and Linux desktop entry use `org.snapetech.pleazyng`. The tvOS Top Shelf extension uses `org.snapetech.pleazyng.TopShelfExtension` and the app group is `group.org.snapetech.pleazyng`. This keeps new packages separate from upstream Plezy's store identities. The internal Android Kotlin namespace remains `com.edde746.plezy`.

Changing the install IDs means an install signed under upstream's identity cannot be updated by Pleazyng. Store users need Pleazyng's own listings and signing keys. New packages register `pleazyng://` and the explicit legacy fork aliases, with upstream `plezy://` registration removed.

## Package managers and stores

| Channel | State | How it works |
| --- | --- | --- |
| GitHub Releases | Active | Dispatch the hybrid `Pleazyng Release` workflow from `main` for a `v<major>.<minor>.<patch>` tag after CI passes on that exact main SHA. Compatible jobs use GitHub-hosted runners; Apple and storage-constrained WebOS jobs use private JIT. Tag pushes do not start jobs. The workflow checks every required artifact before the draft is promoted with `--publish-github-only` or `--publish`. The webOS IPK stays out until its separate artifact and redistribution gates are approved. |
| Homebrew and Sparkle | Partially configured | `update-packages.yml` updates the appcast after a published release. Homebrew Cask is skipped until Developer ID signing and notarization credentials are configured. |
| WinGet | Wired, credential-gated | `publish-winget.yml` submits fork-specific manifests as a pull request. Microsoft review and merge are still required. |
| Chocolatey | Wired, credential-gated | `publish-chocolatey.yml` publishes the fork-specific package after a release. Chocolatey moderation may be required. |
| Microsoft Store | Package prepared, listing identity required | Set the repository variables below to build `plezyng-windows.msixbundle`; submit it through Pleazyng's Partner Center listing. The optional signed Inno Setup installer is also retained for manual EXE/MSI listing workflows. No automated Partner Center submission is configured. |
| Samsung Smart TV (Tizen) | Experimental ARM tester candidate included in versioned builds; Seller Office package and device qualification remain pending | The hybrid Pleazyng Release builds a development-signed ARM TPK on compatible hosted Ubuntu and retains it as an experimental Actions artifact. The build bootstraps a pinned Linux SDK and requires acceptance of Samsung's SDK and extension licenses. The tester package needs re-signing for a specific Samsung TV and is not Seller Office-ready. Seller Office handoff remains disabled; x64 emulator packages are excluded. |
| LG Content Store (webOS) | ARM candidate built in versioned runs; public artifact/release inclusion and runtime redistribution remain gated | Pleazyng Release builds and verifies the experimental ARM IPK on the private JIT runner by default. The IPK stays in that ephemeral workspace unless a separate explicit input and exact-candidate gates approve a draft release; vendor submission remains manual. |
| Google Play | Closed testing - Alpha configured; build 156 is a draft and the track is inactive | Data safety, the default listing, category/contact details, 178 regions, and the five-member `Pleazyng Alpha testers` email list are saved. The dedicated Google Cloud project and Android Publisher API are enabled; service account access is limited to this app's testing tracks, with production publishing disabled. `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` is configured. Build 157 is being prepared in [release run 40272007783](https://github.com/snapetech-org/PlezyNG/actions/runs/40272007783); replace the existing draft with its signed AAB, preview it, and send the closed test for review. The README opt-in URL is inactive until rollout. At least 12 testers must remain opted in continuously for 14 days before production access. |
| Amazon Appstore / Fire TV | App record and listing metadata prepared; binary and IAP test remain blocked | `plezyng_lifetime_unlock` is saved at a USD $2.99 base price; Amazon calculates local-market equivalents. The Amazon public key is in the Android assets. A new Amazon security profile is mapped to App Submission API and its credentials are configured in GitHub Actions. The category, 18+ target audience, content rating, privacy URL, description, icons, feature art, and screenshots are complete; the privacy questionnaire is saved for review. Amazon still returns a generic error when the IAP is submitted to Test, no Fire TV APK has been uploaded, and the export-compliance certification remains to be completed before submission. |
| Apple App Store (iOS) | App record and lifetime IAP created; cloud-signing build configured, not yet validated; TestFlight setup incomplete | `plezyng_lifetime_unlock` is a non-consumable with a USD $2.99 base price and a price schedule for 175 regions. English (Canada) copy is present. It remains Prepare for Submission. The previous 2.24.1 workflow failed while importing the manual PKCS#12. Apple has three active Apple Distribution certificates and disables creating another one, so the release workflow uses Xcode cloud signing through the existing App Store Connect API key and managed certificate. The next release build must verify signing before this channel is considered ready. |
| Apple App Store (tvOS) | App record created; cloud-signing build configured, not yet validated | The app's iOS and tvOS platforms can share the lifetime IAP. The previous 2.24.1 workflow failed while importing the manual PKCS#12. The updated workflow uses Xcode cloud signing for both the app and Top Shelf extension. The next release build must verify signing before this channel is considered ready. |
| Mac App Store | Not a Plezy upstream channel | Plezy distributes macOS through a direct DMG and Homebrew. |
| Snap Store | Pleazyng registered; scoped credential configured; first upload pending | `publish-snap.yml` uploads the matching architecture package to `stable` after a published release. `SNAPCRAFT_STORE_CREDENTIALS` was reissued on 2026-11-05 for `pleazyng` only, with package access/upload/release permissions on all four channels and a 365-day lifetime. The unused old snap is private. Listing edits require the first build. Manual dispatch can publish an existing release to `edge`, `beta`, `candidate`, or `stable`. |
| AUR | Wired, package and credential-gated | `publish-aur.yml` updates the binary package recipe after a published release. Set `AUR_PACKAGE_NAME` and `AUR_SSH_KEY`; the first valid recipe push creates a new AUR package. The current target is `pleazyng-bin` (see the migration receipt). |
| Fedora COPR | Pleazyng project registered; first release upload pending | `publish-copr.yml` builds an SRPM from the checked release bundles and submits it to `COPR_PROJECT`. The target is `slskdn/pleazyng`, configured for Fedora 43–45 and Rawhide on x86_64 and aarch64. The empty old `slskdn/plezyng` project was deleted on 2026-11-05. |
| Launchpad PPA | Pleazyng archive registered; first source upload pending | `publish-ppa.yml` signs and uploads source packages for Jammy and Noble after a published release. `LAUNCHPAD_PPA` is `ppa:keefshape/pleazyng`, enabled for amd64 and arm64, using the existing Launchpad-registered `GPG_PRIVATE_KEY`. Deletion of the empty old archive was confirmed by Launchpad on 2026-11-05. |
| Flathub | Not submitted | The attached Flatpak bundles use the prebuilt Linux bundle. Flathub requires its own source-built manifest submission and reviewer approval; it is not an automatic upload channel. |

The app-store workflow does not build packages or submit store reviews. Run it from `main`, select a release tag, and choose a channel. It accepts a draft GitHub Release for Google Play internal/closed testing tracks, Amazon binary uploads, and iOS/tvOS App Store Connect build uploads. Production Play uploads still require a published stable GitHub Release. The workflow sends binaries only, with no listing metadata or screenshots. Samsung and LG TV handoff bundles use separate build outputs and must be uploaded through Seller Office or Seller Lounge manually; neither workflow claims an automated vendor-store submission. TV screenshots must be captured from the target device.

For Google Play testing, select the `alpha` track (closed testing) and a signed AAB from the draft release; use release status `completed` to make it available to the invited test group after Google's review. The Alpha track has 178 regions and the five-member `Pleazyng Alpha testers` email list selected. Data safety and the default store listing are saved, and the feedback link points to GitHub Issues. Draft build 156 remains in the track; replace it with build 157 from the current release run, preview it, and send it to Google for review. The tester opt-in URL is `https://play.google.com/apps/testing/org.snapetech.plezyng`; it becomes active after rollout and only invited accounts can join. Keep at least 12 testers opted in for 14 continuous days before applying for production access. The README should keep the link marked inactive until rollout is complete.

Google Play's foreground-service declaration has separate app-use videos: [user-initiated data sync](https://drive.google.com/file/d/1UEftKbXx23gz0tCdySJ8ceySXHX655_M/view?usp=drive_link) and [user-started media playback](https://drive.google.com/file/d/14CIjy5f6Xd528IOdrE30Ln2fmGj-hr3Z/view?usp=drive_link). They are silent recordings of the app on an Android device, with no narration or slides. Google's [foreground-service guidance](https://support.google.com/googleplay/android-developer/answer/13392821?hl=en) asks each video to demonstrate the in-app steps that trigger its declared feature.

The GitHub-only release uses the unsigned developer iOS and tvOS IPAs. Signed App Store IPAs require the explicit `include_apple_store_build=true` input and are needed only for App Store Connect upload workflows. Keep that input false until the signed archive and export path passes a release build; the current automatic-signing attempt failed because Apple reported a missing certificate private key and missing provisioning profiles. App Store Connect uploads do not submit builds for review or configure TestFlight groups. App Store Connect processes uploads before they become available for testing. Create TestFlight groups and provide beta test information; internal testers can then receive invitations. The first external TestFlight build must be approved by TestFlight App Review before external testing starts. Add a public TestFlight link to the README when the external group is ready. See Apple's [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/), [API key setup](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/), and [App Store provisioning profiles](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/).

Store builds apply the same access rule on Google Play, Apple App Store, and Amazon Appstore: the app automatically starts a device-local seven-day full-access trial on first launch, then requires one one-time lifetime purchase. Each store sells only the lifetime unlock at a USD $2.99 base price; the app displays the store's localized price.

The upstream [Plezy download guide](https://github.com/edde746/plezy#download) also lists Arch, Fedora/RHEL, Nix, and aerynOS channels. Pleazyng now publishes to AUR, COPR, and Launchpad PPA when their accounts are configured. Nix and aerynOS remain community-maintained package channels; Flatpak remains a GitHub bundle until a source-built Flathub submission is accepted.

## Required configuration

All credentials belong in GitHub Actions secrets or variables. Never put secret values in this document.

For iOS and tvOS signing, the App Store Connect `.p8` key is supplied as the raw PEM value in `APPLE_API_PRIVATE_KEY`. The release workflow leaves signed App Store IPAs disabled by default; set `include_apple_store_build=true` only after confirming Apple signing can archive and export both bundle IDs. The MSIX identity values must match the package identity Microsoft assigns to the Pleazyng Partner Center listing.

| Channel | Secret names / repository variables |
| --- | --- |
| Android release signing (APKs, Play AAB, Amazon APK) | `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS` |
| Samsung TV build | Versioned builds bootstrap a pinned Linux ARM SDK and create a development tester profile. A TV-authorized package requires `tester_build=false`, a Samsung TV certificate profile and the encrypted `SAMSUNG_TIZEN_PROFILE_ARCHIVE_B64` secret; keep certificate and private-key material on the runner. |
| Google Play submission | `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` |
| Amazon Appstore submission | `AMAZON_APPSTORE_CLIENT_ID`, `AMAZON_APPSTORE_CLIENT_SECRET` |
| iOS App Store signing and App Store Connect submission | `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_PRIVATE_KEY`, `APPLE_TEAM_ID` |
| tvOS App Store signing and App Store Connect submission | `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_PRIVATE_KEY`, `APPLE_TEAM_ID` |
| Microsoft Store EXE installer signing | `WINDOWS_SIGNING_CERTIFICATE_BASE64`, `WINDOWS_SIGNING_CERTIFICATE_PASSWORD` |
| Microsoft Store MSIX bundle identity | Repository variables `MSSTORE_PACKAGE_NAME`, `MSSTORE_PUBLISHER`, and `MSSTORE_PUBLISHER_DISPLAY_NAME`, copied exactly from Pleazyng's Partner Center app identity |
| macOS Developer ID signing/notarization | `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` |
| Sparkle / WinSparkle update signatures | Secret `SPARKLE_PRIVATE_KEY`; repository variable `SPARKLE_PUBLIC_KEY` |
| Chocolatey | `CHOCO_API_KEY` |
| WinGet | `WINGET_CREATE_GITHUB_TOKEN` (classic GitHub PAT with `public_repo` scope) |
| Snap Store | `SNAPCRAFT_STORE_CREDENTIALS` (exported Snapcraft credentials scoped to the registered Pleazyng snap and required channels) |
| AUR | `AUR_SSH_KEY` |
| Fedora COPR | `COPR_LOGIN`, `COPR_USERNAME`, `COPR_TOKEN`; repository variable `COPR_PROJECT` |
| Launchpad PPA | `GPG_PRIVATE_KEY`; repository variable `LAUNCHPAD_PPA` in `ppa:<owner>/<archive>` format |
| Relay Docker Hub mirror | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` |

GHCR uses the workflow's `GITHUB_TOKEN`; make the first package public in GitHub Packages settings if anonymous pulls are intended. The Discord publisher uses `DISCORD_RELEASE_WEBHOOK`.

### Automatic Discord announcements

`discord-release.yml` handles `release: published` on compatible hosted Linux.
It reads the published stable release and sends its complete notes in bounded
embeds, with mentions disabled and each response checked. Drafts, prereleases,
foreign release URLs, and feature-branch manual dispatches are rejected.
`publish_github_release()` also explicitly dispatches this workflow because
publication using `GITHUB_TOKEN` does not trigger another workflow's release
event. This applies to GitHub-only publication as well as full channel publication.

Runs serialize by release tag. The release asset
`discord-announcement-receipt.json` records confirmed message IDs after each
chunk; it contains no webhook URL or credentials. Confirmed chunks are skipped
on retries, and definite HTTP rejections leave that chunk retryable. The receipt is also retained as a workflow artifact, including on
failure. If a POST's outcome is uncertain, automation stops instead of repeating
it: inspect the retained receipt and Discord channel, then reconcile the
in-flight entry against the actual message before retrying. Changed release notes
also require reviewing the existing announcement rather than silently reposting.

To announce a previously published release through the same verified route:

```sh
gh workflow run discord-release.yml --repo snapetech-org/PlezyNG --ref main \
  -f action=announce-release -f runner_pool=hosted -f release_tag=v3.0.0
```

At the 2026-10-26 readiness check, repository secrets are configured for Android signing, Google Play,
Amazon Appstore, AUR, Apple App Store Connect API, iOS/tvOS App Store signing, Chocolatey, COPR,
Discord, Docker Hub, Launchpad signing, Snap, Sparkle, and WinGet. The `AUR_PACKAGE_NAME`,
`COPR_PROJECT`, `LAUNCHPAD_PPA`, and `SPARKLE_PUBLIC_KEY` variables are also configured. Google Play
uses the `plezyng-play-release` Cloud project and a dedicated app-level service account; its user
permission allows testing-track releases only. The Android Publisher API is enabled and the
`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` repository secret is present. No production Play permission was
granted.

The Alpha track has 178 regions and a five-member tester list but remains inactive with draft build
156. Release run 40272007783 has passed validation and is building 2.24.1+157 with the refreshed
branding; after it completes, replace the draft with the signed AAB and submit the closed test for
review. The README opt-in URL is not live until rollout, and production access still needs 12 testers
opted in for 14 continuous days.

The old iOS/tvOS build failed during manual PKCS#12 import. The Apple portal disables creation of
another Apple Distribution certificate because the team has reached its certificate limit; no
existing certificate or secret was revoked. The current release workflow uses Xcode cloud signing
through the existing App Store Connect API key. Run 40272007783 will validate access to Apple's
managed certificate and profiles. `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and macOS Developer ID
signing secrets are missing; `APPLE_TEAM_ID` is shared with mobile jobs and is not sufficient for
macOS notarization. Windows installer-signing secrets and Microsoft
Store identity variables are also missing. Keep existing credentials intact when adding
replacements; do not reuse signing keys or store identities from another project.

The `ppa:keefshape/plezyng` archive is active and empty. COPR project `slskdn/plezyng` is active for
Fedora 43–45 and Rawhide on x86_64 and aarch64, with no builds yet. The `plezyng` Snap name is
registered; verify that the existing Snap credential has the package and channel scope required
by the publisher. The Amazon developer account has passed ID verification and a Pleazyng app record
exists. Its `plezyng_lifetime_unlock` entitlement is saved at a USD $2.99 base price; the security
profile is mapped to App Submission API; GitHub secrets `AMAZON_APPSTORE_CLIENT_ID` and
`AMAZON_APPSTORE_CLIENT_SECRET` are configured. The category, age target, content rating, privacy
URL, description, and assets are complete. The IAP remains Ready to Submit after a generic
Test-submission error, the Fire TV APK is not uploaded, and the export-compliance certification is
pending. Google Play's Alpha track has inactive draft build 156, with five testers and 178 regions
configured. Data safety and listing setup are complete; the Play API service account and GitHub
secret are configured with testing-track-only permission. Build 157 with refreshed branding is
running in release workflow 40272007783. The opt-in URL in the README is not live until rollout, and
production access needs 12 testers opted in continuously for 14 days. Apple has iOS and tvOS
records; the USD $2.99 lifetime IAP is configured with a 175-region schedule and remains Prepare for
Submission. App Store Connect API secrets are configured; release run 40272007783 will test cloud
signing access to Apple's managed certificate and profiles.

## Relay containers

The container is only the Go OAuth/artifact relay in `server/`; it is not the Flutter client. After a stable GitHub Release is published, `release-containers.yml` builds `linux/amd64` and `linux/arm64` and publishes version and `latest` tags to GHCR. Docker Hub is a multi-architecture mirror when its credentials are configured. `docker.io` is Docker Hub's registry address, not another registry.

```text
ghcr.io/snapetech-org/plezyng-relay:<version>
ghcr.io/snapetech-org/plezyng-relay:latest
docker.io/snapetech/plezyng-relay:<version>   # when Docker Hub credentials are set
docker.io/snapetech/plezyng-relay:latest      # when Docker Hub credentials are set
```

## Release checklist

1. Update `pubspec.yaml` and add user-facing bullets under `CHANGELOG.md` → `[Unreleased]`.
2. Commit and push the release preparation to `main`.
3. Manually dispatch CI on `main` with `action=ci`, `runner_pool=private`, and `execution_profile=hybrid`; confirm it completed successfully for the exact release commit. Compatible CI jobs use hosted runners while Apple jobs use private JIT.
4. Dispatch **Pleazyng Release** from `main` with `action=release`, `runner_pool=private`, `execution_profile=hybrid`, and the semantic `build_version`. It builds the ARM webOS and Tizen candidates by default. Keep the webOS IPK out of public assets until its separate artifact and redistribution gates pass.
5. Review the draft notes, package list, `SHA256SUMS.txt`, and provenance attestations.
6. Publish the draft. Discord runs automatically; `--publish` additionally dispatches configured downstream package channels.
7. To update a mobile store, run **Publish Pleazyng store builds** manually from `main` after the stable GitHub Release is published, then finish review/promotion in the store console.
8. Submit a configured MSIX bundle manually through Partner Center. Confirm GHCR has both architectures; check Docker Hub, Chocolatey, and WinGet only when their credentials are configured, and track Microsoft's WinGet pull request separately.
