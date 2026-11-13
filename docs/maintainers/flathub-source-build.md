# Flathub source-build gap

Audit: 2026-11-13. Flathub remains **not submitted**. This record covers the
maintained Linux source inputs and the blockers for an offline source build; it
does not qualify the app, either architecture, or desktop playback.

## Requirements and authorship gate

Flathub requires all build and runtime dependencies to be available as declared
sources because its build has no network access. Source-available applications
and included runtime dependencies must be built entirely from source. Flathub
also builds both `x86_64` and `aarch64` by default. See the current
[Flathub requirements](https://docs.flathub.org/docs/for-app-authors/requirements#no-network-access-during-build)
for the [offline build rule](https://docs.flathub.org/docs/for-app-authors/requirements#building-from-source),
[default architectures](https://docs.flathub.org/docs/for-app-authors/requirements#flathubjson),
and [manifest authorship rule](https://docs.flathub.org/docs/for-app-authors/requirements#generative-ai-policy).

The authorship rule prohibits AI-generated or AI-assisted Flathub manifest
content. This change adds no Flathub manifest and does not open or prepare a
submission. A future manifest must be authored and reviewed by a human. The
maintainer audit command is not a manifest generator or a submission-readiness
claim.

## Current GitHub bundle path

The existing
[`org.snapetech.pleazyng.json`](../../linux/packaging/flatpak/org.snapetech.pleazyng.json)
uses a local `bundle` directory source. The directory already contains the
resolved Flutter application and native runtime components. The
[`build-flatpak.py`](../../linux/packaging/build-flatpak.py) packager consumes a
prepared release bundle; it does not build the app or those components from
source. Keep that GitHub release bundle lane separate from any future Flathub
source build.

## Locked inputs

Run the read-only inventory from the repository root:

```sh
python3 scripts/audit_linux_source_build.py
```

The command writes a JSON inventory to stdout and exits `2` while the source
build is not ready. It reads `pubspec.lock`, the native lock files and the
optional local Pub cache; it does not fetch files, build, or write a report.
Its lock inventory covers all packages, including other platforms, rather than
claiming to resolve a Linux-only dependency graph.

At this audit, `pubspec.lock` contains 313 packages: 279 hosted sources with
full SHA-256 hashes, 11 Git sources pinned to commit IDs, 18 local path sources,
and 5 SDK packages. The hosted source archives all have lock hashes. The local
cache contains license-file evidence for 297 locked packages; the 11 Git and 5
SDK package sources are not present in that cache, so their license files were
not inspected by this run. A missing local-cache file is not evidence that a
license is absent upstream.

The `sherpa_onnx_linux` 2.0.1 package is a concrete source-build blocker. Its
locked pub archive SHA-256 is
`4424b09fd26ba79c970b4031d78e58e16f902cb9ef43eeb3809e2dff75246c27`, but that
archive contains six Linux ELF shared libraries: ONNX Runtime, Sherpa's C API,
and Sherpa's C++ API for each of x86-64 and ARM64. The archive includes an
Apache-2.0 `LICENSE` file, while its package metadata does not declare a license
expression. The app currently copies these prebuilt libraries into its release
bundle.

`mpv-build.lock.json` pins source project
[`snapetech-org/mpv-build`](https://github.com/snapetech-org/mpv-build) at
`3e674d64a821dd96a41434a03e72ae358977d83a`, but the Linux entries in that lock
are prebuilt release assets:

| Architecture | Locked release asset SHA-256 |
| --- | --- |
| x86_64 | `0e66d8f408209b56ea3c381ce40c9fe3d07f095c8ce80df56584ffe83196fb56` |
| aarch64 | `2a9ef07c20eac48eb5db24ea76956c84be0f243238dbd2d65d0dbeac58681fe8` |

The pinned source repository has Linux build drivers in
[`platforms/linux/build.sh`](https://github.com/snapetech-org/mpv-build/blob/3e674d64a821dd96a41434a03e72ae358977d83a/platforms/linux/build.sh),
[`container-build.sh`](https://github.com/snapetech-org/mpv-build/blob/3e674d64a821dd96a41434a03e72ae358977d83a/platforms/linux/container-build.sh),
and a component source lock in
[`versions.json`](https://github.com/snapetech-org/mpv-build/blob/3e674d64a821dd96a41434a03e72ae358977d83a/versions.json).
Those drivers fetch sources and install host packages during their build. They
need adaptation to consume pre-staged source trees and build dependencies
without network access inside Flatpak's build sandbox. The complete per-module
license review and license-file staging also remain open.

The app's Flutter pin is version 3.47.8 with framework revision
`737ba8f885dc774b53b442759999a312c9461e4e` and engine revision
`cf636b1dfb818dd6a3ff16e390e93b1a036969c8`. The ordinary Flutter Linux build
uses the engine runtime distributed in the prebuilt SDK; there is no maintained
source-built Flutter engine path for this app. A source build must resolve the
engine/toolchain policy before it can satisfy the all-source requirement.

Linux also installs the architecture-specific prebuilt Dolby Vision runtime
from `tools/dv-engine/offline-runtime.lock.json`. Its producer and some inputs
are pinned in `tools/dv-engine/offline.lock.json`, but the app does not build
the runtime from those sources. Separately, the desktop neural model data is
pinned by source revision and SHA-256 and records MIT license files in
`assets/motion_models/manifest.json`; those are runtime data inputs, not native
code builds.

## Remaining work

1. Decide and implement an offline source-build route for the Flutter engine
   runtime used by Linux.
2. Build the Linux Sherpa ONNX/ONNX Runtime libraries from source and keep the
   existing plugin ABI and both architecture outputs.
3. Adapt the pinned `mpv-build` source driver to use pre-staged locked source
   inputs, without reducing the shipped codecs, subtitle paths, or media
   features.
4. Build the Dolby Vision runtime from its locked sources and review the
   licenses for all included components.
5. Complete the source-license and redistribution review, install the required
   notices, and have a human author the Flathub manifest.
6. Build offline natively for x86_64 and aarch64, lint and review the exact
   human-authored manifest, and qualify the resulting packages before deciding
   whether to submit.

The GitHub release bundle remains the existing binary-based packaging path.
Neither the audit report nor its successful inventory of lock hashes would
change that distinction or establish Flathub acceptance.
