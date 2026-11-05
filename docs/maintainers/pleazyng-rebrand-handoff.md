# Pleazyng implementation and cutover record

Updated 2026-11-05. Source baseline: 601a9dc79. Owner: SnapeTech.
Repository renames are explicitly deferred by the owner. Existing GitHub URLs,
Git remotes, runner routing labels and infrastructure mount names stay valid.
No historical release/tag/asset was modified. v3.0.0 remains the existing release;
the first branded release requires a new unused version and higher build numbers
verified against the actual store records before publication.

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
- Container publication recipes use pleazyng-relay. No service was deployed.
- Lifetime product defaults to pleazyng_lifetime_unlock; a verified existing
  immutable product can be selected with LIFETIME_UNLOCK_PRODUCT_ID at build time.
  This does not transfer purchases between store applications.
- Inherited README showcase and old-name store screenshot bases removed.
  All nine inherited README feature pictograms replaced with independent geometric
  SVGs; all 39 shared upstream images classified in pleazyng-artwork-audit.json.
  README and feature graphic use labelled brand artwork. Store screenshots must
  be recaptured, not repainted and represented as actual captures.
- Scoped regression check: scripts/checks/check_rebrand.py, included in guards.
- Website copy, manifest, source-to-site hash import and artwork updated in the
  existing private snapetech-org/plezyng.app repository. Current domain/project
  remain unchanged; pleazyng.app ownership/DNS/TLS is not yet verified.

Website deployment receipts: GitHub source f732ebfd2a09ebf3a2e88a81a6f6005715d5b4b7;
[successful Cloudflare run](https://github.com/snapetech-org/plezyng.app/actions/runs/42127220857),
[deployed Pages output](https://5bb7ee07.plezyng-app.pages.dev).
The existing owner-private ChatGPT Site was updated with Sites source commit
3f644aee56fd76c026e3fdbef1a8c65d85f8f84f; deployment
appgdep_6aed0c48c99c8191b062729e60417d33 succeeded without changing its audience.
Its URL and both repository names remain unchanged.

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
before this rebrand was pushed. The launcher test rerun on 9e9745362 still cannot
compile: karaoke uses removed FilePicker.platform APIs and
PlatformDetector.isAppleTVSync, karaoke_session.dart has a nullable string
mismatch, subtitle capture references subtitlePcmSeekGeneration without valid
type promotion, and source_playback.dart cannot access hasNativeVideoWindow on
a nullable player. The failing logic is unchanged by this rebrand.

The full local hook also fails existing formatting, translation hygiene,
generated-code freshness, hardcoded strings, 118 icon-rule violations,
guard import-path and analyzer/dependency checks. The authorized source commits
use the hook's documented SKIP_HOOKS escape hatch after focused checks; this
does not waive release qualification. Fix and qualify these problems before
any all-platform release; do not omit required platforms.

External gates still open: new domain ownership and redirects; store records,
certificates and IAP permissions; provider OAuth/Discord registrations and owned
relay deployment; native clean-install/coexistence/data/purchase migration;
signed updater bridge; fresh actual-device screenshots; package-manager review;
all-platform exact-commit CI, signing and release receipts. Do not publish old
binaries under new filenames or claim these steps are complete from source edits.

## Repository and release order

1. Keep repository names/remotes unchanged until the owner reverses the deferral.
2. Resolve build blockers; verify new owned services and domain before enabling them.
3. Implement and test signed fork-only continuity bridges; retain old data and feeds.
4. Confirm next version/build against all store uploads; build every required OS/arch.
5. Record built, signed, uploaded, submitted, approved, published and installed
   separately for each channel. Publish only the qualified new candidate.
6. Preserve historical releases, source attribution, rollback data and trust anchors.

The owner posts the issue update. This task does not post a comment on their behalf.
