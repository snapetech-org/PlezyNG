# Native emulator containment

Desktop builds load a small `plezy_retro` proxy into the app. Bundled libretro
cores, including their library constructors, execute only in the packaged
`plezy_retro_worker`. The Dart host checks isolation ABI 1 before probing or
opening a desktop core. A missing worker, mismatched host or unavailable sandbox
fails closed; it never falls back to loading a core into the desktop app.

The parent owns audio output and the durable save workflow. The worker receives
only the selected game, firmware and core paths. Frames, PCM, SRAM, RTC and save
states cross a versioned, sequenced binary protocol over an inherited private
channel. Stdout is not the protocol, credentials are not passed in the child
environment, and unrelated handles/descriptors are not inherited.

## Platform policy

| Platform | Enforcement |
| --- | --- |
| Linux x64/arm64 | Landlock ABI 3 or later, enabled by the running kernel, is required. Only selected resources and system libraries are readable. No file writes are granted. A seccomp filter rejects networking, process inspection/signalling, new processes, executable replacement, mount operations and filesystem metadata mutations outside Landlock's coverage. Address space is limited to 768 MiB and core dumps are disabled. |
| Windows | An AppContainer with no network capabilities receives a private read-only stage containing the worker, selected core, ROM, firmware and any app-local CRT dependencies. A job allows one process, limits memory to 768 MiB and kills the worker when its owner closes. Native code verifies that its token is an AppContainer. A non-delete-sharing lease protects live stages; later starts remove abandoned, marked stages without following reparse points. |
| macOS | The separately signed helper enters a deny-by-default Seatbelt policy before loading a core. Only selected inputs and system libraries are readable; networking and file writes are not allowed. A parent-side resident-memory watchdog terminates workers exceeding 768 MiB. The worker receives no JIT or unsigned-executable-memory entitlement. |
| Android, iOS/tvOS and TV backends built without this desktop helper | The existing in-process backend remains explicit. It does **not** provide the desktop security boundary. Process/service conversion and physical-device qualification remain open; a Dart isolate is not an OS sandbox. |

Some Linux systems disable Landlock or ship an older ABI. On those systems native
desktop cores are unavailable; existing alternative game routes remain subject
to their own capability checks. This does not raise the OS requirement for the
rest of the app.

## Protocol and lifetime limits

- Frames are at most 2048 × 2048 RGBA pixels; audio is at most 32,768 interleaved
  16-bit samples per response. Shape and exact payload length are checked before
  a frame reaches Flutter or samples reach the audio device.
- Save-state payloads are limited to 128 MiB. Startup and state transfer receive
  a ten-second whole-request deadline; ordinary commands receive two seconds.
  A peer cannot extend a deadline by dripping bytes.
- Unexpected commands, sequence numbers, status values, dimensions or trailing
  bytes fail the session. The parent terminates the worker on transport failure.
- The UI can leave a failed session promptly. Its files and native lease remain
  owned until the OS process handle confirms termination, including after a
  forced stop. A new worker is not admitted while an earlier one is terminating.
- Native save files are not written by the worker. Existing SRAM/state/RTC
  serialization returns bytes to the app's established save workflow.

## Validation

`python3 scripts/games/test_romm_process.py` builds the real process transport
and worker dispatcher with a deliberately faulty core adapter. It exercises
normal frames and save round trips, credential/environment isolation, denied
file access, crashes, hangs, invalid dimensions, oversized states, stuck close
handlers, restart and reaping. A second peer injects oversized, truncated,
mis-sequenced, drip-fed and malformed protocol replies.

`--protocol-only` runs only the malicious-peer cases when the local container
cannot expose the platform sandbox. It is not sandbox qualification. The trusted
`Native emulator isolation` workflow requires the full tests and compilation of
the production host and worker on hosted Linux, Windows and macOS runners.
An additional CMake/CTest target loads a fixture shared library through the
production worker and libretro adapter; it verifies constructors, frame
conversion, private-file denial and save restore without using real game files.
Actual bundled-core, signed-package, audio-device and game compatibility checks
remain part of platform release qualification.

The OS contracts used here are documented in the
[Linux Landlock API](https://docs.kernel.org/userspace-api/landlock.html) and
[Windows AppContainer launch guidance](https://learn.microsoft.com/en-us/windows/win32/secauthz/implementing-an-appcontainer).
