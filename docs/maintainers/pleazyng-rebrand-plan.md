# PlezyNG to Pleazyng: brand, assets, packages and publishing migration

Status: source implementation and the application repository/local checkout rename are complete. The owner authorized the repository cutover on 8 November 2026; see [repository migration](repository-rename.md). Other external channels and device qualification remain separately tracked in the [implementation record](pleazyng-rebrand-handoff.md) and [machine-readable status](pleazyng-rebrand-status.json). The original audit and checklist below are retained as the scope baseline; unchecked items are not completion claims.
Date: 5 November 2026 (America/Regina).
Owner/publisher: SnapeTech.
Source repository at audit: snapetech-org/PlezyNG (now snapetech-org/pleazyng), main at 2bc45e1b890776cb6b1a19ba3434867d01f0a404.
Related website source: snapetech-org/plezyng.app (private), tree 99f46c955f86fbe7ff7c5b8f22d23fd30cf5c0ba.
Upstream comparison: edde746/plezy, tree 0ef47f2711ecb5ff30089831410b6f29b580cdcb.
Issue: [Rename fork before publishing, #149](https://github.com/snapetech-org/pleazyng/issues/149).
Inventory: [pleazyng-rebrand-inventory.json](pleazyng-rebrand-inventory.json).

The approved destination is **Pleazyng**, pronounced “pleasing”, presented as a whole word. This document maps the entire transition, including graphics and inherited artwork. It does not assert trademark clearance, store acceptance, or completion of the changes. Upstream approval is not an execution dependency in this plan; applicable rights and actual channel policies still apply.

## 1. Evidence and limits

Confidence is high for inspected source values, Git tree/blob identity, manifest counts, and the published release asset list. Confidence is moderate for complete external-channel coverage because consoles, registrars, deployed hosts, and organization-wide consumers were not inspected. Live trademark clearance, new domain ownership, final store acceptance and deployed configuration are unknown.

Observed findings:

| ID | Verified at the audit snapshot | Required disposition |
| --- | --- | --- |
| A01 | 675 raster/vector image files were found by the audit extension filter in the app repository. 39 have the same Git blob hash as an image in upstream. | Classify matches by purpose; do not assume all shared images are upstream branding. The inventory lists all audited image paths and shared hashes. |
| A02 | The current default TV icon preview is a three-dimensional folded coral ribbon with an NG detail. The inspected upstream icon is a flatter coral triangle with two wave cutouts. The files and visible designs differ. | Audit the ribbon masters' provenance and adapt or replace them for Pleazyng. Different pixels/hashes do not by themselves establish independent ownership or legal clearance. |
| A03 | assets/readme-showcase.webp is byte-identical to upstream, blob a25e6e4bee943a537e872d152a11a184c73a12da. It depicts upstream's product screens. | Replace with fresh captures of the renamed fork. Do not present it as a Pleazyng screenshot. Check every live reference and composite using it. |
| A04 | Three tvOS LaunchImage PNGs match upstream, blob 9da19eacad3b03bb08bbddbbf4ac48dd78b3d838. The fetched file is a transparent white 1×1 pixel. | These are empty placeholders, not inherited logos. Keep only if required by the launch configuration, or remove the unused set after validating that configuration. |
| A05 | Other image matches are provider/player/rating marks and nine small README feature pictograms. | Preserve legitimate third-party marks and notices; inspect the feature pictograms' provenance and replace if they are project-specific art without a clear grant. No blanket deletion of provider graphics. |
| A06 | The brand configuration contains 491 targets; asset-manifest.json records 591 exports, including generated SVG wrappers. There are 23 alternate launcher themes. | Update the canonical masters and generator, then regenerate every applicable output and refresh the manifest. Check the whole export inventory, not just the launcher icon. |
| A07 | No image in the inspected website tree has an identical Git blob hash to an upstream image. Several website brand exports match the current fork's canonical exports. | Retain the source-to-site hash verification. Inspect website composites visually: absence of an exact hash match does not exclude embedded or transformed upstream graphics. |
| I01 | Android applicationId and iOS/macOS/Linux/webOS identities use org.snapetech.plezyng. Internal Android namespace remains com.edde746.plezy. | Move public package identities to org.snapetech.pleazyng with explicit migration handling. Keep necessary internal namespaces as documented compatibility exceptions. |
| I02 | tvos/Runner/Info.plist still displays Plezy, and TopShelfExtension/Info.plist displays Plezy Top Shelf. | Correct all compiled/localized display names, including extensions and permission prompts. |
| I03 | **Implemented:** `DeepLink.scheme` is `pleazyng`; Android, Apple, Linux and Windows register the canonical scheme and fork-only compatibility aliases, while upstream `plezy://` is not registered. Android/iOS source OAuth uses `pleazyng-source://oauth/callback`. | Preserve the verified grammar and authorization behavior. A user-initiated converter for saved legacy links and a documented retirement window for the old fork-only aliases remain open; never register upstream `plezy://`. |
| S01 | Discord RPC still contains upstream application ID 1453773470306402439. | Register a SnapeTech/Pleazyng Discord application and upload fork-owned Rich Presence assets. |
| S02 | lib/services/plezy_server.dart defaults to https://ice.plezy.app for OAuth/logs/posters, with commerce and Watchmode URLs defaulting to the same service. | Provision and configure a fork-owned relay; eliminate upstream hosted-service fallbacks. Missing configuration must not route to upstream. |
| S03 | The Trakt client constant is bundled in source. Other provider identities can live in relay configuration. Ownership of every provider registration was not verified. | Record ownership for all app registrations and replace upstream registrations, not merely their visible names. |
| P01 | GitHub v3.0.0 is published, with 31 assets containing a mixture of plezy-, plezyng- and PlezyNG- names. pubspec.yaml at the audit commit is 3.0.0+159. | Treat existing installs/releases as real. Use a later release with canonical names and a tested migration. Preserve historical tags, binaries, checksums and attestations. |
| P02 | Repo metadata homepage points at a GitHub URL. Store documentation records prepared Play/Apple/Amazon records and a lifetime product, but this was not rechecked in consoles. | Audit actual records and purchases before retiring or replacing them; correct repo homepage during cutover. |
| P03 | release-channels.md describes push CI, while inspected ci.yml is manually dispatched. Website README describes push deployment while deploy-pages.yml is manually dispatched. Old docs also describe optional webOS release omission. | Reconcile stale instructions with current workflows and AGENTS.md. All required release platforms remain required; a rebrand cannot bypass missing platform or redistribution work. |

## 2. Canonical identity map

The following are targets, not claims that names, domains or store records are reserved.

| Surface | Current | Target |
| --- | --- | --- |
| Product/display name | PlezyNG; residual Plezy | Pleazyng |
| Publisher/maintainer | SnapeTech | SnapeTech |
| Main repository | snapetech-org/pleazyng | snapetech-org/Pleazyng |
| Website source repository | snapetech-org/plezyng.app (private) | snapetech-org/pleazyng.app (private) |
| Website | plezyng.app / www.plezyng.app | pleazyng.app / www.pleazyng.app, subject to verified ownership |
| Primary application/package ID | org.snapetech.plezyng | org.snapetech.pleazyng |
| Experimental Android suffix | org.snapetech.plezyng.dvfel | org.snapetech.pleazyng.dvfel |
| Test application IDs | derived from old application IDs | derived from the new application IDs; verify every variant |
| tvOS extension | org.snapetech.plezyng.TopShelfExtension | org.snapetech.pleazyng.TopShelfExtension |
| Apple app group | group.org.snapetech.plezyng | group.org.snapetech.pleazyng |
| Canonical media links | plezy:// | pleazyng:// |
| Source OAuth callback | plezyng-source://oauth/callback | pleazyng-source://oauth/callback |
| Desktop command/executable | plezy / plezy.exe | pleazyng / pleazyng.exe |
| macOS application | PlezyNG.app | Pleazyng.app |
| Linux desktop/AppStream/Flatpak ID | org.snapetech.plezyng | org.snapetech.pleazyng |
| Tizen app ID/package/exec | org.snapetech.plezyng / plezyng | org.snapetech.pleazyng / pleazyng, subject to Samsung identifier validation |
| webOS app ID/exec | org.snapetech.plezyng / plezyng | org.snapetech.pleazyng / pleazyng |
| Homebrew cask | snapetech-plezyng | snapetech-pleazyng |
| WinGet package ID | SnapeTech.PlezyNG | SnapeTech.Pleazyng |
| Chocolatey package | plezyng | pleazyng |
| Snap name | plezyng | pleazyng; new registration and credential scope |
| Debian/RPM package | plezyng recipes | pleazyng |
| AUR recipe | configured AUR_PACKAGE_NAME | pleazyng-bin by default, subject to name availability and existing package ownership |
| COPR / Launchpad | configured project/archive | product labels and new public URLs under pleazyng; inventory actual names before migration |
| Lifetime product, new store records | plezyng_lifetime_unlock | pleazyng_lifetime_unlock |
| Relay container | ghcr.io/snapetech-org/plezyng-relay | ghcr.io/snapetech-org/pleazyng-relay |
| Docker Hub relay mirror | snapetech/plezyng-relay | snapetech/pleazyng-relay |
| Main brand asset | assets/pleazyng.png; assets/pleazyng-app-icon.png | assets/pleazyng.png; assets/pleazyng-app-icon.png |
| Brand exports/masters | assets/branding/plezyng-* | assets/branding/pleazyng-* |
| Brand docs/features directory | docs/plezyng | docs/pleazyng, with links migrated and appropriate historical stubs |
| Fork-specific public env/config | PLEZYNG_*; some PLEZY_* | PLEAZYNG_* canonical, with explicit temporary compatibility readers where safe |

Use Pleazyng, not PleazyNG, in the public wordmark and copy. Do not market it as upstream's official successor, official next generation, or upstream-maintained edition.

Unbranded identifiers such as signing Team IDs, cryptographic keys, randomly assigned installation GUIDs and existing store-assigned numeric IDs must not be changed just to spell the product differently. Store-assigned identifiers must be copied from their authoritative console. Actual ownership and migration constraints determine which can remain legacy compatibility IDs.

## 3. Work packages and execution order

Every work package gets a focused commit and a recorded result. The plan/inventory commit does not rename repositories, buy domains, change accounts, build packages, publish binaries or post a comment.

### R0 — Inventory, continuity and preparation

- [ ] Refresh the repository/tree snapshot and occurrence inventory immediately before implementation; concurrent work is active.
- [ ] Inventory every existing channel record, release, signing certificate/key fingerprint, package name, app ID, IAP ID, approved callback, group, installed-user population and purchase population. Record record IDs and evidence dates, not secrets.
- [ ] Reserve or verify Pleazyng repository/package/store names and ownership of the intended domains. Domain availability was not checked by this plan.
- [ ] Capture the current website, feeds, DNS/TLS, release metadata, manifests and channel settings for rollback.
- [ ] Check pending builds/publications. Pause new old-name publication through controlled workflow gates without cancelling other agents' active work.
- [ ] Produce a per-platform continuity table: old ID; new ID; same install or separate app; signing requirements; data path; credential scope; purchase recovery; update route.
- [ ] Confirm the next unused version and build numbers. Increase them above relevant published/uploaded versions; do not reset versionCode or Apple build numbers.
- [ ] Prepare fork-only bridge/export functionality where needed before moving package identities. Never infer that an ID change is an in-place update.

Exit: owned destinations and a concrete migration route exist for every current platform/channel; unverified channel/account fields are labelled unknown.

### R1 — Name, graphics, provenance and visual assets

- [ ] Record a versioned Pleazyng brand specification: exact name, pronunciation, publisher, wordmark, symbol, light/dark/monochrome variants, clear space, minimum sizes, palette, font licences and accessibility labels.
- [ ] Inspect the provenance of every canonical source master. The existing distinct folded-ribbon concept may be adapted if independently created/licensed provenance is recorded; otherwise create a new independent master.
- [ ] Typeset the exact word Pleazyng into the new wordmarks. Rework the NG detail so the icon and wordmark support the chosen whole-word identity rather than relying on an added suffix over upstream art.
- [ ] Do not treat renaming a file, recolouring an upstream logo, adding a letter/badge, cropping a screenshot or regenerating an image hash as an artwork replacement.
- [ ] Replace inherited assets/readme-showcase.webp with actual captures from a renamed build. Audit server-options bases, feature-graphic bases, product illustrations, device masks and website composites for embedded old logos/words/screens.
- [ ] Resolve all 39 exact shared-image matches using the inventory. Retain provider/player/rating marks under their applicable terms and notices. Review the nine README feature pictograms separately. Classify transparent tvOS launch placeholders correctly.
- [ ] Regenerate the complete brand.json target set and all asset-manifest.json exports. Preserve all 23 alternate icon choices and preference IDs while replacing their actual artwork.
- [ ] Update asset paths and references together: pubspec.yaml; lib/widgets/app_brand.dart; app icon catalog; Android XML; Apple Icon Composer JSON; asset catalogs; Linux packaging; Windows resources; webOS/Tizen icon copying; README and docs.
- [ ] Cover Android legacy/adaptive/monochrome/notification icons and TV banners; iOS/iPadOS and alternate icons; macOS icons/DMG decoration; tvOS layered stacks and both Top Shelf formats; Windows ICO/MSIX tiles/splash; Linux PNG/SVG; webOS/Tizen icons and splash; web/PWA icons, favicons and social cards.
- [ ] Replace all embedded PlezyNG/Plezy text in artwork, including the small icon detail and light/dark variants. Keep small icons legible without microscopic lettering.
- [ ] Retain upstream and third-party copyright/licence notices. Describe newly created fork branding accurately; do not relabel upstream art as SnapeTech-original work.
- [ ] Store source masters, provenance, generated file list and checksums together. Update docs/maintainers/branding.md and branding-prompts.json.
- [ ] Inspect exported contact sheets and actual rendered launcher/startup/About/settings/permission surfaces in light, dark, system-tinted, alternate-icon and TV modes. Hash checks alone cannot verify visual correctness.

Exit: no upstream product logo or unreviewed upstream marketing screenshot is presented as Pleazyng's identity; every generated/exported surface is accounted for.

### R2 — Application metadata, links and native packages

| Area | Source anchors | Required work |
| --- | --- | --- |
| Shared Flutter/UI | pubspec.yaml; lib/widgets/app_brand.dart; lib/i18n; About/startup/settings/supporter UI; provider authentication and client headers | Rename public strings, semantic labels, permission explanations, notifications, log-export titles and generated text. Update source translation values and regenerate translations; check RTL and long labels. |
| Android/Fire TV | android/app/build.gradle.kts; android/app/src/main/AndroidManifest.xml; resource aliases; source OAuth; signing/publishing scripts | New applicationId and variant/test IDs, label, file-provider/work authorities, permission names, deep links, launcher entries, notification channels and store-specific package wiring. Verify authorities derived from applicationId. Namespace/class names are not automatically app IDs. |
| iOS | ios/Runner/Info.plist; ios/Runner.xcodeproj/project.pbxproj; localized InfoPlist strings; Icon Composer files | Display name, bundle ID, URL names/schemes, background task identifiers, entitlements, keychain/associated-domain configuration, provisioning and export profiles. Inspect org.plezy.preparation and its native scheduling counterparts together. |
| macOS | macos/Runner/Configs/AppInfo.xcconfig; Info.plist; entitlements; project targets | Product name, application ID, app bundle/executable, URLs, icon references, app support paths and updater metadata. Preserve truthful upstream copyright. |
| tvOS | tvos/Runner/Info.plist; TopShelfExtension/Info.plist; both entitlements; project.pbxproj; shelf provider | Replace residual Plezy labels, update app/extension IDs and app group together, regenerate stacks/shelves, and verify extension-to-app URLs and access. |
| Windows | windows/CMakeLists.txt; runner/Runner.rc; runner/window sources; build-installer.ps1; build-msix.ps1; MSIX assets | Rename public executable, product/window/version metadata, shortcuts, protocol/file associations, installer text, paths and update links. Use the actual Partner Center package identity rather than inventing it. |
| Linux | linux/CMakeLists.txt; runner sources; linux/packaging | Binary, application ID, desktop filename, Name/Exec/Icon/StartupWMClass, D-Bus names if present, MIME handlers, metainfo URLs and package scripts. |
| webOS | webos/meta/appinfo.json; build/runner and packaging scripts | ID/title/vendor/main/icon references, app-service permissions and metadata consistency, IPK filenames and store handoff. |
| Tizen | tizen/tizen-manifest.xml; project/build properties; scripts/tizen/package.py; packaging/tizen/apps2samsung.json | App/package/exec/label/icon IDs and filenames, certificate profile, generated package paths and Seller Office handoff. Validate Samsung constraints and ownership of actual assigned identifiers. |

Link contract:

- [x] Set `DeepLink.scheme` to `pleazyng` and generate canonical links for app shares, QR/NFC, Android automation examples, source handoffs, external-player returns and system shelves.
- [ ] Add the canonical link to a game-launcher surface if the app exposes one; otherwise record that no supported game-launch target exists.
- [x] Register `pleazyng://` on Android, Apple, Linux and Windows; source inspection confirms `pleazyng-source://oauth/callback` on Android and iOS. The checker rejects upstream `plezy://` registration and verifies the fork-only compatibility aliases.
- [x] Preserve the existing link grammar, IDs, parameters, profile/PIN handling and authorization checks. Existing content IDs such as `plezy_<server>_<item>` remain data contracts rather than brand labels.
- [ ] Offer a paste/import converter for old plezy://, plezyng:// and plezxyng:// automations, NFC tags and saved links. Do not automatically register upstream's scheme to provide that compatibility.
- [ ] Existing fork-only scheme aliases may remain only in an explicitly documented, time-bounded bridge build where ownership is clear. New canonical packages emit the new scheme. Document retirement conditions, not an unexplained permanent alias.
- [x] Cover Android intents, Apple URL handling, Linux desktop MIME registration, Windows protocol keys, and core deep-link parsing and authorization behavior.
- [ ] Extend the registration checker to validate the source OAuth callback scheme, then add target-platform callback dispatch coverage; it currently verifies only media-link schemes.

Exit: all final compiled packages identify themselves as Pleazyng, and installing upstream alongside the fork does not give the fork ownership of plezy:// links.

### R3 — Settings, downloads, credentials, purchases and upgrades

A new Android applicationId or Apple bundle ID generally means a different application identity. Do not promise automatic access to the old sandbox, purchase history or keychain. This is a migration work package, not a search/replace.

- [ ] Implement a schema-versioned, user-initiated migration/export/import path with integrity checking, path validation, explicit sensitive-data treatment and a backup before the first write.
- [ ] Preserve profiles, server configuration, reading/watch progress, downloads and their ownership records, playlists, queues, custom themes, icon selection, subtitle settings, game pairings and locally saved work where technically transferable.
- [ ] Never move another application's data by directory-name resemblance. Discover only known fork-owned legacy locations under the current user's control.
- [ ] Make desktop migration idempotent and atomic. Validate a copied database before activating it; keep the source intact; avoid running old and new apps against the same mutable database.
- [ ] Audit lib/services/credential_key_store.dart, credential_vault.dart, native credential plugins and shared-preference implementations. Known legacy keys include plezy_credentials and org.snapetech.plezyng.credential-vault. Keep authenticated decryption possible, or require explicit reconnection; do not silently drop encrypted values or weaken keychain access.
- [ ] Preserve installation/device identities and pairing keys when migrating the same user. A brand rename must not reset trust or impersonate a different paired device.
- [ ] Audit discovery service types, companion-remote names, Plex/Jellyfin/Emby client names, Cast receiver branding, Steam/Decky labels and externally visible user-agent/product headers. Change public names without casually breaking protocol/version compatibility.
- [ ] Inspect purchases and testers in each old store record. New records use pleazyng_lifetime_unlock; existing product IDs and transactions are not renamed in place.
- [ ] Separate old and new SKU lookup by actual channel/app identity. Do not reuse an old receipt as proof of a new-app entitlement without verifying issuer, app/bundle identity, product and ownership through the supported store mechanism.
- [ ] Publish a concrete recovery route for any existing paid users before retiring an old listing: supported entitlement migration, verified replacement access, or an explicit store-supported remediation path. Do not charge again merely because the brand changed.
- [ ] Preserve trial start/entitlement state where it can be transferred securely. A reinstall/new ID must not silently erase purchases or accidentally reset paid-access policy.
- [ ] If an immutable legacy channel ID must be retained for continuity, record the exact exception and its reason in the identity map. Public display names still become Pleazyng; no hidden exception is described as a completed full-ID migration.

Windows installer GUID 4213385e-f7be-4f2b-95f9-54082a28bb8f is currently used by the fork installer. Verify its provenance/ownership before deciding to preserve it for an upgrade or replace it for side-by-side installs. A GUID does not need a spelling change. Renaming plezy.exe requires coordinating all installer/elevation/shortcut/uninstaller references.

Exit: clean installation, supported legacy-fork migration and upstream side-by-side installation have independent evidence; unsupported automatic transfers are plainly documented with a usable manual route.

### R4 — Own services and provider registrations

- [ ] Deploy the fork's server/ on infrastructure controlled by SnapeTech. api.pleazyng.app is the preferred target only after domain/TLS/control are verified; configuration must support a verified SnapeTech-controlled alternative.
- [ ] Replace PLEZY_SERVER_BASE_URL and the dependent commerce/Watchmode defaults with canonical Pleazyng configuration. Require valid fork-owned endpoints for enabled services; a missing endpoint disables that optional integration with a useful message, never a fallback to ice.plezy.app.
- [ ] Audit every occurrence and runtime request involving ice.plezy.app, bugs.plezy.app, upstream OAuth clients and upstream telemetry/poster/log infrastructure, including native code and server config.
- [ ] Create the fork's Discord application, app name, icon, Rich Presence asset keys, OAuth settings and any installer/integration registration. Replace ID 1453773470306402439 in client defaults.
- [ ] Inventory Trakt, MyAnimeList, AniList, Simkl and MDBList registrations. Include cloud/source OAuth (Google Drive, OneDrive, Dropbox and any other configured source), commercial catalog keys, Steam/OpenID/relay registrations, and casting identities where relevant. Replace registrations owned by upstream; preserve legitimate user-provided credentials.
- [ ] Update application names shown on consent screens, HTTPS callback URLs, native callbacks, allowlisted origins, associated domains, app links/assetlinks, Android package/certificate bindings and Apple Team/bundle bindings together.
- [ ] Replace or migrate only credentials SnapeTech controls. Keep secrets in protected configuration; do not copy client secrets into the app, plan or repository.
- [ ] Deploy and test the new OAuth server before shipping clients that depend on it. Verify PKCE/state, trusted redirect allowlists, TTLs, token storage, refresh, cancellation, error handling and QR authorization on TV.
- [ ] Tokens issued to upstream-owned clients normally require reconnection through the new client. Preserve unrelated local data; explain the service-specific reconnect once.
- [ ] Drain only fork-controlled legacy callbacks for a bounded time if needed. Do not forward OAuth codes, tokens, credentials or sensitive query strings through generic marketing redirects.
- [ ] Update server emails/titles, consent text, logs, user-agent names, Discord posters, crash/report endpoints, privacy notices and retention/contact details to the actual new operator.
- [ ] Rebrand compose/service names, public container tags and OCI labels. Preserve volumes and database keys; confirm x64/ARM64 manifests, health checks, package visibility, signing/attestations and pull permissions.
- [ ] Publish new container tags before switching deployments. Keep old pinned digests and a controlled, documented compatibility path for existing fork deployers; a repo rename is not a container-tag migration.

Exit: network evidence from enabled integrations shows no calls to upstream-operated services or registrations; missing optional provisioning is explicit and does not borrow upstream resources.

### R5 — Repository, automation and dependency references

- [ ] Rename the existing main repository to snapetech-org/Pleazyng. Preserve Git history, issues including #149, PRs, releases, tags, stars and access settings. Do not recreate it as a history-free replacement.
- [ ] Rename the existing private website repository to pleazyng.app and preserve its visibility. Preserve the existing private Site identity and audience in .openai/hosting.json.
- [ ] Update repository description, homepage, topics, social-preview image, README badges/download links, FUNDING/support metadata, issue/PR templates and release descriptions for the new public identity.
- [ ] Update remotes in working clones and CI workspaces; retain edde746/plezy as upstream. Do not rename unrelated shared dependencies such as mpv-build or MilkRust merely for this migration.
- [ ] Audit all literal snapetech-org/pleazyng and plezyng.app references in workflows, scripts, source, manifests, lockfiles, website source, native-asset repositories and packaging consumers.
- [ ] Check cross-repository actions/reusable workflow calls, token/repository allowlists, GitHub App installation access, deploy keys, environment policies, package links, Pages/custom-domain settings, webhooks and OIDC trust subjects. Repository redirects do not make every consumer work automatically.
- [ ] Update the shared JIT broker/source routing in snapetech-org/packer where it keys on repository names, and only the relevant repository-specific runner labels. Preserve current compatible-hosted-first routing and private JIT for private resources; do not restart active brokers or displace running work.
- [ ] Keep CodeQL disabled as directed by AGENTS.md. Do not enable it or change runner isolation as incidental rebrand work.
- [ ] Update scripts/release_all_platforms.py, lib/services/update_service.dart, scripts/configure_updater.dart, release notes/download/checksum/coverage/recovery tools, generators and all publish-* workflows together.
- [ ] Preserve cryptographic trust anchors, dependency pins and provenance. If a pinned download URL changes, verify the same bytes or create a truthful new artifact/pin; never invent a new checksum or relabel an old build as newly rebuilt.
- [ ] Audit external helper/plugin packaging, including integrations/steam-cloud-decky, public package labels, module metadata and documentation. Keep internal transport compatibility documented.
- [ ] Leave historical tags and original release asset bytes intact. Do not recycle the old repository name in a way that breaks GitHub redirects.

Exit: checkout, CI dispatch, native artifact resolution, update metadata generation and downstream publication resolve the new repository explicitly, with external dependencies accounted for.

### R6 — Release assets, package managers and stores

Canonical new release filenames use lower-case pleazyng-<platform>-<architecture> with the existing extension conventions. Standard files such as SHA256SUMS.txt, appcast.xml and provenance JSON keep their standard names. The inventory maps every one of the 31 observed v3.0.0 assets to its future naming family; it does not authorize editing that historical release.

| Channel | Implementation and external migration |
| --- | --- |
| GitHub Releases | Use the next unused version, new release title/name, canonical asset names, matching checksums/provenance, accurate release notes and a migration notice. Update release coverage/recovery logic; do not reuse old-brand binaries as newly branded outputs. |
| Sparkle / WinSparkle | Current feed is cdn.jsdelivr.net/gh/snapetech-org/pleazyng@appcast/appcast.xml. Update clients and feed generation to the new repository/verified owned feed URL. Keep a signed, tested bridge for installed old clients; preserve signing keys. Test CDN, old feed URL, app identity and installer handling rather than assuming redirects suffice. |
| Homebrew | Rename Casks/snapetech-plezyng.rb.template and generator references; change cask token, app bundle, URL, name and fork-owned data-path handling. Provide a supported cask migration rather than relying on replacing an installed token. Keep old data during migration; review zap rules. Preserve signing/notarization requirements. |
| WinGet | Move generated identity from SnapeTech.PlezyNG to SnapeTech.Pleazyng; update publisher/package/display/installer URLs, executable and ARP/installer identity. Submit the appropriate new/migration manifests and track repository review. A merged package PR is separate from generating manifests. |
| Chocolatey | Rename nuspec/package/output and install URLs/scripts, preserve upgrade/uninstall behaviour and user data, and handle old-package transition explicitly. Track moderation and installed-package continuity. |
| Debian / Ubuntu PPA | Update package/control/changelog/install filenames, desktop files, repo metadata and instructions. Use Provides/Replaces/Breaks only for proven fork-owned predecessor packages, not upstream Plezy. Keep signatures and archive trust valid. |
| RPM / Fedora COPR | Rename spec/package/provides, icons, desktop/AppStream data and project-facing labels/URLs. Coordinate Obsoletes/Provides for fork predecessors and both architectures. Verify existing project/chroot/publication settings. |
| AUR / Arch binary bundle | Rename the fork package/recipe, pkgname, sources/checksums and commands; use maintainer-supported merge/transition procedures if an old AUR entry is live. Avoid claiming or conflicting with upstream's independent package unnecessarily. |
| AppImage / portable Linux | New executable/desktop/icon/update-information and filenames. Provide a migration/import route for old config directories; validate launch from user paths and the installed desktop integration. |
| Flatpak | New manifest, metainfo, desktop filename, app ID and command. New ID means a different app/data directory; provide documented export/import or an actual repository-supported migration. GitHub bundles are not a Flathub publication. If submitting to Flathub later, use its source/review requirements. |
| Snap Store | Register pleazyng, update snapcraft.yaml name/title/apps/desktop/commands and publisher credentials for that name/channels. Existing name/ID and confined data do not automatically move. Provide migration instructions and validate the new confinement/permissions. |
| Google Play | New applicationId requires a new app record. Recreate/verify listing, Play App Signing/upload settings, API account app permissions, IAP product, testing groups/tracks, content/data-safety/privacy/foreground-service declarations and test videos under the new identity. Regenerate opt-in links. Do not assume old testers, eligibility, purchases, reviews or track state transfer. |
| Amazon / Fire TV | Verify whether the prepared record can accept the intended package identity; otherwise create a replacement record. Update name, SKU/IAP mapping, API app/security-profile binding and AppstoreAuthenticationKey.pem from the correct app record. Recreate listing assets, ratings, privacy, export compliance and testing; validate real IAP recovery/fulfilment. |
| Apple iOS / tvOS | Register new app/extension IDs and app group, profiles, entitlements, associated domains and app records as required. Bundle IDs cannot be edited after a build upload; SKU is also immutable. Product IDs cannot be renamed. Update both platforms' copy, IAP configuration, beta groups, review notes, privacy/age/accessibility/export metadata and all screenshots; preserve existing purchasers through a concrete supported route. |
| macOS direct | Update bundle/product/DMG names, appcast and notarized packaging; verify old-to-new update identity and keychain/data migration. No Mac App Store migration is assumed: it is not a configured channel in the inspected sources. |
| Microsoft Store | Reserve the new display name and inspect the actual existing Partner Center record before deciding whether identity continuity or a new listing is required. Use assigned Identity.Name/Publisher and repository variables exactly; update assets, protocols, screenshots, listing URLs and submission material. Do not assume Microsoft can rename every immutable package field. |
| Samsung Seller Office | Reconcile package identifiers and store record, author/distributor certificates, tester handoff, device re-signing instructions, screenshots, age/region/privacy/qualification data and package match/output names. Experimental tester output does not establish Seller Office publication. |
| LG Content Store | Reconcile app ID, IPK, runtime redistribution permission, supported firmware/models, signing/submission data and actual-device screenshots. Existing qualification/redistribution gates remain; missing public webOS output is not hidden by the rename. |
| Nix / other community packages | Identify actual fork entries and maintainers first; update new name/source/hash/app data through their normal process. Do not rewrite upstream Plezy entries as this fork. |
| Relay GHCR / Docker Hub | Publish pleazyng-relay images, update OCI metadata/source links, pull permissions, deployment manifests and multiarch verification. Preserve existing data/rollback and record how old fork tags are retired. |
| Release announcements / badges | Rebrand generated notes, embeds, icons, support links and webhook configuration. Prepare accurate copy; do not announce completion before channel evidence exists. |

Source anchors include .github/workflows/build.yml; publish-app-stores.yml; publish-{aur,chocolatey,copr,ppa,snap,winget}.yml; release-containers.yml; update-packages.yml; fastlane/Fastfile; windows/build-{installer,msix}.ps1; scripts/generate_{homebrew_cask,winget_manifests}.py; linux/packaging; packaging/chocolatey; packaging/tizen; and scripts/tv_store_submission.py.

Channel receipts must distinguish **built**, **signed**, **uploaded**, **processed**, **submitted**, **approved**, **published** and **verified installed**. Credentials or code presence do not prove publication.

### R7 — Website, domains, support and public collateral

- [ ] Establish control of pleazyng.app and any www/API/update subdomains before shipping URLs or changing OAuth origins. Preserve renewal, DNS/TLS and security settings.
- [ ] Update the private website's templates/home.html, locales.json, package.json, scripts/build.py/check.py/sync_branding.py, generated dist, site.webmanifest, robots/canonical/social metadata, favicons, accessibility text and source/download/privacy/support links.
- [ ] Import verified app brand exports through scripts/sync_branding.py; refresh dist/assets/branding/manifest.json. Do not independently modify copies that will be overwritten by the sync.
- [ ] Replace or update dist/assets/plezyng*.png/webp/svg product composites and masks; inspect embedded screens and old-name text. Preserve truthful “interface concept” labels on illustrations, and use real captures for store screenshot slots.
- [ ] Keep the established single-screen layout, appearance controls and single-line provider/platform carousel. A name migration is not authorization for an unrelated site redesign.
- [ ] Audit the actual Cloudflare Pages project, custom domains, deployment branch/command, Tunnel/DNS routes and home NGINX/ACME rollback origin. Source names currently include plezyng-app; README deployment claims are stale relative to the manual workflow. Record what is deployed before changing it.
- [ ] Update the Cloudflare deployment target or create a correctly named replacement project if needed, then validate preview, TLS, domain binding and production output. Keep old service data and rollback state until cutover is verified.
- [ ] Update docker/nginx config, compose image/service metadata, certificate deployment hook and systemd service/timer names where relevant. Do not blindly move mounted data or restart shared infrastructure.
- [ ] Keep the old fork domain under control and serve a clear migration notice plus safe redirects to the new site. Preserve path/fragment links where supported. Do not redirect OAuth/sensitive URLs indiscriminately, and do not assume browser localStorage or cookies transfer between domains.
- [ ] Migrate the website's plezyng-theme appearance preference only through a supported, non-sensitive mechanism; default safely when the new origin has no previous preference.
- [ ] Update PRIVACY.md, support/contact addresses, store policy links, legal/credits/About copy, community/server display names, package catalog badges, social-preview graphics and public profile links actually controlled by SnapeTech. Preserve provider notices and upstream GPL attribution.
- [ ] Check external references owned by other SnapeTech projects, native build repositories, tap/manifests, download directories, app directories and support tooling. Uncontrolled third-party pages get a correction request, not an assumed completed update.

Exit: new identity and links are consistent across the actual site, metadata, download path and store collateral; old fork links still lead users to an accurate migration route.

### R8 — Validation, cutover and evidence

Documentation planning needs no native build. Implementation validation must exercise the affected contracts.

- [ ] Add a scoped old-brand regression check with an explicit allowlist for history, licences, upstream references, compatibility/data keys and internal namespaces. It must reject residual old public branding, upstream runtime services and native registration of plezy://.
- [ ] Run existing brand export/check scripts, app icon/deep-link checks and relevant focused tests after changing their inputs; inspect all changed generated outputs. Update tests' expectations rather than deleting checks.
- [ ] Validate actual Android manifests; Apple plists/entitlements/compiled asset catalogs; Windows PE/installer/MSIX metadata; Linux desktop/AppStream/package metadata; Tizen manifest/TPK; and webOS appinfo/IPK.
- [ ] Test clean installs, legacy fork migration, wrong-signature rejection, upstream coexistence, launch shortcuts, file/protocol opening, preferences/downloads/credentials, restoring purchases, uninstall safety and signed updater behaviour.
- [ ] Exercise real authorization and callback flows through each enabled new provider registration, including TV QR auth. Record network destinations and consent-screen brand evidence without leaking credentials.
- [ ] Validate the new site at mobile/desktop/TV widths, light/dark/system appearance, RTL, keyboard/screen-reader labels and link destinations. Capture new store assets from the actual intended app/platform.
- [ ] Rebuild every required release platform on appropriate OS/architecture. Current AGENTS.md requires Android, Linux x64/arm64, Windows x64/arm64, universal macOS, iOS, tvOS, Tizen and webOS release artifacts. Resolve existing blockers rather than omitting a required platform.
- [ ] Check the exact release candidate SHA against its CI, package identities, complete asset matrix, checksums, signatures, provenance and migration instructions. A brand change prevents treating old-brand platform binaries as equivalent candidate outputs.
- [ ] Deploy fork services and website redirects first, then publish compatible bridge material, then the new client release, then downstream package/store changes in a controlled order.
- [ ] Keep channels paused individually when their new identity/entitlement/signing configuration is incomplete; record the real blocked state. Do not describe a channel-skipped receipt as full migration completion.
- [ ] Confirm repository redirects, raw/CDN artifact URLs, update feeds and downloads as an anonymous user where intended. Explicitly test new Git remotes and cross-repository workflow consumers.
- [ ] Update release-channels.md, full-release-build.md, homebrew-cask.md, store-listing-copy.md, branding.md, platform guides, PRIVACY.md, README and current website runbooks to the final state. Preserve historical receipts/tags as historical evidence.
- [ ] Record completion evidence for each platform/channel and the actual first Pleazyng version. The owner posts the issue reply; no automated issue comment is part of this planning task.

Exit: each claimed platform/channel is verifiably complete at its stated stage, and all residual exceptions have an explicit reason, migration route and retirement condition.

## 4. Compatibility and rollback rules

1. Preserve upstream attribution, GPL notices, third-party licences and source history. “Based on Plezy” is a factual origin statement, not the new product's display name.
2. Keep the Dart package name plezy, internal Kotlin namespace com.edde746.plezy, JNI/method-channel names and native library/ABI symbols initially where changing them creates unrelated breakage. Document their internal-only status and any necessary compatibility readers. Public app/package IDs and user-facing metadata still follow the new map.
3. Do not rewrite existing databases, stable media IDs, external service identifiers, signatures, test fixtures or dependency hashes with an unrestricted global replacement.
4. Continue to recognise securely owned old purchases/data while migrating; do not overwrite old receipts or delete the only source copy.
5. A rollback restores the previous tested application/configuration and data snapshot. Keep new branding services, DNS and old update routes controlled while rollback clients may still use them.
6. Never “roll back” by borrowing upstream's Discord, OAuth, telemetry, poster or infrastructure registrations.
7. Never force-update tags, replace attested historical binaries, recreate old repository names that invalidate redirects, or publish a new identity with mismatched signing.
8. Old fork paths, cask tokens and data locations remain only as explicit migration compatibility, not unexplained new-product branding.

## 5. Completion ledger to populate during implementation

| Work package | Status at this commit | Evidence needed |
| --- | --- | --- |
| R0 inventory and continuity | Planned; source snapshot captured | Refreshed occurrence scan, owned destinations, per-platform user/purchase migration table |
| R1 name and artwork | Planned; hash comparison and four image inspections completed | Provenance, new masters, complete exports, fresh screenshots and visual review |
| R2 native app/package/link identities | Planned | Inspected final binaries/manifests and coexistence results |
| R3 data and entitlement migration | Planned | Upgrade/import/recovery results for each affected identity |
| R4 services and provider registrations | Planned; upstream defaults identified | Fork ownership, consent/callback and network evidence |
| R5 repositories and automation | Application repository/local checkout migrated on 2026-11-08; other repository/registry renames separate | [Repository, redirect and runner routing record](repository-rename.md) |
| R6 publishing channels | Planned; existing GitHub release verified | Per-channel records, signed outputs and publication-stage receipts |
| R7 website and public collateral | Planned; private site source inspected | Domain control, actual deployment, redirects, complete branding sync |
| R8 release verification and cutover | Planned | Complete platform matrix, exact-SHA evidence and final migration record |

The first implementation commit should refresh this ledger and inventory. A checked box requires an actual result; it is not satisfied by changing this plan's wording.

## 6. Primary references checked for migration constraints

- [GitHub repository rename behaviour](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository): Git/web redirects have exceptions; hosted action references do not automatically redirect, and reusing the old repository name breaks redirects.
- [Google Play app setup and permanent package names](https://support.google.com/googleplay/android-developer/answer/9859152): changing the application ID is not a rename of an existing package record.
- [Apple app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information): bundle ID cannot change after a build upload; SKU is immutable after creation.
- [Apple in-app purchase information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information) and [editing IAP information](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/view-and-edit-in-app-purchase-information): product IDs and purchase type are not ordinary editable branding.
- [Snap name registration](https://snapcraft.io/docs/registering-your-app-name/): names are unique and cannot simply be changed after registration.
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) and [Google impersonation policy](https://support.google.com/googleplay/android-developer/answer/9888374): platform review still applies to the resulting presentation.

External configuration and policies must be rechecked when executing the affected work package. This plan preserves the selected Pleazyng direction without claiming that a source-code commit performs an external migration.
