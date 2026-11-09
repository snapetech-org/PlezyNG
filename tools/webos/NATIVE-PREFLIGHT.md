# webOS native API and link preflight

Every webOS build checks all audio, visualization and video plugin C++ translation units
against the pinned LG ARM NDK and checksum-verified common-runtime headers before
fetching and building the Flutter engine. This catches missing namespace imports
and unsupported SDK API overloads without waiting for the engine build. It also
links the navigation codec against the pinned ARM Flutter common runtime and
requires the runner's direct SDK interface link.

Reuse the retained NDK and matching common archive for a local check:

```sh
WEBOS_NDK_ROOT=/absolute/path/to/webos-ndk \
WEBOS_ENGINE_COMMON_ARCHIVE=/absolute/path/to/webos-common.zip \
WEBOS_ENGINE_ARM_ARCHIVE=/absolute/path/to/webos-arm-release.zip \
taskset -c 0,1 bash tools/webos/check_audio_plugin_syntax.sh
```

The command reads the caches and removes only its temporary header/environment
directory. CI retains its output in `logs/native-syntax.log` on failure. Passing
this check proves native source/API compatibility and the codec's ARM link; the full IPK build and physical
TV validation remain separate checks.

After packaging, validation mode also runs the release integrity check against
the actual project version, source SHA and package hash. Provenance takes the
version from `pubspec.yaml` and checks the complete package filename, so an app
ID rename cannot silently corrupt the version field.

The pinned webOS texture registrar has synchronous removal without a completion
callback. The visualizer keeps one texture registration per plugin/view lifetime,
reuses it across session leases, stops its worker and clears its current frame on
dispose, and unregisters during host teardown. Outstanding pixel leases keep their
own frame references alive.

The audio plugin owns NDL slot 0 for its process lifetime. Video uses slots
1–4 through `shared/webos/ndl_media_slots.h`; its host allocation regression
runs in Linux native CI. `test/mpv/player_webos_test.dart` covers failed creation,
initialization ordering, native errors, retry cleanup and opaque HLS URLs. Errors
must reach the Dart event sink before controller disposal; disposing the native
player first clears the sink and strands initialization.
