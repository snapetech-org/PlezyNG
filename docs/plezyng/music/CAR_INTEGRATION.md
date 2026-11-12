# Music car integration

Music is an ordinary Pleazyng feature on every supported platform. Native car
adapters provide another catalog/control surface over the same profile-owned
`MusicPlaybackService`; the phone driving route is a simplified presentation.
No adapter owns a second playback queue or starts audio merely on connection.

## Shared command boundary

`MusicCarHost` binds the `com.pleazyng/music_car` channel only while an unlocked
profile session is mounted. It exposes queue, downloaded music, authorized
libraries, server audio playlists, saved recipes/stations, recent listening, search
and transport. Media IDs are opaque session-scoped references, never media URLs,
tokens or local file paths. The in-memory lookup
registry is bounded to 2,000 items and may require refreshing an old browser page.
Browser pages contain at most 99 content entries plus a continuation folder.

Queue rows carry a queue-shape revision; commands for old indices fail, while
play/pause notifications do not invalidate unchanged rows. Profile
replacement rejects in-flight results and clears the native catalog. Search is
bounded to 200 query characters and 100 results. Exact-title voice resolution
rejects ambiguity instead of playing an arbitrary match. Recipes are resolved
through the current profile's authorized clients at use time. Cached station
snapshots intersect the current profile's completed downloads for offline play.
Native playlist selection resolves ordered pages before replacing the queue,
preserving duplicates and rejecting a changed account or excessive response.
CarPlay continuation folders update the current template instead of increasing
the navigation stack depth.

Library visibility, account sessions and completed-download membership changes
refresh native catalogs. Progress-only download notifications do not repeatedly
reload a car browser. Playback rechecks hidden-library access at selection time.

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
without opening an Activity. The new `MusicBackgroundPlatformPlugin` supplies
engine-only device identity and vehicle-restriction channels; an AAOS engine
cannot accidentally identify itself as an ordinary phone. Unknown vehicle
restrictions retain the existing fail-closed policy. The Activity suspends that
monitor while installing its complete handlers, then restores the background
handlers when a car session retains the engine.

`MusicBackgroundFrames` requests a coalesced warm-up frame only for dirty builds
when a car engine has no resumed phone surface. It keeps ordinary profile/PIN
bootstrap and lifecycle state; it does not invent a resumed Activity or autoplay.
A phone-created Android engine also enables this scheduling while connected to a
car, so profile/connection changes can settle after the phone is backgrounded.
Connection also wakes an already-dirty build that was scheduled before attachment.
These are source implementations with Dart scheduling tests. Android Auto host
recognition, activity plugins and callback/process-recreation ordering still
require a new native build and actual-host qualification.

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

`AppDelegate.ensureMusicEngine` now runs one explicit headless-capable Flutter
engine and registers the application's normal plugins. `MusicPhoneSceneDelegate`
attaches the phone controller to that same engine and forwards scene callbacks
through Flutter's scene lifecycle adapter. CarPlay can request the engine before
any phone window exists. A second phone scene cannot detach the existing phone
controller. Launch storyboard and independent external-video scenes are retained.

Siri `INPlayMediaIntent` handling resolves names through the active profile's
catalog, returns ambiguous choices for disambiguation, and sends shuffle/repeat
and next/later commands to the shared player. An unavailable/locked profile
requires app launch; it never falls through to an old account. Native fallback
messages still need localized resources. Native keyboard search is not emulated
using navigation-only CarPlay templates: supported audio voice entry uses Siri.
See Apple's [CarPlay guide](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf)
and [music integration documentation](https://developer.apple.com/documentation/carplay/integrating-carplay-with-your-music-app).

The additional scene/intent sources have not been compiled with Xcode in this
workspace. Artwork integration, signed entitlement verification, plugin lifecycle
checks and simulator/hardware qualification remain. Neither source registration
nor a simulator session would establish final App Store/device approval.

## Phone driving presentation

The view is available manually from Now Playing. Its persisted automatic-entry
setting opens it only while the app is foregrounded and a native car projection
connection is reported. It is enabled for new settings; an existing explicit
opt-out remains respected. A view opened automatically is removed on disconnect;
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

## Independent Android Automotive media build

Run `scripts/build_automotive_music.sh --release` to build the shared application
as an AAOS audio-category target. The script sets only this invocation's Gradle
property; the normal phone/TV/video manifest remains the default. The media
manifest requires Automotive hardware, exposes the existing MusicBrowserService,
and has no launcher/video deep-link entry. The host renders browse and playback.
An APPLICATION_PREFERENCES activity offers parked setup with the existing account
bootstrap and music home. OAuth callbacks are retained. Do not label setup as
distraction optimized. The native build identity is delivered through both
foreground and headless device channels. Only this target permits music while
restrictions are active; all video playback and normal app distributions keep
the parked-only gate. AAOS browser unbinding is not physical audio-output loss.

The source follows Android's [media manifest](https://developer.android.com/training/cars/media/configure-manifest)
and [Automotive media](https://developer.android.com/training/cars/media/automotive-os)
contracts. Store approval, OEM behavior and native/device qualification are
separate from this source implementation.

## Selected Bluetooth driving outputs

The music discovery settings offer a profile-owned list of explicitly selected
Bluetooth media outputs. Only the current OS media route can be added; merely
available devices cannot arm automatic entry. Saved disconnected outputs remain
removable. The list is bounded to 32 platform-qualified identities and can be
reset explicitly if saved data is unreadable.

Foreground entry requires the automatic-driving preference and a successful,
current profile binding. A late route inspection or event cannot open a retired
profile. Disconnect and profile retirement remove only the automatic view.
Bluetooth UI changes do not start or pause the shared player and do not count
as a projection connection. Native audio-session focus and interruption policy
continue to own playback loss handling.

Apple reads the selected audio-session ports. Android 13 and later query the
public media-attribute route; this is anticipated routing for a music AudioTrack,
not an acoustic measurement. Earlier Android versions, unknown selections and
masked addresses remain unavailable. Sample-rate and channel capabilities are
not reported as measured current output. Native/device route and vehicle
qualification remain separate from the automated tests.
