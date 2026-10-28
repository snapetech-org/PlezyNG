# Steam receiver testing handoff

PR: [#71](https://github.com/snapetech-org/PlezyNG/pull/71)

Branch: `codex/steam-live-test-handoff`

## What this handoff covers

PR #54 has merged. This follow-up preserves its receiver implementation and
regression coverage while reconciling the app with main `eb075932`. Build the
exact PR #71 head; the earlier PR and historical test results are not substitutes.

Test the implemented receivers and connected library described below. The
expanded request is **not fully code complete**. Do not convert the missing
implementations into hardware sign-off items, or label this a release candidate.
[VALIDATION.md](VALIDATION.md) records actual checks; historical results do not
qualify a different commit. Record `git rev-parse HEAD` with every result.

| Area | Implemented behavior to test | Still missing |
| --- | --- | --- |
| Windows | Media Foundation H.264/HEVC SDR, retained texture, XAudio2, Credential Manager and input | Current-head MSVC x64/ARM64 builds and device qualification; HDR/Pyrowave presentation |
| Linux/SteamOS | GStreamer H.264/HEVC SDR, retained texture, libsecret, surround and input | Packaged app qualification; direct GPU Pyrowave and HDR implementation |
| macOS/iOS/iPadOS/tvOS | VideoToolbox/Core Audio, Keychain, retained texture; opt-in Metal Pyrowave SDR 4:2:0/4:4:4 on supported GPUs | Current-head Apple SDK builds and device qualification; HDR presentation implementation |
| Android/Android TV/Fire TV | H.264/HEVC SurfaceView, retained pane/activity, Opus, controller seats; opt-in Vulkan Pyrowave SDR 4:2:0 with CPU readback | Current-head Gradle/NDK/release builds and device qualification; direct GPU Pyrowave and HDR implementation |
| Connected library | Canonical AppID cards with independent routes from several computers, inventory permissions, favorites and preferred routes | Real-host inventory/availability and large-library qualification |
| Steam account/host features | Public catalog/achievements/news, optional social context; permissioned host launch/install/Input/properties handoffs; Cloud/Families account destinations | Live API/host qualification; programmatic Cloud/family mutations |
| Internet streaming | Manually reachable paired hosts, including an existing VPN route | Authenticated rendezvous, NAT traversal and relay implementation/deployment |

No HDR capability is advertised by these SDR receiver paths. A successful
decoder probe, a visible menu entry, or a browser/Steam URI submission is not
evidence of HDR, an installed game, a completed host action, or a changed account.
Cloud OAuth writes require a Valve-issued client grant scoped to the relevant
AppIDs; see [Valve OAuth](https://partner.steamgames.com/doc/webapi_overview/OAuth)
and [ICloudService](https://partner.steamgames.com/doc/webapi/ICloudService).
No documented, authorized general Steam Families mutation contract has been
established for this application. Do not collect Steam passwords/cookies or
ship a publisher key to fill that gap.

## Obtain a build of the exact commit

Use an isolated checkout of this branch, locked dependencies and the platform
pins already in the repository. Keep an older installed build/profile backup
for migration checks. Do not replace the user's working installation or trust
records as a test setup shortcut.

The repository's workflows are manually dispatched. From an authenticated
maintainer session:

```sh
gh workflow run ci.yml --repo snapetech-org/PlezyNG \
  --ref codex/steam-live-test-handoff \
  -f action=ci -f runner_pool=private -f build_linux_packages=true
gh workflow run games-native.yml --repo snapetech-org/PlezyNG \
  --ref codex/steam-live-test-handoff \
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
   before any future support claim; this handoff supplies no such proof.
7. **Check account/companion boundaries.** Exercise public/private accounts,
   unavailable API credentials, expiry, revocation and account switching. Verify
   hidden achievements remain hidden. With host actions disabled, commands must
   fail; enable narrowly, then revoke while an action is pending. Reject replay,
   unknown AppIDs/actions, retired peers and unsolicited URLs. Confirm the
   actual host result separately from submission. Cloud/Families actions should
   open the fixed Steam destination with consent, never claim a mutation.
8. **Accessibility and older builds.** Test screen readers, keyboard-only and
   remote-only use, 2× text, RTL, narrow portrait/landscape, high contrast and
   existing light/dark themes. Focus must return to the opening control after a
   menu/dialog. Upgrade a populated legacy profile and connect an older companion
   lacking new capabilities; unavailable actions must stay unavailable. New
   English fallbacks are explicitly tracked, not language-reviewed translations.

## Result record and stop conditions

Record this for each platform/host pairing:

```text
PR / exact commit:
Build workflow URL, job, architecture and artifact checksum:
Client OS / SDK / device / GPU / driver / display / audio route:
Steam host OS / stable-or-beta version / GPU / selected computer:
Network route (LAN / existing VPN), link speed and loss conditions:
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
