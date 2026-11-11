# Automatic aerynOS release delivery

The independent downstream channel is
[snapetech-org/pleazyng-aerynos](https://github.com/snapetech-org/pleazyng-aerynos).
Canonical `main` metadata is tracked independently in `sync-state/canonical-main.json`.
Tracking an unreleased source commit never compiles the app or advances the feed.
Published core releases from 3.0.29 onward enter the package delivery queue.
Consult downstream Actions and `sync-state/last-good.json` for actual status.

Canonical pushes invoke `aerynos-source-push.yml`, which wakes the downstream
`source-sync.yml` receiver. The receiver verifies both repository identities,
fetches current canonical `main` itself, and updates only the source pointer
with a bounded compare-and-swap. The receiver selects the source independently;
package qualification remains part of the native delivery pipeline.

The caller uses the canonical Actions secret `AERYNOS_SOURCE_DISPATCH_TOKEN`.
Its fine-grained token is restricted to `snapetech-org/pleazyng-aerynos`, with
Contents read/write and required Metadata read-only, and no organization
permissions. The token provisioned on 2026-11-11 expires on **2027-11-11**.
Preserve this single-repository scope when rotating it. Trusted
`refresh-release-metadata.yml` explicitly invokes the caller after successful
reconciliation, including runs that commit using `GITHUB_TOKEN`; those commits
do not start push-triggered workflows.

## Pipeline

The release controller wakes downstream reconciliation after core publication.
A workflow scheduled every five minutes provides catch-up, subject to GitHub
scheduling and compatible runner availability. Manual dispatch is supported.
A shared concurrency group
preserves active work and coalesces pending polls. Release receipts prevent
repeat publication; failed deliveries back off for thirty minutes.

1. Resolve the oldest pending published semantic-version release. Verify its
   attested `SHA256SUMS.txt` against the canonical core workflow and require that
   its certificate-bound final assembler run completed successfully. Match the
   published Linux archive against those checksums and GitHub's asset digest.
2. Verify the Linux archive's own attestation to identify its original compiler
   source and run. Resolve the remote version tag, including annotated tags,
   and require the Linux compiler source to equal that frozen commit. Ordinary
   assemblers use the same source. The closed `frozen-apple-packaging-v1` contract
   in [the release runbook](full-release-build.md) permits an explicitly approved
   Apple packaging repair while retaining the original Linux bytes/certificate.
   The consumer independently checks the exact repair commit, full Git trees,
   approved file/blob inventory and canonical ancestry. Attested core checksums
   must bind the public recovery receipt to the actual workflow/assembler, approved
   checkout, original embedded CI/freeze and artifact identities. The consumer also
   checks signed Apple archive steps and repeats verification after native QA.
   Product, packaging and workflow sources and compiler/assembler runs remain
   distinct in the delivery receipt. Other source substitutions and self-asserted
   equivalence claims are rejected.
   The consumer anonymously downloads the published Linux archive, matches its
   attested digest, then uses `from_core.py` to verify the successful original
   Linux job, retained artifact identity, trusted repository/workflow and exact
   certificate-bound source/invocation. No cross-repository Actions archive
   credential, Flutter setup or application recompilation is needed.
3. `aerynos-qualify.yml` boots a disposable KVM guest from the checksum-pinned
   official aerynOS image, builds the Stone, and upgrades the last-good package.
   Dependency checks, fresh sign-in, default settings, visible H.264 and authored
   audio, pause/seek/fullscreen, playing and paused background return, route
   resume and bookmark resume must pass. Playing phases require moving authored
   frames and advancing clocks; paused return requires fixed pixels and clock
   with no audio. The direct OpenMedia route must also show moving authored
   H.264, audio and advancing clocks on initial playback, before seeking or any
   other playback intervention. Both routes are mandatory. Only authored fixtures
   and accounts are used.
4. Revalidate the qualified binary digest, source, app version, original producer
   and still-published successful core. Attach `core-release.json` with original
   compiler and final assembler identities. Publish immutable package assets,
   verify their remote digests, then atomically commit the recipe, index and
   release receipt. Failure before promotion preserves the last-good feed.
5. A second fresh official guest anonymously installs from the live public feed,
   removes and reinstalls from the pinned release feed, then launches the ordinary
   app. It checks index digests, installed version and runtime source/version.
   Record the public-install receipt and retain screenshots/logs. A failed public
   check holds newer deliveries and retries only this check after thirty minutes;
   it does not recompile, repackage or repeat the preceding native qualification.

Every package retains its matching original source archive. Native QA evidence
includes screenshots, clock/audio measurements, runtime logs and audio capture.
These software-rendered VM checks do not establish physical HDR output, hardware
GPU/NPU execution or FEL reference-picture accuracy.

The package release counter advances monotonically. Canonical ancestry and the
reviewed first-transition seed/bootstrap contract prevent stale or divergent
source promotion. Published assets are never overwritten or force-pushed.

## Feed layout

After the first qualified promotion, the stable channel index is committed at:

```
https://github.com/snapetech-org/pleazyng-aerynos/raw/refs/heads/main/feed/stone.index
```

Its package references resolve to immutable GitHub release assets. Moss resolves
relative package URIs against the original configured index URL, so preserve the
GitHub-domain URL and the five-level relative path generated by the qualifier.
Each release also carries its own `stone.index` for clients that want to remain
pinned. The Git-backed live index and the per-release index have different
relative paths and must not be substituted for one another.

## Native UI harness

The harness uses the ordinary release executable. It clicks the observed password
field with native pointer input before typing the authored credential; a semantic
Tap alone can leave the native Wayland window without keyboard focus. It checks
protected-field length without reading its contents and requires successful
server sign-in. No input-method override is part of this gate.

One persistent AT-SPI client serves the scenario. Repeated short-lived clients
reproduced a GTK accessibility event-listener crash during keyboard navigation;
keeping the client connected passed the same local navigation/playback checks.
Retain crash evidence and distinguish this harness behavior from an established
failure of ordinary pointer-driven sign-in or a different distribution.

The native recipe generates and relocates every shipped GTK input module's cache.
The shared bundle generator also discovers Ubuntu's query tool outside `PATH`;
the launcher relocates moved portable caches without dropping locale records.

## Preflight and recovery

The coordinator may stage and qualify exact existing Linux bytes before the core
release finishes. This establishes native evidence only; it does not permit
publication or represent an overall failed original run as a successful release.

After core publication, normal automatic delivery performs all checks. Native
qualification artifacts are produced and consumed in the same delivery run.
Cross-repository `qualified_run_id` reuse is unsupported; preflight evidence
cannot bypass the current delivery's native qualification. Manual `sync.yml`
dispatch with `retry_now=true` retries a repaired delivery immediately. A pending
post-publication installation check retries that check alone.

The downstream `promotion-hold.json` stops staging and promotion while retaining
source metadata tracking. Use the serialized `hold.yml` maintenance protocol in
the downstream README: disable scheduled polling first, dispatch the hold and
wait for success. An active publication may finish before a queued hold takes
effect. The publisher refreshes hold/feed state after uploads immediately before
making a release public. Scheduled workflow activation is explicit; neither
controller re-enables schedules automatically. The legacy unreleased-source
compilation lane has been removed. A weekly health commit keeps release polling
active without building an app. Package reconciliation uses the consumer
repository's `GITHUB_TOKEN`; the dedicated source-dispatch credential is used
only by the canonical source caller.

A native or channel delivery failure is separate from core success. Repair or
retry delivery with existing immutable artifacts; do not rebuild all platforms,
change core assets, weaken native gates or fabricate qualification metadata.
Use the current workflow revision; reruns retain the original workflow revision.

Native QA requires compatible Ubuntu KVM capacity. Preserve diagnostics before
cleaning stopped task-owned guests. Retain shared ISO/build caches and never
clean another agent's VM, desktop, browser profile or active build.
