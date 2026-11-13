# RomM Games integration

Owner request: implement the RomM assessment in PlezyNG, prioritizing playing
inside the application. Started 2026-10-29. Source contract: RomM 5.4.1,
`9c74d0143fbb876f2f62260b91c6fd0b3f590226`.

## Product boundary

PlezyNG owns browsing, selecting an exact copy, play/resume, input, offline
storage and session presentation. RomM owns its catalog, permissions, browser
engines, streamed emulator sessions and server saves. ROMarrNG/QuestarrNG keep
acquisition; SeerrNG keeps requests. Connecting RomM must not require SeerrNG.
The existing Games navigation, profiles, themes, focus and Steam workflows are
retained. A title, a particular ROM/disc set and a playable route are separate.
No title-only matching silently merges editions, platforms or save data.

## Delivery ledger

| Area | Required behavior | Source status |
| --- | --- | --- |
| Connection | Scoped device authorization, code/QR, manual token compatibility, vault storage, reconnect and remove | implemented in source; runtime validation pending |
| Library | Native Games integration, paged search, platform/source/collection filters, covers, details, variants, favorites and recent play | implemented in source; runtime validation pending |
| Capability | Inspect exact file and server runtime configuration, explain missing bytes/firmware/runtime, choose browser/stream/native independently | implemented in source; runtime validation pending |
| Browser play | In-app player surface, authenticated same-origin transport, bounded resources, controller/touch, close/profile retirement, save handling | implemented in source; runtime validation pending |
| Stream play | RomM WebRTC player, server session ownership, launch/busy/failure states, resume/disc/memory-card controls, reconnect and save-and-exit | implemented in source; runtime validation pending |
| Saves | Exact-ROM and engine identities, list/import/export, conflicts/history, durable pending uploads and per-profile isolation | implemented in source; runtime validation pending |
| Offline/native | Verified downloads, bounded storage, cancellation/recovery, in-app native core host and packaged core recipes, compatible save sync | implemented in source; runtime validation pending |
| Ecosystem | Collections, metadata/art, screenshots/manuals, achievement progress with honest earning capability, multiplayer where supported | implemented in source; runtime validation pending |
| Handoff | Validated external game links, acquisition-to-index matching, no credentials in links, safe source/copy selection | implemented in source; runtime validation pending |
| Platforms | Explicit browser/native availability on desktop/mobile/TV, native packaging recipes and fallbacks that remain inside PlezyNG | implemented in source; runtime validation pending |
| Accessibility/localization | Keyboard/D-pad, large text, RTL, semantic state, stable translation keys with explicit English fallback provenance | implemented in source; runtime validation pending |

## Integration record — 2026-11-05

PR #111 was closed without merging. Its RomM and prerequisite Steam sources
were reconciled with current main, preserving newer profile, podcast, playback,
release and runner-policy changes. The SDK preparation tests pass; new RomM
boundary regressions are checked in. Dart/Flutter, Go, CMake and native SDKs are
not installed in this workspace, so their suites have not executed here.

## Original implementation constraints

- This branch combines current main with Steam PR #81 without modifying its
  branch. Other active agents' work remains separate.
- Runtime and source completion are distinct. No builds, tests, analyzers or CI
  are run under the owner's recorded code-only instruction. Commits skip CI.
- No arbitrary executable downloads, server-supplied shell commands, plaintext
  token persistence, shared-user saves or external emulator launch fallback.
- Online engines may use the server's shipped player, but the library remains
  PlezyNG-native. Redirects and upstream resource destinations are constrained.
- Save states are engine/core/version-specific; a ROM filename or a shared
  game title is never sufficient evidence of compatibility.
- Native recipes pin dependencies and follow the repository runner policy.
  Platform adapters must report absent runtimes honestly until packaged.

## Delivery notes

Implementation and platform handoff are documented in [ROMM_INTEGRATION.md](ROMM_INTEGRATION.md).
The native host is wired into platform build recipes; core binary staging and
Apple signing remain explicit release inputs. The default core recipe excludes
Snes9x and Genesis Plus GX pending distribution-license review. Every native
route requires an OS-isolated worker. Desktop, Android, webOS and Tizen have
worker implementations; iOS 26 and later use the Enhanced Security extension.
The iOS extension has passed hosted packaging validation, while signed-device
acceptance remains open. Native play is unavailable on earlier iOS and tvOS.
webOS and Tizen signed packages and physical-device qualification also remain
open. See [the current policy](../security/native-emulator-isolation.md).
Browser netplay remains unadvertised because device tokens do not establish its
session cookie.

## Acceptance handoff

Exercise classic browser and native play plus a streamed PS2/GameCube title:
connect, browse, select exact copy, launch inside PlezyNG, controller/touch,
save, exit and resume. Include cancellation during launch/download, expired
access, server loss, missing firmware, occupied stream host, disc change,
profile retirement, incompatible state, offline changes on two devices and
large-text/RTL/TV focus. Device results are not implied by source review.

The continued source pass repaired pairing scopes, stable/nightly eligibility,
bearer/cookie account isolation, stale async results, durable per-save journals,
partial-download recovery/quota accounting, stream retirement, Linux load-error
callbacks, native audio/aspect/pause/history handling and the pinned mGBA build
recipe. Native progress now includes exposed cartridge RTC memory, with readers
for older snapshot formats. Follow-up validation must exercise interrupted
payload and manifest writes, quick A→B→A profile switching, end-of-claim
heartbeats, two accounts on one server, paused play history and clock-enabled
cartridges across local and cloud resume. These are source changes, not results
from a build or device run.

## Primary references

- https://docs.romm.app/5.4.0/developers/client-api-tokens/
- https://docs.romm.app/5.4.0/developers/device-sync-protocol/
- https://docs.romm.app/5.4.0/using/emulator-streaming/
- https://docs.romm.app/5.4.0/using/in-browser-play/emulatorjs/
- https://github.com/rommapp/romm/tree/5.4.1
