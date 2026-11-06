# Retry distribution without rebuilding Pleazyng

A complete, validated GitHub release is the release. Package registries, stores
and notifications have separate outcomes. A failed distribution lane does not
unpublish the GitHub release, invalidate its successful build, or require a new
application build.

The release controller owns core publication. Do not restart the full release
controller to repair a downstream channel.

## Retry one existing publication lane

Find the failed channel run in GitHub Actions and inspect what it completed.
Then run, replacing the example run ID with that channel's actual run ID:

```sh
python3 scripts/retry_release_channel.py \
  --release-tag v3.0.1 \
  --run-id 123456789 \
  --retry-failed \
  --wait \
  --receipt /tmp/pleazyng-channel-retry.json
```

The command derives the workflow, action, runner pool, channel and any
publish/submit mode from the previous run's metadata. It does not keep another
channel catalog. It refuses application-build, CI and release-creation
workflows, draft/unpublished releases, a different release tag, and changes to
the selected lane's identity.

A successful or currently running recent attempt of the same lane is reused.
`--retry-failed` requests a new attempt after reviewing the previous failure;
it does not rerun the old workflow revision. The publisher runs from current
`main`, allowing fixes to publishing scripts while all downloads remain bound
to the original release tag. Existing channel workflows retain their own
artifact checksum, provenance, credential and bootstrap checks.

For Google Play, provide the testing track and release status explicitly,
because those values are not encoded in the previous run title:

```sh
python3 scripts/retry_release_channel.py \
  --release-tag v3.0.1 \
  --run-id 123456789 \
  --input play_track=alpha \
  --input play_release_status=completed \
  --retry-failed --wait
```

This automated retry supports internal/closed testing, using `draft` or
`completed`; it does not select production or rollouts automatically. Inputs
are non-secret workflow values. Credentials remain in the workflows' existing
secret configuration.

## Independent result and evidence

The JSON receipt reports `release_status: published` separately from the
channel's status. A failed watched attempt exits nonzero for that channel,
while the GitHub release remains published. Without `--wait`, success means
dispatch/reuse only, not completed distribution. If GitHub has accepted a
dispatch but its new run is not yet visible, a requested wait exits with code 2
and records that state; inspect Actions before requesting another attempt.

The receipt records requested and observed publisher revisions separately.
It never requests compilation, native-pin refresh, CI, tag movement, GitHub
release creation, or release-asset uploads. The published tag and artifacts are
not replaced to repair a distribution adapter.

Discord notifications can be retried the same way, including a previous
release-event notification. Existing notification receipts continue to prevent
repeat delivery.
