# PlezyNG assessment remediation

Baseline: `d130a4e36ba7dfbac1a28bd8b719f472394de89e`.

This ledger records implementation and validation separately. Entries remain open
until their described behavior is implemented; a source change is not device or
release qualification. Changes are committed directly to `main` in small batches.

| Audit ID | Work | Implementation | Validation |
| --- | --- | --- | --- |
| D01, D11 | HLS gateway lifetime and long VOD manifests | Implemented: owner-scoped stable references, buffered-read grace, serialized rewrites; 50,000-reference manifest bound | Large VOD and rolling live regression cases added; execution pending |
| D02-D03 | Recording stop and interrupted-file salvage | Implemented: finish in-flight resources; retain nonempty captures and recover journaled partials | Early EOF and mid-segment deadline regression cases added; execution pending |
| D04-D05 | HLS rendition/map handling | Implemented as self-contained local HLS archives with separate audio, per-segment maps, AES-128 resources, discontinuities and programme timestamps; shared recording playback/deletion/recovery integrated | Archive regression cases added; native player/device execution pending |
| D06 | Bound credential payload caching; avoid caching encryption outputs | Implemented | Regression cases added; execution pending |
| D07 | Native P2P hash capability alignment | Implemented: SHA-256 multihash magnets and native v2 acceptance | Native v2 transfer regression added; execution pending |
| D08 | External stream server reporting | Implemented: matched online items use their server reporting client with offline fallback | Provider/server session acceptance pending |
| D09 | Progressive unified search | Implemented: independent source results, per-server title/people progress, generation/profile guarded publishing and usable results while remaining legs load | Partial publication and A/B/A race regressions added; execution pending |
| D12 | Provider progress outbox rejects its own action kinds | Fixed: valid position/finished/restart/restore/cloud/podcast progress payloads are dispatched by their typed payload and checked against the outbox key | Source trace completed; provider acceptance pending |
| D10 | Translation fallbacks and localized service status | Queued | Pending |
| G01-G02 | Native visualizer delivery and signed catalog activation | Queued | Pending |
| G03 | Live/DVR subtitle capture | Implemented: decoded-route capability gate; two-hour cue history; explicit DVR seeks preserve cues; unexplained live clock rollback clears the old epoch; same-channel server DVR reopen suspends/rebases capture; channel/audio changes invalidate it | Clock/seek/format regression cases added; native route, rollover and server-DVR device execution pending |
| G04 | P2P storage policy for large media | Implemented: per-profile 4/16/64/128/256 GiB choices, 64 GiB default, aggregate lease reservations, known-size checks and 512 MiB free-space reserve; native metadata checks the actual file requirement | Native transfer/large-file, low-space and concurrent-device execution pending |
| G05 | Dedicated karaoke implementation | Queued | Pending |
| G06 | RomM and emulator integration | Queued | Pending |
| G07 | Full theme packages | Implemented v1 native package schema with color, geometry, typography and adaptive/sidebar/bottom flow; bounded import/export, preview, persistence, reset and corrupt-package fallback; TV/automotive retain their navigation contracts | Schema/round-trip cases added; RTL, 200% text, native focus and migration execution pending |
| G08 | Remaining podcast functions | Per-show automatic downloads/retention, restart-safe discovery and opt-in alerts implemented; manual downloads protected; foreground worker integrated with profile/lifecycle/download owners. Archive pagination and transcript search/seek with encrypted offline caching added; opt-in gpodder API v2 sync integrated with HTTPS configuration, unique device IDs, independent revision acknowledgments, deferred active-session changes and explicit progress conflicts. Known-duration RSS episodes supported; HTTP imports remain queued for manual setup | Policy, private archive restart/identity and transcript regression cases added; gpodder protocol and acknowledgment regressions added; worker/native/server/device execution pending |
| G09 | Remaining Steam transport/presentation scope | Queued | Pending |
| G10 | Detached desktop Multiview windows | Queued | Pending |
| M01 | Current release/capability documentation and guards | README and ledger describe the published v3.0.0 release using captured GitHub metadata; current integrated product boundaries corrected; optional independent release-metadata check added | Published tag, source commit, date and actual asset names read from GitHub; source checks pending |
| M02 | Required public platform delivery | Future versioned releases reject omitted webOS/Tizen/Windows ARM64 and verify the assembled platform artifacts before creating a release. Existing eligibility gates retained | Coverage regressions pass. v3.0.0 public webOS repair still requires an eligible packaged artifact and release upload; no matching write capability is exposed in this session |
| M03 | Remove tracked generated package outputs | Removed 16 files / 94,520,572 bytes of generated shared_preferences package output; nested package build directories ignored and source-tree guard added | Current tree checked; history intentionally preserved |
