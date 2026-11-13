# Pleazyng release channels

## v3.0.33 delivery snapshot (2026-11-11)

The [complete 37-asset GitHub Release](https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.33)
is published. AUR, Fedora COPR, Ubuntu PPA (jammy and noble), the initial
Chocolatey submission, WinGet submission, and GHCR/Docker Hub delivery runs
succeeded. Chocolatey publisher [run 43136868515](https://github.com/snapetech-org/pleazyng/actions/runs/43136868515)
submitted 3.0.33; human review requested upstream-author credit and a fork
description. Corrected publisher [run 43321437887](https://github.com/snapetech-org/pleazyng/actions/runs/43321437887)
rebuilt and pushed the same version. The [Chocolatey package page](https://community.chocolatey.org/packages/pleazyng/3.0.33)
now reports `Maintainer updated, waiting for Reviewer`; the current version's
automated checks are pending and moderator approval has not happened. The WinGet
[manifest PR](https://github.com/microsoft/winget-pkgs/pull/478005) still needs
Microsoft acceptance. The Amazon Fire TV build was submitted in the developer
console and is under review; do not repeat its API upload while its bootstrap
flag is false. Snap Store received the arm64 upload but put it in manual review
for interface permissions; the x64 upload is queued behind an earlier review.
Do not discard either review or blindly reupload. Google Play automation
recorded the release as pending because the signed-build purchase/review gate
has not completed and `GOOGLE_PLAY_BOOTSTRAP_COMPLETE` remains false. Apple
App Store upload remains gated by the owner's pending tax information.
Homebrew Cask has no signed/notarized candidate in this release. LG webOS and
Samsung Tizen artifacts are published for tester handoff, with vendor signing
and store qualification still pending. The independent [aerynOS 3.0.33-5
release](https://github.com/snapetech-org/pleazyng-aerynos/releases/tag/main-240994590dd3-r5)
passed native build, Moss upgrade, playback QA, and anonymous installation from
both the live and pinned public feeds in [verification run
43146075189](https://github.com/snapetech-org/pleazyng-aerynos/actions/runs/43146075189).

See [the current publishing readiness matrix](publishing-readiness.md) for business, technical and review gates and staged automation settings.

For the 2026-11-09 Arch/COPR public audit, fork-specific installation paths,
and checksum-pinned Nix recipe preparation, see the
[Linux distribution channel guide](linux-distribution-channels.md).

Live account migration is in progress. See [the dated channel migration receipt](pleazyng-channel-migration.json) for verified new records, API access and pending steps. The older readiness snapshots below describe their audit dates and do not prove current publication readiness.

This is the release support boundary for the Pleazyng client and its separate relay service. A client platform or package channel is active when the manual release workflow creates the package and attaches it to a GitHub Release, or when a named publisher workflow submits that release's package.

## Release trigger and order

Run versioned releases through `scripts/release_all_platforms.py`; tag pushes do not start builds. The release controller validates the exact `main` source and CI, creates or verifies the immutable version tag, dispatches the complete release workflow, verifies every required artifact, and publishes according to the selected option. Its default hybrid profile uses compatible GitHub-hosted runners where available and private JIT for constrained work. Hosted tvOS jobs canceled before runner assignment receive a verified private Apple JIT retry; storage-constrained webOS uses private JIT. Every versioned release includes Android, Linux x64/arm64, Windows x64/arm64, universal macOS, iOS, tvOS, Tizen, and webOS. `--publish-github-only` publishes the core GitHub Release and still starts automatic Play delivery when enabled, aerynOS reconciliation, and the Discord notice unless skipped. `--publish` also dispatches configured manual package and store channels. See [the full release build runbook](full-release-build.md) for the exact process and recovery rules.

Push and pull-request CI runs checks; it does not build release packages or publish images. The only package build dispatch is **Pleazyng Release**. After either publication mode, the controller starts aerynOS reconciliation, automatic Google Play delivery when enabled, and the Discord announcement unless skipped. `--publish` additionally dispatches configured manual Homebrew Cask, Chocolatey, WinGet, Snap Store, AUR, COPR, PPA, relay-container, and app-store upload workflows after the core release is published. The Sparkle `appcast.xml` is generated and delivered as a core GitHub Release asset; there is no appcast publisher workflow. Google Play delivery targets the configured internal testing track; Apple and Amazon uploads do not submit builds for review. Missing credentials, candidate assets, or store identities are recorded as skipped channels in the release receipt.

## Client packages on GitHub Releases

| Platform | Architectures | GitHub Release assets |
| --- | --- | --- |
| Windows | x64 and native arm64 | x64 Inno Setup installer and portable `.7z`, Chocolatey `.nupkg`, and x64 WinGet manifest bundle. The native `windows-11-arm` runner produces `pleazyng-windows-arm64-portable.zip`. A Microsoft Store `.msixbundle` is added when the Partner Center package identity is configured. |
| macOS | x64, arm64 | Universal DMG and Sparkle appcast are core release assets. The Homebrew Cask publishes only when the release includes its attested candidate and signing, notarization, and tap credentials are configured. |
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
| GitHub Releases | Active | Run `scripts/release_all_platforms.py` from the verified checkout for a `v<major>.<minor>.<patch>` release. Compatible jobs use GitHub-hosted runners; hosted tvOS jobs canceled before runner assignment receive a verified private Apple JIT retry, and storage-constrained webOS jobs use private JIT. Tag pushes do not start jobs. The controller checks every required artifact before publication. The v3.0.33 webOS IPK is recorded in the release evidence; future complete versioned releases also include webOS with artifact provenance and package verification. Device and vendor-store qualification are recorded separately. |
| Homebrew and Sparkle | Homebrew 3.0.7 published and natively installed; updater feed is a release asset | The Cask in `snapetech-org/homebrew-pleazyng` passed app signature, notarization ticket and installed-app Gatekeeper checks. New Cask publication requires an attested release candidate plus signing, notarization, and tap credentials; otherwise the release receipt records the skip. Install by its fully qualified Cask name. The Sparkle appcast remains a core release asset, and mutable appcast branch publication is retired. See [channel evidence](releases/v3.0.7-channels.json). |
| WinGet | v3.0.33 manifest submitted; Microsoft review pending | [PR #478005](https://github.com/microsoft/winget-pkgs/pull/478005) is open. `publish-winget.yml` submitted the versioned manifests; merge and public package availability remain separate checks. |
| Chocolatey | Exact v3.0.33 correction pushed on 2026-11-13; reviewer approval pending | Human review requested upstream-author credit and a clear fork description. [Publisher run 43357545060](https://github.com/snapetech-org/pleazyng/actions/runs/43357545060) rebuilt and pushed exact version 3.0.33; checksum and package metadata verification passed. The [Chocolatey package page](https://community.chocolatey.org/packages/pleazyng/3.0.33) reports `Maintainer updated, waiting for Reviewer`; its automated checks are pending and the package is not approved. The corrected package identifies Pleazyng as a fork of Plezy, credits SnapeTech and edde746, retains `slskdn` as owner/author, and keeps `projectSourceUrl` pointed at this source repository. The description names edde746 as the upstream Plezy creator and SnapeTech as the Pleazyng maintainer. |
| Microsoft Store | Package prepared, listing identity required | Set all four repository variables below to build `pleazyng-windows.msixbundle`; the release controller requires the bundle when those values are configured and records it as a manual Partner Center handoff. Partial configuration skips the optional MSIX lane without blocking direct Windows artifacts. The signed Inno Setup installer remains available for manual EXE/MSI listing workflows. No automated Partner Center submission is configured. |
| Samsung Smart TV (Tizen) | Experimental ARM tester candidate included in versioned builds; Seller Office package and device qualification remain pending | The hybrid Pleazyng Release builds a development-signed ARM TPK on compatible hosted Ubuntu and retains it as an experimental Actions artifact. The build bootstraps a pinned Linux SDK and requires acceptance of Samsung's SDK and extension licenses. The tester package needs re-signing for a specific Samsung TV and is not Seller Office-ready. Seller Office handoff remains disabled; x64 emulator packages are excluded. |
| LG Content Store (webOS) | Experimental ARM IPK published in v3.0.33; store submission and broader device qualification remain open | The exact released IPK was installed and launched on a rooted LG C6. Every complete versioned release includes a webOS artifact with verified source provenance and package checks; private JIT supplies the storage-heavy build environment. Device coverage and vendor submission remain separate qualification steps. See [webOS qualification](webos-tv.md). |
| Google Play | Automatic internal-track delivery configured; v3.0.33 code 192 is not delivered and requires Play Console review; installation and review qualification pending | The latest internal-track attempt, [run 43285693893](https://github.com/snapetech-org/pleazyng/actions/runs/43285693893), stopped after Google Play invalidated or expired a prior upload edit. Its receipt matches the immutable v3.0.33 AAB and records an attempted upload, no active edit and no committed distribution. The controller now reports `manual_review` and will not redispatch this version; if a matching non-success run receipt is missing or cannot be verified, it reports `receipt_unavailable` and also withholds automatic dispatch. Failed, cancelled and timed-out publication runs are all checked. Inspect the Play Console before further action. Earlier code 188 attempts, [run 43136364538](https://github.com/snapetech-org/pleazyng/actions/runs/43136364538) and [run 43146206681](https://github.com/snapetech-org/pleazyng/actions/runs/43146206681), were rejected with HTTP 403 because the phone AAB declared Android Auto projection metadata and `android.hardware.type.automotive` together. The phone manifest now leaves the automotive feature to the separate AAOS manifest. Future eligible code must be at least 189. See the [automatic delivery runbook](google-play-release-delivery.md) and [historical v3.0.7 evidence](releases/v3.0.7-channels.json). |
| Amazon Appstore / Fire TV | Existing app renamed and draft listing prepared; first binary pending | `pleazyng_lifetime_unlock` is saved at USD $2.99. New icons, feature art and four authentic TV screenshots are uploaded/validated. First-version submission must use Developer Console; subsequent binary API updates are wired with the existing app ID/security profile. Company conversion, tax/payment verification, qualified APK, declarations and purchase testing remain. |
| Apple App Store (iOS) | New identifiers and lifetime IAP configured; signing and review pending | `org.snapetech.pleazyng`, non-consumable `pleazyng_lifetime_unlock` at USD $2.99 across 175 regions. The existing distribution certificate/private key passed native import, signing and strict verification. New-bundle profiles and isolated manual archive/export signing are configured; full signed IPA qualification remains. No certificate revoked. Paid agreement remains Pending User Info, Canadian tax form has a duplicate-ID error, bank update Processing. Company conversion awaits issued D-U-N-S. |
| Apple App Store (tvOS) | App record created; cloud-signing build configured, not yet validated | The app's iOS and tvOS platforms can share the lifetime IAP. Compatible PKCS12 import and a pinned WWDR G3 chain passed a native signing probe. Separate new-bundle profiles are configured for Runner and TopShelfExtension. The next coordinated release build must verify full archive/export and Store processing before this channel is ready. |
| Mac App Store | macOS 3.0.1 draft added to the existing Pleazyng app; isolated unsigned candidate workflow implemented | The manual candidate workflow creates an unsigned Xcode archive and `productbuild` package with the IAP build mode and Store entitlement file. It is not uploadable or runtime-qualified: distribution signing, sandbox/JIT behavior, StoreKit purchase/restore, authentic captures and Apple review remain. The unlocked direct DMG is separate. |
| Snap Store | v3.0.33 stable delivery blocked by earlier uploads still in Store review | Both architecture jobs in [publisher run 43137401833](https://github.com/snapetech-org/pleazyng/actions/runs/43137401833) reached Snap Store processing, then Snapcraft refused release while previous uploads await review. Inspect the Store review queue and resolve those revisions before retrying delivery from the existing immutable v3.0.33 assets. `publish-snap.yml` uses the package-scoped `SNAPCRAFT_STORE_CREDENTIALS`; manual dispatch can select `edge`, `beta`, `candidate`, or `stable`. Do not claim stable availability from an upload attempt. |
| AUR | Public `pleazyng-bin` package; 3.0.33-3 verified on 2026-11-11 | `publish-aur.yml` updates the [binary package recipe](https://aur.archlinux.org/packages/pleazyng-bin) after a published release. `AUR_PACKAGE_NAME` and `AUR_SSH_KEY` remain required for future updates. Check the live AUR version after each publisher run. |
| Fedora COPR | Public package established; v3.0.33 built on eight Fedora chroots | [Build 11311129](https://copr.fedorainfracloud.org/coprs/build/11311129) succeeded on Fedora 43, 44, 45 and Rawhide for x86_64 and aarch64. Native installation and playback of this exact version remain separate qualification steps. The target is `slskdn/pleazyng`. |
| Launchpad PPA | v3.0.33 re-uploaded as `3.0.33-1ppa3`; binary publication pending Launchpad acceptance | The `1ppa1` binaries were rejected for 1970 file times from the bundled DV runtime, and `1ppa2` was rejected for a regenerated orig tarball. [Publisher run 43247879529](https://github.com/snapetech-org/pleazyng/actions/runs/43247879529) uploaded `1ppa3` for Jammy and Noble with the fixed recipe and the PPA's existing orig tarball; all four amd64/arm64 builds succeeded and were awaiting Launchpad upload processing on 2026-11-12. Confirm published binaries before advertising v3.0.33 installation. To re-upload a release Launchpad already holds, dispatch `publish-ppa.yml` with a higher `ppa_revision`. |
| Flathub | Not submitted; source build is not ready | The current Flatpak lane packages a prebuilt release bundle and fetches several prebuilt native runtime components. A Flathub lane needs offline source builds for the app and native dependencies on x86_64 and aarch64, plus a dependency/license audit and a qualified manifest. Submit it for review only after those checks pass; the GitHub Flatpak bundles remain a separate channel. |

For future Chocolatey releases, keep `projectUrl` on the Pleazyng website,
`projectSourceUrl` on the application source repository, and `packageSourceUrl`
on the Chocolatey recipe. Keep `authors` as `SnapeTech, edde746, slskdn` so the
fork and upstream author are credited while the Chocolatey maintainer account
remains represented; keep `owners` as `slskdn`. The description must explicitly
identify Pleazyng as a fork of Plezy and link to the upstream project. State
that the upstream Plezy project was created by edde746 and Pleazyng is
maintained by SnapeTech; do not imply that edde746 created, contributed to, or
maintains the Pleazyng fork. The release builder and `publish-chocolatey.yml`
validate this metadata. The publisher verifies the attested release checksum
manifest before trusting installer or package bytes; moderation-correction
packages receive their own build-provenance attestation. For a
moderator-requested correction to an already-published GitHub release, dispatch
`publish-chocolatey.yml` with that exact release tag, `rebuild_package=true`, and
`publish=true`; it rebuilds the same package version from the committed recipe
and reuses the release's immutable installer and checksum.

The app-store workflow does not build packages or submit store reviews. Run it from `main`, select a release tag, and choose a channel. It accepts a draft GitHub Release for Google Play internal/closed testing tracks, Amazon binary updates after its first console submission, and iOS/tvOS App Store Connect build uploads. Production Play uploads still require a published stable GitHub Release. The workflow sends binaries only, with no listing metadata or screenshots. Samsung and LG TV handoff bundles use separate build outputs and must be uploaded through Seller Office or Seller Lounge manually; neither workflow claims an automated vendor-store submission. TV screenshots must be captured from the target device.

For Google Play testing, select `alpha` and release status `completed` only after
first console bootstrap and signed-artifact purchase/reviewer-access validation.
The new app is `org.snapetech.pleazyng` (console app `4975934724712317609`), with
178 regions, the renamed existing five-member tester list and
`support@snape.tech` feedback saved. It has no uploaded release. Old package
`org.snapetech.plezyng` and draft build 156 are a separate inactive record; do
not upload another old-package bundle. The new opt-in URL will be
`https://play.google.com/apps/testing/org.snapetech.pleazyng` after rollout.
The account is still Personal and currently shows 12 opted-in testers for 14
continuous days before Production access. Organization conversion is requested,
its website is already verified and its D-U-N-S request is processing; recheck
Production eligibility after Google approves conversion.

Google Play's foreground-service declaration has separate app-use videos: [user-initiated data sync](https://drive.google.com/file/d/1UEftKbXx23gz0tCdySJ8ceySXHX655_M/view?usp=drive_link) and [user-started media playback](https://drive.google.com/file/d/14CIjy5f6Xd528IOdrE30Ln2fmGj-hr3Z/view?usp=drive_link). They are silent recordings of the app on an Android device, with no narration or slides. Google's [foreground-service guidance](https://support.google.com/googleplay/android-developer/answer/13392821?hl=en) asks each video to demonstrate the in-app steps that trigger its declared feature.

The GitHub-only release uses the unsigned developer iOS and tvOS IPAs. Signed App Store IPAs require the explicit `include_apple_store_build=true` input. The existing Apple Distribution identity has passed native import, a signing probe and strict signature verification, and new-bundle profiles are configured. The next coordinated release must qualify complete iOS/tvOS archive/export with these profiles. See [Apple Store signing](apple-store-signing.md). App Store Connect uploads do not submit builds for review or configure TestFlight groups. App Store Connect processes uploads before they become available for testing. Create TestFlight groups and provide beta test information; internal testers can then receive invitations. The first external TestFlight build must be approved by TestFlight App Review before external testing starts. Add a public TestFlight link to the README when the external group is ready. See Apple's [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/), [API key setup](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/), and [App Store provisioning profiles](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/).

Store builds apply the same access rule on Google Play, Apple App Store, and Amazon Appstore: the app automatically starts a device-local seven-day full-access trial on first launch, then requires one one-time lifetime purchase. Each store sells only the lifetime unlock at a USD $2.99 base price; the app displays the store's localized price.

Pleazyng has configured AUR, COPR and Launchpad PPA publishers. The maintained Nix expression and aerynOS preview are separate downstream channels: the [Nixpkgs proposal](linux-distribution-channels.md) awaits maintainer acceptance and full NixOS desktop/hardware playback qualification; aerynOS package `3.0.33-5` passed native build, upgrade, sign-in and playback checks, while [official repository acceptance and physical HDR/FEL output qualification](aerynos-sync.md) remain open. Flatpak remains a GitHub bundle until an offline source-built Flathub manifest is qualified and accepted.

## Required configuration

All credentials belong in GitHub Actions secrets or variables. Never put secret values in this document.

For iOS and tvOS signing, the App Store Connect `.p8` key is supplied as the raw PEM value in `APPLE_API_PRIVATE_KEY`. The release workflow leaves signed App Store IPAs disabled by default; set `include_apple_store_build=true` only after confirming Apple signing can archive and export both bundle IDs. The MSIX identity values must match the package identity Microsoft assigns to the Pleazyng Partner Center listing.

| Channel | Secret names / repository variables |
| --- | --- |
| Android release signing (APKs, Play AAB, Amazon APK) | `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS` |
| Samsung TV build | Versioned builds bootstrap a pinned Linux ARM SDK and create a development tester profile. A TV-authorized package requires `tester_build=false`, a Samsung TV certificate profile and the encrypted `SAMSUNG_TIZEN_PROFILE_ARCHIVE_B64` secret; keep certificate and private-key material on the runner. |
| Google Play submission | `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` |
| Amazon Appstore submission | `AMAZON_APPSTORE_CLIENT_ID`, `AMAZON_APPSTORE_CLIENT_SECRET`; repository variable `AMAZON_APPSTORE_APP_ID` |
| iOS App Store signing and App Store Connect submission | `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `APPLE_TEAM_ID`; uploads additionally require `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_PRIVATE_KEY` |
| tvOS App Store signing and App Store Connect submission | Same distribution certificate/password/team; `TVOS_PROVISIONING_PROFILE_BASE64`, `TVOS_TOPSHELF_PROVISIONING_PROFILE_BASE64`; same API credentials for uploads |
| Microsoft Store EXE installer signing | `WINDOWS_SIGNING_CERTIFICATE_BASE64`, `WINDOWS_SIGNING_CERTIFICATE_PASSWORD` |
| Microsoft Store MSIX bundle identity | Repository variables `MSSTORE_PACKAGE_NAME`, `MSSTORE_PUBLISHER`, and `MSSTORE_PUBLISHER_DISPLAY_NAME`, copied exactly from Pleazyng's Partner Center app identity; `MSSTORE_LIFETIME_PRODUCT_ID` is the assigned 12-character durable add-on Store ID |
| macOS Developer ID signing/notarization | `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_PRIVATE_KEY`, `APPLE_TEAM_ID` |
| Sparkle / WinSparkle update signatures | Secret `SPARKLE_PRIVATE_KEY`; repository variable `SPARKLE_PUBLIC_KEY` |
| Chocolatey | `CHOCO_API_KEY` |
| WinGet | `WINGET_CREATE_GITHUB_TOKEN` (classic GitHub PAT with `public_repo` scope) |
| Snap Store | `SNAPCRAFT_STORE_CREDENTIALS` (exported Snapcraft credentials scoped to the registered Pleazyng snap and required channels) |
| AUR | `AUR_SSH_KEY` |
| Fedora COPR | `COPR_LOGIN`, `COPR_USERNAME`, `COPR_TOKEN`; repository variable `COPR_PROJECT` |
| Launchpad PPA | `GPG_PRIVATE_KEY`; repository variable `LAUNCHPAD_PPA` in `ppa:<owner>/<archive>` format |
| Relay Docker Hub mirror | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` |

GHCR uses the workflow's `GITHUB_TOKEN`; make the first package public in GitHub Packages settings if anonymous pulls are intended. Discord uses `DISCORD_CHANGELOG_WEBHOOK` for #changelogs and the existing `DISCORD_RELEASE_WEBHOOK` for the project channel.

### Automatic Discord announcements

`discord-release.yml` handles `release: published` on compatible hosted Linux.
It reads the published stable release and sends its complete notes in bounded
embeds in #changelogs, with mentions disabled and each response checked. The
project channel receives a link to the first verified note. Until the shared
secret is configured, the existing project webhook receives the notes. Drafts, prereleases,
foreign release URLs, and feature-branch manual dispatches are rejected.
`publish_github_release()` also explicitly dispatches this workflow because
publication using `GITHUB_TOKEN` does not trigger another workflow's release
event. This applies to GitHub-only publication as well as full channel publication.

Runs serialize by release tag. The release asset
`discord-changelog-receipt.json` records confirmed message IDs after each
chunk and the project link. The original single-channel route keeps
`discord-announcement-receipt.json`. Confirmed chunks are skipped
on retries, and definite HTTP rejections leave that chunk retryable. The receipt is also retained as a workflow artifact, including on
failure. If a POST's outcome is uncertain, automation stops instead of repeating
it: inspect the retained receipt and Discord channel, then reconcile the
in-flight entry against the actual message before retrying. Changed release notes
also require reviewing the existing announcement rather than silently reposting.

To announce a previously published release through the same verified route:

```sh
gh workflow run discord-release.yml --repo snapetech-org/pleazyng --ref main \
  -f action=announce-release -f runner_pool=hosted -f release_tag=v3.0.0
```

Current account, credential-presence and console evidence is maintained in
[the migration receipt](pleazyng-channel-migration.json) and
[the readiness matrix](publishing-readiness.md), checked 2026-11-05. Historical
2.24.1/build-156/build-157 release runs are not readiness evidence for the new
package or current release.

The registered downstream identities are `ppa:keefshape/pleazyng`,
`slskdn/pleazyng`, Snap `pleazyng` and AUR `pleazyng-bin`. Scoped Snap credentials
were refreshed for the new name; the COPR/PPA targets and Google app permissions
were updated. First qualified uploads and vendor checks still need to pass.
Homebrew additionally needs Developer ID/notarization and a tap-scoped token.
Microsoft company enrollment is submitted and awaits business/employment
verification before listing/package identity assignment. Company registration
is complete; D-U-N-S issuance and GST/HST validation remain separate gates.

The three first-store readiness flags remain false:
`GOOGLE_PLAY_BOOTSTRAP_COMPLETE`, `AMAZON_APPSTORE_BOOTSTRAP_COMPLETE` and
`APPLE_STORE_UPLOAD_READY`. Keep them false until the corresponding first setup,
signed upload/processing and actual purchase/reviewer-access checks pass. The
owner requested a roughly 24-hour hold on GST/HST-dependent submissions while
CRA accepts the new number. No tax or incorporation number is interchangeable
with D-U-N-S. Preserve existing credentials and certificate limits; no signing
key was revoked or reused from another project.

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
2. Review [the full release build runbook](full-release-build.md), confirm the intended `main` source and required platform inputs, then use `scripts/release_all_platforms.py` to run exact-source CI and build the complete release.
3. Review the generated draft notes, package list, `SHA256SUMS.txt`, release provenance and evidence that all required platform assets are present.
4. Select `--publish-github-only` to publish the complete GitHub Release and start the automatic Play lane when enabled, aerynOS reconciliation, and Discord notice unless skipped. Select `--publish` to also dispatch configured manual package and store channels; each external channel has independent delivery and review status.
5. For later store updates or a failed delivery lane, follow that channel's runbook and reuse the immutable release artifacts where supported. Do not rebuild the full platform matrix to repair a downstream delivery failure.

## Updater feed without a publication branch

Current clients (including published v3.0.7) read
`https://github.com/snapetech-org/pleazyng/releases/latest/download/appcast.xml`.
The core release uploads that asset. `Update Packages` no longer recreates or
writes an `appcast` branch. The immutable annotated `appcast` tag preserves the
old feed tree at `e0ba39dba7aa387c7a8341fb384d5178975f3986`, pointing legacy clients
to v3.0.7; those clients then use release assets. Do not move that compatibility
tag or restore a branch writer. New releases continue publishing their signed
feed and artifacts through the existing core release lane.
