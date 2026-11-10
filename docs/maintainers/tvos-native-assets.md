# tvOS native assets

The custom tvOS engine uses Flutter's iOS backend to generate Dart assets, then
replaces its engine, snapshots and native binaries with tvOS builds. iOS hook
libraries are not tvOS libraries, even when their CPU architecture matches.

`tvos/scripts/stage_native_assets.py` builds SQLite from the official amalgamation
pinned in `tvos/sqlite-source.lock.json`. Its SQLite version matches the source
used by the locked `sqlite3` Dart package. The compiler options and required FFI
exports come from that same resolved package, including FTS5, RTREE, math and
session/preupdate support. A package upgrade requires reviewing the source pin.
The optional column-metadata export is required only when that compile option is
enabled, matching the Dart binding's own capability check.

The same staging builds the `objective_c` bridge and `pdfrx_pdfium_gate` from the
locked package sources. `tvos/native-asset-packages.lock.json` binds package
versions, archive hashes and reviewed hook recipes. The Objective-C build retains
ARC, C API-DL sources and generated protocol trampolines; the PDF gate retains its
process-wide pthread synchronization. Every framework receives the actual tvOS
target, CPU/export checks, source receipt and normal embedding/signing.
Objective-C export checks distinguish bridge-owned classes from Foundation
classes provided by the OS runtime; generated fallback bindings do not make
system classes exports of the bridge.

Both Debug and Release run staging after the Flutter asset build. Staging checks
the CPU slices, genuine tvOS device/simulator load commands and required symbols.
The existing framework embed phase copies native assets, normalizes deployment
metadata and signs device frameworks. New unported native-asset frameworks fail
the build instead of silently disappearing or shipping an iOS binary. Each SQLite
framework includes `pleazyng-source.json`; its binary hash describes the unsigned
compilation, before the framework receives its distribution signature.

Native CI requires the real Dart app to finish its ordinary database open and
report `sqlite_version()` matching the pin. This supplements native tests and
binary inspection; it does not claim physical Apple TV qualification. The
recovery-required startup path remains available without opening the database.

Source references: [SQLite amalgamation](https://sqlite.org/2026/sqlite-amalgamation-3530300.zip),
[the locked package's source selection](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.5.0/tool/download_sqlite.dart),
and [SQLite compile defaults](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.5.0/sqlite3/lib/src/hook/compile/description.dart).
