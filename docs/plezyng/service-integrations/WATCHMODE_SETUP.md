# Watchmode availability setup

Status: the connector is shipped behind a closed-by-default server gate. It returns title-specific movie/TV availability and provider links; it never streams video, checks a viewer's subscription, rents, buys, or records watched state.

## Account and plan

Use a Watchmode commercial plan that includes source availability and app/TV deep links. The official pricing page currently lists Startup at USD $349/month with 40,000 monthly credits, commercial use, 54 countries, and app/episode links. Pricing, quotas, plan entitlements, and terms can change; recheck before purchase. The free Developer tier is non-commercial, covers up to three countries, and does not include usable app/TV deep links.

Watchmode's API terms allow use of non-image data in an owned application but prohibit resale/redistribution. Paid-plan cache rights last only while the subscription is active, and all stored data must be deleted when the account is canceled. This integration requests no images and keeps only a bounded six-hour in-memory cache. The server must be restarted or redeployed when access is revoked so the cache is purged.

## Server configuration

Configure the relay using its deployment secret manager:

```dotenv
WATCHMODE_API_KEY=<commercial-plan-api-key>
WATCHMODE_COMMERCIAL_APPROVED=true
```

Keep the approval value false until the account has an active commercial plan and the app's use is approved under the current terms. If the API is served from a different relay than the default Plezy endpoint, point the app at it at build time:

```sh
--dart-define=PLEAZYNG_WATCHMODE_AVAILABILITY_BASE_URL=https://relay.example
```

For web builds, add the web origin to `COMIC_COMMERCE_ALLOWED_ORIGINS`, which this relay already uses for its exact-origin CORS allowlist. Native requests normally do not send an Origin header. Never add the API key to Dart defines, app settings, URLs, or client logs.

## Runtime behavior

The app requests:

```text
GET /commerce/watchmode-availability?tmdbType=movie|tv&tmdbId=<exact-id>&region=<ISO-3166-1-alpha-2>
```

The detail action obtains a typed TMDB ID from Plex `Guid`, Plex legacy `guid`, or Jellyfin/Emby `ProviderIds`. It never resolves a match from a title string. Region follows the active profile's country preference. The server applies a 5-second upstream timeout, a 30-request/minute per-client limit, at most 50 returned rows, and a six-hour cache capped at 256 title-region keys.

Rows may describe subscription, rental, purchase, free, or TV-provider availability. App and TV deep links are platform-specific and can be absent. The UI only opens HTTPS hosts already present in the app's curated official destination directory; an unknown host is never launched. A provider link may open an app or website, but the provider still controls sign-in, regional eligibility, price, playback, and checkout.

No purchase or playback telemetry is sent by this integration. The exact offer may change after the response is fetched, and an offer row is not verified against a user's account.


## Provider budget and concurrent requests

The relay coalesces simultaneous requests for the same title/region into one
upstream lookup and caches upstream failures for 30 seconds. At most four
distinct lookups run at once. A process-wide bucket admits ten initial lookups
and replenishes one per minute; cache hits and joined requests do not spend it.
Budget exhaustion returns HTTP 429 with Retry-After. A cancelled caller does not
cancel another caller's shared fetch; that work has its own five-second deadline.

This is a per-process bound, not a billing-account quota guarantee. Replicas and
restarts multiply the allowance. Match deployment concurrency and provider-side
hard quotas/alerts to the approved commercial plan before enabling the service.
