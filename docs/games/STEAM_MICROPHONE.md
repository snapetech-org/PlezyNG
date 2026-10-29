# Steam microphone forwarding

The stream toolbar has an explicit microphone control. Sharing requires a
confirmation, OS permission where the platform provides a permission prompt,
the current workspace input lease and a host-negotiated Opus microphone channel.
The microphone starts muted. Neither permission nor consent is inferred from
audio playback, pairing, installation, a previous stream or a persisted setting.

| Receiver | Capture implementation | Permission / unsupported behavior |
| --- | --- | --- |
| Android | AudioRecord, PCM16, voice communication input | RECORD_AUDIO requested only after confirmation; optional hardware declaration; denial/removal mutes |
| Windows | WASAPI shared eCapture/eCommunications endpoint, negotiated PCM conversion | Windows privacy/device access is enforced on activation; no loopback recording |
| Linux | Fixed GStreamer autoaudiosrc conversion pipeline and bounded appsink | Missing/busy devices, plugins or sandbox access leave it muted; no arbitrary launch strings |
| iOS/macOS | AVAudioEngine input tap, AVAudioConverter, bounded PCM queue | AVCaptureDevice audio permission; iOS privacy description and macOS audio-input entitlement |
| tvOS | Unavailable | No input-node access, permission prompt or microphone advertisement |

The indicator distinguishes muted, starting and actual transport submission.
Host audio reception and voice-chat selection still require live verification;
successful local submission does not claim that a game or another person heard
it. A headset is recommended to avoid feeding receiver speakers back into chat.

Microphone forwarding stops on mute, dialog suspension, pane detachment,
background/input-lease loss, native reset, disconnect, host format replacement
and profile retirement. It never resumes automatically. A late permission result
cannot start capture, and a late capture worker cannot mute or submit into a
newer generation. One worker per runtime must acknowledge retirement before a
new one starts. Capture/device work runs off the UI and transport callback
threads; the UI never waits for a capture worker to join.

The runtime accepts mono/stereo Opus at 8, 12, 16, 24 or 48 kHz and emits 10 ms
frames (32/64 kbit/s). Samples never enter Dart, logs, preferences, recordings,
analytics or a persistent queue. PCM/encoded scratch buffers clear on mute,
failure and retirement. OS buffers are released; microphone packets use the
same authenticated encrypted Steam session as other input. No retransmission
or reconnect replays old voice data. Raw/unknown host microphone codecs are
reported unavailable instead of mislabeled as supported.

`steam-runtime-zz-microphone-lifetime.patch` protects the pinned transport's
microphone pointer separately from its mutable channel array. Host teardown
detaches the pointer and waits for an in-flight send before calling application
stop, without holding the transport lock across that callback. This prevents
channel removal from freeing memory while a capture thread submits.

On iOS the capture worker temporarily uses PlayAndRecord/VoiceChat. It restores
the previous category only if its own category/mode/options remain current and
does not deactivate another player's audio session. Device/route interruption
requires explicit re-enabling. Apple availability and device behavior need the
signed SDK build and hardware cases below.

## Live acceptance

1. Start each receiver with a paired Steam host. Verify no OS prompt or capture
   occurs until Share microphone is confirmed. Verify denial and missing-device
   errors leave playback intact, including settings-based permission revocation.
2. Enable the host's Remote Play microphone path and select its streamed input
   in Steam voice/game chat. Confirm audio in both directions with a headset;
   distinguish host routing from successful client packet submission.
3. While speaking, mute, open a dialog, change pane/input owner, background the
   app, disconnect, reconnect and switch profiles. Verify capture stops and never
   resumes without another explicit action. Exercise slow permission responses
   and unplug/replug while starting. No buffered speech may appear afterward.
4. Test the default input, USB/Bluetooth headset and revoked device access on
   Windows, Linux, Android, iOS and macOS. Confirm receiver playback survives
   category/route restoration on Apple. Check missing Linux capture plugins.
5. Verify tvOS does not access an input node or request recording permission.
   Verify large text, screen-reader state, keyboard/D-pad focus and visible mute.

Source tests exercise codec round trips, buffer bounds, stale leases, one-worker
ownership, channel-removal races and Flutter consent/lifetime flows. They do not
substitute for platform SDK builds or host/physical-device qualification.
