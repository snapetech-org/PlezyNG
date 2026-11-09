# Pleazyng Linux distribution channels

Audit: 2026-11-09. This guide distinguishes shipped GitHub packages, configured
publishers, generated recipe candidates and accepted distribution entries.
It does not qualify a channel merely because a credential exists.

## Verified state

The published `v3.0.7` GitHub release contains x64 and ARM64 tarballs, Pacman
packages, RPMs and Flatpak bundles. These are named `pleazyng-linux-*` and the
Flatpak application ID is `org.snapetech.pleazyng`.

| Channel | Evidence checked | Remaining before channel availability |
| --- | --- | --- |
| Arch / Pacman direct | Both `.pkg.tar.zst` assets exist in v3.0.7 | Users install the matching asset with `pacman -U`; this does not register a pacman repository |
| AUR | Public RPC returns zero entries for `pleazyng-bin`; repository variable and SSH secret name exist; no publisher runs recorded | Validate the rendered recipe with native `makepkg`, publish it, and verify its public `.SRCINFO`, both architecture URLs and package installation |
| Fedora RPM direct | Both RPM assets exist in v3.0.7 | Use `dnf install ./pleazyng-linux-<arch>.rpm`; RHEL dependency support needs separate qualification |
| COPR | Project target `slskdn/pleazyng` and credential names configured; public build list empty; no publisher runs recorded | Submit checked SRPM, wait for successful supported Fedora x86_64/aarch64 builds and verify repository installation |
| Nix | Candidate generator and FHS bundle recipe added | Build on x86_64-linux and aarch64-linux, qualify runtime and pin the tested nixpkgs revision; arrange maintainer and nixpkgs review or a maintained downstream distribution |
| Google Play | New app ID recorded as `org.snapetech.pleazyng`; `GOOGLE_PLAY_BOOTSTRAP_COMPLETE=false`, track `alpha`, status `completed`; AAB exists in v3.0.7 | First console bootstrap/App Signing, signed AAB and purchase/reviewer-access qualification, review and explicit activation; an AAB on GitHub does not prove a live test |
| Homebrew | Dedicated tap configured, but Cask raw-file request returned 404 | Signed/notarized/Gatekeeper-qualified DMG and successful verified tap publication |

Public checks used the [AUR RPC](https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=pleazyng-bin),
[COPR build API](https://copr.fedorainfracloud.org/api_3/build/list?ownername=slskdn&projectname=pleazyng),
and [GitHub v3.0.7 assets](https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.7).
Treat these results as dated evidence and recheck before acting.
No package publisher or app-store upload was dispatched during this audit.

## Prepare immutable Nix candidates

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
compatibility environment, not a security sandbox. On each native Nix host:

```sh
nix-build "$channel_scratch/recipes-v3.0.7/nix/pleazyng.nix" -o "$channel_scratch/nix-result"
"$channel_scratch/nix-result/bin/pleazyng"
```

The expression currently uses the host's `<nixpkgs>`; record and pin the revision
that passes evaluation and runtime qualification before distributing it.

The v3.0.7 checksum manifest passed GitHub attestation verification against
`snapetech-org/pleazyng` (repository ID `1433487464`). The Nix candidate was
generated from that manifest. Four preparation/cache-relocation tests and five
existing Linux launcher/COPR staging tests passed. These checks validate
preparation and staging, not playback.

The recipe preserves the full bundle layout and relocates GTK cache paths.
Before advertising the channel, verify fonts, TLS, desktop/URI launch, file
chooser, Wayland video, GPU drivers/hardware decoding, audio, offline downloads,
and persisted opt-in experimental settings with packaged native components.
Inspect every bundled ELF and provider, including dynamically loaded libraries;
resolve dependency and duplicate-provider conflicts without silently deleting
experimental engines or substituting a system mpv. Keep Off as the default.

Repository submission must include a maintainer, license/provenance review and
the tested native outputs. Confirm whether each community requires source
builds; a request for source packaging is a separate build adaptation, not a
reason to describe a binary candidate as accepted. No nixpkgs PR is submitted
by the renderer and no binary cache is configured.

## Publish already-built Arch and Fedora artifacts

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

These candidates package Pleazyng's own release bundles. They do not copy the
upstream Plezy recipes or imply participation by their maintainers.
