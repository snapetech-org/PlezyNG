# Pleazyng 3.0.21 release preparation

Prepared on 2026-11-09. This is a source/readiness record, not a claim that
3.0.21 is published or qualified on every device. The latest published release
at preparation time is 3.0.7; existing tags through 3.0.20 remain immutable.
Flutter and webOS metadata advance together to **3.0.21+180**. The concurrent
3.0.20 tag and validation remain untouched; this final regression/readiness
update uses a fresh version rather than moving that tag.

## Branch disposition

The canonical GitHub repository has only `main` and no open PRs. The earlier
[25-PR disposition](pr-consolidation-2026-11-09.md) remains applicable.
The remaining Linux channel work was reviewed and merged into main in
`69c74ef32`: native `makepkg --printsrcinfo`, checksums for local AUR recipe
inputs, and Fedora repackaging without fabricated debug packages or build-ID
requirements that reject packaged native providers. Both sides' changelog
entries were retained when resolving the merge conflict.

These former local names were integrated into main, with their committed tips
retained in its history:

| Local branch | Disposition |
| --- | --- |
| `fix/qa-image-security-refresh` | Already integrated; no unique committed work. |
| `task-upstream-attribution-release` | Already integrated; no unique committed work. |
| `task/first-channel-publication` | Remaining channel fixes integrated; no unique committed work. |

Local cleanup in `4a16cfb09` waited for the active packaging push, detached
those worktrees at identical commits and removed their branch names, preserving
files, caches and evidence. Both local and GitHub branch inventories now contain
only `main`. Cached upstream feature refs were archived rather than integrated;
see the [cleanup receipt](local-branch-consolidation-2026-11-09.json).
The separate `edde746/plezy` remote tracks only its main branch.

## Resumed playback over retained home artwork

The reported Arch desktop was running 3.0.7. Its player route is intentionally
non-opaque to expose native video beneath Flutter. Making the video widget
transparent does not erase home/detail artwork already painted underneath it,
so transport controls and audio can work while the home screen obscures video.

Main already contains the shared fix in `5ba78320a`: clear the video aperture
with `BlendMode.clear` after the first-frame gate releases the startup cover,
then draw controls. Linux and Windows native planes, Apple/mpv and Android's
ExoPlayer adapter all pass through this shared `VideoRectSupport` path. No
additional decoder workaround or webOS-specific change is justified by this
desktop report.

The expanded pixel regression uses `VideoPlayerRoute`, `OverlaySheetHost` and
the transparent player `Scaffold`. It checks black startup/reload covers,
transparent ready video, intact controls, home artwork repainting during
playback, and normal home restoration on exit for all four adapters. Disabling
the aperture clear reproduces the Linux failure: home pixels remain opaque
where the native video needs transparency. Restoring the fix passes. Native
channels are mocked; this verifies Flutter composition, not hardware decoding
or device playback. webOS and Tizen retain their separate plugin video-hole
paths and their existing adapter tests.

## Local validation

- 42 playback/compositing/native-TV adapter tests passed.
- Full Flutter analysis passed with no issues; maintained-source formatting passed.
- Shared release/workflow guard suite: 1,063 test cases across 106 groups passed,
  together with the standalone package, provenance, workflow and metadata guards.
- Native revision preflight passed for Apple, Android, Linux and Windows.
- Packaging merge checks passed: four channel-recipe, 23 dependency and five
  Linux launcher tests; native `makepkg --printsrcinfo` emits the required
  unindented package stanza.
- Release version/coverage helpers passed 12 tests. Regenerated release notes
  retain upstream source credit. The deliberately disabled-clear regression
  failed as expected; this is negative-test evidence, not a release failure.

## Release gates

- Native preflight verified the current `snapetech-org/mpv-build` main revision
  `6b0c227cb484a705dd9797d798d6f319b7377cfa`, including all four published native
  platform groups. Recheck immediately before building; do not move old tags.
- New upstream changelog references since 3.0.7 are represented in
  `UPSTREAM_ATTRIBUTION.md`; the earlier source-credit ledger and distinctions
  between shipped, planned and unqualified work remain intact.
- Require the complete CI gate on the exact final source SHA before tagging.
  Historical or individually successful platform jobs do not satisfy it.
- Build and validate Android/Fire TV, Linux x64/ARM64, Windows x64/ARM64,
  universal macOS, iOS, tvOS, Tizen and webOS; run the release coverage checker
  on actual nonempty artifacts. Do not drop a platform to obtain success.
- Use public GitHub-hosted runners for compatible jobs, including unsigned
  Apple builds. Private JIT is limited to requested Apple signing and the
  webOS 60 GiB storage overflow; inspect its live capacity without interrupting
  active guests. CodeQL execution remains disabled.
- Enable automatic DV/FEL routing and compatibility fallback by default, preserve
  explicit runtime overrides, and include all corresponding native components.
  Neural motion processing remains off by default. Source tests do not claim device or provider qualification.
- Keep GitHub core publication separate from channel/store delivery retries.
  Existing AUR/COPR delivery runs use immutable published artifacts and do not
  justify another all-platform build.

Until the exact-source CI and all-platform artifact gates pass, this version is
prepared for validation, not ready to publish. Existing CI/build/publication
runs are preserved; no old release, tag, or artifact is replaced by this prep.
