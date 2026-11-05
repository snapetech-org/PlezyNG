# PlezyNG assessment remediation

Baseline: `d130a4e36ba7dfbac1a28bd8b719f472394de89e`.

This ledger records implementation and validation separately. Entries remain open
until their described behavior is implemented; a source change is not device or
release qualification. Changes are committed directly to `main` in small batches.

| Audit ID | Work | Implementation | Validation |
| --- | --- | --- | --- |
| D01, D11 | HLS gateway lifetime and long VOD manifests | Implemented: owner-scoped stable references, buffered-read grace, serialized rewrites; 50,000-reference manifest bound | Large VOD and rolling live regression cases added; execution pending |
| D02-D05 | Recording stop, salvage and HLS rendition/map handling | In progress | Pending |
| D06 | Bound credential payload caching; avoid caching encryption outputs | Implemented | Regression cases added; execution pending |
| D07 | Native P2P hash capability alignment | Queued | Pending |
| D08 | External stream server reporting | Queued | Pending |
| D09 | Progressive unified search | Queued | Pending |
| D10 | Translation fallbacks and localized service status | Queued | Pending |
| G01-G02 | Native visualizer delivery and signed catalog activation | Queued | Pending |
| G03 | Live/DVR subtitle capture | Queued | Pending |
| G04 | P2P storage policy for large media | Queued | Pending |
| G05 | Dedicated karaoke implementation | Queued | Pending |
| G06 | RomM and emulator integration | Queued | Pending |
| G07 | Full theme packages | Queued | Pending |
| G08 | Remaining podcast functions | Queued | Pending |
| G09 | Remaining Steam transport/presentation scope | Queued | Pending |
| G10 | Detached desktop Multiview windows | Queued | Pending |
| M01 | Current release/capability documentation and guards | Queued | Pending |
| M02 | Required public platform delivery | Queued | Pending |
| M03 | Remove tracked generated package outputs | Queued | Pending |
