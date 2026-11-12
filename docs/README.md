# Pleazyng documentation

This index points to the main product guides, implementation records, and maintainer runbooks. The repository contains both current operating guidance and dated research, handoffs, incident records, and qualification evidence; a document's presence does not by itself mean its proposal shipped or remains current.

## Start here

- [Project overview and feature comparison](../README.md)
- [Contributing and development workflow](../CONTRIBUTING.md)
- [Repository policies and owner directives](../AGENTS.md)
- [Capability and qualification ledger](maintainers/capability-manifest.json): implementation, platform limits, release evidence, and open gates

## Product and setup guides

- [Files, books, and listening](FILES_AND_BOOKS.md)
- [Public-library setup](LENDING_SETUP.md)
- [Universal media](UNIVERSAL_MEDIA.md)
- [SeerrNG requests](SEERRNG_REQUESTS.md)
- [BookOrbit](BOOKORBIT.md)
- [VLC feature parity](VLC_FEATURE_PARITY.md)
- [Feature comparison](FEATURE_COMPARISON.md)
- [Curated extras](features/curated-extras.md)
- [Provider branding coverage](provider-branding-coverage.md)

## Pleazyng implementation and feature records

- [Feature handoff (historical snapshot, 2026-10-28)](plezyng/HANDOFF.md)
- [Service integrations](plezyng/service-integrations/README.md): provider scope, current code slices, commercial gates, and source register
- [Remote streams, debrid, and Stremio](plezyng/remote-streams/README.md)
- [Multiview](plezyng/multiview/README.md)
- [Cross-media discovery](plezyng/swipe/README.md)
- [Motion clarity](plezyng/motion-clarity/README.md)
- [Visualizations user guide](plezyng/visualizations/USER_GUIDE.md)
- [Podcast client contract](plezyng/podcasts/CLIENT_CONTRACT.md)
- [Music feature status](plezyng/music/STATUS.md)
- [Comics delivery status](plezyng/comics/DELIVERY.md)
- [IPTV delivery status](plezyng/iptv/DELIVERY.md)
- [Subtitle implementation and qualification](plezyng/subtitles/PLAN.md)
- [Karaoke requirements and plan](plezyng/karaoke/PLAN.md)
- [Audiobook sync plan](AUDIOBOOK_SYNC_PLAN.md)
- [Android automation links](plezyng/android-automation.md)
- [Discord client and PiP feasibility](plezyng/discord/README.md): deferred design, not a delivery commitment

Feature folders also contain architecture, UX, implementation, validation, and dated evidence records. Follow each folder's README or delivery/status document where available; check the capability ledger before treating older handoffs as current.

## Maintainer runbooks and operational status

- [Release channels and current delivery snapshot](maintainers/release-channels.md)
- [Full release build and recovery](maintainers/full-release-build.md)
- [Publishing readiness matrix](maintainers/publishing-readiness.md)
- [Pleazyng relay endpoint inventory](maintainers/pleazyng-relay-endpoints.md): application-visible HTTP routes and WebSocket events
- [Owned provider registrations](maintainers/owned-provider-registrations.md)
- [Localization maintenance](localization/README.md)
- [Branding and asset pipeline](maintainers/branding.md)
- [Security remediation status](security/audit-remediation-2026-11-09.md)
- [aerynOS synchronization](maintainers/aerynos-sync.md) and [qualification](maintainers/aerynos-qualification.md)
- [Samsung Tizen](maintainers/tizen-tv.md) and [LG webOS](maintainers/webos-tv.md) platform records
- [Testing appearance](testing/APPEARANCE.md) and [cross-platform storage and input](testing/CROSS_PLATFORM_STORAGE_AND_INPUT.md)

## Research, historical records, and evidence

The `games/`, `sources/`, `themes/`, `security/`, `localization/`, and `plezyng/` feature folders contain deeper design, source, validation, and evidence records. Many filenames include a date because they preserve what was inspected or qualified at that point in time. Use the newest relevant delivery ledger and verify live external service or store status before acting on dated operational notes.

Plans and handoffs describe intent or work in progress unless a current delivery record and source confirm completion. Release and device evidence applies only to the exact versions, commits, artifacts, and hardware recorded in that evidence.
