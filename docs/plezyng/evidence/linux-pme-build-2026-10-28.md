# Linux PME debug build — 2026-10-28

**Host:** `kspld0`
**PlezyNG source:** `codex/qairt-context-fix-20261028`, `e261af80b9e1847abb2509c6cc82d04d45629b41`
**mpv-build source:** PR #2 branch at `5c241907b5e5a1ee661b68981b766f9acc53987a`

## Build and packaging

- Built the Linux x64 libmpv artifact with key `3fc7d9bd61b8` from the mpv-build
  PR #2 source. This includes the PME filter and Vulkan-enabled Linux series.
- Built the PlezyNG Linux debug bundle with `flutter build linux --debug
  --no-pub`, using that libmpv prefix.
- Fixed a Flutter Linux runner compile error where a `const FlValue*` was passed
  to Flutter APIs that require mutable `FlValue*`.
- Ran `linux/packaging/bundle-libs.sh` and added the host's
  `/usr/lib/gio-launch-desktop` location to its candidate search. The bundle
  includes the helper at `lib/glib-2.0/gio-launch-desktop`.
- The portable launcher prepends its bundled `lib` directory to
  `LD_LIBRARY_PATH`. With that launch environment, `ldd` resolves the custom
  libmpv, PME, Lua 5.2, MuJS, and display-info dependencies.
- Archive integrity passed with `zstd -t`; `tar -tf` listed the bundle.

## Retained artifacts

- PlezyNG debug bundle:
  `/var/tmp/plezyng-motion-sdk-acquisition-20261028/artifacts/linux-pme-debug-bundle-20261028/plezyng-linux-x64-debug-bundle-20261028.tar.zst`
- Bundle archive size: 292,588,692 bytes.
- Bundle archive SHA-256:
  `10eb5beb8b4463a81e1b2cd1ecc1751b08ddcd50071260ecdd3691e2cd7a75a7`.
- Executable SHA-256:
  `b0a1fcc60a7644f6fd4b1f90e2ca99a04be8ea30e23e2795971b46267fb1b25d`.
- Bundled libmpv SHA-256:
  `a596e7baccc475a5f8cbd46a173eaff4aab5d2e6b1e930b16be9925d1437310d`.
- Bundled PME library SHA-256:
  `69199f7d862110865dabcb5ab848b38bc86b38ac20ee7491aae74ef22b9cfd08`.
- Supporting libmpv archive and symbols:
  `/var/tmp/plezyng-motion-sdk-acquisition-20261028/artifacts/mpv-build-pr2-linux-20261028/`.

## Qualification limits

This is a local debug bundle. The checked-in `mpv-build.lock.json` still points
to the pre-PME artifact; PR #2 needs its build artifacts published before the
application pin can be advanced. No app launch, inference, visible playback,
display timing, A/V sync, or model-quality claim is made from this build.
