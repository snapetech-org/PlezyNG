# Screenshot review and release handoff

[View all nine native captures](native-captures-contact-sheet.jpg).

| Layout | Committed screenshots | Provenance |
| --- | --- | --- |
| TV | [Four 1920×1080 captures](amazon/) | [TV receipt](amazon/tv-capture-provenance.json) |
| Phone | [Three 1080×1920 captures](google-play/) | [Phone receipt](google-play/capture-provenance.json) |
| Tablet | [Two 2560×1600 captures](google-play/) | [Tablet receipt](google-play/tablet-capture-provenance.json) |

These are genuine captures of the signed app running on Android TV, phone and
tablet emulators with public Jellyfin demo content. The store PNGs preserve the
original RGB pixels; only fully opaque alpha channels were removed. The contact
sheet contains review thumbnails. Emulator captures do not qualify physical
Fire OS hardware, playback or Amazon purchase/restore behavior.

## Capture build

The screenshots use version **3.0.0**, source
`28486bba2bb42d25bc17d127ca73c5ccc27ba1a3`, from the successful
[Android validation run](https://github.com/snapetech-org/PlezyNG/actions/runs/42142321277).
The APK SHA256 is
`cb02bfbce6fd5b940de104ddcee52c9f34a0e422555ec2f06c8bce336926622a`.
[Build, signature and attestation evidence](capture-build-evidence/) is committed
here. The APK is an Actions artifact, rather than a Git source file. It predates
the later review-access and native-runtime implementation work; it must not be
relabelled as a final 3.0.1 build.

## Next release

Follow the [Fire TV runbook](../fire-tv.md). The full release workflow builds a
fresh signed `pleazyng-amazon-firetv.apk` and matching provenance receipt from the
release source, attests both, and includes both in release assets and checksums.
The coverage gate requires both files. Validate that release build before store
handoff; do not substitute the older capture APK.

Amazon's first version is a Developer Console handoff. Leave
`AMAZON_APPSTORE_BOOTSTRAP_COMPLETE=false` until the initial submission is
completed. Subsequent uploads verify the release APK/receipt and preserve the
listing metadata, artwork and USD $2.99 lifetime SKU. Physical Fire TV playback
and purchase/restore testing remain separate qualification steps.

## Interface concepts

[Sixteen labeled TV, phone, tablet and desktop previews](../interface-previews/)
are retained separately. They render production Flutter widgets with synthetic
fixtures and are **not store screenshots**. Their manifest records their own,
earlier source revision. Do not mix them into store upload slots.
