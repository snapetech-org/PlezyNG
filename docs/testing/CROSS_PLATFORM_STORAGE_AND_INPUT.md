# Cross-platform storage and input follow-up

Implemented on 2026-11-05 (America/Regina), following the upstream parity
follow-up. These changes extend the fork's existing shared behavior.

## Download storage

Android's destination-descriptor guard now charges writes against at most
1 MiB of sampled headroom. A sample expires after one second; an explicit
flush also invalidates it. Buffered writes drain before another capacity
sample. Known-size admission, the configured reserve, unknown-capacity
failure, SAF descriptor validation, and immediate ENOSPC/EDQUOT handling
remain in force. Flush and close failures also remove incomplete output and
report storage exhaustion. This is a per-writer budget, not a reservation
against concurrent disk users; OS write failures remain authoritative.

The desktop guard already covers Windows, macOS and Linux. Queue suspension
and manual recovery are shared Dart behavior wherever downloads are supported;
tvOS downloads remain unavailable.

## Backup and restore

- Android excludes `app_flutter/downloads` and `app_flutter/artwork` from
  legacy backup, modern cloud backup and device-to-device transfer. These
  are root-domain paths because Flutter documents use `Context.getDir`.
  Credential exclusions remain intact.
- macOS excludes the `downloads` and `artwork` directories underneath the
  bundle's Application Support directory. The native method channel accepts
  only those exact directories, rejects symlink roots, updates existing roots
  at launch and handles directory recreation during a session. It is also
  registered in the preparation-worker launch path.
- iOS retains its existing native policy. Custom download locations, recordings,
  settings, bookmarks and database metadata are not newly excluded.
- Startup reconciles completed entries whose files are missing from the
  app-managed download root. It retains their metadata, clears stale part/task
  state, and marks them failed with the existing localized missing-file message
  for retry. Reconciliation does not enqueue downloads or remove remaining files.
  External, custom and SAF paths are outside its scope.

References: [Android Auto Backup](https://developer.android.com/identity/data/autobackup),
[Apple filesystem guidance](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).

## Deletion and remote controls

Jellyfin and Emby now repeat their live, bounded `CanDelete` query immediately
before issuing DELETE. A denied, unknown, disappeared or failed permission
query never issues DELETE. Server-side authorization remains authoritative.

Shared cards, chips and list rows consume repeated context-menu/gamepad-X
events without opening duplicate actions. SELECT holds retain physical-key
identity; another SELECT key's release cannot finish the hold. Short presses
also verify that their owner is still active. Wrapper disable/focus handoff
cancels pending activation.

The logical-input matrix exercises Enter, numpad Enter, Select, gamepad A,
context menu and gamepad X across Android, iOS, Linux, macOS and Windows
Flutter platform variants. tvOS, webOS and Tizen use the corresponding
Flutter platform contracts; their remote firmware is not simulated by this
matrix.

## HDR

HDR detection and control remain native to each platform. The Linux
`PLEAZYNG_HDR_OUTPUT` override remains Linux-only. Opening playback statistics
now writes a deduplicated `HDR configuration` log record on source, backend or
policy changes. All platforms use the same vocabulary for source transfer,
primaries, the user's HDR preference and video output. Linux also records the
validated override and tone-mapping preference. A source flag or preference
is never labeled as proof of active HDR display output.

## Verification

Host verification passed: 547 focused Flutter tests, 14 production Android
guard JVM scenarios, two XML backup-policy tests, and analysis of all changed
Dart libraries and tests. The Flutter run includes the HDR diagnostic log's
source-change/deduplication integration test, restore recovery and existing
Linux HDR refusal/startup coverage.

The repository-wide check passed code-generation freshness but remained red
on existing formatting, translation hygiene, hardcoded UI strings, workflow
guards, icon consistency, native formatting and analyzer findings outside this
batch. The documented `SKIP_HOOKS=1` escape was used for the commit after the
focused checks passed. Apple native compilation and physical-device checks
below remain unrun on this Linux host.

Run the focused Flutter suites for downloads, deletion permissions, focus,
player controls, performance statistics, display-mode handling and Linux HDR
startup. Standalone Android guard and backup-rule checks are:

```sh
bash scripts/test_android_storage_guard.sh
python3 scripts/checks/test_download_backup_rules.py
```

The JVM suite needs `kotlinc` and Java and exercises the production guard
without Android stubs. macOS XCTest coverage in `RunnerTests.swift` checks
bundle scoping, exclusion attributes, recreation and symlink rejection.

Device qualification is separate from host regression tests:

| Platform | Remaining physical/native qualification |
| --- | --- |
| Android / Android TV | Cloud/D2D restore, low-storage download to internal/SAF volumes, remote key mappings |
| macOS | Execute RunnerTests with Xcode; verify Time Machine excludes only managed roots |
| iOS / tvOS | Apple device backup behavior and Siri Remote select/menu sequence |
| Windows / Linux | USB/Bluetooth keyboard and controller; HDR/SDR monitor moves and native display diagnostics |
| webOS / Tizen | Installed-app remote mappings, including held-select, repeat, menu release and focus restoration |

No physical-device results or Apple native-build results are claimed by the
Linux host test run.
