# Connected games code completion

This ledger tracks the implemented receiver/client scope and external API boundaries on PR #81. It
does not replace the SDK build and real-device acceptance cases in
[LIVE_TEST_HANDOFF.md](LIVE_TEST_HANDOFF.md).

[SDK_BUILD_HANDOFF.md](SDK_BUILD_HANDOFF.md) provides SDK acquisition and
preparation scripts, exact platform commands and build-agent assignments. All
four Android JNI ABIs and the Kotlin bridge now compile against real SDKs;
full application packages and native Windows/Apple builds remain separate gates.

## Implemented in this follow-through

- Desktop/Apple receiver creation and teardown are owned by the workspace
  session. Presentation widgets can unmount/remount without restarting the
  transport. Detachment releases input and hides native planes. Late creation,
  timeout, reconnect and profile retirement still retire the correct receiver.
- Android retains its session outside the Flutter PlatformView. The video
  worker rebuilds its output against replacement Surfaces while preserving
  transport/audio ownership; engine destruction and explicit disconnect retire
  the session. Older view arguments keep their original disposal behavior.
- The authenticated internet tunnel carries opted-in Pyrowave/HDR requests.
  Native decoder/display probes and conventional-codec fallback remain
  authoritative. The tunnel forwards the same bounded encrypted datagrams,
  independent of codec; hardware and real-network throughput remain unmeasured.

- Per-game, per-profile controller layouts are shared across host choices. The
  in-app editor remaps or disables 15 buttons for each of up to four seats,
  adjusts stick/trigger deadzones, inverts stick axes and swaps sticks/triggers.
  The shared native runtime applies the mapping to physical and touch input on
  every receiver. Custom layouts must acknowledge before input is enabled, replay
  after fallback and roll back on partial failure. Host Steam Input remains the
  authority for game-specific action sets through the existing host configuration
  action. PlezyNG does not alter another game's Steam Input files.

- The Steam controls toolbar sends explicit default host shortcuts for the
  overlay/Remote Play Together and screenshot capture. Input ownership gates
  submission, and all keys release on completion/error/lease loss. The UI explains
  host shortcut configuration, game eligibility and Steam-owned guest permissions.
- Installation confirmation identifies other installed host snapshots and their
  observation dates. It excludes the target and incomplete copies, preserves the
  paired-peer/install permission gates, and distinguishes request submission from
  observed installation or Steam's LAN donor selection.
- Optional 4K60 and 1080p120 requests now reach every receiver. All native decoder
  and output bounds, compressed access units and texture allocations are consistent.
  Host dimensions cannot exceed the selected request. The legacy preset remains
  1080p60/30 Mbps; older persisted settings remain valid.
- Relay bandwidth is explicitly configurable from 1..64 MiB/s per direction,
  retaining the 8 MiB/s default. Its optional ready field is backward compatible.
  Receiver video requests reserve headroom for a later direct-to-relay transition.

- The Steam controls dialog composes text through PlezyNG's existing local/TV
  keyboard and IME. Composing text stays local; only an explicit committed Send
  submits bounded standard UTF-8 through every native receiver. Control bytes,
  invalid sequences and oversized payloads are rejected. Submission requires a
  current input lease and native acknowledgement; there is no automatic retry.
- Profile-scoped touch opacity and swapping controller sides work on the shared
  Flutter overlay and Android native controls. Defaults and 48-pixel minimum hit
  targets stay intact. Changes apply when the next stream opens.

- Explicit microphone sharing now captures on Android (AudioRecord), Windows
  (WASAPI), Linux (GStreamer) and iOS/macOS (AVAudioEngine). OS permission and
  current input ownership gate capture; 10 ms Opus frames use the authenticated
  Steam transport. Fixed-size buffers, bounded queues, stale-generation checks
  and a transport channel lifetime guard protect capture and teardown. The
  visible toolbar indicator distinguishes starting from actual submission.
  Leaving input ownership, opening a dialog, backgrounding or disconnecting
  mutes; capture never resumes automatically. tvOS reports unavailable and does
  not advertise microphone capture. See [STEAM_MICROPHONE.md](STEAM_MICROPHONE.md).

- Physical controller rumble, trigger rumble where supported, and opt-in motion
  are wired from Steam SDL reports through bounded native queues to the existing
  device plugin on Windows, Linux, Apple and Android. The default Xbox profile
  is preserved; motion uses an explicit PS4-compatible virtual profile. Device
  capability checks, same-device identity, ownership tokens, input/focus gates,
  cancellable requests and neutral motion expiry protect teardown and handoff.
- Individual touch controls can be dragged or positioned with accessible sliders,
  saved per game/profile with separate wide and compact layouts. Collision and
  viewport bounds preserve minimum targets. Embedded Android shares the themed
  Flutter editor/overlay; legacy standalone callers retain native controls.
  See [STEAM_CONTROLLERS.md](STEAM_CONTROLLERS.md).

- Native input updates share one revision- and receiver-checked path. Revocation
  is sent before waiting for reset completion, so a delayed old reset cannot
  overwrite a newer grant, including after receiver replacement. Controller
  effects and microphone capture stop immediately when input is revoked.
  Touch-position sliders expose the selected control, axis, value and semantic
  increase/decrease actions as one accessible control.

## Remaining contracts and qualification

- SDK preparation is implemented: checksum-verified Android host tools and all
  vendored-module pins; NDK/JNI/ELF artifact inspection; Linux development/codec
  preflight; Windows VS/SDK provisioning and verification; process-local Xcode,
  Metal and actual Apple source probes. Private-runner CI invokes these checks
  and preserves receipts. Windows/Apple host execution and the amended workflows
  have not run in this Linux development environment.

- Cloud settings: public Steamworks exposes account-wide read access and an
  app-scoped setter for the calling game's own AppID. A general account-wide
  mutation must not be fabricated from those APIs or from an assumed VDF key.
- Steam Input game-side glyph/action APIs and automatic Together invites belong
  to the game SDK, not an arbitrary receiver. The implemented receiver layout and
  host overlay flows do not impersonate game AppIDs.
- SDK builds, physical HDR/chroma output, real Steam hosts/accounts and deployed
  relay throughput still require the exact-head handoff cases.

## Contract references

- [Valve Remote Play](https://partner.steamgames.com/doc/api/ISteamRemotePlay)
- [Valve Remote Storage](https://partner.steamgames.com/doc/api/ISteamRemoteStorage)
- [Valve Steam Input](https://partner.steamgames.com/doc/api/ISteamInput)
- [Valve LAN transfers](https://help.steampowered.com/en/faqs/view/46BD-6BA8-B012-CE43)

Game-side Steamworks methods do not authorize a third-party client to impersonate
another game's AppID. LAN file transfer selection and integrity remain Steam's
responsibility; installation assistance must report submission and observed
inventory separately from completion or a guaranteed transfer source.

## Evidence

- Nineteen targeted Flutter tests pass for presentation lifetime, late teardown,
  input ownership and the real TLS/UDP relay fixture after enabling codec
  preferences over the tunnel.
- Android Steam Java sources compile against API 36 (20 existing deprecation
  warnings). This does not establish a Kotlin/Gradle/NDK or device build.

The controller checkpoint passed 22 focused Flutter tests, Android Java API 36
compilation, 42 native tests (one separate GPU/display case skipped), and Windows
MinGW runtime plus five test-executable links. The host/quality follow-through
also passes Go race tests and the targeted dialog/lease/tunnel cases. These
checks are not substitutes for Kotlin/Gradle/NDK, Apple SDK or MSVC builds.

The final input pass expands verification to 141 Steam Flutter tests and 16
Android JVM tests, while retaining the native build/test and strict Linux/Windows
adapter checks. See [VALIDATION.md](VALIDATION.md#code-follow-through--2026-10-29)
for the exact distinction between source checks and platform qualification.

The microphone checkpoint additionally passes 26 receiver/ownership Flutter
tests, the standard analyzer, 42 native tests (one display case skipped), Android
Java API 36 compilation, and Windows runtime/test executable links. The runtime
suite now includes concurrent microphone channel removal and lease invalidation;
the audio suite decodes real 10 ms Opus packets at every supported input rate.

The controller/touch completion pass passes **171 Flutter tests**, the standard
analyzer, strict Linux/Windows adapter and controller-plugin syntax checks,
Android API 36 Java compilation, **16 JVM tests**, and the expanded native
runtime checks. The native suite remains **42 passed plus one display skip**;
Windows runtime/test executable links pass. Current details and SDK/live gates
are in [VALIDATION.md](VALIDATION.md#controller-and-touch-completion--2026-10-29).

The ownership/accessibility follow-up verifies **174 distinct Flutter tests**,
including a final 27-case receiver/touch run, and a clean standard analyzer.
Delayed reset acknowledgements cannot overwrite newer input grants, and the
touch editor's merged semantics support named, axis-specific adjustment.
See [the follow-up evidence](VALIDATION.md#input-ownership-and-accessible-adjustment--2026-10-29).
