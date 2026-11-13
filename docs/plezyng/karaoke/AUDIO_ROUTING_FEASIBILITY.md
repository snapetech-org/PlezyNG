# Karaoke audio routing feasibility

Reviewed against `origin/main` 6b6237905 and the pubspec-locked recorder API on
2026-11-12. This is a source and dependency review; no builds, tests, or device
qualification were run.

## Current requirement and source boundary

K14/K16 require separate, synchronized microphone, backing, monitor, and
recording buses, with selectable output routing and feedback controls. K17
requires singer-to-input-channel mapping and qualified interface support.

The current local vocal mixer in `lib/karaoke/karaoke_stem_mixer.dart` mixes
aligned song stems inside MPV's `lavfi-complex` playback graph. Microphone PCM
comes separately from `record` in `lib/karaoke/karaoke_audio.dart`. The phone
input implementation explicitly describes itself as capture/recording
transport, not a speaker or monitor route. These paths do not provide an
application-owned live graph joining microphone and backing audio.

## Locked recorder API

`pubspec.yaml` pins `record` 7.1.2; `pubspec.lock` resolves
`record_platform_interface` 2.1.0 and the Android 2.1.2, iOS 2.1.1, Linux
2.1.0, macOS 2.1.1, Windows 2.2.0, and web 2.1.1 implementations.

The locked `RecordConfig` describes `numChannels` as mono or stereo and says
most platforms accept at most two channels. `InputDevice` reports an ID, label,
type, and sample rates, but does not expose an input channel count or a channel
map. `AudioRecorder.startStream` returns raw PCM bytes and offers no output
device, output bus, monitor, or playback interface. Its `setOnConfigChanged`
callback reports when a backend adjusts the requested format to hardware or
codec constraints; the karaoke capture path now rejects changes that would
invalidate its 48 kHz mono analysis and WAV layout.

## Feasibility and scope

The locked recorder can capture a mono or stereo input stream. It cannot by
itself implement separate guide/backing/microphone/monitor/recording buses or
live mic monitoring. The existing MPV graph can mix playback stems, but it
does not mix the independent microphone stream into a routable output.

Completing K14/K16 needs a cross-platform native live audio graph or a
compatible PCM playback/output backend, synchronized capture and playback
clocks, explicit input/output route capabilities, feedback/limiter behavior,
and per-route qualification. A channel-to-singer mapping additionally needs
verified per-device channel-layout reporting and capture support; the current
recorder reports neither in a way the app can rely on across platforms. Do not
show a live-monitor capability based on permission or stereo capture alone.

No new route settings are persisted by the current fix. Explicit external
mixer mode and all independent buses remain unimplemented until the native
route capabilities and their device gates exist.
