# webOS native API preflight

Every webOS build checks all audio/visualization plugin C++ translation units
against the pinned LG ARM NDK and checksum-verified common-runtime headers before
fetching and building the Flutter engine. This catches missing namespace imports
and unsupported SDK API overloads without waiting for the engine build.

Reuse the retained NDK and matching common archive for a local check:

```sh
WEBOS_NDK_ROOT=/absolute/path/to/webos-ndk \
WEBOS_ENGINE_COMMON_ARCHIVE=/absolute/path/to/webos-common.zip \
taskset -c 0,1 bash tools/webos/check_audio_plugin_syntax.sh
```

The command reads the caches and removes only its temporary header/environment
directory. CI retains its output in `logs/native-syntax.log` on failure. Passing
this check proves native source/API compatibility; the full IPK build and physical
TV validation remain separate checks.

The pinned webOS texture registrar has synchronous removal without a completion
callback. The visualizer keeps one texture registration per plugin/view lifetime,
reuses it across session leases, stops its worker and clears its current frame on
dispose, and unregisters during host teardown. Outstanding pixel leases keep their
own frame references alive.
