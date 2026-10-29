# Windows x64 and ARM64 libmpv cross-builds — 2026-10-29

This file records the earlier patch-0156 packages. The current local rebuild
with patch 0157 is documented in
[windows-libmpv-pme-0157-2026-10-29.md](windows-libmpv-pme-0157-2026-10-29.md).

## Result

The Windows x64 and ARM64 libmpv packages built locally from `mpv-build` commit
`773c66b02bb88b89cbc158f999e5ceff990be2eb` on Ubuntu 24.04. The Windows patch
series includes `0156-desktop-pme-single-inference-phases.patch`; both build
logs show `video_filter_vf_plezy_pme.c` compiled into `libmpv-2.dll`. Both
architectures passed ZIP integrity and build-date checks.

The build used the repository's normal local commands:

```sh
platforms/windows/build.sh x86_64
platforms/windows/package.sh x86_64
platforms/windows/build.sh aarch64
platforms/windows/package.sh aarch64
scripts/test_build_date.sh dist/release/*.zip
```

It used GCC 13.3, Clang/LLD 18.1, and libc++ 18 in an isolated Ubuntu 24.04.4
container. The aarch64 bootstrap additionally needed `wget` for winbuild's
`cppwinrt` metadata download; this is now listed in the Windows build notes in
the `mpv-build` worktree. The applied upstream
mpv source revision was
`41f6a645068483470267271e1d09966ca3b9f413`. The task-local build and patch
application logs are retained in the `x86_64/` and `aarch64/` subdirectories of
`windows-build-evidence-20261029/` under the motion qualification scratch
directory.

## Artifacts

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| `windows-libmpv-x86_64-20261029.zip` | 42,042,875 bytes | `a3ce42e2f7083a13b417d435866486bb8d9904b3fd4dbcf7b511bbf976e8835a` |
| `windows-libmpv-x86_64-symbols-20261029.zip` | 84,185,095 bytes | `d7a42b2c4318fd4d53edbb6cfc47c02ba93fe3766c92f1df186032e26e166491` |
| `windows-libmpv-aarch64-20261029.zip` | 35,264,826 bytes | `0f2a0e4419ba97dacddb7d5f03a574ba16d27e5d2a28b28aef5f87360e74cf18` |
| `windows-libmpv-aarch64-symbols-20261029.zip` | 78,080,897 bytes | `1ecee1b856a03e67be86413d43e599c73b3a51017161d8960e0fc291e0484569` |

All four archives are local task outputs under the motion qualification scratch
directory. No CI was used.

## Limits

These are cross-built libmpv packages, not a PlezyNG Windows application build.
The packages have not been published or added to `mpv-build.lock.json`, and no
Windows runtime or display playback was qualified. A Wine startup probe stalled
during first-time prefix initialization and was stopped; it provides no runtime
evidence. Real-display phase cadence, visual quality, A/V sync, and sustained
playback remain open.
