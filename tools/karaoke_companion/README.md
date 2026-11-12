# Karaoke companion runtime

The separation profile uses Demucs 4.1.0 with patched PyTorch 2.15.0 with TorchAudio 2.11.1,
TorchCodec 0.17.0 and Setuptools 84.2.1. TorchAudio and TorchCodec support the
newer Torch ABI; this combination is qualified on Linux CPU with Python 3.12
and FFmpeg 9 shared libraries. The worker selects CPU execution explicitly.

The authenticated job queue runs one task at a time and orders newly selected
tracks ahead of older preparation requests. Pleazyng sends a short playback
lease while a karaoke performance is active. Starting a performance stops the
current worker, removes its partial output, and keeps its request queued; work
restarts from the beginning after the last active playback lease ends. A lost
foreground heartbeat expires after 45 seconds. Background playback uses a
bounded six-hour lease, renewed while the app is running. The companion reports
CPU-only capability and does not advertise GPU or NPU execution. Each worker
has an enforced 8 GiB memory/address-space cap in addition to the existing
input, output, runtime and total-storage bounds.

For an isolated CPU environment, install the official CPU wheels first, then
complete the pinned profile from the repository root:

```sh
python -m pip install --index-url https://download.pytorch.org/whl/cpu \
  torch==2.15.0 torchaudio==2.11.1 torchcodec==0.17.0
python -m pip install -r tools/karaoke_companion/requirements-separation.txt
python -m pip check
python -m unittest discover -s tools/karaoke_companion -v
```

Provision approved local model files separately and select them with the
server's existing model-directory and revision options. The worker does not
download models. Its Demucs wrapper forces weights-only checkpoint loading
with an explicit allowlist of Demucs constructor classes and version metadata;
it rejects arbitrary checkpoint globals. Runtime versions below the qualified
dependency floors disable separation capability. Worker version 3 invalidates the
previous preparation fingerprint, and output provenance records the audio
backend versions.

The native tests create local synthetic Demucs/HTDemucs weights, complete a
CPU separation job, check stereo 48 kHz/24-bit stem outputs and verify that
unapproved checkpoint classes are rejected. They do not download trained
models or establish trained-model separation quality. Protocol tests also run
without optional ML packages; native tests skip in that environment.

Compatibility references: [TorchAudio](https://github.com/pytorch/audio/blob/main/docs/source/installation.rst),
[TorchCodec](https://github.com/pytorch/torchcodec#compatibility-with-torch-versions).

The optional alignment profile remains an upstream upgrade blocker: WhisperX
3.8.6 pins the older Torch 2.8 stack. Do not install that profile over the
qualified separation environment or treat its dependencies as patched.

CPU wheel versions include a `+cpu` build tag that the PyPI advisory service
may skip. Audit the installed dependency inventory together with the pinned
upstream release versions; skipped package records are not clean results.

Analysis uses Librosa 1.0 on Python 3.12+ and retains 0.11 on Python 3.11.
The 1.0 worker path was checked with synthetic waveform, tempo/chord analysis
and isolated-vocal pitch extraction. Demucs 4.1 passed synthetic CPU separation
and checkpoint rejection checks against the patched Torch profile. This
qualification is Linux CPU only; Demucs 4.1 requires older Torch on Intel macOS
and must not be installed there with this Linux profile.
