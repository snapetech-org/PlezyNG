# Desktop PME nominal slot grid and Windows build evidence — 2026-10-29

## Change

`mpv-build` commit `8a94d7a5d3617e56538a7df6c9f75aa45049c955` adds patch
0158 to both the Linux and Windows mpv patch series. The phase planner keeps
patch 0157's error-diffused count of nominal display intervals per source
pair, then places up to the preset budget on integer subdivisions of that
rounded per-pair grid. It rounds evenly spaced ideal indices to valid slots
and alternates exact half-slot ties. Generated timestamps therefore stay on
the nominal per-pair grid instead of stretching a smaller preset budget
uniformly across the full source interval.

This grid is an approximation based on the reported display interval, source
timestamps, and effective playback speed. The filter does not receive mpv's
final per-frame `num_vsyncs` decisions or later A/V-sync drop/repeat
corrections, so this change does not establish cadence-exact presentation.

## Local builds and checks

- The full Linux and Windows mpv 0.41.0 patch series applied cleanly with
  patch 0158.
- The Linux Vulkan-enabled `mpv` and `libmpv.so.2.5.0` build compiled the PME
  filter with patch 0158.
- Windows x64 and ARM64 were cross-built locally in the retained Ubuntu 24.04
  build container. Both build logs show
  `video_filter_vf_plezy_pme.c` compiled into `libmpv-2.dll`.
- The Windows artifacts use key `df64efffd436`. The local artifact manifest
  verifies for the Windows group, and `scripts/test_build_date.sh` found no
  build clock in either package or symbols archive.
- No CI was run.

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| `libmpv-windows-df64efffd436-x86_64.zip` | 42,039,100 bytes | `8654bf77c5171eaf6c5777dd52fe52a4546c8c3c1b62d0a7e49eaf527123e327` |
| `libmpv-windows-df64efffd436-x86_64-symbols.zip` | 83,663,504 bytes | `0239c6172fc32a4b6de30b6fc465d964073621151cfea7164694f0b7119556ff` |
| `libmpv-windows-df64efffd436-aarch64.zip` | 35,266,683 bytes | `5e7f0102c615c5b16be8250b30e1e692d2dd45404d3a10055a3baca939433017` |
| `libmpv-windows-df64efffd436-aarch64-symbols.zip` | 78,081,008 bytes | `ee928dad09c383418cb5c533e97725f0814887da1e585e476511e44e7ec5bba7` |

The packages are retained under
`/home/keith/Documents/code/task-scratch/plezyng-motion-qualification-20261028/mpv-build-windows-0157-native-20261029/dist/release/`.
They are local candidates only: no release assets were uploaded, and the
PlezyNG mpv lock still points to its previous package set. The earlier Linux
x86_64 package key `b9f611ed45f8` predates patch 0158; a matching Linux ARM64
build was unavailable, so a new Linux group package was not produced.

## Qualification limits

The Windows builds prove compilation and package integrity. They do not
qualify the Windows application, real-display phase cadence, neural image
quality, A/V synchronization, sustained playback, or any target-device
provider. The Linux build is source/build evidence only and does not establish
visible playback or actual display-slot alignment.
