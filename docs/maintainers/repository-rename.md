# Application repository rename

The owner authorized the application repository and local checkout rename on
8 November 2026 (America/Regina), after the complete 3.0.5 release was published.

| Item | Current identity |
| --- | --- |
| GitHub repository | `snapetech-org/pleazyng` |
| Stable GitHub repository ID | `1433487464` |
| Previous GitHub name | `snapetech-org/PlezyNG` |
| Local checkout | `/home/keith/Documents/code/pleazyng` |
| Local compatibility symlink | `/home/keith/Documents/code/plezyng` → `pleazyng` |
| Upstream | `edde746/plezy` (unchanged) |

This was an in-place GitHub rename. Issues, releases, tags, repository settings
and fork ancestry remain attached to the same repository ID. GitHub redirects
the old repository, Git and release URLs. Do not create a new repository at the
old name: that would replace its redirects. The website repository
`snapetech-org/plezyng.app`, package registries, application IDs and shared
NFS/cache directory names were outside this rename.

## Local checkout and old paths

The main checkout was moved and `git worktree repair` repaired the linked
worktrees. `origin` uses the canonical URL. The old `plezyng` path remains a
symlink because running tools and cached build configurations contain absolute
paths. It is a compatibility alias, not a second checkout or copy of artifacts.
Retire it only after its consumers and absolute-path cache references have
migrated. Do not clear shared compiler or dependency caches to rename a folder.

The separate old `plezy` directory contained only empty Android build
directories. Empty build directories can be removed with `rmdir`; an empty root
still used as a running process's working directory must remain until idle.

## Automation and runner access

Current URLs and repository checks use the new name. Repository ownership
conditions in the Discord and DV workflows use the stable numeric repository
ID. Repository-scoped private labels use `ng-shared-main-pleazyng`; shared pool
names and other repositories' labels remain unchanged.

The exact workflow references were renamed in runner groups 6, 8, 10 and 11
(respectively 1, 5, 17 and 5 references). Workflow counts, repository membership
and trust restrictions were preserved. Packer source and deployed broker policy
use the same identity. Broker reloads require zero active guests; renaming must
not cancel builds or widen runner access.

Windows native dependency caches include the repository name in their key
because cached CMake configuration can embed the checkout's absolute path.
Other SDK, pub, Gradle and native download caches remain available.

## Published artifacts and signatures

The immutable 3.0.5 tag remains at
`f253feb9a8a0949443d569af901f521df2be6f3c`. Published binaries, signing material,
release notes and their attestations were not rebuilt or rewritten for this
rename. Historical signed provenance continues to name its original publisher.

For an old artifact, `gh attestation verify --repo snapetech-org/PlezyNG`
continues to verify the historical issuer through the repository redirect.
`scripts/verify_release_attestation.py` first tries the current issuer, then the
historical issuer. Both names must resolve to repository ID `1433487464` before
they are trusted. A recreated old name or an invalid signature still fails.

Package publication workflows use this verifier. Homebrew comparison renders
the expected Cask using the verified artifact's publisher, so a renamed URL does
not invalidate an otherwise unchanged attested Cask. Future client builds use
the canonical GitHub `releases/latest/download/appcast.xml` feed.

## Verification after future path or identity changes

Check the numeric repository ID, old web/Git/release redirects, immutable tag
and asset IDs/digests, worktree connections and `origin`. Reconcile exact runner
workflow references and source/deployed policy before dispatching jobs. Run the
repository guards and the relevant CI once on the final main commit; do not
rebuild a published release merely to change repository links.
