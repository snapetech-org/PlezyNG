# Pleazyng Linux distribution channels

Audit: 2026-11-09. This guide distinguishes shipped GitHub packages, configured
publishers, generated recipe candidates and accepted distribution entries.
It does not qualify a channel merely because a credential exists.

## Verified state

The published `v3.0.7` GitHub release contains x64 and ARM64 tarballs, Pacman
packages, RPMs and Flatpak bundles. These are named `pleazyng-linux-*` and the
Flatpak application ID is `org.snapetech.pleazyng`.

| Channel | Verified publication / native evidence | Remaining acceptance or qualification |
| --- | --- | --- |
| GitHub direct Linux bundles | Existing immutable v3.0.7 x64/ARM64 artifacts and attested checksum manifest preserved | The repaired channel repacks below do not modify those original assets |
| AUR | Public `pleazyng-bin` 3.0.7-3, commit `bad1d8026657d10bac568abb5e03762870f9f433`; [publisher run](https://github.com/snapetech-org/pleazyng/actions/runs/42715848434) succeeded. Native x64 makepkg build and clean Arch install resolve the app and matched WebKit helper ELF dependencies | Native ARM recipe installation and hardware playback remain separate |
| COPR | [Build 11294319](https://copr.fedorainfracloud.org/coprs/build/11294319/) succeeded on Fedora 43/44/45/rawhide, x86_64 and aarch64. Native Fedora 43 repack, clean local RPM install and clean installation from public `slskdn/pleazyng` all passed | RHEL dependency support, other Fedora desktop sessions and hardware playback remain separate |
| Nix | [Both native builds](https://github.com/snapetech-org/pleazyng/actions/runs/42714489114) passed. Maintained locked flake built locally. Software WebView smoke rendered HTML and ran JavaScript with WebKit sandbox enabled (`NoNewPrivs=1`, `Seccomp=2`). Final Nixpkgs proposal also built on x64 | [Nixpkgs PR 585758](https://github.com/NixOS/nixpkgs/pull/585758) awaits maintainer acceptance; full NixOS desktop and hardware playback remain unqualified |
| Google Play | Existing v3.0.7+166 AAB uploaded to closed Alpha; foreground-service declaration and release notes saved; release saved in Publishing overview, ready for review. Lifetime SKU is active at USD 2.99 base in 174 regions. Compiled reviewer public key matches on all three ABIs | Signed-build expired-trial grant redemption, purchase/restore, Google review and actual test activation remain gates; `GOOGLE_PLAY_BOOTSTRAP_COMPLETE` stays false |
| Homebrew | Tap Cask 3.0.7 published by [run 42702581594](https://github.com/snapetech-org/pleazyng/actions/runs/42702581594); [native signature/ticket/Gatekeeper qualification](https://github.com/snapetech-org/pleazyng/actions/runs/42702586238) passed | [Native Cask installation and installed-app Gatekeeper qualification](https://github.com/snapetech-org/pleazyng/actions/runs/42717147909) passed |
| aerynOS / Moss | Independent x86_64 preview: native build/install, visible video, default-on P7 routing and renderer-failure fallback pass | [Install and review](https://github.com/snapetech-org/pleazyng-aerynos); [snapshot qualification](aerynos-snapshot-qualification.md); physical HDR/FEL accuracy unqualified |

The AUR RPC and cgit responses may be cached briefly after a push. Verify the
public Git head and use a fresh RPC request before treating stale metadata as a
failed publication. COPR submission success alone is not asynchronous build
success; inspect every supported chroot.

Homebrew installation uses the fully qualified Cask name, granting trust only
to that item under [Homebrew tap trust](https://docs.brew.sh/Tap-Trust).

All work above repairs delivery against the existing v3.0.7 artifacts. No new
all-platform application build was requested. Dated machine-readable evidence
is retained in [the first-publication receipt](releases/v3.0.7-channels.json).

## Prepare immutable Nix and aerynOS candidates

Use a fresh task-owned scratch directory on a host with sufficient free space.
Download only the checksum manifest first, then authenticate it using the
repository's attestation verifier. The renderer is offline: its input is trusted
only after this verification succeeds.

```sh
gh release download v3.0.7 --repo snapetech-org/pleazyng \
  --pattern SHA256SUMS.txt --dir "$channel_scratch"
python3 scripts/verify_release_attestation.py "$channel_scratch/SHA256SUMS.txt" \
  --repo snapetech-org/pleazyng
python3 scripts/prepare_linux_channel_recipes.py --tag v3.0.7 \
  --checksums "$channel_scratch/SHA256SUMS.txt" \
  --output "$channel_scratch/recipes-v3.0.7"
```

Set `channel_scratch` to the confirmed task directory before running these
commands. Substitute the intended published release tag consistently. Generation
requires exactly one valid checksum for each architecture and refuses to replace
an existing output directory. The handoff includes desktop entries, license,
cache relocation helper and `preparation.json` with hashes, release identity and
explicit unqualified/unpublished state. Keep it with the qualification logs.

The Nix candidate retains the whole binary bundle inside `buildFHSEnv` so the
custom native engines, neural providers and models remain present. This is a
compatibility environment, not a security sandbox. Its runtime must include
`xkeyboard-config`: the bundled GTK stack reads `/usr/share/X11/xkb` inside the
FHS environment. Without that data, native application startup can fail before
the sign-in screen, even when the package builds successfully. Verify real app
startup and keyboard input separately from the WebKit sandbox probe; neither
alone establishes visible video playback. On each native Nix host:

```sh
nix-build "$channel_scratch/recipes-v3.0.7/nix/pleazyng.nix" -o "$channel_scratch/nix-result"
"$channel_scratch/nix-result/bin/pleazyng"
```

The rendered expression uses the host's `<nixpkgs>`. The maintained flake pins
revision `4fe25e12eb9f4c744966dd3de5a05246cf098601`, which passed native builds
on x64 and ARM64. Use the locked flake for user installation.

The v3.0.7 checksum manifest passed GitHub attestation verification against
`snapetech-org/pleazyng` (repository ID `1433487464`). The Nix candidate was
generated from that manifest. Four preparation/cache-relocation tests and five
existing Linux launcher/COPR staging tests passed. These checks validate
preparation and staging, not playback.

The recipe preserves the full media bundle layout, regenerates the released
empty GdkPixbuf module cache with a native ABI-compatible query tool, and
relocates its paths. Exact Ubuntu WebKit 2.52.6 helper packages are pinned by
signed-index checksums in `linux/packaging/webkit-runtime.json`; the installer
requires the released library and downloaded package library to match
byte-for-byte before staging helpers. The helpers occupy the Ubuntu multiarch
paths compiled into the production library. `WEBKIT_EXEC_PATH` is not a
production-library repair. Nix's bubblewrap adapter exposes only the immutable
runtime closure read-only to WebKit's nested sandbox; it does not disable the
sandbox. The native software smoke explicitly enables MiniBrowser's sandbox,
checks the actual WebKitWebProcess executable and seccomp state, and serves only
a local test page. That test does not establish hardware video qualification.

The matching helpers and cache repair apply to channel repacks; immutable
GitHub binary packages are unchanged.
For complete desktop/device qualification, verify fonts, TLS, desktop/URI launch, file
chooser, Wayland video, GPU drivers/hardware decoding, audio, offline downloads,
and persisted automatic-DV and optional neural settings with packaged native components.
Inspect every bundled ELF and provider, including dynamically loaded libraries;
resolve dependency and duplicate-provider conflicts without silently deleting
experimental engines or substituting a system mpv. Keep automatic DV/FEL and compatibility fallback enabled by default; neural
motion processing remains off by default.

Repository submission must include a maintainer, license/provenance review and
the tested native outputs. Confirm whether each community requires source
builds; a request for source packaging is a separate build adaptation, not a
reason to describe a binary candidate as accepted. The renderer does not submit PRs. The approved Nixpkgs PR is linked above; no binary cache is configured.

## aerynOS

Use `--channel aerynos` to prepare only this x86_64 channel; this requires only
the x64 checksum. The default also prepares Nix and requires both architectures.

The same preparation command produces `aerynos/stone.yaml` and its supporting
files in `aerynos/pkg/`, as required by Boulder's `%(pkgdir)` macro. This recipe
packages the x86_64 release bundle. It does not build the app from source or
add an ARM64 aerynOS port.

The archive has no enclosing directory, so `stripdirs: 0` is required. The
recipe preserves the bundled engines, providers and models, installs the
checksum-pinned WebKit helper processes matching the bundled library,
normalizes ELF search paths, and rebuilds the GdkPixbuf cache with installed
paths. Stripping and debug splitting are disabled. ELF search paths and cache
files change during packaging; the native components remain included.

On an aerynOS host with Boulder configured:

```sh
cd "$channel_scratch/recipes-v3.0.7/aerynos"
boulder build stone.yaml
```

Inspect the resulting manifest for dependency/provider conflicts and unintended
subpackage splitting before indexing and installing the `.stone` output in the isolated
test instance. The current Moss CLI uses `moss index --input-dir <output-dir>`,
`moss repo add <name> file://<absolute-output-dir>/stone.index`, and
`moss -y pkg add pleazyng`. Keep qualification repositories local to the test guest until native QA passes. Retain the package, manifest, build/install logs and runtime QA
evidence. Increment `release` for recipe-only changes to an already distributed
version. See the [native qualification record](aerynos-qualification.md): build
and installation pass; the published v3.0.7 input fails video playback QA.
The separately versioned [3.0.22+181 source snapshot](aerynos-snapshot-qualification.md)
passes native visible-video and fallback checks and is delivered through the
[independent preview feed](https://github.com/snapetech-org/pleazyng-aerynos).

aerynOS is a downstream publication target. Qualify the exact package before
publishing an independent Moss repository; retain the source checksum and native
evidence. The renderer itself performs no publication or official submission. The official project's
[contribution policy](https://github.com/aerynOS/.github/blob/main/CONTRIBUTING.md#llm-contributions)
prohibits LLM-generated contributions; a human submitting this AI-assisted recipe
does not change its authorship. That policy does not establish a prohibition on
independently publishing compatible packages or on packaging an application
whose upstream code includes AI-assisted work.

## Publish already-built Arch and Fedora artifacts

### EL10 target bootstrap

`bootstrap-copr-el10.yml` enables `epel-10-x86_64` and `epel-10-aarch64` on
the existing `slskdn/pleazyng` project. It preserves every enabled target and
other project setting, verifies the resulting public configuration, and retains
a receipt. It uses the existing COPR API secrets only on canonical main;
credentials remain in process memory. Repeating it makes no changes when the
targets are already enabled. It shares the publisher's concurrency group and
does not submit an application or package build.

Once enabled, ordinary COPR submissions include those targets on future releases.
Enabling an empty target is not native qualification. Check every asynchronous
build, then install the exact release on clean EL10 with EPEL and CRB enabled.
Verify dependencies, ordinary startup and playback before adding supported
Red Hat installation instructions. The EPEL10 COPR environments use CentOS
Stream plus EPEL; record the tested OS rather than claiming RHEL certification.

Use the [channel retry guide](release-channel-retries.md) with the qualified
immutable release. Existing `publish-aur.yml` and `publish-copr.yml` use hosted
Ubuntu and require a published stable tag on main's history. Do not rebuild all
platforms to repair delivery. Inspect existing runs and side effects first;
an accepted COPR submission is not proof that its asynchronous builds passed.

After successful COPR builds, verify on supported clean Fedora hosts:

```sh
sudo dnf copr enable slskdn/pleazyng
sudo dnf install pleazyng
```

Publish these repository commands to the README only after that check. For AUR,
verify the actual public package, then document `makepkg -si` from its reviewed
recipe or the user's preferred AUR client; do not advertise `pacman -S` without
a configured binary package repository.

## Google Play activation

Follow [publishing readiness](publishing-readiness.md) and the dated
[identity migration receipt](pleazyng-channel-migration.json). Keep the bootstrap
flag false until the matching app's first console setup and signed-artifact
validation succeed. Confirm tester assignment, purchase/restore, reviewer
access, regions and review status before activating Alpha. The public test URL
must use `org.snapetech.pleazyng`. Apply the
[12-testers/14-days requirement](https://support.google.com/googleplay/android-developer/answer/14151465)
only where it applies to the current developer account; recheck after account
conversion. Never treat an upload or completed workflow as review approval.

## Packaging references

- [Nixpkgs FHS environments](https://nixos.org/manual/nixpkgs/stable/#sec-fhs-environments)
- [aerynOS upstream archive options](https://aerynos.com/packaging/recipes/upstreams/)
- [aerynOS package definitions and runtime dependencies](https://aerynos.com/packaging/recipes/package-definition/)

These candidates package Pleazyng's own release bundles. They do not copy the
upstream Plezy recipes or imply participation by their maintainers.

### aerynOS source synchronization

Canonical main pushes wake the consumer's metadata-only `source-sync.yml`
receiver through `aerynos-source-push.yml`. The receiver ignores event payloads,
resolves authoritative canonical main, and advances only its source-tracking
record after identity, ancestry and compare-and-swap checks. The scheduled
consumer reconciliation remains a catch-up path subject to GitHub availability.
A source record does not qualify or publish a package; native acceptance and
last-good public-feed promotion retain their separate gates. Dispatch credential
failures are source-delivery follow-up work and never request a core rebuild.

Configure `AERYNOS_SOURCE_DISPATCH_TOKEN` in the canonical repository's Actions
secrets with a fine-grained token restricted to `snapetech-org/pleazyng-aerynos`,
Contents write and mandatory Metadata read. Keep the Homebrew tap credential
restricted to its own repository. Rotate the dispatch token before its expiry;
an expired or pending-approval token leaves scheduled catch-up available.
