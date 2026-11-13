# Trakt production registration and activation

The public client ID identifies an app; it is not a client secret. Do not issue,
embed or request a client secret for Pleazyng user sign-in.

## One registration, two sign-in paths

- TV hardware uses Trakt Device Code. The app requests a code, observes the
  provider's polling interval/expiry, and exchanges it without a client secret.
- Browser-capable devices use S256 PKCE through a relay the user operates. Each
  attempt has a fresh verifier and separate browser-state and poll capabilities.
  That relay exchanges the code and returns tokens to the app. The operator's
  public Worker and retired home relay never handle this Trakt flow.
- Refresh and revoke are direct public-client requests. Disconnect clears the
  local connection before attempting remote revocation; failed revocation must
  not restore a disconnected session. Users can revoke access in Trakt itself.

The production callback is derived by `oauthProxy.redirectURI("trakt")` from
`OAUTH_BASE_URL`: the callback URL belongs to the user's own relay. The
operator's `pleazyng-api.snape.tech` Worker does not serve a Trakt callback. Do
not register a support page as an OAuth callback, and do not replace a real
callback with a custom scheme or localhost address in production.

Trakt's **Development** registration editor permits loopback callbacks only.
Explain that development restriction in the production request. Ask Trakt to
convert the existing app or issue its production registration with the exact
owned HTTPS callback. Do not describe a development loopback registration as
already satisfying production HTTPS requirements.

## Activation checklist

1. Supply Trakt support with the app description, existing repository URL,
   development Client ID, privacy URL and accurate answers to its PKCE,
   client-secret, callback and API-use-policy questions. The development Client
   ID is backed up in the approved provider record and staged as repository
   variable `PLEAZYNG_TRAKT_DEVELOPMENT_CLIENT_ID`; do not use that variable as a
   production-key fallback.
2. Obtain production approval and confirm the exact HTTPS callback. Retain
   privacy/support links, developer ownership, and the separate development
   record if Trakt issues a new production client.
3. Configure the same approved public production Client ID as the app
   `PLEAZYNG_TRAKT_CLIENT_ID` and in the relay the user operates. Configure the app's
   user-operated HTTPS relay in **Settings → Services → User-hosted relay** for
   browser OAuth. Official builds do not embed a relay URL. Never add a
   `client_secret` build input; Trakt TV device-code sign-in exchanges tokens
   directly with Trakt.
4. Deploy the user's tested relay revision, then qualify the exact HTTPS PKCE path,
   state rejection, one-time result retrieval, token refresh, disconnect, TV
   device flow and selected sync features with the production registration.
5. Verify that the public privacy page reflects `PRIVACY.md`, and include
   **Pleazyng uses Trakt but is not endorsed or certified by Trakt** in every
   applicable store description. The app's About screen derives this notice
   from the canonical English translation and generated locale fallback.
6. Record the exact source/build, registration and test results. A revoke
   endpoint returning success does not prove immediate rejection of an existing
   access token; record both observations rather than marking a failed check as
   passed. Keep tokens and live authorization capabilities out of evidence.

Primary references: [PKCE](https://developer.trakt.tv/docs/pkce),
[authentication](https://developer.trakt.tv/docs/authentication-oauth),
[API Use Policy](https://developer.trakt.tv/docs/api-use-policy).
