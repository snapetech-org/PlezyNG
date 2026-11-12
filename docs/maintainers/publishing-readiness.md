# Pleazyng publishing readiness

**Historical onboarding snapshot checked 2026-11-05.** For current package and store deliveries, see [release channels](release-channels.md). Owner incorporated **SNAPE TECHNOLOGIES LIMITED**, Saskatchewan corporation **102247318**, on this date and authorized company verification across stores. The supplied Certificate of Incorporation is retained privately; it does not establish a CRA/GST account or D-U-N-S number. The owner separately confirmed registered address/contact details. Microsoft company enrollment is submitted; email is verified, business and employment verification are pending. The console estimates five business days. The D-U-N-S request was submitted through Apple and awaits D&B processing. Apple/Google organization conversion is now requested by the owner and requires their supported verification flows.

The [live migration receipt](pleazyng-channel-migration.json)
records console evidence. A configured credential or upload workflow is not proof
of an accepted package, active beta, or approved store release. Repository names
remain unchanged.

Apple’s app-level free download price and all 175-region availability are saved; its separate lifetime unlock remains USD $2.99. iOS, tvOS and macOS drafts are set to release automatically after Apple approval. No version has been submitted.

Pricing is decided: seven days of all features free, then one USD $2.99 lifetime
unlock on supported paid platforms. Free package channels remain free. Do not
publish a free/unlocked build to a paid store and describe it as the paid model.

Owner requested a roughly 24-hour hold on GST/HST-dependent tax submissions while CRA accepts the new number. Continue non-tax setup; do not substitute the Saskatchewan corporation number for a tax account. LG and Samsung store setup is explicitly included and scheduled last in this work.

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
| Homebrew custom tap | Attested Cask verification and tap publishing implemented; Developer ID certificate issued and dedicated signing secrets configured; API-key notarization wired; dedicated Pleazyng tap and repository-restricted token configured | First native signing/notarization/Gatekeeper qualification, generated release Cask and live workflow validation |
| Official Homebrew Cask | Candidate generator available | Same signing requirements, then upstream acceptance/audit/review; approval is not automated |
| Google Play internal test | New app/package, testing-only service account access, upload workflow and review grant configured | First signed Play AAB, Play App Signing, purchase product and real-device purchase/review-access validation; internal distribution must be explicitly activated |
| Google Play closed beta | Sign-in/review instructions, privacy, category/contact, rating and other declarations saved | Data safety, listing with three phone/two tablet images, 178 Alpha regions and existing five-member tester list are saved. Remaining: first AAB and requested permissions declarations, tester/country configuration, IAP validation and Google review |
| Google Play production / open testing | Existing personal developer account; website verified, company display name under review, organization conversion awaits D-U-N-S | Closed-test eligibility and production-access approval. Current personal-account console requires 12 opted-in testers for 14 continuous days; this does not delay starting the closed test. Recheck eligibility after an approved organization conversion |
| Amazon Fire TV Appstore | Existing app and entitlement renamed; USD $2.99 IAP and new artwork saved; subsequent binary upload automation configured | Four actual TV screenshots are uploaded/validated. Remaining: qualified APK, company account conversion and tax/payment verification, declarations and purchase testing. Amazon requires first-version submission in Developer Console; later updates can use its API |
| Apple TestFlight | Active Individual Developer Program membership, team `DM9A59DC85`, new identifiers and upload API credentials | English US beta/review information and the automatic-distribution Pleazyng Internal group are saved (zero testers/builds; no invitations sent). Remaining: complete signed iOS/tvOS archive/export and IPA processing, tester assignment, export compliance and external beta review. The existing distribution identity passed native import/signing/strict verification; new-bundle app/extension profiles and the isolated signing path are configured. Validate billing separately before promising full paid-feature testing |
| Apple iOS / tvOS App Store | Existing app reused, new identifiers and USD $2.99 non-consumable configured; upload automation available | Same signing/build gates plus real screenshots, privacy/review metadata, IAP screenshot and purchase/restore validation, paid agreement activation and Apple review |
| macOS direct DMG / Sparkle | Universal DMG and appcast pipeline | Developer ID certificate and dedicated secrets now configured; qualified native signing/notarization/Gatekeeper and updater signature verification remain |
| Flatpak direct bundle | Release bundle supported | Qualified Linux artifact; this is sideloading, not Flathub publication |
| Relay GHCR / Docker Hub | Container publication workflows and optional mirror credentials configured; owned service now deployed separately | Source-built service passes public HTTPS/WSS checks. Container image release, provider OAuth registrations and client compile activation remain separate qualification steps |

## Business, tax, vendor or unsupported-integration gates

| Channel / goal | Exact gate | What can be prepared now |
| --- | --- | --- |
| Apple paid unlock | Free Apps Agreement is Active, Paid Apps Agreement is Pending User Info. W-8BEN and U.S. foreign-status certificate are Active. Canadian GST/HST Form 506 is Missing Tax Info and owner submission returns “The Tax ID entered already exists.” Bank update is Processing | Continue builds, identifiers, metadata and testing preparation. Resolve the duplicate Canadian tax record with Apple Finance; do not invent another tax ID or repeatedly recreate the form. This is not a D-U-N-S gate |
| Apple company seller name | Current membership is Individual; conversion form opened, organization enrollment requires legal-entity verification and D-U-N-S | Publish eligible apps under the individual seller once other gates pass; company conversion is now requested; D-U-N-S/Apple verification remain |
| Microsoft Store company route | Authenticated account has no Windows publishing workspace. Company onboarding accepts documents instead of D-U-N-S. Incorporation certificate uploaded and legal name/registration extracted correctly; owner-confirmed company/contact details saved and agreement accepted; Microsoft business/employment verification pending | Prepare assets and packaging. After enrollment, copy Microsoft's assigned package/publisher identities exactly, configure signing/submission credentials and the assigned lifetime add-on Store ID. The Windows billing adapter and separate trial/IAP MSIX build path are implemented and locally tested; native Store installation/purchase/restore/refund and workflow qualification remain. Direct downloads stay unlocked |
| Microsoft Store individual alternative | Enrollment also offers Individual; owner identity verification and account setup would apply | Does not inherently require company papers, but individual enrollment has not been completed; do not claim a reserved listing or automated Store publication |
| Samsung Tizen TV | Company Public Group and Pleazyng app **3202611050784** created; English title/description, service/privacy, US region and feature/player information saved. Listing now reflects the current 1080p H.264 profile. Public tier is US-only; other regions require Partner approval. Production signing, physical TV qualification, authentic Tizen captures and Samsung Checkout DPI configuration/real purchase testing remain. The Checkout source adapter and opt-in store build are implemented and locally tested; DPI settlement onboarding requires a business bank account, which the owner does not yet have. Applicable EU distribution also needs EAA conformity documentation | Development tester TPK exists; preserve its tester-only status. Prepare listing and authentic TV captures. Billing and full Seller Office publication are not automated |
| LG webOS Content Store | Owner completed LG sign-in/terms; seller profile saved and company Group created. `org.snapetech.pleazyng` passes the app-ID check, but first IPK is required before listing sections unlock. Corporate verification status and target-device qualification remain unverified; legacy LG Billing service is discontinued | IPK/handoff build support exists. Store submission is manual; do not assume native IAP or invent a payment provider. A supported payment integration needs separate implementation if monetized |
| Mac App Store | macOS platform added to the existing Apple app; version 3.0.1 draft with English listing/review details saved, no screenshots or builds. No Mac App Store build path validated; direct DMG remains configured unlocked | Separate sandboxed App Store packaging, entitlements, StoreKit trial/purchase mode, signing, listing and review are needed |
| Flathub | No accepted submission; attached prebuilt Flatpak bundle is not a source-built Flathub manifest | Prepare a source-build manifest and dependency/license audit, then upstream review |
| Nix / downstream aerynOS packaging | Fork-specific recipes can be generated; aerynOS native build/install/sign-in pass, but v3.0.7 fails video playback QA; no public aerynOS package entry verified | Follow the [Linux channel guide](linux-distribution-channels.md) and [aerynOS qualification record](aerynos-qualification.md); repeat video QA with a repaired release bundle before publication |

## Publication behavior

`--publish-github-only` publishes GitHub assets and the configured announcement;
it does not upload to app stores. `--publish` dispatches configured downstream
publishers, with receipts for completed, skipped and failed channels. Before
first store publication, complete the console bootstrap and validate the actual
signed artifact. [Automatic Google Play delivery](google-play-release-delivery.md)
uses `GOOGLE_PLAY_AUTO_TRACK=internal` for completed internal-testing releases.
The older manual publisher setting remains `GOOGLE_PLAY_TRACK=alpha`.
`GOOGLE_PLAY_BOOTSTRAP_COMPLETE=false` gates automatic alpha/beta selection;
internal distribution supports the pending device, reviewer and purchase/restore
qualification. An unconfigured manual publisher defaults to internal draft.
Neither a draft upload nor a successful dispatch proves a completed rollout.
Apple uploads do not submit App Review or configure
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

## Activation handoff

This is a staged launch, not a claim that every channel has a single API switch.
Use the current exact-main release qualification run owned by the release task;
do not start a duplicate build or upload an older screenshot-capture APK as the
final candidate.

1. Finish company verification: D-U-N-S issuance, Google organization payments
   profile/document/contact verification and Apple membership conversion;
   Microsoft business/employment approval. Confirm the exact legal seller and
   package identities in each portal after approval. Google's verified website
   is already `https://snape.tech/`; public developer-name change is under review.
2. After the owner's CRA hold, complete each store's corporation tax/payment
   forms. Reconcile Apple's existing duplicate-ID record through its supported
   finance route. Do not replace the still-active individual records with
   guessed corporate values. Amazon's locked company type/publisher name needs
   the [prepared conversion request](amazon-company-conversion-request.md).
3. Qualify the final signed store artifacts: new Play/Amazon package and signing
   identity; Play/Amazon USD $2.99 entitlement purchase/restore; disclosed Android
   review-grant redemption after trial expiry and restart; iOS/tvOS signing,
   StoreKit purchase/restore and processing. Complete each store's remaining
   permissions, privacy, reviewer, screenshot and compliance fields.
4. Complete first publication in its required console. Google needs its first
   signed AAB/App Signing and new product bootstrap. Amazon requires the first
   version through Developer Console. Apple needs processed signed builds and
   explicit review/TestFlight setup. Enable only the matching readiness flag
   after its own upload and validation evidence exists; retain that evidence.
5. Publish the qualified version through the release owner. Full publication
   runs the configured downstream package publishers. Google automatic routing
   remains testing-only. If Google approves Organization conversion and removes
   the personal testing gate, confirm Production access, grant the app-specific
   production release permission and use a reviewed Production submission;
   do not silently widen the existing testing-only service account.
6. Verify customer-facing listings/downloads and record upload, review,
   approval and availability separately. Keep Samsung/LG manual certification
   and partner/device requirements explicit; their handoff bundles do not submit
   vendor reviews.

For a subsequent store upload from an already qualified release, the explicit
workflow accepts these parameters (substitute the real qualified tag and channel;
this example preserves a Play draft):

```sh
gh workflow run publish-app-stores.yml --repo snapetech-org/pleazyng --ref main \
  -f action=publish-app-stores -f runner_pool=public -f release_tag=vX.Y.Z \
  -f channel=google-play -f play_track=alpha -f play_release_status=draft
```

Supported channel values are `google-play`, `amazon-appstore`, `app-store-ios`
and `app-store-tvos`. A successful upload does not prove review approval or
availability. Tax-dependent tasks remain deferred; registration, preparation
and technical validation can continue independently.

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

## Owned service verification — 2026-11-06

`https://pleazyng-api.snape.tech/health` returns HTTP 200. A real secure WebSocket protocol 2 session passed create, join, leave and end; the test room was removed. Scanner requests are blocked, the existing Knock boundary refuses a blocked identity, and the backend/origin/metrics listeners remain loopback-only and unreachable from the peer LAN. The dedicated connector is healthy; existing shared ingress services were preserved.

See the [Pleazyng service endpoint inventory](pleazyng-relay-endpoints.md) for
the complete route list and app-feature mapping, including routes outside the
room protocol exercised by this check.

This service was built from immutable source `4eb97fe98dcf1115a98aa4c081c43ad981c12d44`. It does not qualify provider OAuth or enable new client compile settings. Provider credentials remain absent; missing integrations stay disabled. Client activation is staged for a separate release after the current full-platform qualification.
