# Qualcomm QAIRT context build — 2026-10-28 (partial)

This records a host-side QAIRT context-generation run for the Android ANVIL
QNN HTP route. It is partial evidence; it is not an Android package input or
device qualification.

## Inputs and environment

- Host: `kspld0`, x86_64 Linux.
- QAIRT SDK: 2.51.200, build `261021095627`. The downloaded archive was
  `v2.51.200.261021.zip`, SHA-256
  `c0dbd66d6eb25c5ac2d099f6eebc9a7dfd05ff8d22e96028c475efc4fbbbe2e0`.
- ANVIL source revision:
  `f701fd9b01b9fbb20822637b5d82cac626079e5f`.
- Checkpoint revision:
  `fa97e30f6aabe897bd4f6f82d971ad607f5d61fa`.
- Calibration: 16 evenly spaced consecutive frame pairs from the Blender
  Foundation *Tears of Steel* clip at 720p and 1080p; the generator downsamples
  the 1080p samples for 720p where needed.
- Build output and logs were kept under `/var/tmp/qctx281028`; the full log is
  `/var/tmp/qctx281028/full-build.log`.

The task worktree's context builder preserves a caller-provided `TMPDIR` for
QAIRT multiprocessing sockets. It also clears and verifies an executable-stack
request only on a generated temporary x86_64 host model library when `patchelf`
is available. The vendor SDK and Android context binaries are not edited by
that compatibility step.

## Observed result

Nineteen of the full 22 selected context files were published:

| Targets | Models | Resolution | Contexts |
| --- | --- | --- | ---: |
| `sm7325`, `sm7450`, `sm7475`, `sm8350`, `sm8350p`, `sm8450`, `sm8475` | ANVIL-S and ANVIL-M | 720p | 14 |
| `sm8550`, `sm8650` | ANVIL-S and ANVIL-M | 1080p | 4 |
| `sm8750` | ANVIL-S | 1080p | 1 |

The run stopped while generating the host model library for `sm8750` ANVIL-M.
It did not publish that context or the two `sm8850` contexts. The `manifest.json`
in the output directory is from the earlier `sm7325` ANVIL-S preflight and
contains a one-context selection; it is not a full-build manifest and does not
describe all 19 files. The current partial directory must not be supplied as a
complete ANVIL package root.

The log records QAIRT's `unexpected GraphHtpSettings option 66` error message
and optional ONNX simplification warnings about the absent `onnxsim` module.
Context-generator commands did emit files after those messages, but this run
does not establish HTP execution on a phone. No APK was packaged, no Android
device/provider execution was performed, and the partial manifest was not
accepted as complete packaging provenance.

## Remaining work

After the QAIRT license gate is resolved, regenerate the complete 22-context
selection into a clean task-owned output directory, produce a matching full
manifest, verify each context hash and SDK provenance, and then package and
qualify on a compatible Snapdragon device. Keep this 19-context directory and
its log as partial evidence until that work is complete.
