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

The manifest freshness check now rejects MPV entries without an exact packaged
receipt, including all four Android ABI paths. The package hash and every
inspected native member hash are retained. Changes to the inspector move MPV
content keys, so an archive accepted by an older inspection contract cannot
reuse an immutable artifact name. This does not constitute runtime qualification.

Inspection schema 2 requires all four public tap exports (`version`, `enable`,
`read` and `read_next`) in every binary and Apple architecture. Windows PE
inspection accepts export-table entries, not matching import-table names; ELF
default symbol versions are accepted. Promotion and immutable-reuse checks reject
older one-symbol receipts. Inspector changes produce new content keys, so old
archives cannot be silently relabelled. These are static package requirements;
the ABI function has not been called and no artifact has been built here.

Inspection schema 3 additionally reads ELF/PE machine headers and Apple's lipo
architecture inventory. Android ABI directories and desktop variant names must
match those machines. Apple XCFramework `AvailableLibraries` declarations must
match every inspected binary and include iOS device/simulator, tvOS
device/simulator, macOS and Mac Catalyst architectures (including the build's
tvOS arm64e slice). Missing simulator/device slices cannot pass merely because
the remaining slices export the ABI. Consumer promotion requires schema 3;
older receipt-bearing artifacts are not silently promoted.

Publication availability was checked read-only on October 29, 2026. The main
manifest at `bb618dfd5b6bb1a06088d411eb283137cda05f73` still has no ordered-PCM
receipts on its MPV assets. The ordered-PCM PR branch reports no workflow runs;
the visible Apple rolling assets predate this patch, and the Linux rolling
release has no assets. There is no compatible published manifest to promote
under the code-only constraint. Consumer pins therefore remain unchanged.
Confidence is high in that metadata finding; no archive inspection, build or
publication was executed during this check.
