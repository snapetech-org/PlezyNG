# RomM in PlezyNG

This integration targets RomM **5.4.1** at
`9c74d0143fbb876f2f62260b91c6fd0b3f590226`. PlezyNG supplies the native Games
library, source/collection/platform selection, exact-copy details, storage and
save management. RomM supplies catalog access, browser engines and streamed
emulator sessions. No RomM deployment or ROM acquisition is performed by this
change.

## Use

Open **Games → Connect RomM**, enter the server URL (including its reverse-proxy
prefix), and approve the code/QR in RomM. A personal client token can also be
entered. Each PlezyNG profile keeps its own connections, encrypted credentials,
library cache, downloads and pending saves. If the platform vault cannot protect
the token, the connection lasts only for that app session.

Pairing requests `me.read` and `firmware.read` as well as the catalog, user-ROM,
asset, collection and device scopes. Account verification requires `me.read`;
EmulatorJS also fetches firmware metadata during startup. Re-pair older tokens
that lack those grants. A stable profile/server device identifier preserves the
device's save-sync history across reconnects. Effective permissions come from
the authenticated account response.

Search queries page the server. Select a source to filter its platforms and
normal/smart/virtual collections. Details show files, sibling copies, metadata,
manuals, screenshots and RetroAchievements information. Favorites synchronize
with the caller's favorite collection. Backlog, now-playing and completion
status update the exact ROM's user properties.

Cached rows still obey platform and collection filters when a refresh fails.
Downloads, interrupted transfers and pending saves remain reachable even when
they are absent from the server's current first page.

A playable route requires current server capability evidence or an installed
native core. Browser routes cover EmulatorJS, Ruffle, js-dos, PICO-8 and EasyRPG
where RomM enables them. They use RomM's player inside PlezyNG. Browser netplay
is not advertised: device-token authentication does not establish the session
cookie needed by RomM's general Socket.IO namespace.

The capability map distinguishes RomM's stable and nightly EmulatorJS cores;
nightly-only systems are offered only when the server selects that loader.

Streaming uses RomM's own session claim/status/heartbeat APIs and WebRTC room.
It does not reuse Steam's receiver. Launch options offer server-approved states,
saves, memory cards and multiplayer. Existing container memory cards require an
explicit keep/erase decision. Only the session owner can save/release/change
discs; joining another player's game grants no owner controls. Every owner
command includes the container and original claim timestamp. Save-and-exit
requires both `saved` and `released` acknowledgments.

Ended heartbeats retire the claim and its player surface. Cancellation during
startup releases a late successful claim, and old polls cannot revive a retired
session. Disc controls exclude playlist files and descriptor companion tracks.

## Saves and offline play

The Saves screen lists only the signed-in user's files for the selected ROM.
Imports and exports use the platform file picker. Imports require an emulator
identity; state imports also record the intended core. Pending uploads keep
fsynced bytes and content hashes in a per-profile manifest. Each queued version
also has an atomic journal written before its payload: interrupted writes recover
verified temporary bytes, and retirement tombstones prevent completed uploads
from reappearing. Missing payloads stay visible as failures. Concurrent changes
surface keep-both, use-server and explicit replace-server actions. Disconnecting
a server never deletes server-side saves.

EmulatorJS snapshots are also kept through the native save queue. Other browser
engines retain their RomM save controls and persistent, isolated browser data;
the close dialog asks the player to finish saving there. A reserved loopback
origin prevents another profile from inheriting its IndexedDB. The proxy never
exposes the RomM API token to browser JavaScript. Stream-room requests never
receive that token and reserve their own profile/source/room origins. Bearer
requests never reuse upstream login cookies, which RomM would otherwise resolve
before the token. EmulatorJS capture verifies the active ROM ID before labeling
bytes, including after navigation inside RomM's player.

Offline downloads select an exact file, support validated byte-range recovery,
check size and available SHA-1/MD5 hashes, and commit a manifest after completion.
The UI distinguishes server-verified content from servers without a checksum.
Downloads have a configurable 5–250 GiB UI quota; pending saves have a separate
512 MiB ceiling. Partial files count against the download quota, survive a
restart in the library and can be removed. A completion journal recovers a
verified ROM renamed just before a manifest write was interrupted. Concurrent
transfers reserve their full size, including during resume. Cancellation closes
only that transfer's HTTP client.

The software libretro host handles video, audio, keyboard, up to four gamepads,
touch controls, pause, SRAM, cartridge RTC memory and states. Core calls and
serialization run on one worker isolate. It stays paused until restoration
completes and clears buffered audio on pause. SRAM, state and exported RTC memory
are captured together and atomically committed as one local snapshot. Native
states include the indexed ROM identity, the
downloaded file fingerprint and exact core/version identity;
incompatible states cannot be restored as browser/stream states. Local progress
resumes offline; a new device can fetch a compatible native state from RomM.

Local `PLZYPRG2` snapshots and cloud state-v3 envelopes retain all three memory
components. RTC-bearing cloud saves use a versioned memory envelope. Readers
also accept earlier local snapshots, state-v2 envelopes and plain SRAM saves.
Native save-and-exit waits for durable local progress while upload continues in
the background; cores without serialization can fall back to battery/RTC saves.
Start-from-beginning is an explicit alternative. Archives, disc sets, firmware-
dependent systems and GPU-rendered cores use server/browser routes in this
initial native adapter; they are not mislabeled as supported native cartridges.

Core-provided display aspect ratios are preserved, stereo overflow drops whole
frames, and legacy core options receive their declared defaults. Focus loss
pauses playback and releases held input. Native play history excludes pauses
and dialogs; browser play history stays with RomM's own session lifecycle.

Disconnect refuses while a source has an open player, pending save uploads or active downloads,
so unsynced progress remains reachable. Pending versions can be exported or
explicitly deleted from the Saves screen. Successful refreshes retry the outbox;
uploads for the same slot are serialized and unknown hashes are treated as
conflicts. Imported states retain their declared core as a RomM asset label.

The browser-origin registry retains every port assigned to a profile/source,
including ports replaced after a collision. Registry replacement is atomic,
with a separate cross-process lock. Linux browser operations carry a surface
owner ID, preventing a retired page from closing or changing a newer player.
Main-page load failures, HTTP errors and WebKit process termination report back
to the player UI through owner-scoped callbacks. Retirement disconnects the old
surface's WebKit failure signals before destroying it.
Retries recreate plugin WebViews with the new bootstrap URL. Keyboard, touch,
D-pad and stick controls retain separate held-input state, so releasing one
input source does not release a button still held by another.

## Platform packaging

| Platform | Embedded web player | Native host |
| --- | --- | --- |
| Android / Android TV | Existing in-app WebView plugin | App CMake target and ABI-specific staged cores |
| iOS / macOS | Existing in-app WebView plugin | `PlezyRetro.xcframework` from the local pod build hook |
| Windows | Existing WebView2 plugin; runtime must be present | Runner copies `plezy_retro.dll`; stage matching core DLLs alongside it |
| Linux | WebKitGTK 4.1 ≥ 2.40, discovered by CMake | Runtime/core shared libraries under the bundle's `lib/` |
| tvOS | No browser route | Apple native host; signed core XCFrameworks required |
| Tizen | No browser route | Private toolchain recipe builds/copies the native host; stage matching cores in `lib/` |
| webOS | No browser route | CMake installs the native host; stage matching cores in `lib/` |

`native/games/romm/CMakeLists.txt` pins libretro-common and miniaudio. Apple pod
installation invokes `scripts/games/build_romm_apple.py`; no build was executed
while authoring this change. These hooks build the **host**, not arbitrary cores.

Use `scripts/games/build_romm_cores.py` on the authorized platform build machine
to produce the core staging directory and its hash/license manifest. Its default
set is Gambatte, mGBA and FCEUmm. Snes9x and Genesis Plus GX are optional inputs
with separate distribution-license restrictions, excluded from the default.
Core revisions are immutable; runtime downloads of emulator executables are
prohibited. Pass each upstream makefile's target platform and cross-compiler
variables explicitly. The pinned mGBA revision uses CMake's `mgba_libretro`
target; pass its target/toolchain definitions with repeated
`--cmake-arg=-DKEY=value` arguments. Cross builds require an explicit CMake
toolchain, system name or Apple target SDK. Per-target build directories prevent
mixing CMake artifacts, and make-based cores clean old objects before each build.
The stage includes tracked license files from nested dependencies and records
the selected target and toolchain arguments. Android libraries must have the
`lib` prefix and be copied to the correct `android/app/src/main/jniLibs/<abi>/`
directory before packaging.

Apple core slices must be packaged as signed-capable XCFrameworks named
`<core>_libretro.xcframework` containing `<core>_libretro.framework`, under
`native/games/romm/apple/Frameworks/<ios|macos|tvos>/`. The pod includes these
alongside the host. Release signing must cover every embedded binary. Missing
core artifacts simply remove that native route. Firmware and games are never
part of the package.

Apple host builds isolate dependency output per SDK and prepare a complete
replacement XCFramework before swapping the package artifact and stamp.

## Ecosystem handoff

Canonical format:

```text
plezy://game?source=romm&server=https%3A%2F%2Fromm.example%2F&rom=42&copy=sha1%3A<40-hex>&platform=snes
```

The `server` must match an already connected source. `rom` identifies an indexed
copy; `copy` optionally strengthens it with SHA-1/MD5. An acquisition handoff may
supply `igdb` and `platform` before it has an indexed ROM ID. PlezyNG resolves the
metadata provider endpoint, checks sibling copies and asks the viewer to choose
when more than one matches. It never fuzzy-matches a title, fetches a link's
arbitrary content URL, silently switches accounts or auto-starts a game.
Unknown fields, duplicate query keys, credentials and malformed hashes are
rejected. A missing item remains an indexing state; SeerrNG and ROMarrNG retain
request/acquisition ownership.

## Validation and remaining release gates

Source implementation and packaging recipes are provided. **No builds, tests,
analyzers, CI or device playback were run**, as requested. Runtime compatibility,
performance, Apple signing, WebView2 availability, TV SDK/core combinations and
packaged third-party licenses still require validation on private build agents.
The PR remains a draft until those checks are authorized and completed.

All 168 new messages have stable catalog keys and explicit English-fallback
provenance in other locales. They are not claimed as reviewed translations.
