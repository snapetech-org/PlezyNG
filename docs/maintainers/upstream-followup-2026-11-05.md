# Upstream follow-up, 2026-11-05

The upstream delta was assessed from `edde746/plezy` `1fc16b6c` (the
October 27 parity checkpoint) through `6cc283a7`. Implementation started from
Pleazyng main `0e3c4d9`, after checking which behaviors the fork already had.
No upstream commits were cherry-picked for this batch.

## Selected scope

| Area | Fork implementation | Upstream signal |
| --- | --- | --- |
| Automatic downloads | Rule-driven admission cannot clear a storage failure. Failed rows and their error remain intact until an explicit download, resume or retry. | PR #2938 |
| Storage throughput and capacity | Desktop writes consume a bounded 1 MiB capacity budget across packets; capacity is resampled after draining the sink. iOS includes capacity reclaimable for important usage, with raw capacity as fallback. | Commit `80c562ff`, storage follow-up |
| Plex direct play | Register the selected original media/part indices before returning the chosen file; five-second total deadline, no endpoint failover, ordinary failure preserves the file, cancellation propagates. The URL and internal/external/Cast progress share a session identity. Music, download resolution and Live TV keep their own paths. | PR #2960 |
| Plex deletion | Fetch the live `allowMediaDeletion` preference, combine it with the existing account admin/owner gate, and recheck before sending DELETE. Unknown, offline, failed and timed-out permission reads cannot enable deletion. | PR #2898 |
| Remote rows | Reuse our shared select-hold controller for list rows: short press activates, hold/context-menu opens the secondary action, repeats do not duplicate actions, blur/disable/dispose cancels the hold, and release cannot activate a newly opened dialog. Pointer actions and switch/checkbox behavior remain intact. | Commit `0ef47f27` |
| Linux HDR detection | Three-state per-launch output policy, retaining all existing protocol/framebuffer/source/app-setting checks. | PR #2971 |
| iOS backup size | Mark only managed download/artwork roots as excluded, including existing legacy roots at launch and newly created/recreated roots. Other documents and externally selected roots are not excluded. | Commit `d192a726` |

The deletion and direct-play logic use the fork's existing optional client
capabilities, HTTP transport and playback reporting. Storage changes preserve
our vendored downloader and its existing credential and recovery behavior.

## Linux override

The normal default remains automatic detection. When an HDR-enabled Wayland
compositor misreports display headroom, launch the app with:

```sh
PLEAZYNG_HDR_OUTPUT=hdr pleazyng
```

Use `PLEAZYNG_HDR_OUTPUT=sdr` to force the output-detection gate off, or `auto`
(or remove the variable) to restore detection. Unknown values use automatic
detection. This applies to every video surface in that process; it is not a
per-monitor setting. It cannot enable a missing color-management protocol,
unsupported source curve, shallow framebuffer, or the app's disabled HDR
setting. Display peak luminance remains the compositor's reported value.

## Deliberately outside this batch

Genre browsing, whole-library shuffle, Jellyfin subtitle search, download-size
accounting, forced Plex transcode after HTTP 500, and the noted health/focus
fixes were already present. They were not duplicated.

Bonfire profiles, actor filmographies, theme-music controls, resume-profile UX,
watch-together deep links, tracker banners, and scoped zoom need separate
product decisions. Blanket mpv/Apple shader upgrades need reconciliation with
our custom native patches and platform qualification. ExoPlayer removal is
inappropriate for this fork. Closed upstream proposals alone are not a reason
to add code.

## Validation

Regression coverage includes real temporary-file writes with simulated disk
capacity, durable download queue transitions, Plex HTTP/session sequencing,
external-player progress and return callbacks, deletion permission changes,
and remote widget events. `hdr_metadata_test.cc` is compiled and executed on
Linux, including all pre-existing metadata and output-gate cases.

Apple filesystem backup tests are included in `ios/RunnerTests`; execution and
an iOS build require macOS/Xcode. No hardware HDR/Plex-server/Apple-device
qualification or release publication is claimed by this change.

The final focused Flutter suite passed all 475 tests across download manager,
provider, storage, Plex playback/permissions, external-player and focus/menu
coverage. Changed application Dart files passed analysis with no issues;
the desktop downloader files were analyzed separately. Linux HDR metadata and
policy tests passed with `g++ -std=c++14 -Wall -Wextra -Werror`.
Code-generation freshness also passed.

The repository-wide hook was not green: existing formatting, translation,
hardcoded-string, workflow-guard, icon-consistency, native-format and analyzer
checks failed outside this batch. Commits use the documented hook bypass after
focused validation; no schema or translation generation changes are part of
this batch.
