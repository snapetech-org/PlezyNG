# TV audio analysis helper

This target builds `plezy-subtitle-ffmpeg` for independent VOD caption windows.
It does not modify the audible player, request audio focus, or expose a live NDL
tap. Android/Apple use their native readers; Linux/Windows can use installed
FFmpeg. The shared Dart decoder keeps cancellation/source ownership and bounds
all windows to 64 seconds, 16 kHz mono PCM16, and a 90-second decode deadline.

`ffmpeg.lock.json` reuses mpv-build's reviewed source commit. Prepare an immutable
checkout with `python3 build.py source --destination /new/ffmpeg`; alternatively
provide a local pristine checkout at that commit. The Tizen native builder uses
`--source-root/ffmpeg` when `--source-root` is supplied. Configure this CMake
target with an explicit cross toolchain and
`-DPLEZY_SUBTITLE_FFMPEG_SOURCE_DIR=/path/to/ffmpeg`, then build the
`plezy_subtitle_ffmpeg` target. A target sysroot, compiler and arch are mandatory;
there is no desktop compiler fallback. Tizen/webOS packaging invokes these steps.

The build produces the executable, actual binary hash, source/configuration
receipt, and copies of the source license notices. Target execution is not part
of the builder. App packages retain the notices, source pin and recipes beside
the receipt. Package inspection checks architecture, permissions, hash and
license binding. The app verifies the receipt before launching the helper.
A changed SDK/configuration requires a clean helper build directory. All future
CI build/package work remains subject to the repository's private ephemeral JIT
runner policy. No build or runtime qualification was run while adding this code.
