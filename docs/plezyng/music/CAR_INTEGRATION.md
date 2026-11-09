# Music car integration

Music is an ordinary Pleazyng feature on every supported platform. Native car
adapters provide another catalog/control surface over the same profile-owned
`MusicPlaybackService`; the phone driving route is a simplified presentation.
No adapter owns a second playback queue or starts audio merely on connection.

## Shared command boundary

`MusicCarHost` binds the `com.pleazyng/music_car` channel only while an unlocked
profile session is mounted. It exposes queue, downloaded music, authorized
libraries, saved recipes, search and transport. Media IDs contain stable item
identities, not media URLs, tokens or local file paths. The in-memory lookup
registry is bounded to 2,000 items and may require refreshing an old browser page.
Browser pages contain at most 99 content entries plus a continuation folder.

Queue rows carry a catalog revision; commands for old indices fail. Profile
replacement rejects in-flight results and clears the native catalog. Search is
bounded to 200 query characters and 100 results. Exact-title voice resolution
rejects ambiguity instead of playing an arbitrary match. Recipes are resolved
through the current profile's authorized clients at use time.

The existing playback coordinator still arbitrates music, video and other audio.
Existing OS playback controls and the music engine remain authoritative.

## Android

`MusicBrowserService` is registered as a media browser, with an automotive media
app descriptor. It shares the vendored `os_media_controls` MediaSessionCompat
token. MediaBrowserServiceCompat is used to preserve that existing session rather
than introduce a second Media3 player/session. A later Media3 migration must
preserve the same ownership contract and all existing platform behavior.

Trusted callers are checked through AndroidX MediaSessionManager. The service
reuses a cached Flutter engine or starts the ordinary application entry point
without opening an Activity. This boot path is source implementation only:
initialization that waits for a visible first frame, plugin activity attachment,
profile unlocking and process recreation must be completed/qualified before
claiming reliable native cold launch. Android Auto host recognition and callback
ordering must be tested on the actual host.

A disconnected browser clears its connection state and pauses through the shared
Dart session. Existing audio-focus/noisy-route logic remains in the playback
backend. Browse/service lifetime alone does not prove all Bluetooth, wired and
wireless route transitions; selected Bluetooth car identification is not added.

The existing AAOS parked-video/game restrictions remain. This branch does not
change those restrictions into a certified moving-vehicle media target. A media
store/distribution target and independently qualified audio policy are still
required.

## iOS

`MusicCarSceneDelegate` supplies list and Now Playing templates, using the same
channel and existing MPNowPlaying/remote-command implementation. Info.plist
registers the CarPlay scene. A locked/uninitialized profile exposes an unlock
message, not a previous profile's catalog.

Actual signed CarPlay availability requires Apple's approved audio entitlement
and a provisioning profile containing it. [CarPlay.entitlements](CarPlay.entitlements)
is the entitlement input, not an activated project signing configuration. Once
approval is present, merge it with the target's existing entitlements and set the
appropriate `CODE_SIGN_ENTITLEMENTS` in the signed build configuration; preserve
all other entitlements. Do not replace production signing with an unapproved
profile. Verify the resulting signed app's entitlements and run the CarPlay
simulator/device tests before distribution.

CarPlay-only cold launch still needs an independently initialized Flutter engine;
currently the bridge becomes ready with the normal application engine. Native
fallback messages need localized resources, and Siri media intents are not
implemented in this change. Neither source registration nor a simulator session
would establish final App Store/device approval.

## Phone driving presentation

The view is available manually from Now Playing. Its persisted automatic-entry
setting opens it only while the app is foregrounded and a native car projection
connection is reported. A view opened automatically is removed on disconnect;
manual navigation remains user-controlled. Opening either native or phone car
presentation does not autoplay. The operating system/head unit controls native
app selection and background-launch policy.

## Required qualification

Exercise existing queue playback and parked restore; locked/unlocked profile;
server startup and downloaded-only startup; queue replacement during browse and
voice; repeated attach/detach; calls/navigation ducking; screen lock; process
recreation; foreground notification permission; video taking audio ownership;
multiple native browser clients; and connection loss while a refill is pending.
Use Android Auto/AAOS hardware and iOS/CarPlay simulator plus hardware, preserving
per-platform logs and observed outcomes. Keep the open items in
[STATUS.md](STATUS.md) visible until each has implementation and evidence.

## Upstream sources

The existing [media-controls dependency](https://github.com/edde746/media_controls/tree/a27208e641790029ac54d825b97508575caee1a7), maintained by [@edde746](https://github.com/edde746),
is vendored at its former dependency pin with its license. Pleazyng independently
adds the browse bridge; the upstream maintainer did not contribute to or endorse
this fork. See [UPSTREAM_ATTRIBUTION.md](../../../UPSTREAM_ATTRIBUTION.md#music-media-session-integration).
