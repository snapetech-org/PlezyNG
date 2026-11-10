# aerynOS qualification — 2026-11-09

**Result: package build and installation pass; video playback fails.** Do not
advertise this candidate as a qualified aerynOS release.

## Tested inputs

- Pleazyng `v3.0.7` x64 release archive, SHA-256
  `fbe98082916f0131981d71e4fee4dba900a2da1b62d9f82b9a3555e1da09fde9`.
  Its checksum manifest passed the repository's GitHub attestation verifier.
- aerynOS 2026.11 GNOME live ISO, SHA-256
  `e348b88da07e5876d1e0fc50e156f0a062c58251ab6deb2a897155980fa6c419`.
  The official root filesystem was copied to a task-owned ext4 disk and booted
  with its own `7.2.14-71.stable` kernel, initrd, UEFI and systemd-boot. This tests
  the operating system and package, not the Lichen installation procedure.
- QEMU/KVM on kspld0: two CPUs, 8 GiB RAM, virtio graphics and Mesa llvmpipe;
  Boulder `v0.26.10`, Git revision `7630acf727195fba7cac4bdb76cbe8bdb25aad73`.
- Generated recipe revision `recipes-v3.0.7-r6/aerynos/stone.yaml` in the retained
  evidence directory. The package is `pleazyng-3.0.7-1-1-x86_64.stone`.
- A separate, task-owned Jellyfin 10.11.11 container with deterministic media,
  a 60-second H.264/AAC test pattern and fixture accounts. No personal server
  account was used.

## Results

| Check | Result |
| --- | --- |
| Recipe preparation and real ELF relocation regressions | Six tests pass |
| Native Boulder build | Pass; one complete package, no development split |
| Dependency metadata | Pass; bundled libraries resolve privately and private CMake/pkgconfig/Python metadata is not advertised as system providers |
| Local Moss repository, dry run and actual installation | Pass; exit 0, package registered as installed |
| Installed dynamic ELF dependencies | 402 checked, zero missing libraries or inspection errors |
| Desktop launch, database and credential storage | Pass; fresh keyring created, application relaunch retains the Jellyfin connection |
| Jellyfin discovery, sign-in, three libraries and movie detail | Pass |
| Playback | Fail; timeline and audio advance, but the preceding detail view remains in the video aperture |
| Matching WebKit helper processes | Pass; bundled WebKit MiniBrowser displays the fixture server's login page, with WebKitWebProcess and WebKitNetworkProcess running |
| Experimental Dolby Vision setting | Off initially; opt-in survives application restart; restored to Off after testing |
| Packaged Dolby Vision CLI | `--help` executes successfully |
| Process crashes | No guest coredumps recorded |

## Playback blocker

The published archive reports `v3.0.7+166 (9de07ca)`. The tag's
`lib/mpv/video.dart` returns an empty transparent widget for native video, which
retains pixels from the covered route. Main already contains the aperture-clear
repair in [5ba78320a](https://github.com/snapetech-org/pleazyng/commit/5ba78320ab54f4fdd7d9d3927a6d30c30f70461c).
That repair is absent from this immutable release bundle. The VM observation
matches that failure; it does not qualify the repair on aerynOS.

Repoint the recipe to a newly published, attested Linux bundle containing the
repair, regenerate it, then repeat installation and pixel-visible playback QA.
Do not replace the existing v3.0.7 asset or mark a dependency/install pass as a
playback pass. No new application release was built or published in this task.

The guest also logs Fontconfig configuration-version warnings and an optional
Canberra GTK module warning. Text and the tested WebKit page render, but these
diagnostics remain recorded. Hardware decoding falls back to software in the
VM. Physical GPU decoding, HDR/Dolby Vision/FEL output, NPU execution, Plex/Emby
accounts, offline playback and all-platform release qualification are untested.

## Evidence and retained instance

Evidence is retained on kspld0 at
`/home/keith/Documents/qa/pleazyng-aerynos-20261109/`: the final generated recipe
and helpers, package and checksum, preparation receipts, native build/install
logs, manifest, dependency checks, runtime journal and screenshots. Earlier
recipe revisions and failed/superseded build logs remain as evidence.

The task-owned VM is powered off after QA and retained for inspection. Its
startup script and disk paths are recorded in `vm/README.txt` alongside the
disks. The unrelated Agent GUI VM, desktop pool and browser profiles are
unchanged. The fixture container is stopped after QA.
