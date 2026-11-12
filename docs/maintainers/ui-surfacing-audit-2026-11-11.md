# UI surfacing audit — 2026-11-11

This is a code-level audit checkpoint for fork additions. It compares the
[feature inventory](../../README.md#features), the
[comparison evidence](../FEATURE_COMPARISON.md), recent application changes,
and UI entry points at `1cac4f470`. A reachable class is evidence of a route,
not proof that a user can find or operate it on every device. Physical-device
and service qualification remain separate.

## Confirmed gaps and repairs

| Capability | Gap | Repair on `main` |
| --- | --- | --- |
| Native music group equalizer | The shared music session persisted and applied native parametric EQ, but the Caldera/Plexamp group screen offered no local editor. | `6b0152d56`: add a group-screen editor for enabled state, gain and existing bands, plus a new peak band; save through the existing profile-scoped control. Remove the inaccurate “anyone can control” subtitle from native availability. |
| Orphaned-download cleanup | The reviewed cleanup flow was available only through a toolbar icon in Downloads. | `1cac4f470`: add a labeled Download settings row that invokes the same guarded scan, file review and confirmation. Keep automatic cleanup separate. |

## Static reachability checks

- Public Karaoke and Extras screen classes appear unreferenced by class name
  outside their own files, but `openKaraoke` is reached from Libraries and Now
  Playing, and `openExtras` is reached from media detail and Extras widgets.
- The reader settings screen is opened from the publication reader; music group
  and audio settings screens are reached from Now Playing and Music home.
- Every music `*Controls` interface found in `lib/services/music` has a UI or
  Karaoke-session consumer. The native group equalizer interface was consumed
  only by native group transport before the editor above.
- The apparent unreferenced `SettingsService` preferences include scoped player
  defaults, a per-show Include Specials dialog choice, download location through
  `DownloadStorageService`, and internal cache/entitlement state. These are not
  evidence of missing settings rows by themselves.
- The Downloads, Requests, sources/readers, Podcasts, Games, IPTV, discovery,
  playback and workspace features listed in the README have named screens or
  contextual actions in the current tree. This check does not establish flow
  completeness or platform behavior.

## Further flow review

The static pass cannot establish whether a reachable action is understandable,
fits a narrow/TV layout, has correct permissions, or works with a live server.
Continue with the actual screens and account/device fixtures for each README
feature group. Podcast automation labels were made specific in `7ed91dece`;
native EQ band-type selection was subsequently added. Preserve the existing
provider and platform gates during further review.
