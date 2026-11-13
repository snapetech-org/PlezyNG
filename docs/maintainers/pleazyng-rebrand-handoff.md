# Pleazyng implementation and cutover record

Updated 2026-11-12. Source baseline:
af5b1b21a7ddf986f20efd91ba475c406ee119ab. Owner: SnapeTech.
The application repository and local checkout now use the canonical
`snapetech-org/pleazyng` identity; the old GitHub URL redirects to it. The
private website repository remains `snapetech-org/plezyng.app`. The app
repository homepage points to `https://pleazyng.app/`; apex and `www` both
returned HTTP 200 with valid TLS on 12 November. Domain registrant/control
evidence and historical-domain redirects remain unverified. The current complete
core release is [GitHub v3.0.33](https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.33),
published 12 November 2026. Package/store delivery and reviewer decisions
remain separate. Historical tags and release assets remain preserved.

## Implemented in source

- Pleazyng display names, localized copy and native permission text.
- Coral ribbon without NG lettering; exact Pleazyng wordmarks; light/dark art;
  regenerated canonical platform exports, checksums and all 23 alternate icons.
- New public org.snapetech.pleazyng package IDs, tvOS extension and app group,
  Pleazyng Apple products and pleazyng Windows/Linux/TV executables.
- Canonical pleazyng:// media links and pleazyng-source://oauth/callback.
  Native registration of upstream plezy:// removed. Legacy fork plezyng:// and
  plezxyng:// handlers remain explicit compatibility aliases.
- Future release asset consumers/producers, Homebrew, WinGet, Chocolatey,
  Debian/RPM/AUR, Flatpak/Snap and TV recipes use the new public identities.
- The Pleazyng relay is deployed at the configured
  `pleazyng-api.snape.tech` endpoint. Its `/health` endpoint returned HTTP 200
  with TLS verification on 12 November 2026. Route-specific provider activation
  and end-to-end account qualification remain separate gates.
- Lifetime product defaults to pleazyng_lifetime_unlock; a verified existing
  immutable product can be selected with LIFETIME_UNLOCK_PRODUCT_ID at build time.
  This does not transfer purchases between store applications.
- Inherited README showcase and old-name store screenshot bases removed.
  All nine inherited README feature pictograms replaced with independent geometric
  SVGs; all 39 shared upstream images classified in pleazyng-artwork-audit.json.
  README and feature graphic use labelled brand artwork. Store screenshots must
  be recaptured, not repainted and represented as actual captures.
- Scoped regression check: scripts/checks/check_rebrand.py, included in guards.
- Website copy, manifest, source-to-site hash import and artwork were updated in
  the existing private `snapetech-org/plezyng.app` repository. The app homepage
  now uses `https://pleazyng.app/`; apex and `www` have valid TLS. Domain
  registrant/control evidence and historical-domain redirects remain unverified.

Website deployment receipts: GitHub source f732ebfd2a09ebf3a2e88a81a6f6005715d5b4b7;
[successful Cloudflare run](https://github.com/snapetech-org/plezyng.app/actions/runs/42127220857),
[deployed Pages output](https://5bb7ee07.plezyng-app.pages.dev).
The existing owner-private ChatGPT Site was updated with Sites source commit
3f644aee56fd76c026e3fdbef1a8c65d85f8f84f; deployment
appgdep_6aed0c48c99c8191b062729e60417d33 succeeded without changing its audience.
Its URL and both repository names remain unchanged. Anonymous Pages checks
return HTTP 401; no access policy was changed. The app repository homepage now
points to `https://pleazyng.app/`; apex and `www` return HTTP 200 with valid
TLS. Domain registrant/control evidence and historical-domain redirects remain
unverified.

## Compatibility and continuity

| Platform | Install relationship | Required continuity work before promotion |
| --- | --- | --- |
| Android / Fire TV | New application ID; separate sandbox | Register/sign new app, export supported settings from old fork and import explicitly; downloads and credentials need a signed bridge or reauthentication. Verify old purchase recovery with the real store. |
| iOS / tvOS | New bundle IDs/group; separate containers | Register IDs, profiles and entitlements; validate old-data export and new import on devices. New app group does not read the old group automatically. |
| macOS | New bundle ID/product | Verify same-team signing, keychain ACLs, old app support discovery/import and updater bridge. Do not assume a bundle rename transfers data. |
| Windows direct | Existing installer GUID retained | Verify old-to-new executable/shortcut/update and uninstall behavior. Credential vault target keys remain stable. |
| MSIX | Assigned Partner Center identity required | Keep authoritative identity variables; reconcile actual listing, package family and data before submission. |
| Linux direct | New command/package | Preserve old config/data. Test explicit fork-only import and launcher coexistence. No ownership claim over upstream plezy packages. |
| Flatpak / Snap | New application IDs/names; separate confinement | Register/review new packages and document/test export/import through supported boundaries. |
| Tizen / webOS | New public IDs and executable | Validate store identifiers, signing, device install, data path and redistribution requirements. |

Existing credential-vault names, Dart package plezy, JNI/Kotlin namespaces,
method channels, content IDs, serialized formats, docs/plezyng paths and
build helper/library names remain compatibility contracts. Do not rewrite
these as cosmetic branding. Provider/player/rating marks and transparent
launch placeholders retain their existing purposes and licences; new branding
provenance is separate. Historical inventory remains a snapshot, not a claim
that every old occurrence is a current defect.

## Verification and blockers

Local checks: 327 Python guard/release tests; 49 webOS package tests; 19 Tizen
package tests; 7 brand property tests; 72 focused Flutter brand/link/widget tests.
Brand export/hash, native protocol registration, public identity, build workflow,
update-package and workflow security checks passed. Website build/check and
four browser-logic tests passed. Visual contact sheet reviewed for symbol,
wordmark and artwork. These are source/export results, not signed binary or
device qualification. Generated localization output was regenerated from sources.

The initial broader Flutter run found malformed games, RomM and visualization
source. Concurrent commit 2a5378d62 repaired those defects and was integrated
before this rebrand was pushed. Historical local validation at source commit
9e9745362 could not compile the launcher because: karaoke uses removed FilePicker.platform APIs and
PlatformDetector.isAppleTVSync, karaoke_session.dart has a nullable string
mismatch, subtitle capture references subtitlePcmSeekGeneration without valid
type promotion, and source_playback.dart cannot access hasNativeVideoWindow on
a nullable player. This is a historical result for that source revision, not
the status of the current v3.0.33 core release.

A historical full-hook run also reported formatting, translation hygiene,
generated-code freshness, hardcoded strings, icon-rule, guard import-path and
analyzer/dependency findings. These results are tied to that earlier checkout;
review current checks against the exact source revision before acting on them.
For v3.0.33, the complete core release is already published. Treat notification,
store and package-channel delivery failures as follow-up work against the
existing immutable artifacts; do not start another all-platform build solely
for a delivery error.

External gates still open: website domain registrant/control evidence and
historical-domain redirects; store records, certificates and IAP permissions;
production provider approvals and end-to-end OAuth/account flows; native clean-install, coexistence,
data and purchase migration; signed updater bridge; fresh actual-device store
screenshots; and package-manager review. The relay is live and the Discord app
is configured, but neither fact qualifies every integration. Do not publish old
binaries under new filenames or infer channel approval from the GitHub release.

## Repository and release order

1. Keep the application repository on canonical `snapetech-org/pleazyng`;
   preserve the old URL redirect. Change the separate website repository or
   domain only with verified ownership and a migration route.
2. Keep the v3.0.33 core release and its artifact identities fixed. Enable each
   optional provider only after its production registration and end-to-end checks
   pass; verify website domain ownership separately.
3. Implement and test signed fork-only continuity bridges; retain old data and feeds.
4. Confirm next version/build against all store uploads; build every required OS/arch.
5. Record built, signed, uploaded, submitted, approved, published and installed
   separately for each channel. Publish only the qualified new candidate.
6. Preserve historical releases, source attribution, rollback data and trust anchors.

Issue #149 remains open with the maintainer's 6 November 2026 response
recorded. This handoff updates repository status only and does not post another
issue comment.
