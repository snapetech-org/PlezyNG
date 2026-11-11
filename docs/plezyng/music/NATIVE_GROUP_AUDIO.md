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

Native availability and incoming membership are implemented below. These
transport results do not establish acoustic synchronization or physical output
latency qualification.

## Native availability and incoming membership

The native group screen has an explicit Allow playback switch. While enabled,
the active profile advertises its lease UUID on private IPv4 interfaces using
the native multicast beacon, serves mesh WebSockets on 1998 and bounded
Companion metadata/controls on 32500. Availability alone opens no audio player.
Other native players/controllers can assign Pleazyng as source or sink. This
native LAN protocol has no paired-account authentication: the switch permits
nearby native music control, and is off by default. The paired encrypted
Pleazyng device protocol retains its separate authentication.

Incoming clients must send a supported Hello before commands. Private-peer,
identity, connection, byte, rate, source/sink-count and queue bounds apply.
Membership resolves only currently known private endpoints; both full and
additional-sink native forms canonicalize to the same idempotent assignment.
Reserved source state is acknowledged before audio setup, because a native
sender waits for that acknowledgement. Replaced assignments lose their scope
immediately and only the latest pending operation runs. Group changes reuse the
shared session; departure restores local output without stopping other players.
Profile/account/client-set retirement closes discovery, controls and audio.

Initial peer state can still describe its previous source before membership is
requested. The receiver accepts this handshake state, then enforces the assigned
source for subsequent updates. Native-controller tests cover that transition,
the exact additional-sink relay payload, duplicate commands and scope races.

In two isolated network namespaces, the official Caldera 1.1.0 reference
discovered Pleazyng's advertisement and was discovered in return. Commands to
the official player's own group endpoint assigned Pleazyng as a source, then as
a sink. The source supplied 76,800 generated frames; the receive bridge supplied
176,540 WAV bytes. These runs use generated/idle audio and null outputs, not a
physical account or speaker.

## Receive metadata and controls

An independently bounded EventSource connection follows the selected source's
track, artist, album, playhead and transport state. Per-event byte limits reset
for long sessions. Mesh UUIDs and Companion playback identifiers are distinct:
the first state binds the latter and every forwarded command rechecks it. Native
artist/album fields (grandparentTitle/parentTitle) and explicit artist/album
fields are accepted. The shared media session shows source progress rather than
the local live decoder's elapsed time; no server listen authority is created.

Pause, resume, previous, next and seek are serialized and forwarded to the source.
Pausing keeps the local decoder draining silence and retains membership beyond
the ordinary audio-idle timeout. Suspend/resume resets the receive timeline so
queued pre-pause audio cannot replay. Mesh or state disconnection, changed
identity and account retirement still release the stream. Local Stop leaves the
group without stopping the other speakers.

The official Caldera 1.1.0 reference accepted the revised handshake and supplied
211,812 WAV bytes with its distinct Companion identifier. Automated regressions
cover long state feeds, malformed/changed identities, paused membership, resumed
counter reset, source metadata and the shared transport route.

## Audible output clock

Native MPV receive output now reads audio-PTS with ownership checks before and
after the asynchronous bridge call. This property includes audio-driver delay.
A separate monotonic WAV clock follows bounded hardware drift and phase, rejects
reversed/outlying observations, and paces a bounded output lead. The initial
live stream primes with silence while an audible anchor becomes available.
Fractional source-frame lookup schedules each PCM sample for the estimated
audible presentation time, including interpolation across UDP packet boundaries
and 32-bit frame-counter wrap. Paused silence keeps this clock running.

The receive core specifies its owned WAV format and disables stream-info probing,
which otherwise accumulated several seconds of silence before the actual pinned
decoder began rendering. Priming is capped at 100 ms even if audio-PTS remains
unavailable. It requests a small audio buffer and disables read-ahead; normal
queues open a fresh core with their normal policy. A stalled/unsupported native
clock retires after five seconds. Non-MPV output adapters retain the bounded
packet-clock path and are not claimed to provide renderer synchronization.

The actual pinned Linux decoder, run asynchronously in an isolated namespace,
rendered a generated scheduled pulse through a timed null output within 15 ms of
its expected audible time. The same probe before the format/probing correction
did not render that pulse within five seconds. A delayed-clock socket regression
checks the priming cap and recovery. Null output is not acoustic qualification.

Ten-minute simulations cover opposite 1000 ppm hardware drift at 8/48/96 kHz.
Generated impulse tests reconcile 20/50/80 ms renderer delay with independent
source/device drift, and the real socket regression exercises the clocked
output path through pause/resume. These are code results: device-reported audio
timing accuracy, external Bluetooth/receiver latency and acoustic alignment
against native speakers still require qualification.

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
presentation-timed bounded copy queue. Native capture folds known mono, stereo,
surround and height speaker assignments into the stereo wire bus, normalizing
summed weights and excluding LFE and silent padding. The original multichannel
copy remains available to visualizations. Unknown/duplicate speaker assignments
and non-finite samples fail closed. Native multichannel wire output is not
implemented; the negotiated source format remains stereo. Shared downmix tests
pass in C++17 and C++20, and the changed Linux wrapper compiles.

Verification: 116 focused source, mixer, shared-session and UI regressions pass.
The production Dart source, driven by generated PCM in an isolated namespace,
was accepted by the official Caldera 1.1.0 receiver. The receiver negotiated
48 kHz stereo, resampled to its 44.1 kHz null device and reported 718 packets
received with zero packet drops. Its unpaced null device reported underruns;
this run cannot qualify acoustic synchronization or real output latency.

Native capture is before AO volume/mute and after decoded filters/resampling.
Music fade and headroom scalars now account for MPV's cubic user volume curve;
an equal-power envelope remains an equal-power envelope at the actual output.
Transmission reapplies the native AO volume, ReplayGain mode/tag/preamp/peak
clipping policy, fallback and additional volume gain once. It does not repeat
decoded filters. Short-lived revision-bound gain caches cannot cross a decoder
handoff, and render-time lane gain updates already queued PCM without waiting
for another capture. Synthetic received tracks never enter session persistence.

The actual pinned Linux library was executed in an isolated namespace with
generated audio and null/file outputs. Capture remained nonzero while muted.
A 0.199981689 peak rendered at 0.024997711 with volume 50, confirming the 1/8
native amplitude, and at 0.099990845 with a -6.0206 dB ReplayGain tag. These
measurements qualify this generated native capture/gain path, not a complete
platform application or a physical audio device.

The current dependency lock (mpv-build d74e7a4a) already records the ordered
PCM ABI for Android, Apple, Linux and Windows. Its pinned Linux x86_64 archive
was checksum-verified and all four tap exports, including read_next, inspected.
Older notes claiming that binary promotion is still pending were stale.
Export inspection does not qualify native execution or physical output.

Transmit deadlines now follow bounded PCM-buffer feedback (at most 2000 ppm)
instead of accumulating differences between hardware and monotonic rates.
Ten-minute simulations cover both directions at 200 and 1000 ppm. Descriptor
timestamps use a fixed wall anchor plus monotonic elapsed time. Rejected timing
outliers cannot change receive frame unwrapping. Current native Companion
commands can acknowledge with an empty HTTP 200 body; the controller also
retains the older XML acknowledgement validation.

## Membership changes without restarting audio

An established source keeps its decoder capture, UDP port and advancing frame
clock while adding or removing speakers. New peers receive no PCM until they
acknowledge source ownership; a failed or superseded addition leaves existing
output running. Committing a destination set repeats the descriptor on the
existing timeline. A departing peer releases only its own link, while the final
departure restores the previous local mute. Metadata streams recheck the current
destination set. Setup-request scope is temporary; accepted audio belongs to the
availability lease and remains bound to its original account/client set.

Real socket regressions use two local private addresses (or an isolated Linux
network namespace with two dummy addresses) because the native protocol fixes
each receiver at UDP 5000. They verify stable source port, advancing counters,
acknowledgement gating, cancelled/failed joins and sibling survival.

The official Caldera 1.1.0 reference was run twice in separate network
namespaces, attached to an isolated bridge. Its native group control added the
second receiver and removed the first. The production source kept the same
capture lease and UDP port throughout 120,960 generated frames. The native
receivers reported 613 and 686 packets with zero drops; the removed player
explicitly stopped receiving while its sibling continued. Unpaced null-device
underruns remain outside acoustic qualification.

## Native source state and transport

Selected peers receive bounded title, artist, album, playhead, duration and
volume metadata from the source's Companion endpoint on port 32500. Transport
controls require the current source identity and a bounded controller/command
identity; duplicates share their original result and stale commands cannot
execute after scope retirement. Queue loading and media URLs are not exposed.
A Stop can retire its own source while still completing its acknowledgement.
The host and audio lease also retire if the registered client set changes,
covering an initially empty account context gaining a new connection.

The production endpoint and source were exercised across two isolated network
namespaces with the official Caldera receiver. It automatically subscribed to
the source's EventSource. An allowed peer read the metadata and paused the
source through the native control route; 589 audio packets arrived with zero
packet drops. This remains generated audio through an unpaced null device.

## Native volume relays

Native controllers relay per-player volume as SetSinkVolume with a single
finite 0–100 volume value. Hosted and dedicated source/receiver links handle
this command through a bounded serial queue. Each queued operation rechecks its
connection and account; accepted changes publish updated mesh state. A receiver
applies its own shared-session volume without forwarding it to the source.
Volume changes retain capture, queue and membership. Parametric EQ relays are
separate and remain to be integrated.

The official Caldera 1.1 controller's own setSinkVolume route sent a volume of
37 to the production host. Exactly one shared control write occurred while
source audio continued. There are 139 focused control, socket and session
regressions, including malformed payloads, pending limits and retired scopes.

## Backpressure retirement

Metadata writes have a 500 ms flush budget. Retirement uses the HTTP response
deadline to destroy the connection instead of closing an HTTP sink while flush
has it bound; that close can throw synchronously. Late flush errors are absorbed,
retirement is idempotent and retired streams cannot write again. The receive WAV
server similarly uses its owned server's forced teardown. A real native probe
exposed the original failure; deterministic pending-flush regressions cover it.

## Protocol sources

- mpv's [demuxer options](https://mpv.io/manual/stable/) document the known-format and stream-info probing controls used for this owned WAV.
- mpv's [audio-PTS property](https://github.com/mpv-player/mpv/blob/master/DOCS/man/input.rst)
  defines the audible position used for renderer feedback.
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
