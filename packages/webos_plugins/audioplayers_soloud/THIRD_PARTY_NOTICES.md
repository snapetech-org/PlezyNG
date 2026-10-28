# webOS SoLoud plugin notices

PlezyNG vendors `audioplayers_soloud` from the LG Flutter webOS plugin
repository at `3a742bb86b04e261044f0864f9b1f71acf0bbad3` and modifies its SoLoud
mixer callback, source-size admission and MilkRust texture/audio host. The LG
plugin's BSD-3-Clause SPDX headers and source notices are retained in the
vendored files.

The plugin's own `LICENSE` contains the `flutter_soloud` MIT license. The
vendored SoLoud source includes `src/soloud/LICENSE` (zlib/libpng). The webOS
app registers those licenses and the LG BSD-3-Clause license in Flutter's
acknowledgements. `assets/licenses/LGFlutterWebOSRuntimeNotice.txt` also
retains the full dependency inventory shipped for the pinned webOS Flutter
runtime, including Xiph Ogg/Opus and the plugin's other third-party
dependencies.

The native plugin is source-only in this change. A binary must not be
redistributed until its complete dependency inventory, linked-library notices,
and the current LG runtime notice have been reviewed against the exact build.
This notice documents provenance and obligations; it does not add any license
to preset packs or other third-party content.
