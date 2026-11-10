# Google Play first-publication recovery

The original immutable v3.0.7 AAB uses Android version code 166. Google retained
its generated APKs after the unpublished Alpha configuration was discarded, but
the release library is empty, track assignment returns404, and reupload returns
“Version code 166 has already been used.” Failed delivery runs are
[42728878763](https://github.com/snapetech-org/pleazyng/actions/runs/42728878763)
and [42730459200](https://github.com/snapetech-org/pleazyng/actions/runs/42730459200).
The original GitHub release and binaries remain intact.

`repack-play-v307.yml` prepares a store-only 167 variant of that exact AAB. It
authenticates the published checksum manifest and pins the AAB and official
bundletool 1.18.3 digests. Google's AAPT protobuf classes change only the manifest
version code; package identity and version name 3.0.7 remain. All 1,667 payload entries are compared before and after signing; only that
manifest entry may differ. No Flutter, Dart or
native application code is rebuilt.

The workflow uses the existing CI upload key, verifies the original upload
certificate `BB:0F:AA:2C:AF:87:C6:DE:B1:29:E9:94:56:7B:C8:0D:CF:5C:65:27:61:B3:AB:78:3D:D4:75:CC:FE:51:D9:AC`
on every signed payload entry, validates the bundle, and attests the derived
artifact. This differs from Google's registered app-signing certificate
`66:EA:DD:02:16:2A:81:E1:65:0B:C6:20:15:BC:E8:FF:67:72:9C:0D:DE:B1:1A:35:9A:78:D3:87:99:E8:0C:22`.
Passwords stay in CI environment variables; the temporary 0600 keystore is
removed when signing exits and is excluded from retained artifacts.

Inspect live state before dispatching this one-off workflow. It only creates an
internal **draft**, and refuses unrelated/live internal releases or an existing
review. It does not request rollout or review. The receipt and signed AAB are
retained separately as workflow artifacts.

If upload is attempted but commit fails, inspect `pending_play_edit` in the
compact receipt and the streamed CI log. Its ID and expiration are recorded
before upload. Avoid Console mutations, which invalidate pending API edits.
Resolve that same transaction before rerunning: the workflow does not
automatically resume an old edit, and Google expires edits. Do not discard a
newly uploaded version or increment again without inspecting the actual result.

The first 167 delivery ([42733775175](https://github.com/snapetech-org/pleazyng/actions/runs/42733775175))
uploaded the bundle and assigned its internal draft successfully, but Google
rejected validation with “This app has no APKs.” Recovery
[42737436827](https://github.com/snapetech-org/pleazyng/actions/runs/42737436827)
confirmed that exact draft and attempted commit with the review guard; commit
returned the same 403. That uncommitted edit expired on 2026-11-10 at 02:15 UTC.
Do not retry its edit ID or repeat the upload workflow. First-app registration
must now be completed in Play Console using the retained signed bundle.

The signed store-167 AAB has SHA-256
`143c18c488118e91740bc2d662308ec79cd044200f3b263d7f45959ae6a58fbc`.
Its workflow attestation verifies against this repository, the repack workflow,
`refs/heads/main`, and GitHub-hosted execution. Console attachment, registration,
and review state still need live verification; API upload success alone proves
none of those outcomes.

After the internal draft is committed, run `qualify-play-existing.yml` for 167.
It verifies Google's actual signed APKs, uses Google's official unprotected QA
splits in a fresh emulator, and tests the expired-trial review grant and restart
persistence. No populated grant screenshot or XML is retained. This does not
qualify Automatic Protection or billing: those require an actual Play install
and licensed test purchase/restore on the physical phone. Keep bootstrap false
until the required evidence exists. Restore the closed Alpha release and its
notes, then submit review and verify activation separately.

References: [Google's edit model](https://developers.google.com/android-publisher/edits),
[commit review guard](https://developers.google.com/android-publisher/api-ref/rest/v3/edits/commit),
[official bundletool](https://github.com/google/bundletool/releases/tag/1.18.3),
and [billing qualification](https://developer.android.com/google/play/billing/test).
