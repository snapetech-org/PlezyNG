# Automatic Nix release metadata

From v3.0.33 onward, `refresh_release_facts.py` advances
`linux/packaging/nix/release.json` from the complete public latest release.
The release controller invokes this after core publication. The separate
`refresh-release-metadata.yml` catches human publication events, supports manual
retry and reconciles twice an hour. Token-created release events may not trigger
another workflow, so the controller hook and schedule are both required.

Before writing, the helper verifies canonical repository identity, stable public
status, all required platforms, the immutable tag's ancestry and pubspec version,
the final manifest's workflow attestation and exact successful assembly attempt,
and both Linux archive digests. Unsupported assembly/product-source recovery
provenance fails closed; it must be explicitly verified before metadata can
advance. It never substitutes an older candidate or rebuilds the application.

Identical metadata is a no-op. Downgrades and changed hashes for an existing
version are errors. The reconciler uses a fresh detached current-main checkout
for each of at most three push attempts, stages only the Nix metadata file, and
regenerates after concurrent main movement. It never force-pushes. Verification
receipts and attempted patches are retained; dirty failed checkouts are preserved
for inspection. The controller preserves core publication success if a metadata
follow-up fails.

To retry on the hosted runner without store credentials:

```sh
gh workflow run refresh-release-metadata.yml --repo snapetech-org/pleazyng --ref main
```

For a local read/verification pass that updates only the maintained file, use a
clean detached task worktree and retain the public receipt outside that checkout:

```sh
python3 scripts/refresh_release_facts.py --tag v3.0.33 --nix-only \
  --receipt "$task_scratch/nix-metadata-verification.json"
```

Metadata advancement does not assert native runtime qualification or Nixpkgs
acceptance. Keep package build, keyboard/WebKit/playback evidence and upstream
maintainer acceptance separate. Update the existing Nixpkgs proposal additively
after review; this automation does not submit or edit upstream pull requests.
