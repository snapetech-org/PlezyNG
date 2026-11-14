## Runner policy — owner directive, 2026-11-13

Use compatible public GitHub-hosted runners first for every build, test, scan,
package, release, and delivery job. Preserve the target OS and architecture.
The MacBook Air is not a build dependency: unsigned Apple builds, mpv builds,
and ordinary Apple tests use hosted runners and must continue when that Mac is
offline.

Private ephemeral JIT is not a general build pool. Use it only for requested
Apple signing/notarization and the one verified webOS capacity overflow. The
webOS source build preflights for 60 GiB under `RUNNER_TEMP`; this organization
has no configured GitHub larger runners, and standard Ubuntu hosted runners
provide only 14 GB. Keep that webOS lane on Linux x64 JIT until the build fits a
standard public runner or a larger hosted runner is configured. Do not use
private JIT for MPV builds, ordinary Apple builds, or jobs that merely seem
heavy. If the MacBook is offline, report the signed Apple lane unavailable and
continue unsigned Apple artifacts and the rest of the release.

Update stale private-only instructions, selectors, and workflow routes when
found. A rerun uses its original workflow revision; validate each changed
revision on its selected GitHub-hosted runner class. Preserve active builds and
other work, and do not restart the broker while it owns running guests. Consult
the shared JIT inventory at
`snapetech-org/packer/scripts/shared-jit-runner-pool/` only when an approved
overflow or Apple signing route needs it.

Public pull-request code runs without secrets and with minimal permissions.
Use GitHub-hosted disposable execution for untrusted code; never widen trusted
runner-group access to admit it.

## CodeQL

The owner-directed organization policy dated 2026-10-30 disables CodeQL across
all `snapetech-org` repositories, including this public fork. Do not enable
CodeQL default setup or add or restore CodeQL workflow invocations unless the
owner explicitly reverses that direction. Keep the other approved security
scans and checks in place; this instruction applies specifically to CodeQL.

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

## Dolby Vision/FEL and experimental features — owner directive, 2026-11-09

Include implemented experimental Dolby Vision/FEL paths and HDR/SDR tools in
normal builds for compatible platforms. Dolby Vision/Profile 7 FEL playback is
automatic and enabled by default, with persisted runtime Settings overrides and
automatic fallback to the best supported native, compatible base-layer or server
route when the preferred path is unavailable or fails. Do not require a separate app build, compiler flag, manual
engine replacement, or prior device qualification to make an implemented
experiment available. Ship the required native components and verify packaging;
a toggle without its implementation does not satisfy this requirement.
A missing preference must enable automatic DV/FEL; preserve explicit Off and
manual conversion choices. Keep compatibility fallback enabled by default and
report actual layer use, output and qualification status accurately. This
supersedes the earlier default-off Dolby Vision directive.

The normal-build inclusion rule also applies to implemented NPU/neural experiments: include their
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

Feature guides and implementation records must include a short **Upstream
sources** footer when an upstream record materially informed the feature.
Link the original PR, issue, report, discussion or commit and the upstream
author, describe its relevant scope, and link `UPSTREAM_ATTRIBUTION.md`.
Keep proposal/report credit distinct from implementation and qualification;
do not attach unrelated records to new downstream features.

## Branch consolidation — owner directive, 2026-11-09

Keep `main` as the only local branch and the steady-state branch on `origin`.
Use detached worktrees for isolated tasks. Integrate reviewed changes into main
and push promptly; retire merged or explicitly superseded task/PR branch names.
Before removing a checked-out branch, wait for active Git/build consumers,
verify its final tip is on main or explicitly accounted for, and detach the
worktree at that identical commit. Preserve its files, index, caches and evidence.
Do not remove worktrees or unique work merely to reduce a branch count.

The `upstream` remote is the separate Plezy project. Track its `main` only;
its feature branches are not Pleazyng work to merge or delete automatically.
Keep upstream attribution requirements when actually adapting upstream work.

## aerynOS publication and qualification — owner directive, 2026-11-09

The owner explicitly restored aerynOS as an actual downstream publication target,
including a working recipe, native installation and QA. This supersedes earlier
exclusion and review-only scope. Preserve truthful candidate/qualified status,
source provenance and historical evidence. Publish independently after native
qualification; official aerynOS repository acceptance is a separate matter.
Do not submit AI-authored contributions where the project's policy forbids them.
