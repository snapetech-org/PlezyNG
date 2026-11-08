# 3.0.5 platform audit

The C6 fixes include shared application corrections and LG-specific native
repairs. Ship the shared changes in every platform build; do not copy LG's
NDL lifecycle or slot allocation into other player engines.

| Platform | Playback implementation | Applicable corrections |
| --- | --- | --- |
| Android / FireTV | mpv, or opt-in ExoPlayer | Shared artwork, track metadata, codec labels and controls. Existing native statistics remain authoritative. |
| Windows x64 / ARM64 | mpv | Shared artwork, track metadata, codec labels and controls. No LG slot changes apply. |
| Linux x64 / ARM64 | mpv | Shared artwork, track metadata, codec labels and controls. No LG slot changes apply. |
| macOS / iOS / tvOS | mpv | Shared artwork, track metadata, codec labels and controls. No LG slot changes apply. |
| LG webOS | LG NDL video; app audio backend where applicable | Shared changes plus LG native lifecycle, codec/video callbacks, audio rejection handling and standalone PGS rendering. |
| Samsung Tizen | Samsung native media player | Shared changes, native audio channels/sample rate/bitrate, bounded original-source format fallback, native-TV diagnostic logging and proxy redirect cancellation. |

## Audit findings

- Cards, wide previews, hub heroes, Discover heroes, TV spotlights, chapter
  thumbnails and queue pictures use reactive, owner-aware artwork clients.
  A known item owner cannot fall through to an unrelated server or a hidden
  profile. Temporary image failures expire and are keyed by the resolved
  source URL. A missing picture does not cause a URL-resolution request.
- Live-program and audio-format subscriptions have distinct widget keys;
  source/player replacement keeps their state independent on every layout.
- Plex and Jellyfin audio models preserve source codec profiles, sample rate
  and bitrate. DTS-HD MA/HRA formatting is shared across platforms.
- LG and Samsung share the bounded original-file audio descriptor logic.
  Hints are consumed by one open, require a complete matching native catalog,
  never describe a converted rendition, and cannot replace a known native
  codec or contradict reported native channel counts/sample rates.
- Samsung's native API already supplied audio channels, sample rate and
  bitrate. Forward them through its plugin and performance properties;
  unsupported receiver/output properties remain unreported.
- The loopback TV proxy is shared by LG and Samsung. Cancel redirect bodies
  instead of draining them: a server may never finish an irrelevant body.
  Preserve the same-origin credential boundary and redirect limit.
- Unsupported desktop media-control calls are disabled on both native TV
  backends. Both retain bounded, redacted app-private diagnostic logs.

## Validation and qualification

Run the full application suite and native TV acceptance commands from
`.github/workflows/ci.yml`, including both `PLEZY_TIZEN` and `PLEZY_WEBOS`
identities. The focused regression tests cover native TV metadata, source
replacement, contradictory catalogs, unfinished redirect bodies and stable
spotlight artwork after client arrival/profile changes.

The owner confirmed artwork and audible playback on the C6 and later confirmed
the source codec/channel overlay. Six source channels are not proof of six
receiver input channels. Physical receiver format, other LG firmware variants,
and Samsung hardware qualification remain distinct from build/test success;
see [receiver diagnostics](webos-lossless-audio-and-pgs.md).

The complete release includes Android, FireTV, Linux and Windows architectures,
universal macOS, iOS, tvOS, Tizen and webOS. Use the existing all-platform
controller, validate its complete artifact set and checksums, then publish.
