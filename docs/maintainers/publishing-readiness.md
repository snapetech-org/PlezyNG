# Pleazyng publishing readiness

Checked 2026-11-05. The [live migration receipt](pleazyng-channel-migration.json)
records console evidence. A configured credential or upload workflow is not proof
of an accepted package, active beta, or approved store release. Repository names
remain unchanged.

Pricing is decided: seven days of all features free, then one USD $2.99 lifetime
unlock on supported paid platforms. Free package channels remain free. Do not
publish a free/unlocked build to a paid store and describe it as the paid model.

## No business-registration prerequisite identified

These channels can proceed when their technical prerequisites pass. None is
currently claimed to have published the new release.

| Channel | Current setup / automation | Remaining before first Pleazyng publication |
| --- | --- | --- |
| GitHub Releases / direct downloads | Full platform build and checksum/provenance gates; release orchestrator can publish | Exact intended main revision must pass CI and every required platform build/asset check |
| Website | Rebrand deployed at existing URLs | Update download links only after verified release; existing access settings remain |
| AUR | SSH publisher verified; target `pleazyng-bin` configured; recipe publishing automated | First qualified Linux release and valid recipe push create the package |
| Fedora COPR | `slskdn/pleazyng` registered with eight Fedora/architecture chroots; target configured | First qualified source-package upload; confirm credential acceptance and successful COPR builds |
| Launchpad PPA | `ppa:keefshape/pleazyng` enabled for amd64/arm64; target and existing signing secret configured | First signed source upload and successful Launchpad builds; verify signing-key association |
| Snap Store | `pleazyng` registered; package-scoped upload/release credential configured | First qualified Snap, automated store checks, then listing/screenshots and channel verification |
| Chocolatey | New `pleazyng` package recipe and API secret configured; no old/new public entry found | Qualified Windows installer/package, credential acceptance and community moderation |
| WinGet | `SnapeTech.Pleazyng` manifests and submission token configured; no publisher namespace found | Qualified installer, valid manifest PR, upstream validation/review and merge |
| Homebrew custom tap | Attested Cask verification and tap publishing implemented | Developer ID signing/notarization, `HOMEBREW_TAP_TOKEN`, generated release Cask, first live workflow validation |
| Official Homebrew Cask | Candidate generator available | Same signing requirements, then upstream acceptance/audit/review; approval is not automated |
| Google Play internal test | New app/package, testing-only service account access, upload workflow and review grant configured | First signed Play AAB, Play App Signing, purchase product and real-device purchase/review-access validation; internal distribution must be explicitly activated |
| Google Play closed beta | Sign-in/review instructions, privacy, category/contact, rating and other declarations saved | Data safety, real Android screenshots/listing, first AAB and requested permissions declarations, tester/country configuration, IAP validation and Google review |
| Google Play production / open testing | Existing personal developer account; no company conversion requested | Closed-test eligibility and production-access approval. Console requires 12 opted-in testers for 14 continuous days; this does not delay starting the closed test |
| Amazon Fire TV Appstore | Existing app and entitlement renamed; USD $2.99 IAP and new artwork saved; subsequent binary upload automation configured | Qualified APK, three actual TV screenshots, account tax/payment verification, declarations and purchase testing. Amazon requires first-version submission in Developer Console; later updates can use its API |
| Apple TestFlight | Active Individual Developer Program membership, team `DM9A59DC85`, new identifiers and upload API credentials | New-bundle signing/provisioning and signed IPA, processing, beta information/groups, export compliance and external beta review. Validate billing separately before promising full paid-feature testing |
| Apple iOS / tvOS App Store | Existing app reused, new identifiers and USD $2.99 non-consumable configured; upload automation available | Same signing/build gates plus real screenshots, privacy/review metadata, IAP screenshot and purchase/restore validation, paid agreement activation and Apple review |
| macOS direct DMG / Sparkle | Universal DMG and appcast pipeline | Qualified build; configure Developer ID/notarization for trusted distribution and Homebrew; updater signature verification |
| Flatpak direct bundle | Release bundle supported | Qualified Linux artifact; this is sideloading, not Flathub publication |
| Relay GHCR / Docker Hub | Container publication workflows and optional mirror credentials configured | Verify relay source/image release separately; publishing an image does not deploy a working relay service |

## Business, tax, vendor or unsupported-integration gates

| Channel / goal | Exact gate | What can be prepared now |
| --- | --- | --- |
| Apple paid unlock | Free Apps Agreement is Active, Paid Apps Agreement is Pending User Info. W-8BEN and U.S. foreign-status certificate are Active. Canadian GST/HST Form 506 is Missing Tax Info and owner submission returns “The Tax ID entered already exists.” Bank update is Processing | Continue builds, identifiers, metadata and testing preparation. Resolve the duplicate Canadian tax record with Apple Finance; do not invent another tax ID or repeatedly recreate the form. This is not a D-U-N-S gate |
| Apple company seller name | Current membership is Individual; organization enrollment requires legal-entity verification and D-U-N-S | Publish eligible apps under the individual seller once other gates pass; company conversion is separate |
| Microsoft Store company route | Authenticated account has no Windows publishing workspace. Company onboarding requires D-U-N-S or business verification documents; none submitted | Prepare assets and packaging. After enrollment, copy Microsoft's assigned package/publisher identities exactly, configure signing/submission credentials and implement/validate the required trial/purchase path. Existing free direct-download build does not implement Microsoft Store billing |
| Microsoft Store individual alternative | Enrollment also offers Individual; owner identity verification and account setup would apply | Does not inherently require company papers, but individual enrollment has not been completed; do not claim a reserved listing or automated Store publication |
| Samsung Tizen TV | Seller partnership/certification, account/region eligibility, production signing profile and TV testing remain unverified. EU distribution asks for business registration information; Samsung Checkout needs separate integration and configuration | Development tester TPK exists; preserve its tester-only status. Prepare listing and authentic TV captures. Billing and full Seller Office publication are not automated |
| LG webOS Content Store | Seller Lounge approval/account verification and target-device qualification remain unverified; legacy LG Billing service is discontinued | IPK/handoff build support exists. Store submission is manual; do not assume native IAP or invent a payment provider. A supported payment integration needs separate implementation if monetized |
| Mac App Store | No Mac App Store platform submission/build path validated; direct DMG is configured unlocked | Separate sandboxed App Store packaging, entitlements, StoreKit trial/purchase mode, signing, listing and review are needed |
| Flathub | No accepted submission; attached prebuilt Flatpak bundle is not a source-built Flathub manifest | Prepare a source-build manifest and dependency/license audit, then upstream review |
| Nix / aerynOS community channels | No fork-specific maintained package entry or publisher integration verified | Community recipe submission and maintainership needed; business registration is not the technical blocker |

## Publication behavior

`--publish-github-only` publishes GitHub assets and the configured announcement;
it does not upload to app stores. `--publish` dispatches configured downstream
publishers, with receipts for completed, skipped and failed channels. Before
first store publication, complete the console bootstrap and validate the actual
signed artifact. Google supports a configured testing track and release status. This repository
now stages `GOOGLE_PLAY_TRACK=alpha` and `GOOGLE_PLAY_RELEASE_STATUS=completed`;
`GOOGLE_PLAY_BOOTSTRAP_COMPLETE=false` prevents rollout until first console setup
and signed-build review/purchase validation pass. An unconfigured repository
defaults to internal draft. Neither a draft upload nor a successful dispatch is
a beta rollout. Apple uploads do not submit App Review or configure
TestFlight groups. Amazon's initial submission must go through its console.

`AMAZON_APPSTORE_BOOTSTRAP_COMPLETE` similarly enables subsequent Amazon API
updates after the required first console submission. `APPLE_STORE_UPLOAD_READY`
enables signed iOS/tvOS uploads once signing and processing are verified; it does
not claim paid-agreement activation or enable review submission. Both currently
remain false. App-store publishers use public hosted runners by default with
optional native private routing. These revisions still need live validation
against qualified store assets; no extra build was dispatched for this change.

Store approval, tester participation, Apple Finance correction, and vendor
partnership decisions cannot be guaranteed by CI automation. Keep any review or
publication receipt explicit about whether it proves upload, review submission,
approval, or customer availability.

## Authoritative references

- [Google test setup](https://support.google.com/googleplay/android-developer/answer/9845334)
- [Google production-access testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465)
- [Google reviewer access requirements](https://support.google.com/googleplay/android-developer/answer/15748846)
- [Apple tax information](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information/)
- [Apple organization D-U-N-S requirements](https://developer.apple.com/help/account/membership/D-U-N-S/)
- [Apple review access](https://developer.apple.com/app-store/review/guidelines/)
- [Amazon tax setup](https://www.developer.amazon.com/docs/reports-promo/setup-tax.html)
- [Samsung application information and region requirements](https://developer.samsung.com/tv-seller-office/guides/applications/entering-application-information.html)
- [Samsung Checkout](https://developer.samsung.com/smarttv/develop/guides/samsung-checkout/samsung-checkout.html)
- [LG billing discontinuation](https://webostv.developer.lge.com/develop/guides/in-app-purchase)
