# Steam receiver testing handoff

PR: [#81](https://github.com/snapetech-org/PlezyNG/pull/81)

Branch: `codex/steam-vulkan-cloud-relay-20261028`

Start with [SDK_BUILD_HANDOFF.md](SDK_BUILD_HANDOFF.md) for SDK acquisition,
platform preparation, reproducible native build commands and build-agent
receipts. Android JNI builds now pass for all four ABIs and the Kotlin bridge
compiles against real SDK APIs; full application packaging remains a gate.

The [visual and interaction pass](VISUAL_EXPERIENCE.md) adds focused library,
Connections and streaming-settings routes, responsive game details, explicit
computer preferences and consistent Steam attribution. Its widget evidence
and physical accessibility checks are recorded separately from receiver builds.

## What this handoff covers

PRs #54 and #71 have merged. This follow-up adds native Vulkan/HDR10 reception,
scoped Cloud file actions, paired internet streaming, Windows/Apple HDR and
reviewed Families management. Build the exact PR #81
head; earlier PRs and historical test results are not substitutes.

Test the implemented receivers and connected library described below. The
requested Families and Windows/Apple HDR source paths are integrated. The supported receiver/client source scope is integrated, including controller
feedback/motion, microphone sharing and per-game touch positioning. Account-global
Cloud mutation has no assumed write contract; game-side SDK actions still need
the owning game. Do not label this a release candidate or treat source
integration as deployment.
[VALIDATION.md](VALIDATION.md) records actual checks; historical results do not
qualify a different commit. Record `git rev-parse HEAD` with every result.

| Area | Implemented behavior to test | Still missing |
| --- | --- | --- |
| Windows | Media Foundation H.264/HEVC SDR, retained texture, XAudio2, Credential Manager and input; opt-in Win32 Vulkan direct Pyrowave/HDR plane | Current-head MSVC x64/ARM64 builds and device qualification; Vulkan HDR/Pyrowave output qualification |
| Linux/SteamOS | GStreamer H.264/HEVC SDR; opt-in Wayland Vulkan direct GPU Pyrowave 4:2:0/4:4:4 and gated HDR10; libsecret, surround and input | Packaged app, compositor/GPU/HDR and host qualification; X11 keeps the compatible SDR path |
| macOS/iOS/iPadOS/tvOS | VideoToolbox/Core Audio, Keychain, retained texture; opt-in Metal Pyrowave SDR/HDR 4:2:0/4:4:4 on supported GPUs/displays | Current-head Apple SDK builds and device qualification; native Metal HDR output qualification |
| Android/Android TV/Fire TV | H.264/HEVC SurfaceView, session-owned replaceable Surface/activity, Opus, controller seats; opt-in native Vulkan direct GPU Pyrowave 4:2:0/4:4:4 and gated HDR10 | Current-head Gradle/NDK/release builds, GPU/display/color and host qualification |
| Connected library | Canonical AppID cards with independent routes from several computers, inventory permissions, favorites and preferred routes | Real-host inventory/availability and large-library qualification |
| Steam account/host features | Public catalog/achievements/news, optional social context; permissioned host actions; scoped Cloud listing/download/replace/delete; separately authorized and reviewed Families mutations | Valve-issued Cloud approval/configuration, live Families and Cloud qualification; account-global Cloud mutation requires a supported write contract |
| Internet streaming | Paired same-Steam-account WSS relay, encrypted IPv4 UDP hole punching, automatic relay fallback and route diagnostics | Operator deployment, current platform builds, real NAT/CGNAT/mobile and throughput qualification; opted-in internet Pyrowave/HDR throughput and output qualification |

HDR is advertised only by an opted-in Vulkan or Metal decoder/native-plane path
that passes its runtime display and format probes. Conventional SDR receivers
do not advertise it. A successful
decoder probe, a visible menu entry, or a browser/Steam URI submission is not
evidence of HDR, an installed game, a completed host action, or a changed account.
Cloud OAuth writes require a Valve-issued client grant scoped to the relevant
AppIDs; see [Valve OAuth](https://partner.steamgames.com/doc/webapi_overview/OAuth)
and [ICloudService](https://partner.steamgames.com/doc/webapi/ICloudService).
Families uses a separate explicit user QR session, never catalog/OpenID
authority, a publisher key or an existing cookie. Its Steam client-service
contract is not a general third-party Steamworks API guarantee. Review the
trust model and live cases in [STEAM_FAMILIES.md](STEAM_FAMILIES.md) before
enabling it; the feature defaults off.

## Obtain a build of the exact commit

Use an isolated checkout of this branch, locked dependencies and the platform
pins already in the repository. Keep an older installed build/profile backup
for migration checks. Do not replace the user's working installation or trust
records as a test setup shortcut.

The repository's workflows are manually dispatched. From an authenticated
maintainer session:

```sh
gh workflow run ci.yml --repo snapetech-org/PlezyNG \
  --ref codex/steam-vulkan-cloud-relay-20261028 \
  -f action=ci -f runner_pool=private -f build_linux_packages=true
gh workflow run games-native.yml --repo snapetech-org/PlezyNG \
  --ref codex/steam-vulkan-cloud-relay-20261028 \
  -f action=games -f runner_pool=private
```

Confirm each run's SHA matches the intended checkout. The CI workflow covers
the existing private Linux, Android, Windows x64/ARM64 and Apple jobs. Apple
tests build the real Runner workspaces and invoke the VideoToolbox/Metal tests;
a simulator/Intel Metal skip does not qualify the GPU path. The Android module
job now runs the Steam JVM tests as well as building both embedded engines.
No hosted runner fallback or runner permission widening is authorized.

Before live testing, require the platform's build and tests to pass. Build
Android's minified app release as well as debug; verify both supported ABIs and
the `-PplezyGamesEmbedded=false` configuration. Verify Linux packages contain
the fixed GStreamer dependencies and notices. Qualify Windows N without Media
Feature Pack and Windows without an HEVC decoder. Confirm browsing stays usable
when a receiver is unavailable.

For local portable verification on a provisioned Linux builder:

```sh
flutter pub get --enforce-lockfile --no-example
python3 -m unittest discover -s scripts/games -p 'test_*.py'
python3 scripts/games/prepare_steam.py
cmake -S native/games/steam -B build/steam-handoff \
  -DPLEZY_STEAM_TESTS=ON -DPLEZY_STEAM_GSTREAMER=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build/steam-handoff --parallel 2
ctest --test-dir build/steam-handoff --output-on-failure
flutter test test/games test/multiview test/services/gamepad_service_test.dart \
  test/providers/companion_remote_provider_test.dart \
  test/services/companion_remote_receiver_test.dart \
  test/services/companion_remote_peer_service_test.dart
python3 scripts/checks/check_localizations.py
```

The GStreamer test needs the bad/good/libav plugins, including `openh264enc`
and the H.264 parser. It decodes actual pixels using both Annex-B and avcC
framing. A missing plugin is a provisioning failure, not a passing test.

## Live test sequence

1. **Pair and retire trust.** Pair with correct/wrong/expired PINs; reject on the
   host; revoke pairing in Steam and reconnect. Cancel during discovery, PIN,
   launch, first-frame wait and shutdown. Forget a host and switch/delete a
   profile during each operation. No old operation may launch a game, publish
   an inventory, regain input or save credentials after retirement. Check OS
   vault/keyring failure, a locked keyring, and changed host identity.
2. **Unify three computers.** Use a Steambox, desktop and BC250 with overlapping
   and distinct installed titles and more than one library volume. Confirm one
   card per Steam AppID, distinct computer routes and preserved local shortcut
   identities. Test the same display name with different AppIDs, a disconnected
   volume, host offline, stale inventory, revoked sharing, partial/paged refresh,
   and an install/uninstall between refresh and launch. A failed refresh must
   retain useful prior data without claiming current playability. Test preferred
   routes and favorites after relaunch and profile changes.
3. **Establish the conservative stream.** Start with Pyrowave off, H.264,
   720p30/stereo and one controller. Then 1080p60, HEVC, quad/5.1 and four seats.
   Record what the host actually negotiated. Verify first-frame evidence before
   enabling controls/recording recents; verify disconnect does not quit the
   host game. Test a host that accepts a connection but sends no video.
4. **Exercise recovery.** Reject/fail HEVC and verify one H.264 compatibility
   retry. Reject surround and verify stereo. Opt into Pyrowave only on a capable
   device; fail initialization, malformed framing and first-frame delivery.
   The capability must be removed on retry, without a reconnect loop. Android
   must finish its decoder workers before the old runtime is destroyed or a new
   decoder touches the surface. A stuck shutdown must fail visibly rather than
   acknowledge completion. Drop the network during each retry and close a pane
   while it is reconnecting.
5. **Check ownership and controls.** Mix video/music/game panes; change active
   audio and controller owners. Verify inactive panes are muted and cannot send
   input. Unplug one of four pads while holding buttons; the others must retain
   their state. Verify touch assistance shares player one without taking a
   physical seat. Hold two touch buttons and a stick, resize/rotate, lose focus,
   hide touch controls and close the view. Every held input must be released.
   Test keyboard/pointer/scroll and Shift+Escape on desktop; D-pad/Back on TV.
6. **Measure output.** Use channel-identification audio for mono/stereo/quad/5.1,
   not just an audible sound. Change Bluetooth/HDMI/default audio output during
   playback. On Apple Metal, compare fine colored text/chroma patterns in host
   selected 4:2:0 and 4:4:4. Confirm diagnostics report observed chroma/decoder
   type. Confirm unsolicited PQ/HLG content is rejected by SDR paths. Record
   CPU/GPU load, latency, dropped frames, memory, thermals and power over a
   sustained session and repeated reconnects. Direct GPU/HDR proof is required
   before a release support claim; this handoff supplies no hardware proof.
   Follow [VULKAN_RECEIVER.md](VULKAN_RECEIVER.md) for Android/Wayland PQ,
   10-bit swapchain, GPU synchronization and SDR fallback cases.
7. **Check account/companion boundaries.** Exercise public/private accounts,
   unavailable API credentials, expiry, revocation and account switching. Verify
   hidden achievements remain hidden. With host actions disabled, commands must
   fail; enable narrowly, then revoke while an action is pending. Reject replay,
   unknown AppIDs/actions, retired peers and unsolicited URLs. Confirm the
   actual host result separately from submission. Follow
   [STEAM_CLOUD.md](STEAM_CLOUD.md) with a disposable authorized save for the
   separate read/write grants, conflict, cancellation and ambiguous-result cases.
   Disabled/older servers keep the confirmed Steam fallback. When separately
   enabled and authorized, qualify the implemented Families mutations using
   [STEAM_FAMILIES.md](STEAM_FAMILIES.md); a submitted request must never be
   described as an observed account change.
8. **Accessibility and older builds.** Test screen readers, keyboard-only and
   remote-only use, 2× text, RTL, narrow portrait/landscape, high contrast and
   existing light/dark themes. Focus must return to the opening control after a
   menu/dialog. Upgrade a populated legacy profile and connect an older companion
   lacking new capabilities; unavailable actions must stay unavailable. New
   English fallbacks are explicitly tracked, not language-reviewed translations.
9. **Internet routes.** Provision the optional service and follow
   [STEAM_INTERNET.md](STEAM_INTERNET.md). Verify the two opt-ins, same-account
   admission and pairing gates; LAN preference, WSS start, authenticated direct
   UDP upgrade and automatic WSS fallback. Measure interruption and sustained
   load across real networks, including a mid-stream revoked grant. Confirm
   each computer on a shared game card remains a distinct route.

## Result record and stop conditions

Record this for each platform/host pairing:

```text
PR / exact commit:
Build workflow URL, job, architecture and artifact checksum:
Client OS / SDK / device / GPU / driver / display / audio route:
Steam host OS / stable-or-beta version / GPU / selected computer:
Network route (LAN / existing VPN / direct UDP / WSS relay), speed and loss:
Requested settings / observed codec, chroma, resolution, rate and channels:
Checks performed / pass, fail or skipped / reproduction steps:
First-frame time / reconnect time / latency / drops / CPU-GPU-memory-power:
Accessibility and legacy-profile findings:
Sanitized logs / screenshots / profiler traces:
```

Remove PINs, trust keys, account tokens, API keys, cookies, full home paths and
private addresses from shared evidence. Keep test accounts and destructive host
operations explicitly authorized. Stop promotion for a crash, credential leak,
cross-profile disclosure, stuck input, stale callback/action, unbounded resource
growth, false playback claim, corrupt color/audio or unacknowledged teardown.
File implementation gaps separately from device failures and skipped tests.

## Windows and Apple HDR source checkpoint (2026-10-29)

See [DESKTOP_HDR.md](DESKTOP_HDR.md) for output gating, lifecycle and the device test matrix. Windows Vulkan-enabled cross-compilation/linking and strict adapter syntax checks pass. Apple HDR code and GPU precision tests are integrated but have not run under an Apple SDK here. Do not promote that to a tested Apple build or measured HDR output.

## Follow-through acceptance cases — 2026-10-29

- Unmount/remount a workspace pane during playback. The native receiver ID,
  route and transport survive; input is neutral while hidden. Rotate Android,
  replace its Surface and background/foreground it; decoder output recovers.
  Explicit close and engine destruction still retire the session exactly once.
- Edit each controller seat's mapping, disabled buttons, stick axes/deadzones and
  trigger deadzone. Confirm no stuck keys/buttons, isolation between players,
  persistence across host choices for the same AppID, profile isolation and
  replay after conventional-codec fallback. Reject malformed native mapping data.
- Use Steam controls with and without a live input lease. Shift+Tab opens the
  configured host overlay; test an eligible Remote Play Together game and invite
  manually in Steam. F12 captures on the host with the default shortcut. Custom
  or disabled Steam shortcuts must not produce a false success claim.
- Install on the BC250 with the game already installed on the desktop. Confirm
  snapshot dates, target exclusion and request-only feedback. In Steam Downloads,
  verify whether Steam selects LAN transfer; repeat with a stale/offline donor.
- Test opt-in 4K60 and 1080p120 on capable and incapable hosts/devices. Confirm
  unchanged defaults on an older saved profile, actual diagnostics, bounded
  queues and graceful decoder rejection. Verify HDR/chroma independently.
- Relay old/new ready messages and invalid rate announcements. Confirm request
  bitrate fits the advertised budget with headroom, including a direct-to-relay
  transition. Higher relay limits require explicit operator provisioning.

- Compose CJK, accented and astral/emoji text using the local keyboard and TV
  keyboard fallback. Do not submit pre-edit composition. Confirm the active host
  field receives committed text once, input lease loss cancels submission, and
  invalid controls or payloads over 512 UTF-8 bytes fail without partial text.
- Change touch opacity and swap controller sides in profile settings. Start a
  new stream on Android and a texture receiver; verify unchanged labels/actions,
  independent multi-touch release, physical minimum targets and profile isolation.

## Microphone forwarding

Follow [STEAM_MICROPHONE.md](STEAM_MICROPHONE.md) on each built receiver. Verify
permission denial/revocation, actual host voice input, all mute/lifetime paths,
headset changes and simultaneous receiver playback. No local source test proves
OS capture permissions or real host microphone negotiation. tvOS must show
unavailable without prompting or advertising a microphone channel.

## Controller and touch completion pass

Use [STEAM_CONTROLLERS.md](STEAM_CONTROLLERS.md) for capability and ownership
contracts. Build the vendored gamepad plugin on every target as part of the app;
Windows now pins SDL3 to an immutable commit and uses C++20 for Flutter's
current event-channel headers. Apple SDK compilation and full Gradle app
packaging remain required gates. The SDK preparation checkpoint separately
records successful real NDK builds and Kotlin adapter compilation; neither
substitutes for packaged app execution.

- Exercise one through four controllers, USB/Bluetooth hot-plug and OS ID reuse.
  Rumble must affect the correct physical controller and stop on focus/dialog/
  profile/lease loss. Unsupported controllers still provide buttons/sticks.
  Rapidly transfer ownership between panes and replace a receiver while input
  resets are delayed; an older completion must not disable the current owner
  or resume the retired receiver's effects/microphone.
- Enable the motion profile before opening the stream; configure a compatible
  game or host Steam Input gyro binding. Verify gyro/acceleration axis orientation,
  neutral input after disconnect/backgrounding and no phone-IMU substitution.
- Arrange touch controls through Steam controls. Drag, use position sliders,
  Cancel/Save/Reset, rotate and resize, and switch profiles or host machines.
  Check large text, RTL, TalkBack/VoiceOver and D-pad navigation. Keep a finger
  held while hiding the overlay or transferring input; every input must release.
  Each position slider must announce its selected control, axis and percentage;
  screen-reader increase/decrease must move that control along only that axis.
- On Android verify the embedded Flutter overlay above both SurfaceView codecs
  and Vulkan output; separately verify legacy standalone native controls.
- Keep microphone consent off while qualifying controller sensors: gyro is
  controller input and must never turn on microphone capture.
