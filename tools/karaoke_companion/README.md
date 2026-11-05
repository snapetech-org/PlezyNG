# Karaoke companion runtime

The separation profile uses patched PyTorch 2.15.0 with TorchAudio 2.11.1,
TorchCodec 0.17.0 and Setuptools 84.2.1. TorchAudio and TorchCodec support the
newer Torch ABI; this combination is qualified on Linux CPU with Python 3.12
and FFmpeg 9 shared libraries. The worker selects CPU execution explicitly.

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
dependency floors disable separation capability. Worker version 2 invalidates the
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
