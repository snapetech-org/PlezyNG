# User-hosted relays and token-safe OAuth — 2026-11-13

This review changes the previous hosting model. The 2026-11-06 edge review and
2026-11-12 home-hosting review are historical records; their statements about
the operator-hosted Go relay are no longer current after the retirement
recorded in `snape.local/pleazyng-relay/retirement-20261113.json`.

## Required boundary

- Official builds contain no operator-hosted relay URL. Relay-backed features
  remain disabled until the user configures an HTTPS endpoint they operate in
  **Settings → Services → User-hosted relay**.
- The first-party Cloudflare Worker supports only MAL authorization-code
  handoff. It sees the signed state and one-use authorization code, but never
  receives the PKCE verifier, access token or refresh token.
- The app generates the verifier locally, opens MAL directly, retrieves the
  code from the broker and exchanges it directly with MAL. Token refresh is
  also direct to MAL.
- Trakt TV Device Code exchanges tokens directly with Trakt. AniList, Trakt
  browser OAuth, Steam account capabilities, uploads, commerce lookups, music
  control relaying and Steam streaming require a relay URL explicitly set by
  the user.
- The home Go relay and its dedicated Tunnel connector are stopped and
  disabled. Caddy has no origin route for the relay. The whole-host Worker
  Route owns `pleazyng-api.snape.tech`; every other path returns 404 and is
  never forwarded to the home origin.

## Controls retained

The Worker validates the fixed MAL origin, callback path and client ID before
opening the browser flow. The app holds a 32-byte cryptographically random
verifier in memory and rejects unexpected authorization URLs. Browser state
and device polling capabilities are separately signed, role-bound and
single-use. Callback and poll results contain only a code or sanitized error.
Sessions expire after ten minutes; callback replay, invalid capabilities and
legacy token-bearing results are rejected. Worker logs and traces are disabled,
and responses are non-cacheable with browser security headers.

Cloudflare's country block is applied to the API host except for the exact MAL
start, result-poll and callback routes. All other paths on the host, including
the old Go APIs and WebSockets, return 404. The old proxied Tunnel CNAME is
retained only because the Worker Route requires a proxied DNS record; its
connector is disabled and its config is a 404-only catch-all.

## Residual risks

MAL currently requires PKCE `plain`. The app keeps the verifier locally, but
the authorization request includes the same value as the challenge; an
observer able to capture both the callback code and browser authorization URL
could redeem the code. The first-party Worker sees only the code, not the
challenge, and cannot exchange it. Move to `S256` if MAL adds support.

Cloudflare temporarily stores the one-use authorization code in a Durable
Object. Deleting it at delivery/expiry does not promise immediate physical
erasure from provider recovery systems. Cloudflare administrators remain
within the trusted boundary for this code-only handoff. A user-selected relay
can receive the data and tokens sent to it; the app warns users to configure
only a server they operate and trust.

These controls reduce operator access to account credentials; they do not
guarantee provider availability or protect an already-compromised client.
This source and routing review is not an independent penetration test. The
repository's automated tests were updated for the new contract but were not run
in this change.
