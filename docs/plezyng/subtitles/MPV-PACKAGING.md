# Ordered PCM package promotion

The additive `mpv_plezy_audio_tap_read_next` ABI is supplied by
[snapetech-org/mpv-build PR 1](https://github.com/snapetech-org/mpv-build/pull/1).
The app probes the loaded library and keeps capture unavailable if it is absent.
Source support does not change the capability of already locked binaries.

The build repository now inspects the **final archive**, including every native
library in the Android AAR and every Apple framework slice, before recording an
ordered-PCM capability. Linux, Windows and Android local package entry points
perform the same inspection. The receipt binds the archive SHA-256, binary
members and required symbol. Windows inspects the PE export directory; Apple
checks every universal architecture. This is ABI presence, not execution or
hardware qualification. Existing checksummed artifacts remain unchanged.

After the authorized private-JIT build/publication has produced all platforms,
use the publication commit (the commit containing the new artifacts manifest):

```sh
scripts/set_native_revision.sh FULL_40_CHARACTER_PUBLICATION_COMMIT \
  --repo https://github.com/snapetech-org/mpv-build --require-subtitle-pcm
```

Promotion refuses absent/hash-mismatched receipts, missing Android ABIs, missing
Linux/Windows architectures or absent Apple frameworks before writing any pin.
It moves the Android verification hash, Linux/Windows lock, all Apple project
requirements and SwiftPM locks together. The new lock remembers the requirement,
so subsequent ordinary promotions cannot regress to a runtime without this ABI.
The existing Apple mirror-refresh procedure still applies after promotion.

No build, packaging execution, publication, dependency promotion, test or CI run
was performed for this source change. New release binary checksums cannot be
filled in until those actual artifacts exist. No hosted runner fallback exists.
