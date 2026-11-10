# Automatic Google Play release delivery

Every complete, published stable release from 3.0.29+188 onward is eligible for
automatic delivery. The owner's 2026-11-10 instruction supersedes the v3.0.7
first-publication/repack path. Build current application and native code once,
from one frozen source checkpoint; other agents review rather than dispatch
competing release builds. `build.yml` serializes the core release workflow.

## Triggers and configuration

`release_all_platforms.py` runs exact-source CI, creates the immutable version
tag, performs one complete all-platform release build, verifies its artifacts,
and promotes the GitHub draft. Its post-publication hook explicitly dispatches
`deliver-google-play.yml`, including when the publication uses `GITHUB_TOKEN`.
Human-created release events also invoke that controller. The separate
`reconcile-google-play.yml` catch-up schedule runs every ten minutes; the
non-scheduled controller can re-enable a schedule disabled for inactivity.
It respects a manually disabled schedule.

Repository variables:

- `GOOGLE_PLAY_AUTOMATIC_RELEASES=true` enables delivery; `false` pauses it.
- `GOOGLE_PLAY_AUTO_TRACK=internal` selects the phone-test track independently of
  the older manual `GOOGLE_PLAY_TRACK` setting.
- `GOOGLE_PLAY_MIN_VERSION_CODE=188` prevents backfilling the retired bootstrap.
- `GOOGLE_PLAY_BOOTSTRAP_COMPLETE` remains false until signed-build reviewer
  redemption, purchase/restore and required store qualification pass. Automatic
  alpha/beta selection requires this flag. Internal distribution supports that
  qualification; it does not assert that it is complete.

The controller requires all mandated platform assets, the signed Play bundle,
checksum manifest, matching immutable pubspec version and ancestry on canonical
main. Drafts, prereleases and incomplete releases are not delivered. An older
incomplete release records its own error without blocking a later complete one.
Successful completed-track runs are idempotent; successful draft uploads do not
count as completed distribution. Failed runs become retryable after two minutes,
so the next catch-up run can recover a still-valid pending edit.

## Publication and recovery

`publish-app-stores.yml` runs from protected main and authenticates the release
checksum manifest's attestation before using its signed AAB. It obtains the
expected Android code from the immutable release source and verifies Google's
returned version and SHA-256. Google Play mutations are serialized across every
track for this package/service account. No application rebuild occurs in delivery.

The publisher retains a non-secret `google-play-delivery-receipt` artifact before
upload and after every transaction transition. A retry restores the same
matching tag/code/bundle-digest/track edit, even when moving draft to completed.
Staged track state never counts as a committed publication. Committing uses
`ERROR_IF_IN_REVIEW`; a fresh read verifies the committed track and bundle.
A lost commit response is detected without uploading the version again. Existing
newer versions are never rolled back. An expired reserved upload that is not
assignable fails explicitly rather than silently consuming another build number.

Do not change Console release state while a delivery owns a pending edit.
Inspect the retained receipt and actual track before retrying. Retry delivery
against the immutable release; keep core publication successful when a store
lane fails. Preserve the complete release, upload identity and qualification
history. Never rerun an all-platform build solely to repair store delivery.

Enrolled phones receive this as a normal Play update. Actual update timing
follows Google Play and the device's auto-update settings. Verify the installed
version/installer and playback on the device; publication alone does not prove
installation, compositor behavior, billing, review approval or production access.

References: [GitHub token-trigger semantics](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow),
[Google Play edits](https://developers.google.com/android-publisher/edits), and
[commit review protection](https://developers.google.com/android-publisher/api-ref/rest/v3/edits/commit).
