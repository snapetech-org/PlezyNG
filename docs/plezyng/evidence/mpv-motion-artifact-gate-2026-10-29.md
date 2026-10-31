# MPV motion artifact gate — updated 2026-10-30

This records the local package state for the MPV motion-processing integration. It separates locally built files from retrievable release assets; only the latter can be pinned by PlezyNG.

## Previous package candidates through patch 0158

The checked source worktree is `snapetech-org/mpv-build` at `8a94d7a5d3617e56538a7df6c9f75aa45049c955` (`fix(pme): align phases with nominal slot grid`). Its generated keys are:

| Package | Key | Local status |
| --- | --- | --- |
| `libmpv-android` | `0494457e8620` | Four ABI tarballs and symbols built |
| `mpv-android` | `dfe7d6a5ad4e` | AAR and four ABI symbol archives built |
| `libmpv-linux` | `aeb29921a7de` | x86_64 tarball and symbols built; aarch64 missing |
| `libmpv-windows` | `df64efffd436` | x86_64 and aarch64 packages and symbols built |

The PlezyNG [MPV lock](../../../mpv-build.lock.json) still points to `edde746/mpv-build` commit `3b9f38affe3c4171f8e6bc47331feffd3d13be1d`, so it does not consume these candidates.

## Linux candidates with adaptive phase reporting and source resampling

The MPV build branch `codex/motion-adaptive-phases-20261029` contains patches 0159 and 0160. Patch 0160 was added at `d27f3cc83672aad4ff728e5d1931d59f127e98e2`; current branch head `2442c616744760d21b81ada05956547939480c59` records the corrected Linux 0160 two-architecture set and the Windows 0160 package set in `artifacts.json`. Patch 0159 limits later frame pairs to one fewer generated phase after a deadline miss, recovers one phase after 120 on-time pairs, and exports the active/configured phase limits as filter metadata. Patch 0160 adds progressive 1280×720 input alongside 1920×1080, resamples supported sources to a fixed same-aspect model shape at 0.5×–4× source/model ratio, restores output dimensions, and reports CPU fallback as CPU when no provider vendor label is available.

The Linux x86_64 patch-0159 package was built with the pinned Ubuntu 24.04 container (`sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517`) and native `linux/amd64` selection. Its content key is `09ebe80cfc4f`.

| Candidate | Retained path | SHA-256 |
| --- | --- | --- |
| Linux x86_64 package | `task-scratch/plezyng-motion-qualification-20261028/mpv-0159-linux-x86_64-20261029/libmpv-linux-09ebe80cfc4f-x86_64.tar.zst` | `91bf345b4f303baecd7b31af3938e6e3c92ee737b2a820816793dc5ef11736e7` |
| Linux x86_64 symbols | `task-scratch/plezyng-motion-qualification-20261028/mpv-0159-linux-x86_64-20261029/libmpv-linux-x86_64-symbols.zip` | `7d556d58ac6951865705b027a4fa00bc85a7dbd808d93ab8fa67f06791a0ff71` |

The package passed `zstd -t`, its library and shaderc entries were listed from the tarball, and the symbols ZIP passed `unzip -t`. Inspecting the packaged `libmpv.so.2.5.0` confirmed both phase-budget metadata keys and the governor's reduction/recovery log strings. This proves a local package contains the source change; it is not a playback run or a published artifact.

The updated Linux x86_64 patch-0160 package was rebuilt locally in the pinned Ubuntu 24.04 container on native x86_64. A key audit against MPV source commit `d27f3cc83672aad4ff728e5d1931d59f127e98e2` computes Linux key `500fcbd3b251`; the 0159-only parent computes `09ebe80cfc4f`. Earlier notes used `437ae3c80872` for this 0160 package. The package bytes were unchanged; its filename and the MPV manifest entry were corrected to the computed 0160 key.

| Candidate | Retained path | SHA-256 |
| --- | --- | --- |
| Linux x86_64 package | `task-scratch/plezyng-motion-qualification-20261028/mpv-0160-linux-x86_64-20261029/libmpv-linux-500fcbd3b251-x86_64.tar.zst` | `d30e156e7933c3dbd5a9c5b8c5c7c6e4893808dca062cb1a54f23a8459af9d02` |
| Linux x86_64 symbols | `task-scratch/plezyng-motion-qualification-20261028/mpv-0160-linux-x86_64-20261029/libmpv-linux-500fcbd3b251-x86_64-symbols.zip` | `f33eddaae651b2178b5b43b28d4143e5faafc53b74ed7570916c18c18854fa17` |

The package passed `zstd -t` and the symbols ZIP passed `unzip -t`. The packaged library contains both `phase-budget` metadata keys, adaptive reduction/recovery messages, and the 0160 scale-range diagnostic. This proves the Linux x86_64 candidate was packaged from the updated source; the candidate is still local and not retrievable from the rolling release.

### Linux patch-0160 aarch64 package

The Linux aarch64 candidate was built locally from the same pinned source and key under the pinned Ubuntu 24.04 image using QEMU user-mode on the x86_64 host. The temporary AArch64 binfmt registration was removed after the build. The package passed `zstd -t`, the symbols archive passed `unzip -t`, and the extracted library header reports ELF64 little-endian AArch64. Its strings include both phase-budget metadata keys and the 0160 same-aspect-ratio diagnostic.

| Candidate | Retained path | SHA-256 |
| --- | --- | --- |
| Linux aarch64 package | `task-scratch/plezyng-motion-qualification-20261028/mpv-0160-linux-aarch64-20261029/libmpv-linux-500fcbd3b251-aarch64.tar.zst` | `2af01ddc6830258d6d9ba56a2afe2d75744e0b264fb2ae25c82f7d8eeae12431` |
| Linux aarch64 symbols | `task-scratch/plezyng-motion-qualification-20261028/mpv-0160-linux-aarch64-20261029/libmpv-linux-500fcbd3b251-aarch64-symbols.zip` | `ddc9ebb1770cf7a91e2d50ba46a36a0bbbcbe64adad4de70fc1b017e45057a89` |

The build log is retained at `task-scratch/plezyng-motion-qualification-20261028/logs/mpv-0160-linux-aarch64-qemu-build-20261029.log`. This is local package validation, not playback on native aarch64 hardware.

The MPV build branch's `artifacts.json` now records the x86_64 and aarch64 Linux candidates under `500fcbd3b251`. The packages have not been uploaded, so the release URLs and PlezyNG lock remain unchanged.

### Windows patch-0160 packages

Windows x86_64 and aarch64 packages were built locally from the same 0159/0160 source series in the Ubuntu 24.04 build container, reusing the retained Windows dependency/toolchain cache. Both DLLs contain the phase-budget metadata, adaptive reduction/recovery messages, and the 0160 same-aspect resampling diagnostic. The four archives passed `unzip -t`; their content key is `544d2295432e`.

| Candidate | Retained path | SHA-256 |
| --- | --- | --- |
| Windows x86_64 package | `task-scratch/plezyng-motion-qualification-20261028/mpv-0160-windows-20261029/libmpv-windows-544d2295432e-x86_64.zip` | `b6ef479535aa4f508322e450339f490616c45f8b76867b27890a2884accd7be2` |
| Windows x86_64 symbols | `task-scratch/plezyng-motion-qualification-20261028/mpv-0160-windows-20261029/libmpv-windows-544d2295432e-x86_64-symbols.zip` | `b0bc264cf96dc14fbc218e30b2196f1d6cb3e22bfa16e62ec9847150c36b8ff0` |
| Windows aarch64 package | `task-scratch/plezyng-motion-qualification-20261028/mpv-0160-windows-20261029/libmpv-windows-544d2295432e-aarch64.zip` | `c6dc18a50dd8889574e92d2e3ad0455a210bf93f044f553a3723ba1d3974fb08` |
| Windows aarch64 symbols | `task-scratch/plezyng-motion-qualification-20261028/mpv-0160-windows-20261029/libmpv-windows-544d2295432e-aarch64-symbols.zip` | `2abb3bb3f9fb20889b04dfb1761d0004938a829d9b9467acda3fb3248bb347de` |

These are locally built package candidates. DLL string inspection and archive integrity do not establish Windows playback, provider placement, display cadence, A/V sync, or hardware qualification.

The MPV build branch's `artifacts.json` now records both Windows variants and both keyed PDB archives under `544d2295432e`. The manifest is the local publication inventory; no assets were uploaded, and the release URLs remain unavailable.

### Synthetic 1080p playback smoke (CPU only)

A local MPV cplayer smoke used a synthetic 1920×1080, 24 fps H.264 clip, FFmpeg `flags2=+export_mvs`, the ANVIL-S 960×540 model, and the locally bundled ONNX Runtime/PME libraries. It ran through mpv's X11 video output on Xvfb and selected `CPUExecutionProvider`. The manifest-listed CUDA provider could not load its absent `libonnxruntime_providers_cuda.so`, so this run used CPU inference only. The PME log recorded three missed neural deadlines, engaged the ten-second Neural bypass, and reduced the adaptive display phase limit from 3 to 1; recovery probes also missed their deadlines. The run emitted an A/V desynchronization warning.

This confirms the software-decoder motion-vector path, model/session initialization, and deadline fallback wiring on a synthetic clip. It also confirms the CPU path is too slow for this real-time playback target. The Xvfb output is not a physical-display result, and this smoke does not qualify GPU/NPU placement, image quality, cadence, synchronization, or sustained playback. An earlier 960×540-source attempt did not reach PME because the filter only accepts 1920×1080 input for this path; the retained logs and corrected clip are in `task-scratch/plezyng-motion-qualification-20261028/mpv-0159-linux-x86_64-20261029/`.

### Synthetic 720p playback smoke (CPU only)

A local MPV cplayer smoke used a synthetic 1280×720, 24 fps H.264 clip, FFmpeg `flags2=+export_mvs`, the ANVIL-S 960×540 model, and the locally bundled ONNX Runtime/PME libraries. The 0160 filter logged `CPUExecutionProvider on CPU ready` with model 960×540, source 1280×720, and scale 1.333×. It initialized and ran through the model-input resampling path, recorded deadline misses, reduced the adaptive phase limit, and engaged the ten-second Neural bypass; recovery probes also missed their deadlines. The clip and log are retained in `task-scratch/plezyng-motion-qualification-20261028/mpv-0159-linux-x86_64-20261029/`.

This confirms 720p input resampling and CPU runtime wiring only. CPU inference misses real-time deadlines; this smoke does not qualify accelerator/NPU placement, physical display, image quality, cadence, A/V synchronization, or sustained playback. The filter still rejects 960×540 source input and shapes other than 1280×720 or 1920×1080.

## Patch-0161 desktop candidate packages (2026-10-29)

MPV branch `codex/motion-adaptive-phases-20261029` now includes patch 0161 at commit `4fe0b706`. Local packages were built from that source in the pinned Ubuntu 24.04 container. The Linux x86_64 archive passed `zstd -t`; all Windows package and symbol archives passed `unzip -t`. The packaged Linux shared library and both Windows DLLs contain `mpv-display-sync`, `phase-timing-source`, and `phase-budget-configured`. These checks establish package contents only, not playback behavior.

| Candidate | Retained path | SHA-256 |
| --- | --- | --- |
| Linux x86_64 package | `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/artifacts/linux-x86_64/libmpv-linux-d142165ec420-x86_64.tar.zst` | `e21549437c7c28809e66151ecd144a6b0bcae825731a6edd280627245dc8681c` |
| Linux x86_64 symbols | `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/artifacts/linux-x86_64/libmpv-linux-d142165ec420-x86_64-symbols.zip` | `67bbe2bef05421c295aff522d0cfa004ec49fed85c4b86a2a579270794b7a0c8` |
| Windows x86_64 package | `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/artifacts/windows/libmpv-windows-01139c3f4748-x86_64.zip` | `444033941c856340c43939f17370b5e87858f9f0318a597a8d0eec2c152a45fa` |
| Windows x86_64 symbols | `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/artifacts/windows/libmpv-windows-01139c3f4748-x86_64-symbols.zip` | `cbc91f7b258a22e7cb5f4a973622d9cc6032e3d2ff545afdf87bcdc51bf5938e` |
| Windows aarch64 package | `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/artifacts/windows/libmpv-windows-01139c3f4748-aarch64.zip` | `e2142209ba84a3cedc2eba082594ba5a958188ae8fa234e210b9f644cdf355cc` |
| Windows aarch64 symbols | `/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/artifacts/windows/libmpv-windows-01139c3f4748-aarch64-symbols.zip` | `76d6af3ad255f25a1c76df7d2392217472fb2fc67715ac6ba5960568b1168539` |

### Linux aarch64 patch-0161 package (2026-10-30)

The Linux aarch64 candidate was built from the same patch-0161 MPV source commit `4fe0b706` and content key `d142165ec420` using the pinned Ubuntu 24.04 container with QEMU user-mode. The build completed through the PME filter and linked `libmpv.so.2.5.0`. `zstd -t` and the symbol archive's `unzip -t` passed. The extracted shared library is ELF64 little-endian AArch64 and contains `mpv-display-sync`, `phase-timing-source`, and `phase-budget-configured`.

| Candidate | Retained path | Size | SHA-256 |
| --- | --- | ---: | --- |
| Linux aarch64 package | `/mnt/disks/scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/artifacts/linux-aarch64/libmpv-linux-d142165ec420-aarch64.tar.zst` | 24,381,396 bytes | `6493c3f69a57fb9ed8c043537409bebf0e6e9854841e4bc889bda77fb1b8690b` |
| Linux aarch64 symbols | `/mnt/disks/scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/artifacts/linux-aarch64/libmpv-linux-aarch64-symbols.zip` | 9,731,078 bytes | `bb507124e3f3fd6d6a3a294cfc9fdc858402d2b1db238f9c2c71a88e7b84ff9c` |

The build log is retained at `/mnt/disks/scratch/plezyng-motion-qualification-20261028/mpv-0161-local-candidates-20261029/logs/linux-aarch64-build.log`. The local candidate manifest now lists Linux x86_64/aarch64 and Windows x86_64/aarch64 under their matching keys. It is not committed to the MPV build branch or published. The PlezyNG lock remains unchanged. This is package validation, not native-device playback or display qualification.

## Earlier local artifact checksums (patch 0157)

The earlier locally retained Windows/Linux files are under the task scratch `mpv-build-windows-0157-native-20261029/dist/release`; Android files are under `mpv-android-motion-aar-20261029/release-tarballs-and-symbols-20261029`, with the AAR alongside that directory.

| Candidate | SHA-256 |
| --- | --- |
| Windows aarch64 package | `5e7f0102c615c5b16be8250b30e1e692d2dd45404d3a10055a3baca939433017` |
| Windows aarch64 symbols | `ee928dad09c383418cb5c533e97725f0814887da1e585e476511e44e7ec5bba7` |
| Windows x86_64 package | `8654bf77c5171eaf6c5777dd52fe52a4546c8c3c1b62d0a7e49eaf527123e327` |
| Windows x86_64 symbols | `0239c6172fc32a4b6de30b6fc465d964073621151cfea7164694f0b7119556ff` |
| Linux x86_64 package | `816fbd730efcd15765a157acb1d70abdb412103e29de28b5daf45fcc0c25e5bb` |
| Linux x86_64 symbols | `2ee8edeb650cb2febdbe261cc566a9afc794510a76c9c6166de9d5224b7ec8e9` |
| Android arm64-v8a tarball | `1e147c3e1ee94a394876706dbaddb762d2eb6bf3977b69f40067453ca32e0db3` |
| Android armeabi-v7a tarball | `282fc05a3ac9075fc2608fa1513ccdbd5bf5dfe972b66989f9c2af72affa8f33` |
| Android x86 tarball | `9c5ce1c4911a6fca43e4ef7ec7f16c1a9428b93583bde45dd797a70ce8eb1211` |
| Android x86_64 tarball | `fdf6f7b6043c0ea72210fa94a9f55ed1a534db5f520fa60542f7c0474f2f6e19` |
| Android AAR | `298afc307faae72a2ba81b3440c874a95c765e017f97017cd6f3667e6bae8765` |
| Android arm64-v8a symbols | `5c3eafb50c96f5f2a8be93f7d59dc11eaaa27a457754c98aa77832e60553a15f` |
| Android armeabi-v7a symbols | `74e0e49fa44d19108ad32a63708c4c25bd1b4b02f21f9a7bb751abaf619edf29` |
| Android x86 symbols | `14165853a645b2170b537812ff4a4da43dc886f8b5ee708e2340d60a63d15b98` |
| Android x86_64 symbols | `0a67040f945ed3fe6b5ace934063ab16e74acb2a9de058d123f1195d9a3bb7fa` |

These hashes identify local candidates only. They do not imply upload, publication, or device qualification.

## Remaining publication and architecture gates

On 2026-10-29, direct downloads for previous Windows packages, the Linux package, and Android ABI tarballs/AAR/symbols returned HTTP 404 from the `snapetech-org/mpv-build` rolling release URLs ([Windows](https://github.com/snapetech-org/mpv-build/releases/tag/binaries-windows), [Linux](https://github.com/snapetech-org/mpv-build/releases/tag/binaries-linux), [Android](https://github.com/snapetech-org/mpv-build/releases/tag/binaries-android)). The latest remote check found no Linux assets and no Windows or Android rolling releases; no upload has been made since. The MPV build branch `artifacts.json` records local Windows key `544d2295432e` and Linux key `500fcbd3b251`, but neither candidate set is published. The 0159 Linux key `09ebe80cfc4f` is also unpublished. The PlezyNG lock still references its previous keys `52b991183e5f` (Linux), `8dbcea0c526c` (Windows), `5b7e6b31ab13` (Android native libraries), and `f9b1be38a527` (Android AAR). `scripts/keys.py verify` checks local manifest consistency; it cannot establish that assets are available from the real download URLs.

The Linux patch-0161 group now has both x86_64 and aarch64 local packages; the x86_64 build was native and the aarch64 build used QEMU user-mode. The Windows patch-0161 group has x86_64 and aarch64 local packages. Archive integrity, ELF architecture, and feature-string inspection establish package contents only, not target-device playback. No CI workflow or remote build was run.

The PlezyNG lock stays on its existing published package revision until the matching source commit and complete asset set are retrievable at their real release URLs. All four Linux and Windows desktop architectures now have locally verified patch-0161 candidates; they remain unpublished. Android uses a separate MPV patch series and does not consume desktop-only patch 0161. Android Tensor/NPU provider execution, Windows and Linux hardware playback, visible presentation, cadence, A/V sync, and device quality remain device-qualification gates; these package builds do not establish them.
