# Windows x64 libmpv cross-build — 2026-10-29

## Result

The Windows x64 libmpv package built locally from `mpv-build` commit
`773c66b02bb88b89cbc158f999e5ceff990be2eb` on Ubuntu 24.04. The Windows patch
series includes `0156-desktop-pme-single-inference-phases.patch`; the build log
shows `video_filter_vf_plezy_pme.c` compiled into `libmpv-2.dll`. The generated
packages passed ZIP integrity and build-date checks.

The build used the repository's normal local commands:

```sh
platforms/windows/build.sh x86_64
platforms/windows/package.sh x86_64
scripts/test_build_date.sh dist/release/*.zip
```

It used GCC 13.3, Clang/LLD 18.1, and libc++ 18 in an isolated Ubuntu 24.04.4
container. The applied upstream mpv source revision was
`41f6a645068483470267271e1d09966ca3b9f413`. The task-local build and patch
application logs are retained in `windows-build-evidence-20261029/` under the
motion qualification scratch directory.

## Artifacts

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| `windows-libmpv-x86_64-20261029.zip` | 42,042,875 bytes | `a3ce42e2f7083a13b417d435866486bb8d9904b3fd4dbcf7b511bbf976e8835a` |
| `windows-libmpv-x86_64-symbols-20261029.zip` | 84,185,095 bytes | `d7a42b2c4318fd4d53edbb6cfc47c02ba93fe3766c92f1df186032e26e166491` |

Both artifacts are local task outputs under the motion qualification scratch
directory. No CI was used.

## Limits

This is a cross-built libmpv package, not a PlezyNG Windows application build.
The package has not been published or added to `mpv-build.lock.json`, and no
Windows runtime or display playback was qualified. A Wine startup probe stalled
during first-time prefix initialization and was stopped; it provides no runtime
evidence. Real-display phase cadence, visual quality, A/V sync, and sustained
playback remain open.
