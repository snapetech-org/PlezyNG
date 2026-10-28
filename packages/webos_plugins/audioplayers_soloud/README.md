# audioplayers_soloud

The WebOS implementation of the [`audioplayers`](https://pub.dev/packages/audioplayers) plugin based on flutter_soloud.

## Supported platforms

This plugin is supported on webOS 26 media or above.

## Usage

PlezyNG uses this pinned webOS implementation directly through the upstream
`xyz.luan/audioplayers` method/event channel protocol. It does not add the
cross-platform `audioplayers` Dart package or its other platform backends to the
application dependency graph.

**PlezyNG pubspec.yaml:**

```yaml
dependencies:
  audioplayers_soloud:
    path: packages/webos_plugins/audioplayers_soloud
```

The app-owned adapter is `lib/mpv/player/platform/webos_soloud_player.dart`.

## Example

See the [example application](example/lib/main.dart) for a complete usage demonstration.

## API Reference

See the [API Reference](API_REFERENCE.md) for detailed documentation of all classes, methods, and parameters.

## Limitations

- `AudioPlayer.setSourceUrl` downloads the file into memory before handing it to the decoder. PlezyNG enforces known size and supported format metadata before selecting this backend, and the native downloader has a hard 10 MiB body limit. Live streams, HLS, unknown-size responses and unsupported formats stay on LG NDL.
- HLS (m3u8) manifests are not supported. The implementation has no manifest parser or segment downloader, so the manifest body is handed to the SoLoud decoder which cannot interpret it. HLS with a video track is additionally unsupported by `audioplayers_webos` (audio-only consumer cannot drive a video sink).

PlezyNG adds a final-mix PCM tap and MilkRust GLES texture host in source. The
tap observes the SoLoud plugin's master mix; multiple simultaneous voices are
not isolated. See [the third-party notice](THIRD_PARTY_NOTICES.md). This
integration has not been compiled or qualified on a webOS TV.
