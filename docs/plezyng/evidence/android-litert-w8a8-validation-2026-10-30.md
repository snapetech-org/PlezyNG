# Android LiteRT W8A8 holdout reproduction — 2026-10-30

This rerun reproduces the calibration inputs recorded by the checked-in LiteRT
manifest and validates its four W8A8 models against their float32 counterparts.
It supplements the original [quantization evidence](android-litert-w8a8-validation-2026-10-28.md).

## Calibration and holdout sets

The source is Blender Foundation's 2012 *Tears of Steel* 1080p clip
([download](https://download.blender.org/demo/movies/ToS/tears_of_steel_1080p.mov.zip),
[CC BY 3.0](https://mango.blender.org/about/)). Its SHA-256 is
`99486359be7e3681168a0fe94e1cbb0284c48b57b2a3ce7df4fa75e185987a15`.

The calibration set contains 16 pairs selected at even indexes from a 32-pair
grid. The new helper reproduced every recorded filename, frame index, and
tensor SHA-256 from the existing model manifest at both resolutions. The
separate holdout set uses odd grid indexes `1, 3, …, 31`; none of its frame pairs
overlap the calibration pairs. Both sets come from the same source clip, so the
holdout checks different moments in that film rather than independent content.
The source is fitted to 16:9 with centered black bars before packing two RGB
frames as six float32 NCHW channels.

The sample builder now writes tensors and indexes through temporary files,
checks each expected byte count and SHA-256 before publishing, and records the
sampling grid, stride, offset, and per-file sizes. The model exporter and
quantization validator verify the listed sample order, sizes, and hashes when
metadata is present. The previously retained incomplete calibration copy was
not used.

## CPU LiteRT comparison

LiteRT's XNNPACK CPU interpreter compared each W8A8 synthesized frame with the
same model's float32 output. The residual is added to the source-frame blend and
clamped to `[0, 1]`, matching the playback model contract.

| Model | Resolution | Float bytes | W8A8 bytes | RMSE | MAE | PSNR | Worst-pair PSNR |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ANVIL-S | 720p | 3,463,252 | 958,080 | 0.006485 | 0.002085 | 43.762 dB | 34.55 dB |
| ANVIL-S | 1080p | 3,464,436 | 959,312 | 0.007888 | 0.002526 | 42.061 dB | 33.10 dB |
| ANVIL-M | 720p | 10,707,640 | 2,828,160 | 0.007508 | 0.002132 | 42.489 dB | 32.39 dB |
| ANVIL-M | 1080p | 10,708,864 | 2,829,440 | 0.009178 | 0.002304 | 40.745 dB | 30.95 dB |

The worst pair was `pair-023.f32`. A CPU-only re-export of ANVIL-S at 720p
reproduced both checked-in model files byte-for-byte using the reconstructed
calibration data and pinned PyTorch `2.14.1+cpu`, LiteRT-Torch `0.10.0`, and
quantizer `0.10.0`:

- Float32 SHA-256: `b3b9084659890557cafd9245e4f45925b1578c023895bfbffb234cfdfb140ac8`
- W8A8 SHA-256: `bbdce7001042f7b9318968638546ec534ba5f23e27c96b899999be3ca04c3eca`

All model payloads and their per-file hashes are unchanged. The manifest's
calibration provenance now records per-sample byte counts and the exact 32-pair
grid, stride, and offset. Its calibration metadata SHA-256 is
`61f677653a8cc9765ff927ba3a272e77256bb12784ccee143cceba93391dc9a2`. The full
report is in
[android-litert-w8a8-validation-2026-10-30.json](android-litert-w8a8-validation-2026-10-30.json)
(SHA-256 `3222342bd4c0d8483cd0d1a5e090158715bfe07481b2c6ecbe6fb27b1e76ca5c`).

On the local `kspld0` host, GPU qualification remains pinned to the RX 7900 XT:
ROCm reports it as HSA UUID `GPU-6bdce6ea1d388c5c`, PCI `0000:15:00.0`, and
`renderD129`. The RX 9070 XT used by the desktop is HSA UUID
`GPU-2388c382a826700f`, PCI `0000:03:00.0`, and `renderD128`; motion profiling
must not expose it. On Linux, `ROCR_VISIBLE_DEVICES` accepts a device UUID and
AMD recommends it for ROCm device isolation
([AMD ROCm GPU isolation](https://rocm.docs.amd.com/en/latest/reference/system-optimization/gpu-isolation.html)).
The local MIGraphX profiling helper checks that only one RX 7900 XT GPU agent is
visible before opening an inference session.

These are fidelity measurements against float32 model outputs, not ground-truth
midpoints or perceived-quality scores. They do not establish Android NPU
execution. No Android device was attached during this run; the reported
interpreter was CPU/XNNPACK, with one thread.
