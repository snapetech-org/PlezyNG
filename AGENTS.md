## Runner policy — owner directive, 2026-11-03

Use compatible public GitHub-hosted runners by default, preserving each job's
required OS and architecture. Use private ephemeral JIT runners only when a
task requires private hardware, network, files, or other task-specific private
resources. Public pull-request code must run without secrets and with minimal
permissions; use disposable isolated execution when the task requires tighter
egress or environment controls. Preserve active builds and other agents' work.
Do not restart the broker while it owns running guests. Validate each workflow
revision on the runner class it selects; rerunning an old run uses its old
revision.

The shared JIT inventory lives in
`snapetech-org/packer/scripts/shared-jit-runner-pool/`. Check source routing,
runner-group access, deployed broker policy, and live capacity when a task
needs a private JIT route.

Public-fork and other untrusted code remains isolated in a disposable VM-backed
JIT sandbox with no secrets, minimal permissions, and restricted egress. Do not
widen trusted runner-group access to make untrusted code run.

## CodeQL

CodeQL workflow execution remains disabled across Snapetech repositories under
the owner's directive. Do not restore or reroute CodeQL workflows unless the
owner explicitly reverses that directive.

## Release coverage — owner directive, 2026-11-05

Versioned GitHub releases include Android, Linux x64/arm64, Windows x64/arm64,
universal macOS, iOS, tvOS, Tizen, and webOS artifacts. Fix failed platform
builds and validate their outputs; do not omit a platform to get a green run
without the owner's explicit approval. A published release missing a required
platform is incomplete. Keep artifact provenance and qualification truthful.

The complete build published on GitHub is the successful core release. Treat
notification, store and package-channel delivery failures as separate follow-up
work. Repair or retry those lanes against the existing immutable artifacts;
preserve core success and avoid another all-platform build for a delivery error.

## Experimental features — owner directive, 2026-11-05

Include implemented experimental Dolby Vision/FEL paths and HDR/SDR tools in
normal builds for compatible platforms. Users opt in through persisted runtime
Settings controls. Do not require a separate app build, compiler flag, manual
engine replacement, or prior device qualification to make an implemented
experiment available. Ship the required native components and verify packaging;
a toggle without its implementation does not satisfy this requirement.
Keep experiments off by default and report qualification status accurately.

The same rule applies to implemented NPU/neural experiments: include their
native filters, compatible provider runtimes and models in normal releases.
Playback → Motion smoothing → Neural is the persisted opt-in; Off remains the
default. Runtime hardware/stream availability and accurate provider diagnostics
remain required, without a device-qualification or build-time inclusion gate.


## Dart generation and formatting

Use `scripts/format_dart.sh` for maintained Dart source and `scripts/format_dart.sh --check` to verify it. Regenerate translations and model outputs with `scripts/codegen.sh`; preserve those canonical outputs instead of formatting generated files manually.

## Repository identity — owner directive, 2026-11-08

The canonical repository is `snapetech-org/pleazyng` and the authoritative local
checkout is `/home/keith/Documents/code/pleazyng`. The old `PlezyNG` GitHub URL
redirects to this same repository; do not recreate a repository at the old name.
The local `plezyng` path is a compatibility symlink for existing tools and cached
absolute paths. Use the canonical path for new work. Upstream remains
`edde746/plezy`; published tags, binaries and signed provenance retain their
original identities.

## Upstream source attribution

When Pleazyng gathers or adapts an idea, report, discussion, patch, rejected
request, issue, pull request, or commit from upstream Plezy, update
`UPSTREAM_ATTRIBUTION.md` and the user-facing changelog in the same change.
Record the originating upstream URL, the upstream author’s GitHub handle, the
kind of source, and the behavior brought into Pleazyng. Say that the person
contributed or suggested it to the upstream project and that Pleazyng
independently adapted, integrated, or verified it. Never imply that the person
contributed directly to, endorsed, or participated in this fork.

Credit closed, unmerged, superseded, and rejected upstream records when their
code or ideas materially informed the fork. Before a release, audit every new
upstream reference in commits, release-note fragments, and changelog entries
for an author link and originating issue, PR, or commit link. Missing source
credit is a release-note defect and must be fixed before publication.

If an upstream record informs a maintained plan, roadmap, partial
implementation, or unresolved investigation, add it to a clearly labeled
planned/not-yet-shipped section. Preserve a reviewed disposition for captured
records that are withdrawn, superseded, inapplicable, or still unreviewed;
never turn source credit into a claim that unfinished behavior shipped.
