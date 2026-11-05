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

Normal app builds compile the pinned Gambatte, mGBA and FCEUmm software cores
alongside the native host. `native/games/romm/core-sources.json` is the canonical
source pin set. No emulator executable is downloaded at runtime.

| Platform | Native delivery |
| --- | --- |
| Android / Android TV | Host and three core libraries built for each APK/AAB ABI; matching source/notices packaged as variant-specific assets |
| iOS / macOS / tvOS | Four XCFrameworks built per platform SDK by the local pod hook, embedded and signed with the app; source/notices in the pod resource bundle |
| Windows | Host and three matching core DLLs beside the executable; source/notices under `data/romm-notices` |
| Linux | Host and three matching core shared libraries under `lib/`; source/notices under `data/romm-notices` |
| Tizen / webOS | Cross-built host and three core libraries under `lib/`, with matching source/notices |

Apple builds stage the entire host/core/source set before replacing the previous
set, and verify the cache's file contents, permissions and framework symlinks.
Android release inspection checks all four libraries per ABI, their exported
interfaces, alignment and dependencies, and the matching source receipts.
The desktop install steps run after Flutter's bundle cleanup so the cleanup
cannot delete the just-installed host.

Each package retains the exact default-core source archives, tracked license
files, host implementation/header notices and the application build recipe.
Receipts identify the source pins and pre-packaging library hashes; Gradle
stripping and Apple signing may change the shipped binary hashes. Final Android
package inspection separately records the packaged library hashes. None of
these receipts claims device qualification.

Snes9x and Genesis Plus GX remain optional inputs with separate distribution
restrictions. The standalone `scripts/games/build_romm_cores.py` recipe remains
available for explicitly staged additional cores and cross-toolchain work.
Firmware and game content are never part of the application package.

Linux host and all three default cores compile, link and pass actual dynamic
loading checks on the current host. Android, Apple, Windows and TV package/device
execution remains pending; the source recipes alone do not certify those builds.

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

Source implementation and packaging recipes are integrated into main. The
2026-11-05 reconciliation passes the SDK helper tests and adds copy/URL/capability
regressions, which have not run without Flutter. Historical authoring notes
describe their original source-only checkpoints. Runtime compatibility,
performance, Apple signing, WebView2 availability, TV SDK/core combinations and
packaged third-party licenses still require validation on private build agents.
These checks remain release qualification work; no device result is implied.

All 168 new messages have stable catalog keys and explicit English-fallback
provenance in other locales. They are not claimed as reviewed translations.
