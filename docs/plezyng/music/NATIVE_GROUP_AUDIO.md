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
primary and overlap decoders is mixed onto bounded 48 kHz stereo/5.1/7.1 buses sharing one frame clock;
seek generations, pause, track changes and native ownership changes retire stale
samples. A source preserves the local queue, duplicate occurrences, transport
controls and listen-reporting authority. An independent audio-only core now
renders the source speaker from the same stereo Xita packets and audible-clock
mapping used by remote sinks. It retains bounded PCM/reorder/HTTP windows, drops
queued samples on pause/resume, and adds only local physical-output and native
per-speaker EQ; shared gain, ReplayGain, fades and general EQ are not repeated.
Workspace muting also silences the renderer immediately. Stop and video claims
await its teardown, and closing retires delayed output before restoring the
capture decoders' prior local mute. Stereo rendering beside stereo/5.1/7.1 peers,
ownership retirement, per-speaker EQ isolation and stopped-renderer races have
direct socket/session regression coverage. Acoustic alignment still requires
device qualification.

The native bridge shares one tap with the visualizer using an independent,
presentation-timed bounded copy queue. Native capture preserves and reorders
canonical 5.1/7.1 speaker assignments into WAVE order (FL FR FC LFE RL RR SL SR).
5.1 side assignments map into the six-channel rear slots. Other known layouts,
including height, fold into stereo with normalized summed weights, excluding LFE
and silent padding. The original multichannel copy remains available to
visualizations. Unknown/duplicate assignments and non-finite samples fail closed.
Shared preservation/downmix tests pass in C++17 and C++20; the current Linux
wrapper also compiles.

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

The current dependency lock (mpv-build 3e674d64) already records the ordered
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

## Parametric DSP foundation and dependency qualification

The native player has a separate finite parametric EQ capability with peak,
low-shelf and high-shelf bands, gain and enable state. It composes with existing
ten-band/effect state, copies caller lists and serializes native reconciliation.
A rejected graph restores the accepted DSP state without poisoning later
requests or applying filters to passthrough. There are 85 focused player/policy
tests, including rollback and concurrent unrelated audio changes.

Execution against the pinned Linux library exposed absent FFmpeg equalizer
support; accepting Dart strings does not qualify DSP. Producer repair eb78e98
retains the required filters in the deliberately pruned Linux/Android builds and
adds Apple's missing shelf/effect filters. Linux publication now executes
generated tone checks before packaging. The checker measured the expected peak,
shelf and gain output using the system decoder as a harness check. Promotion of
rebuilt, receipt-checked artifacts and native command integration are still
required; this foundation alone does not claim working native EQ on the old pin.

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

## Native per-player parametric EQ

Hosted, dedicated source and receive mesh connections accept native
SetSinkEqualizerEnabled, SetSinkEqualizerGain and SetSinkEqualizerBands commands.
Each command is bounded and copied before queueing; individual fields compose
against accepted settings at execution time. Queued work rechecks account and
connection ownership. Only successful changes publish the new native state.

The shared session owns the typed DSP layer and its versioned profile document.
It preserves ten-band EQ and other effects, cancels a pending overlap before
changing audio policy, and rolls back rejected graphs. A cold restored preset
that cannot execute on the decoder is disabled in memory and reported while
ordinary playback continues. Receiver settings apply only locally. While
transmitting, this per-player layer is bypassed on capture decoders so changing
one native speaker cannot contaminate every destination's wire PCM; leaving the
group restores the local layer.

227 focused volume/EQ/mesh/shared-player/native-bridge tests pass. The official
Caldera 1.1.0 controller applied enable, -3.5 dB gain and exact 100/1000 Hz bands
to the production host through its native HTTP-to-mesh relay. This checks the
wire and ownership path. Separately, producer eb78e98's rebuilt Linux decoder
executed generated PCM checks: flat 0.1999817, peak EQ 0.3990173, low/high shelves
0.2825012 and global attenuation 0.0999908. The all-platform publication run and
atomic application lock promotion are still pending; the application remains
pinned to its previous decoder until verified artifacts are available.


## Per-peer channel negotiation

After a supported mesh Hello and before membership/capture, the source reads
/api/prefs?name=audio.channels from the pinned private peer. Reads have a
three-second deadline, 64-byte limit, no redirects and ownership checks.
Only saved widths 0/2/6/8 are accepted; automatic 0 and legacy 404/405 retain the
established stereo contract. This preference is not a physical device probe:
a native command-line channel override does not update the saved value. Widths
must not be inferred from null mesh capabilities or a track's audioChannels.

All three bounded output buses advance together, so new or differently configured
speakers use the existing clock. Stereo expands with silent extra channels;
7.1-to-5.1 folds side into rear, and surround-to-stereo uses a normalized Lo/Ro
fold excluding LFE. Packet payloads include the 20-byte header within 1472 bytes;
trailing partial packets retain the same period counter. A periodic preference
check retires changed, malformed or unreachable verified peers independently,
without restarting capture or disturbing siblings. This does not provide an
atomic handshake with an external decoder changing its configuration.

307 combined format/mixer/source/membership/mesh/clock/player tests pass. Tests
exercise mixed stereo/surround peers, common anchors, exact channel samples,
MTU limits, invalid input, cancellation and independent retirement. The official
Caldera 1.1.0 reference, with saved preferences matching output width, received
production 48 kHz 6-channel PCM (1,608 packets) and 8-channel PCM (2,053 packets),
both with zero drops. Each supplied 95,520 capture frames and remained alive.
Automatic-preference runs correctly retained stereo. Null-device underruns
remain unqualified and these runs do not establish acoustic synchronization.

## Controller ownership during local output

Saving speaker edits while this device is transmitting calls the shared source's
replace operation. It does not promote the selected remote speaker into a new
leader. The native controller route is retained when controlling another source.
Source and receiver Stop remain available when discovery loses the selected
peer. Five widget regressions cover these ownership changes, native control,
profile retirement and 320px/200% text layout.

## Physical-output correction stays local

Starting native transmission bypasses the current physical-output/headphone
preset and its preamp while retaining the general music policy. Preset edits
during transmission are saved for the local output; leaving restores the latest
assignment without replacing the queue. A partial overlap is re-armed during
this output/DSP transition. Later overlap decoders inherit the shared source
curve, so both lanes use the same policy. 113 focused output-EQ/shared-session
tests pass, including real socket ownership and unchanged track identity.

A full Linux debug application built successfully at a64e31c8b, including the
native capture/channel registration and pinned MilkRust runtime. This is a
compiler result with the existing decoder pin, not physical output or native
mobile-platform qualification.
