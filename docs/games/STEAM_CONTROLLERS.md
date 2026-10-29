# Steam controller feedback and touch layout

The embedded receiver retains four independent physical controller seats and a
separate player-one touch assistance state. Per-game button/axis remapping
applies in the shared runtime. The vendored `universal_gamepad` extension uses
the same device IDs as input, so vibration cannot select a device by an inferred
enumeration order. See its [integration notes](../../packages/universal_gamepad/PLEZYNG.md).

## Feedback and motion

Games settings expose controller vibration and a motion controller profile.
Preferences are scoped to the PlezyNG profile and apply on the next stream.
Vibration is enabled by default; motion remains opt-in. The default virtual
Xbox identity stays unchanged. The motion profile presents a PS4-compatible
SDL controller so a compatible game or host Steam Input binding can request
gyro/accelerometer reports. It can change the host's button prompts. It does
not install action sets or impersonate a game's Steamworks identity.

| Client | Rumble | Motion |
| --- | --- | --- |
| Windows | SDL3 low/high motors and trigger rumble when advertised | Existing SDL gamepad gyro/accelerometer sensors |
| Linux/SteamOS | evdev FF_RUMBLE on a verified writable device; no privilege escalation | Verified controller sensor sibling, kernel axis resolutions and monotonic timestamps |
| macOS/iOS/iPadOS/tvOS | GameController/CoreHaptics supported handle and trigger localities; combined fallback | That GCController's supported motion properties and manual activation |
| Android/Android TV/Fire TV | InputDevice's combined vibrator; no invented independent motor mapping | API 31+ InputDevice SensorManager; no phone/tablet IMU substitution |

The host's SDL output stream uses bounded, fragment-aware parsing. Only the
latest command of each kind is retained per seat, with a maximum one-second
rumble duration. Unknown commands are rejected; recognized LED/player/enhanced
rumble commands without a corresponding output implementation are consumed
without claiming physical support. Reserved feature-report bytes are zeroed.
Gyro is encoded at ±34.90659 rad/s and acceleration at ±19.6133 m/s², matching
the pinned ihslib SDL report. Input ownership and the host's sensor request must
both be active. Missing/invalid samples are neutral; native motion expires after
250 ms without refresh.

The Flutter bridge polls at most once every 20 ms, never overlaps a poll, and
accepts at most four validated rows. Every device operation carries the current
opaque effects token. Old acknowledgements, lease changes, dialogs, focus loss,
native text input, detach, cancellation and profile retirement release effects.
Pending request timers are cancelled on retirement. Losing the effects plugin
does not disable button/stick input. Each native implementation stops outputs
on device removal or pause as well.

Native input ownership is dispatched before awaiting reset acknowledgements.
Every update records its revision and receiver identity, so an older completion
cannot replace a newer grant or restart effects for a retired receiver. Dialog,
focus, attachment and reconnect updates use the same ownership path; microphone
and controller effects stop immediately when that path revokes input.

## Touch layout

Steam controls → Arrange touch controls opens a local editor with game input
suspended. Each button and stick can be dragged independently. Position controls
provide a selectable control list and keyboard/screen-reader-operable horizontal
and vertical sliders. Each slider announces the selected control, axis and
percentage, and supports the screen reader's increase/decrease actions.
Save commits; Cancel leaves the current layout unchanged;
Reset returns both layout variants to defaults. The editor sends no host input.

Positions are normalized over each control's available travel and stored per
game AppID and PlezyNG profile, shared across that game's machines. Wide and
compact variants are independent. Buttons remain 48 logical pixels and sticks
88 pixels; controls cannot overlap or leave the viewport. If resizing makes a
saved variant unusable, the receiver uses its safe default layout without
overwriting the saved one. Small panes explain that they need enlargement.
Labels, layout semantics, theme colors and opacity remain consistent with the
existing overlay. Embedded Android uses this shared overlay; standalone legacy
Android callers keep their native controls when the new argument is absent.

## Controller-only phone connection

On iOS and Android, a Steam game's card menu offers **On-screen controller**.
It opens that game in the workspace with touch controls enabled and hardware
controllers still accepted. The receiver requests Steam video and audio off
while keeping input on; native negotiation preserves those independent flags,
does not start audio/video decoders, and marks the session ready on connection
instead of waiting for a first frame.

This is a separate app-scoped Steam Remote Play connection to the selected
paired computer. Steam and the host decide whether it can coexist with another
device already playing that game. It does not use a Steamworks game API or
guarantee Remote Play Together behavior. Multi-device host behavior remains a
live qualification item.

## Qualification

Run the exact PR head on each platform with USB and Bluetooth controllers,
including a device without rumble/sensors, two same-model devices, four seats,
disconnect/reconnect and reused OS device IDs. Verify physical motor identity,
motion units/orientation, host Steam Input bindings, backgrounding, dialogs,
profile swaps and simultaneous input. Exercise touch rotation, RTL, large text,
TalkBack/VoiceOver, remote/D-pad navigation, safe areas and native HDR planes.
These physical/SDK checks remain build and live-test acceptance work.
