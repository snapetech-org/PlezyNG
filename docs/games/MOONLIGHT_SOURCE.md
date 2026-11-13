# Moonlight Android corresponding source

Android releases include a separate source archive for the embedded Moonlight
receiver and Pleazyng's Android adapter. The archive is generated from the
same application commit as the release and includes the prepared source after
the repository's pinned patches, the Moonlight common submodule, the lock and
preparation recipe, adapter sources, and license notices. A receipt records
the upstream revisions and a digest of the prepared source tree.

## Rebuild the bundled receiver

Use the Pleazyng source checkout at the `applicationCommit` recorded in
`SOURCE-RECEIPT.json`. Extract this archive and copy its `upstream` directory
to `.dart_tool/games/moonlight-android` in that checkout, preserving hidden
files such as `.plezy-recipe`. Then run the normal Android build from the
checkout:

```sh
flutter pub get --enforce-lockfile
cd android
./gradlew :moonlight:assembleRelease :app:assembleRelease
```

The matching repository source supplies the Flutter app, Android host project,
and release configuration. The prepared source marker is checked against the
repository's `games-native.lock.json` and `scripts/games/prepare_moonlight.py`;
the archive contains both so the generated engine can be audited and rebuilt
without fetching a replacement revision. Standard Android SDK, NDK, JDK,
Gradle, and Maven dependencies are required.

The archive is a corresponding-source handoff, not device or decoder
qualification. Its source revision and contents do not certify stream
latency, SurfaceView recovery, controller behavior, audio routing, HDR output,
or support on a particular Android device.

## Upstream sources

The receiver is based on [Moonlight Android commit
`b48494cb`](https://github.com/moonlight-stream/moonlight-android/commit/b48494cb96bff23d8886c4775cc4f39a1075495d),
authored upstream by [@cgutman](https://github.com/cgutman). The author
contributed the receiver implementation to Moonlight; Pleazyng independently
adapted the connection, decoder, audio-renderer and input lifecycle for its
retained Android workspace surface. See
[UPSTREAM_ATTRIBUTION.md](../../UPSTREAM_ATTRIBUTION.md#credited-moonlight-android-source).
