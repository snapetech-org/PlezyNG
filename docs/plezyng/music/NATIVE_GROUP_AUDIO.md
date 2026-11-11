# Native group audio protocol

The native Caldera / Plexamp controller is separate from audio membership.
Xita uses the published Zita network-audio packet layout: a 32-byte
descriptor and a 20-byte audio header; all multibyte fields, including float32
samples, use network byte order. The audio header field at byte 16 is
transmission delay in microseconds, not a packet sequence. The descriptor's
frame counter and NTP timestamp occupy bytes 20 through 31.

The independent Dart codec bounds datagrams, channels, rates, frame counts,
finite PCM, control flags and exact payload lengths before allocation. The
receive clock uses monotonic arrival times corrected by transmit delay,
unwraps 32-bit frame counters, ignores reordered timing observations and
limits rate correction. NTP era resolution requires an explicit wall anchor;
wall-clock jumps do not retime active audio.

These facts were checked against the public Zita source and the Caldera
Music 1.1.0 headless packet routines. A 1.0.44 public descriptor capture is a
regression fixture. No proprietary executable or third-party source is included.
The native-controller screen can explicitly receive the selected source on this
device. The shared music session owns the player, focus and OS controls.
A synthetic display item carries no server identity, stream authorization,
persistence or listen-reporting authority. The receiver pins the selected LAN
address and first valid UDP source port; bounded reordering, exact gap silence,
a half-second receive window, bounded HTTP backpressure, peer heartbeat and
profile/account checks protect stream lifetime. A normal queue disposes the
live core before opening its own source. Stale receive cleanup cannot stop it.

Verification on 2026-11-11: 121 focused codec, real WebSocket/UDP/HTTP, UI and
shared-player regressions passed. In an isolated network namespace, the official
Caldera Music 1.1.0 player accepted this implementation's Hello and membership,
started its LiveSender to port 5000, and supplied 160,652 bytes through the
Dart WAV bridge. No actual account or speaker was used. The independent player
and protocol logs are retained under build/native-groups-20261111/.

Unsolicited native group discovery/membership and physical output latency
calibration are not yet complete. This result establishes receive
transport interoperability; it does not establish acoustic synchronization.

## Native source output

The native group screen can send the current shared music session to selected
native speakers. Each peer must acknowledge its new source before capture and
local muting begin. Missing capture support fails before native membership is
changed. No additional media-server stream is opened. Ordered PCM from the
primary and overlap decoders is mixed onto a bounded 48 kHz stereo frame clock;
seek generations, pause, track changes and native ownership changes retire stale
samples. A source preserves the local queue, duplicate occurrences, transport
controls and listen-reporting authority. Closing restores the prior local mute.

The native bridge shares one tap with the visualizer using an independent,
presentation-timed bounded copy queue. Source capture currently accepts mono and
stereo decoder output. Multichannel decoder capture fails closed.

Verification: 116 focused source, mixer, shared-session and UI regressions pass.
The production Dart source, driven by generated PCM in an isolated namespace,
was accepted by the official Caldera 1.1.0 receiver. The receiver negotiated
48 kHz stereo, resampled to its 44.1 kHz null device and reported 718 packets
received with zero packet drops. Its unpaced null device reported underruns;
this run cannot qualify acoustic synchronization or real output latency.

The shipped dependency lock still lacks the native ordered PCM extension.
A built and promoted dependency artifact is required to enable source capture
in packaged applications; no unproduced artifact or hash is substituted.

Transmit deadlines now follow bounded PCM-buffer feedback (at most 2000 ppm)
instead of accumulating differences between hardware and monotonic rates.
Ten-minute simulations cover both directions at 200 and 1000 ppm. Descriptor
timestamps use a fixed wall anchor plus monotonic elapsed time. Rejected timing
outliers cannot change receive frame unwrapping. Current native Companion
commands can acknowledge with an empty HTTP 200 body; the controller also
retains the older XML acknowledgement validation.

## Protocol sources

- Fons Adriaensen's [Zita tools](https://kokkinizita.linuxaudio.org/linuxaudio/downloads/index.html)
  and the [netdata.h](https://github.com/digital-stage/zita-njbridge/blob/master/source/netdata.h)
  / [netdata.cc](https://github.com/digital-stage/zita-njbridge/blob/master/source/netdata.cc)
  wire definitions (GPL-3.0-or-later); independently implemented framing facts.
- [Caldera headless](https://caldera.homes/music/headless/) official 1.1.0
  Linux x86_64 reference player, run with generated audio, invalid test
  credentials, a null device and an isolated network namespace.
- anatosun's [Caldera capture notes](https://github.com/anatosun/caldera-snapjack)
  and descriptor bytes. The notes' tentative header lengths and sequence
  interpretation are superseded by the published packet definition and the
  current native routines.
