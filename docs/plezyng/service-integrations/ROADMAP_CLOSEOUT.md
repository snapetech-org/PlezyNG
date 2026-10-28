# Service roadmap closeout

Status: code-level work for the selected handoff and optional connector scope is delivered on branch codex/service-roadmap-closeout-20261028. The closeout branch starts from current main at 0515ab66366da82858cadf9ae5a6af05f504d47b and preserves the service, remote-streaming, IPTV, player, and profile work already merged there.

## Delivery by work package

| Package | Code state | What is still required |
| --- | --- | --- |
| W00–W03 | Delivered | Standard review and runtime qualification of the existing route owners. |
| W04 | Delivered in existing screens | Check accessibility and device behavior for each target. |
| W05 | Official comic/book/game handoffs and approval-gated affiliate link broker delivered | Partner/property approval and credentials for each merchant; no order sync, checkout, or purchased-state mutation is included. |
| W06 | Watchmode server connector, app client, typed TMDB lookup, existing Links-screen rows, safe host policy, rate limit, and bounded memory cache delivered | Active commercial plan, Watchmode key, correct relay deployment, current terms review, and live region/title checks. |
| W07 | Audiobookshelf token refresh and OPDS safe acquisition behavior already delivered | Live supported-version and device qualification. |
| W08 | OverDrive client/gateway code already delivered behind its disabled flag | OverDrive application/sandbox/production/branding approvals. Hoopla has no PlezyNG adapter; its signed API license, library-specific credentials, privacy/display rights, and express written commercial permission must be obtained first. Palace requires a selected library/vendor contract and DRM path. |
| W09–W10 | Connected catalog search, OpenSubsonic/Subsonic, podcasts, and OPML delivered | Provider version, feed, and playback qualification. |
| W11 | iOS Apple MusicKit catalog/playback pilot delivered in the existing Links flow; flag defaults off | Enable MusicKit App Service on the correct Apple App ID, sign the app, build with ENABLE_APPLE_MUSICKIT=true, and qualify on real supported devices/accounts. |
| W12 | Hardcover guarded shelf sync and local Trakt-to-Letterboxd export delivered | Account/file/device qualification. |
| W13 | Exact Steam store links and Fanatical/Awin broker path delivered | Accepted Awin advertiser/publisher relation and current surface approval. Product feeds are optional; no game ownership or installation is inferred. |
| W14 | Decision record complete: Home Assistant, native HDHomeRun, and LCP are no-go for this release | Reopen only with a specific product use case, required license/contract, target hardware, and funded certification where applicable. |
| W15 | Setup, architecture, UX, provider, source, and validation ledgers updated | Record tests/build/live account/device receipts before labeling any provider/platform as supported. |

## Operator activation gates

- **Watchmode:** use a plan and key that permit the intended commercial use. Configure WATCHMODE_API_KEY and set WATCHMODE_COMMERCIAL_APPROVED=true only after terms and deployment approval. The connector stores no images; its six-hour bounded cache is process memory and must be purged when the service is canceled or disabled. The response describes regional service links and does not confirm playback or user subscription.
- **Apple MusicKit:** enable MusicKit App Service for the iOS bundle ID, retain the purpose string in Info.plist, use the matching signed profile, and build with ENABLE_APPLE_MUSICKIT=true. Users authorize access and need an eligible Apple Music subscription for catalog playback.
- **Affiliate links:** configure only the approved network/advertiser pairs and the exact app surfaces the agreement permits. All switches default off. The retailer/network owns conversion records, reversals, and payout; PlezyNG does not mark a purchase or claim revenue from a click.
- **OverDrive:** keep ENABLE_OVERDRIVE=false until the existing application receives its assigned credentials, scopes, environments, IDs, branding, and successful provider qualification.
- **Hoopla:** no adapter is shipped. The API terms require a signed agreement and prohibit deriving income from API/data without prior express written permission. Metadata display, pricing, patron authentication, and library-by-library availability need explicit agreement.

## W14 outcomes

- **Home Assistant — no-go for this release.** REST control is feasible, but no distinct action was selected beyond existing Cast, remote-streaming, server, and deep-link controls. Avoid adding a second long-lived token/entity control surface until a concrete household automation is selected.
- **HDHomeRun — no-go for a native tuner adapter.** Keep the existing Live TV and user-provided M3U routes. A tuner adapter needs a target device, channel/DRM matrix, EPG/DVR rights, and any vendor discovery-license decision.
- **Readium LCP — no-go for protected reader work.** Current EPUB/PDF readers cannot consume a protected LCP license by generic parsing. Proceed only with certification, yearly fees, rights, licensed SDK delivery, secure license storage, offline-expiry handling, and platform qualification.

## Qualification state

No tests, analyzer, iOS build, relay deployment, live provider request, or device qualification was run for this closeout. Existing fixture suites remain unexecuted. Keep new Watchmode and Apple MusicKit paths disabled until the corresponding live setup and checks have passed. No provider, merchant, library, platform, or revenue-share agreement is represented as approved by this code.