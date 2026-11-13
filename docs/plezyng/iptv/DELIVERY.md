# IPTV implementation delivery

Reconciled 2026-11-12 against the current `main` source tree. This tracker
supersedes the initial-branch status below in the original handoff. It records
source presence separately from automated results, provider acceptance and
device qualification.

## Current source on main

- Profile-scoped sources are stored through `IptvSourceRepository`; provider
  configuration is protected by `CredentialVault` before it enters SQLite.
- Source setup and management are present in `add_iptv_source_screen.dart` and
  `iptv_sources_settings_screen.dart`. The source model includes M3U, Xtream,
  Tunerr, Dispatcharr and Stalker inputs; Stalker has a native portal adapter.
- Playlist and XMLTV parsers, channel/guide persistence, channel overrides,
  favorites, parental access and channel selection are implemented in the
  `lib/iptv/` services and `lib/screens/iptv/` screens.
- Live playback uses `IptvLiveTvPlaybackSession`. HLS archive handling,
  recording scheduling and scheduled stream capture have source implementations.
  Dispatcharr DVR and Xtream VOD also have dedicated clients and UI routes.
- VOD progress synchronization has a profile-scoped service.
- XMLTV timestamp parsing rejects invalid calendar dates, clock fields and
  numeric timezone components so malformed guide entries are skipped instead
  of being normalized into a different UTC interval.

This is a static source inventory. It does not claim that every one of the 240
requirements in `PLAN.md` is implemented, that every backend is compatible, or
that a platform has passed device qualification.

`PLAN.md` is a research roadmap rather than an accepted commitment to ship all
240 proposals. No handoff ZIP, handoff JSON, or machine-readable requirement
status map is maintained. This page records source presence and evidence limits;
it is not a requirement-by-requirement completion ledger.

## Verification inventory

The repository currently contains 26 Live TV/IPTV-related test files under
`test/`, including parser/model, guide, playback-session, HLS archive,
recording recovery, scheduled recording, VOD/server support and screen coverage.
Their presence is not a result for the current `main`; this audit did not run
them.

## Delivery boundaries

- User-supplied credentials and generic source adapters are application scope.
  Live partner credentials, proprietary SDK access, provider enrollment and
  provider-specific secrets remain in the separate handoff boundary.
- Device-specific stream behavior, unattended recording, platform packaging,
  and live-provider interoperability require their own evidence. Do not infer
  them from source presence or from another platform's results.
- `PLAN.md` is the requirements and research baseline. Its baseline commit and
  historical handoff statements describe the planning snapshot, not current
  branch state. Requirement-by-requirement implementation, automated-test,
  device-qualification and release status must be recorded only when supported
  by current evidence.
