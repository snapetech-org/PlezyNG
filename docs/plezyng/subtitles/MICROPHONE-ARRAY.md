# Declared microphone-array direction research

Source adapter, October 29, 2026. Confidence: moderate for source integration;
unknown for calibration correctness, angular accuracy and runtime performance.
No tests, models, builds, dependency installs, CI or recordings were run.

`sound_localize` accepts an explicitly selected original PCM16 WAV and reviewed
calibration. It preserves all channels, sample rate, cue text and cue boundaries.
The app asks for a calibration file, previews each channel's position, latency
and polarity, and requires a fresh declaration that these are the original
synchronized channels in the listed order. A separate companion upload review
still applies. Ordinary player-source uploads and stereo soundtrack analysis do
not supply calibration or activate this adapter.

Limits are 4–8 channels, 16–48 kHz, two minutes of WAV, 1–60 file-clock cues,
12 seconds per cue and two minutes of summed cue duration. Geometry must span
three dimensions, have a condition number at most 30, and microphone separations
between 3 cm and 2 m. Planar/linear arrays are rejected rather than hiding their
direction ambiguities. Raw position components are bounded to ±2 m, declared
latencies to ±5000 µs, and sound speed to 300–380 m/s. Channel polarity is ±1.
The uploaded WAV is capped at 100 MiB, slightly above the 92.16 MB maximum raw
PCM payload for eight channels at 48 kHz over two minutes.

The worker scans 256 ms windows at 128 ms steps. All microphone pairs use a
300–6000 Hz bounded GCC-PHAT delay estimate, declared electronic-delay removal,
and a far-field least-squares direction fit. Input clipping, insufficient
energy, ambiguous peaks, weak aligned correlation, impossible delays, an
implausible unit-vector fit or excessive normalized-fit residual reject a
window. A cue summary needs three accepted windows, at least 30% acceptance and
direction concentration of at least 0.8. These are engineering gates, **not
calibrated probabilities or angular error bounds**.

Evidence retains the input digest, normalized calibration digest and values,
coordinate convention, accepted/rejected counts and reason codes, fit residuals,
peak/correlation diagnostics and up to 32 evenly sampled accepted observations
per cue. Omitted observation counts are explicit. Azimuth zero is forward,
positive azimuth is right, and positive elevation is up relative to the declared
array. No world coordinates, source range, identity, object association, subtitle
wording or caption placement are inferred.

The capture must use a common synchronized clock and valid measured geometry,
polarity and channel delays. The software cannot verify that declaration.
Reflections, near-field or simultaneous sources, wiring changes, independent
channel processing, clock drift and narrow-band signals can defeat the model.
Stereo mix balance/delay evidence remains a different feature. This adapter
does not establish physical localization from ordinary film or music mixes.

Calibration interchange (replace every example value with measured values):

```json
{
  "schema": "plezyng.microphone-array.v1",
  "axes": "x-right-y-forward-z-up",
  "speedOfSoundMps": 343,
  "channels": [
    {"positionM": [0, 0, 0], "delayUs": 0, "polarity": 1},
    {"positionM": [0.15, 0, 0], "delayUs": 0, "polarity": 1},
    {"positionM": [0, 0.15, 0], "delayUs": 0, "polarity": 1},
    {"positionM": [0, 0, 0.15], "delayUs": 0, "polarity": 1}
  ]
}
```

The app adds `rawSynchronizedCapture: true` only after the review checkbox.
Python SDK callers must explicitly include that declaration in `microphoneArray`
when creating a `sound_localize` job with the matching WAV and cues. NumPy is
the only added runtime dependency (`requirements-array.txt`). The host's Python
WAV reader must support the actual PCM container; no decoder fallback silently
changes channels.

Primary references for conventions and algorithm assumptions:

- [SciPy correlation definition](https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.correlate.html)
- [Pyroomacoustics direction-of-arrival inputs](https://pyroomacoustics.readthedocs.io/en/stable/pyroomacoustics.doa.doa.html)

The implementation uses NumPy FFT and least squares directly; it does not claim
to run Pyroomacoustics SRP or to reproduce its measured results.
