# Public-library services and OverDrive activation

OverDrive/Libby native integration ships **Coming soon**. `LendingService.overdriveEnabled` defaults to `false` and blocks native authorization, discovery and circulation requests. Users can still save their library's official site and open Libby normally. The app contains the catalogue, loans/holds, availability, checkout, hold placement/pickup, hold-email editing, suspension/resumption, cancellation/early-return and fulfillment flows. The companion token gateway is in `tools/lending_gateway/`; it is not deployed by building the client.

Native release activation is a deliberate rebuild with `--dart-define=ENABLE_OVERDRIVE=true`, after the approved developer integration has passed its assigned sandbox and branding checks. The flag is not a claim of provider approval or live-service certification. No credentials have been embedded or deployed.

The Title Link path is a separate, approved-only handoff. It searches one title in OverDrive's global catalog and returns the official Libby share URL. It does not expose a patron's library collection, active loans or holds, and does not perform checkout, early return or fulfillment inside Pleazyng. The title URL is handed to the operating system, which can open Libby when installed or use the device's browser when no app handles the link. A browser handoff depends on that browser being supported by Libby; for devices that cannot run Libby web, users can continue on a supported device. Pleazyng does not receive Libby login credentials or synchronize loan state.

## Which credentials belong where

| Service | Maintainer | Individual user |
| --- | --- | --- |
| OverDrive / Libby native circulation | Approved application key/secret, assigned website/library IDs and allowed scopes/environments | Library-card authorization in OverDrive's hosted QR/device flow. The app stores the resulting encrypted patron/refresh tokens. |
| OverDrive Title Link | Separate approved client key/secret with the `SRCH` scope in the gateway's `title_link` section | Signs in and manages loans in Libby after following the share link. |
| Hoopla | Integration agreement and developer credentials from its developer program | Uses Hoopla's own app/site sign-in. Native patron authorization is not enabled without an approved supported flow. |
| Open Library | No app key for public catalogue search | Signs into Open Library/Internet Archive on its own site for borrowing/reading where offered. |
| Palace, cloudLibrary, BorrowBox, Cantook, Onleihe or another library | Provider-specific agreement/API if native circulation is desired | Saved official library/service link; hosted account and reader flow. |

These services are not interchangeable OAuth providers. SCIM provisions accounts; it is not a consumer sign-in mechanism. Do not collect library-card PINs in a generic PlezyNG password form or scrape private Libby/Hoopla endpoints. Native Open Library search is available; actual availability/borrowing stays on its official site. Provider handoffs preserve that service's lending/DRM rules rather than importing a loan as a perpetual owned file.

The current OverDrive application for Discovery/Circulation was denied because no existing customer relationship or partner library was supplied. The response suggested reapplying for Title Link. For this consumer handoff, request the **Title Link API** specifically; its client-authentication documentation says Title Link often has separate credentials from Discovery, and it needs the `SRCH` scope. Reapply through [OverDrive request access](https://developer.overdrive.com/request-access). This implementation does not submit an application or contact OverDrive.

## Title Link handoff setup

After OverDrive approves Title Link and issues its separate client key/secret, put those values in `title_link.client_id` and `title_link.client_secret` in the private gateway configuration. Leave both blank before approval; the gateway returns unavailable when the credentials are absent. Keep them server-side. The gateway obtains and caches a client-credentials token from OverDrive, verifies the `SRCH` scope, and calls the official `/v1/share/find` endpoint. The Title Link client key and secret stay exclusively at the gateway. The app only calls the Pleazyng gateway.

After the gateway URL and approved credentials are configured, build with `--dart-define=LENDING_GATEWAY_URL=https://your-gateway.example.org --dart-define=ENABLE_OVERDRIVE_TITLE_LINK=true`. That deliberate flag exposes a Libby / OverDrive search option in Public libraries. Users search one title or digital ISBN, optionally limit the result to an ebook or audiobook, and follow the official share link. OverDrive returns one matching title rather than a paged catalogue. Libby controls sign-in, borrowing, holds, returns and fulfillment after handoff. Pleazyng cannot observe or control those actions through Title Link.

## Gateway configuration

Copy `tools/lending_gateway/config.example.json` to a private file outside the checkout and keep it mode 0600, owned by the unprivileged service account. For a Title Link-only approval, set the OverDrive-issued credentials in `title_link.client_id` and `title_link.client_secret`; leave the top-level native credentials and `libraries` empty. The Title Link gateway does not need patron-auth signing keys or library IDs. Native patron routes return 503 until their own approved credentials, a random signing key of at least 32 characters, and explicit library configuration are supplied. The signing key binds native refresh proofs to the selected library/environment; rotating it requires users to authorize again. Run a single gateway process behind your HTTPS reverse proxy:

```sh
PLEZY_LENDING_CONFIG=/etc/plezy-lending/config.json python3 tools/lending_gateway/server.py
```

The server binds only `127.0.0.1:8788` (override `PORT` locally if necessary). Configure TLS and a real hostname at the proxy, preserve `Host`, overwrite `X-Real-IP` with the actual remote address, cap request bodies/connections, and disable access/query logging for these routes. A sample Nginx location is included. Do not expose the Python listener to the public network or log callback URLs, token bodies, authorization headers or config files. Supervise the process with your existing service manager; do not run it as root.

- The gateway exposes only explicitly configured libraries, never arbitrary caller-selected website IDs.
- Authorization uses a random request ID, a secret callback capability, a ten-minute lifetime and S256 PKCE binding between the app and gateway.
- Polling consumes a provider code before exchange, so replay cannot exchange it twice. Refresh uses a signed library-bound proof. OverDrive developer secrets stay exclusively at the gateway.
- Native patron-token exchange uses the approved OverDrive patron endpoint. The separate Title Link route is disabled unless its own client key/secret are configured; it requests a client-credentials token, requires `SRCH`, validates the returned `link.overdrive.com/share` URL and refuses redirects.
- The upstream exchange uses official HTTPS endpoints and refuses redirects. Responses are no-store; origins/CORS are rejected. Rate, body and pending-session limits are enforced.
- Pending sessions are memory-only and disappear on restart. A single process is required; multiple replicas need a shared atomic session store before deployment. Existing encrypted refresh tokens keep working across restarts while the signing key is stable.
- The callback query parameter defaults to `code`; OverDrive's public QR guide describes the returned code without naming the parameter. Confirm the actual approved integration and set `code_parameter` accordingly before activation.

## Activation sequence

1. Put the assigned integration credentials and website IDs in private gateway configuration. Set `integration: true`; configure `circulation` only if that scope is approved. Complete the provider's callback/display-name setup and confirm the logo/partner-branding terms.
2. Run `python3 -m unittest discover -s tools/lending_gateway -p 'test_*.py' -v`. Build a private client with `--dart-define=ENABLE_OVERDRIVE=true`.
3. In Files and books → Public libraries → Libby / OverDrive, open app registration, enter the gateway's HTTPS origin and select an allowed library. Save it, then authorize using the hosted screen. Users enter personal card/PIN details only there.
4. Validate fresh sign-in, cancellation, expiry, refresh rotation, revoked-card recovery and profile changes. Confirm the exact patron collection (including Advantage), paging, availability and cover metadata using the assigned sandbox.
5. Exercise checkout, holds including ready-for-pickup, suspension/resumption, email updates, cancellation, supported early return, due dates and download/reader redirects. A loan never downloads into owned-file storage. Kindle/service-specific fulfillment remains provider-owned.
6. Verify physical platform/browser accessibility and branding. Replace integration libraries with approved production IDs, keep production credentials server-side, and rebuild the release with the flag. Follow the repository's normal manual release process; do not merely distribute a developer-key-containing client.

Returning a loan or cancelling a hold always requires a user confirmation. Availability is fetched explicitly before deciding between checkout and hold. Only provider-advertised early-return/remove/suspend actions are offered; eligibility and actual DRM formats remain provider-controlled. The implementation does not decrypt licensed content or reverse-engineer Libby's private APIs. Hoopla and regional services currently use official handoffs; their native circulation cannot truthfully be enabled solely with an OverDrive key.

## Official API references

- [QR/device authentication](https://developer.overdrive.com/api-docs/authentication/qr-code-authentication)
- [Patron information and personal collection links](https://developer.overdrive.com/api-docs/circulation-apis/patron-information)
- [Catalogue search](https://developer.overdrive.com/api-docs/discovery-apis/search)
- [Title Link API](https://developer.overdrive.com/api-docs/other-apis/title-link)
- [Client authentication](https://developer.overdrive.com/api-docs/authentication/client-authentication)
- [Checkouts and fulfillment](https://developer.overdrive.com/api-docs/circulation-apis/checkouts)
- [Holds and suspension](https://developer.overdrive.com/api-docs/circulation-apis/holds)
- [Open Library API guidance](https://openlibrary.org/developers/api)
- [Official Libby assets](https://resources.overdrive.com/library/marketing-outreach-community/libby-website-assets/)
