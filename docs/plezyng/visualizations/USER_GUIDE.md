# Using the visualizer library

Open Now Playing, enable the visualizer, then choose the library button. The six original scenes remain available on their existing platforms. Native preset playback is currently unqualified; regular build recipes include MilkRust, while engine/audio availability still varies by platform. It needs the matching native dependencies described in `native/visualizer/README.md`. Existing shipped binaries have not been replaced by this PR.

Original scenes also remain available for local/source audio. They use Plex loudness when present, otherwise available live MPV audio statistics, otherwise ambient motion. The live statistics are compact measurements, not a full spectrum or waveform display. Native preset controls use the active dedicated audio player in either source path.

## Get presets

The library installs the small authored CC0 MilkRust sample pack from the app bundle when first opened; no download is needed. Removing it is remembered, and Restore included pack reinstalls it offline. The unmodified archive retains its source and notices, which also appear in app acknowledgements. It is a fixture pack whose rendering fidelity remains unqualified.

Installation verifies the pinned archive and its contents before making the directory active. Remote entries use the same verification path; Cancel stops installation even if transfer has finished and verification is still running. Interrupted downloads keep a bounded local record. Resume download reuses saved bytes only when the server confirms the same strong ETag and exact byte range; otherwise it restarts. Discard saved download removes those bytes. Opening the library never resumes network work automatically. When a future app catalog pins a newer version, Download update keeps previous complete versions available in Installed presets.

Use Import .milk or .milk2 for loose files, Import folder with textures and notices for a local collection, or Import .rmpack for a packaged collection with its integrity index, provenance and license notices. Folder import preserves relative paths and notices in a private, content-addressed copy. It rejects links and unsupported assets, bounds the collection to 2,500 entries/64 MB, and can be canceled. Hidden repository/OS files are omitted. The source folder is unchanged; this local copy makes no redistribution-rights claim. Files stay on the device and work offline. MilkRust implements all 30 saved `.milk2` pattern formulas and the documented saved sprite fields in its native/WebGL profile. Pixel parity remains unqualified, and unknown executable trailer extensions are blocked. Historical collections with unresolved redistribution status have source links rather than app-hosted downloads.

## Choose and organize

Choose Browse installed presets, search by title/author/pack/tag, and select a supported `.milk` or `.milk2` candidate. MilkRust implements the 30 documented saved blend formulas and all eleven saved sprite blend modes. The typed legacy HLSL profile has explicit limits; unsupported shaders, resources and trailer extensions produce diagnostics. If the native dependency or playback audio is unavailable, the browser shows the reason and still offers metadata and notices. The details button shows author, license and content notice. Visual fidelity has not yet been measured for these entries.

Favorites and display choices belong to the active profile. Filter a list, save it under a playlist name, and use its reorder menu to move entries up or down. Selecting a preset uses the visible playable list for previous/next and shuffle. Playlists can be imported/exported as bounded JSON containing library-relative references. They do not include preset artwork; missing references require separately installing or importing the corresponding pack.

## Playback controls

The options menu provides Original scenes, preset lock, shuffle, automatic-change interval, transition duration, lower resolution, reload, playback details and fullscreen. Lock prevents timed changes. In fullscreen, left/right changes the preset, Escape or Exit fullscreen closes the view, and music continues. Fullscreen reuses the same renderer.

Native rendering pauses with music, backgrounding, a hidden view, or reduced motion. Presets may contain rapid flashes or intense movement. When a preset fails or fresh audio is unavailable, the original scene appears with the status reason; Reload retries with a new worker after an engine failure.

On iOS and tvOS, an interrupted MilkRust session prevents that preset from loading automatically on restart or during timed changes. Choose Reload preset or select it in the library to retry explicitly. If the renderer remains busy, choose an original scene and wait for recovery or restart the app.

Remove a pack or loose import in the library manager. Removing a pinned pack removes its installed versions; playlist references can remain and are skipped when their files are missing. Downloading or importing files does not alter the six original scenes.

## Current limits

Imports reject executable asset types, shader includes, ambiguous portable paths, unsupported image layouts and missing declared dependencies. Preset files are capped at 2 MB. Texture headers are checked before activation: 4096 pixels per side, 8 megapixels per image and 32 megapixels per pack. Animated GIF, PNG (APNG), and WebP animations are charged by every decoded frame (up to 120 frames and 16 megapixels per animation). The installed library is capped at 512 MB; remove unused packs or older versions to make room. These checks do not establish native decoder/driver isolation.

The Linux integration uses native pixel-buffer readback at up to 1920×1080/60 FPS on desktop, or 1280×720/30 FPS on mobile and TV, with automatic resolution adjustment; performance and driver behavior have not been qualified. Native host source now exists for the other listed platforms, including Tizen and webOS, but is uncompiled and unqualified; existing release binaries have not gained those hosts. Unsupported HLSL/resource and preset-format cases, reference-pixel parity, production signed-catalog delivery, broader qualified community packs and physical-device validation remain open. The implementation status document records the complete remaining gates.

## Pack catalog updates

Use **Check for pack updates** in the library to fetch a signed catalog when the release has configured signing keys. Playback never initiates a catalog request. Downloads require an app pin or a current, verified catalog; failed verification leaves the previous catalog and all installed presets intact. Expired or withdrawn packs remain available offline after installation, but cannot be downloaded again until authorized. New catalog versions can offer **Download update** while retaining installed versions. Builds without a release trust root keep the included pack and local import available, with remote updates disabled.


### Choosing a native engine

The preset library offers projectM and experimental native MilkRust. The choice
is saved with the profile. Linux has source for both engines; Windows, macOS,
iOS/tvOS, Android/TV, Tizen and webOS have source for native MilkRust. A build without the
matching engine and same-player PCM extension reports the missing dependency.
This source increment does not add compiled engines to existing releases.

Native MilkRust currently accepts classic `.milk` candidates and implements the
documented saved `.milk2` pattern formulas and sprite fields in its native/WebGL
profile. Reference-pixel and device fidelity are unqualified. The typed legacy
HLSL profile has explicit unsupported resource and declaration forms; unknown
trailer extensions, unsupported shaders and missing images produce diagnostics.
The selected transition duration applies to both engines. MilkRust fades the last displayed frame into the next preset; projectM uses its native transition. Compatibility and performance remain unqualified across
devices.

Two new original CC0 study collections (24 presets) are committed in MilkRust.
They are not published app downloads yet: archive production, rights review and
per-target rendering qualification must precede signed-catalog promotion.

## Automatic rendering quality

Rendering adapts to the measured capture and presentation cost. It lowers the
resolution after sustained slow frames and restores it gradually after ten
seconds of headroom. Desktop starts with a 60 FPS budget and can reduce to 30;
mobile and TV retain a 30 FPS budget. Lower resolution also remains available
as a user preference. These ceilings are not performance guarantees.

## Copies, fragments and shared textures

Each preset's menu offers export with assets and notices. The ZIP is a local
folder copy with hash provenance; it does not grant redistribution rights or
become a signed catalog artifact. Import .rmpack or ZIP accepts these folder
exports with the same size, path and image limits as folder import.

For a classic preset, Add shape or wave to a new copy imports a .shape/.wave
fragment into unused object slots, preserving equations and source assets. The
installed preset remains unchanged. Shape and wave export carries the indexed
objects plus the original assets/notices. Saved double presets remain selectable
but must be split into a classic source before this object-editing action.

Texture-only packs are shared by exact version and integrity hash. Installation
may fetch an authorized required texture pack; local-only dependencies must be
imported first. Remove dependent preset packs before deleting their textures.
A changed dependency must use a new version while installed presets reference
the old bytes. Available manifest thumbnails appear beside preset titles.
