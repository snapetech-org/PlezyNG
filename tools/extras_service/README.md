# Pleazyng Extras helper

Optional Python 3.11+ standard-library service. It discovers candidates and
verifies their origin and work identity; it does not play or download video and
does not run a language model. The application keeps working without this helper.

## Run

Create a YouTube Data API key and, for catalogue discovery and exact IMDb/TVDB
resolution, a TMDB API read access token. Supply secrets through the deployment's
environment/secret manager, not a committed file:

```sh
export EXTRAS_SERVICE_TOKEN='replace-with-a-random-token-at-least-24-characters'
export YOUTUBE_API_KEY='your-youtube-data-api-key'
export TMDB_ACCESS_TOKEN='your-tmdb-read-access-token'
python3 tools/extras_service/service.py \
  --registry tools/extras_service/registry.json \
  --database /path/to/private/extras-cache.sqlite3
```

Default binding is `127.0.0.1:8792`. Put it behind your existing HTTPS reverse proxy
for other devices. In Pleazyng, open a title → Extras → Settings and enter the
service base URL and matching bearer token. HTTPS is accepted everywhere; explicit
loopback/private IPv4 HTTP is supported for local deployments. Platform network
policies can require HTTPS even on a LAN. Never put a token in the URL.

Docker is optional:

```sh
docker build -t pleazyng-extras tools/extras_service
docker volume create pleazyng-extras-data
docker run --rm --name pleazyng-extras \
  -p 127.0.0.1:8792:8792 \
  -e EXTRAS_SERVICE_TOKEN -e YOUTUBE_API_KEY -e TMDB_ACCESS_TOKEN \
  -v pleazyng-extras-data:/data pleazyng-extras
```

The container runs as UID 10001 and ships the same reviewed registry. To customize
it, bind a validated JSON file read-only at `/app/registry.json` and restart after
changes. The SQLite cache contains public metadata, candidate IDs and quota
counters; keep the volume private. It never stores media-server credentials or
profile watch history.

## Registry review

A publisher record contains a stable YouTube channel ID (`UC…`), name and HTTPS
identity evidence URL. Approval of a channel alone does not admit its videos.

An association contains `videoId`, exact `parents` such as `movie/tmdb:120`, a
bonus-feature `kind`, `reviewedBy` and `evidenceUrl`. Bind `publisherId` to the
verified uploader. Use `scope: franchise|season|episode` and a `scopeLabel` for
broader footage. Do not attach an entire franchise to one film without that label.
`spoilerSafe` defaults false. `contentGroup` optionally deduplicates reviewed
alternate uploads of the same feature. `analysis` requires the client's opt-in.

The bundled Wētā associations were verified from the actual video embeds on the
publisher's film-specific pages; they have no transcript-analysis permission.
Operator-added transcript `passages` require `analysisAllowed: true` and
`transcriptPermissionUrl`, with integer `start`/`end` seconds and bounded text.
There is no caption scraping or inferred permission.

Find more searches at most two approved channels, within the requested title.
Unknown results enter a separate, bounded 24-hour review queue. Inspect it with:

```sh
python3 tools/extras_service/service.py --registry tools/extras_service/registry.json \
  --database /path/to/private/extras-cache.sqlite3 --review-queue
```

`proposedParent` is a search hypothesis, not a verified match. Open the source,
confirm the actual film/version and craft category, obtain provenance, then add a
reviewed association. No queue entry can approve itself. Before deployment:

```sh
python3 tools/extras_service/service.py --registry tools/extras_service/registry.json --validate
python3 -m unittest discover -s tools/extras_service -p 'test_*.py' -v
```

## API and operations

- `GET /health`: liveness only, no key/account/configuration disclosure.
- `POST /v1/discover`: bearer authentication, JSON body, maximum 128 KiB.
- Input: `identities`, `language`, `region`, optional `expand`, `query` and
  `includeAnalysis`. Catalogue hints may be sent by the client but cannot grant
  trust. Only exact IMDb/TVDB lookups resolve aliases; fuzzy title lookup is absent.
- Output: `version: 1`, `entries`, `partial`. Entries include canonical parents,
  kind, scope, publisher, original title, canonical watch URL, language/duration,
  supported provider thumbnail, verification flags and optional permitted passages.
- Unknown input identities return an empty result. Conflicting canonical work IDs
  or ambiguous alias resolutions return empty rather than choosing a match.
- Upstream hosts are fixed to TMDB and Google APIs. Redirects are refused. Upstream
  responses are capped at 1 MiB. No arbitrary client URL is fetched.
- Eight concurrent connections maximum; socket/upstream timeouts bound slow peers.
  Metadata misses are serialized and cached; no unbounded worker spawning.
- Cache: 1,000 entries, 24-hour expiry. Registry hash, locale, region, analysis flag,
  query and search scope are part of its key. Failed partial responses are not
  cached as successful results. Restart after editing the registry.
- `EXTRAS_YOUTUBE_DAILY_UNITS` defaults to 9,000; metadata calls cost one internal
  budget unit and search costs 100. `EXTRAS_SEARCH_DAILY_LIMIT` defaults to 80.
  These are conservative configurable deployment budgets, not a guarantee of the
  quota Google grants your project. TMDB calls have a separate daily cap.
- Search review queue: at most 200 video/work pairs, deleted after 24 hours when
  accessed. The service does not log tokens, query bodies or user identities.
- Invalid/restricted/deleted/provider-missing entries are omitted. API key expiry,
  quota exhaustion and upstream outages set `partial`; library extras are handled
  independently by the client.

No live API keys are included or required for the tests. Deploying the helper and
qualifying real provider availability are separate from the source test suite.
