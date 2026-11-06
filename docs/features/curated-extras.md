# Curated title extras

Pleazyng attaches a restrained **Extras** browser to movie and show details in
both Libraries and Explore. A title previews at most four admitted items, with
category diversity. See all retains the same quality gates. Find more asks the
configured discovery service for additional catalogue languages and targeted
publisher searches; it never lowers the admission threshold. Empty is valid.
Extras do not create Home recommendations or automatically extend the movie queue.

## Admission and provenance

`ExtrasPolicy` applies independent gates before presentation:

1. An exact canonical movie/show identity must match. Remakes and similarly named
   titles are distinct; ambiguous IMDb/TVDB resolutions return no external result.
2. A native extra must be attached by the active media library. External automatic
   entries need a reviewed work/video association, or both a catalogue association
   and an independently verified publisher. A search hit alone never qualifies.
3. Only bonus-feature categories qualify. Commentary and craft analysis are
   distinguished; third-party analysis requires an explicit preference. Personal
   links are explicitly attached by the user and authorize only that title/link.
4. Broader franchise/season/episode associations require a visible scope label.
   They do not silently become exact-film footage.
5. Availability, region, profile restrictions, source exclusions and spoiler rules
   apply equally to the preview, full browser, cached results and AI search.

The starter registry contains three publisher identities and two Fellowship of
the Ring VFX links embedded by Wētā FX on its own site. Provenance URLs are in
`tools/extras_service/registry.json`. These are external provider links, not a copy
of DVD appendices or a promise that every film has extras. The service checks
current YouTube metadata before returning them. Unknown spoiler status stays
hidden for unwatched titles unless the user enables spoilers. Unknown language
is disclosed rather than guessed.

Native Plex/Jellyfin/Emby extras remain independent of external discovery. Seerr
related-video names, categories, languages and exact work IDs survive catalogue
mapping, but their metadata does not confer publisher verification. Provider
validation happens independently in the helper. Client-submitted trust flags are
not used by that helper.

## Interaction and playback

The browser supports topic text, category chips, source attribution, duration,
language, scope labels, hide, wrong-title, publisher exclusion, personal links,
transcript import/search and separate progress. Conventional search works with
AI disabled. Unavailable discovery leaves native and personal data usable.

| Client | Native extras | External playback | Optional inference |
| --- | --- | --- | --- |
| Android / iOS handheld | Existing media player and download manager | YouTube embed when the WebView works; provider app/browser; QR | Compatible loopback, own server or cloud runtime |
| Windows / macOS | Existing media player and download manager | YouTube embed when the WebView works; provider app/browser; QR | Compatible loopback, own server or cloud runtime |
| Linux / Steam Deck | Existing media player and download manager | Provider app/browser or QR | Compatible loopback, own server or cloud runtime |
| Android TV / Fire TV / tvOS / Tizen / webOS | Existing media player; downloads only where supported | Provider app when available; QR phone handoff | Own server/cloud; conventional search requires no model |

Desktop architecture does not change these shared Dart routes. No platform
package, SDK or supported architecture is removed. Flutter Web is not introduced
as a new application target by this feature.

YouTube uses its official IFrame player. Provider ads and controls remain intact.
There is no raw YouTube stream extraction, media download, caption scraping,
background audio, or ad suppression. The iframe is limited to the selected
video, stops on a changed video identity, and returns to the handoff screen at
completion. `rel=0` is not treated as a guarantee that provider recommendations
are absent. An embed failure offers the provider/QR route. Vimeo personal links
use the provider handoff, including the chosen timestamp.

Opening an external URL records **Opened**, never **Completed**. Only an observed
completion of the selected iframe video or an explicit user action marks it
complete. Provider-app playback cannot report progress back. Native extras use
their own clip identity and existing player timeline; they do not mark the parent
film watched. Device-local extra progress and exclusions are profile scoped;
this feature does not add a new cross-device watch-state sync service.

Native extras can be queued through the existing download flow. Offline title
pages restore only profile-owned completed downloads from saved server/item
references and the existing metadata cache. No cached external video is presented
as offline media, and external discovery is skipped offline.

## Optional AI

Settings expose Off (default), On device, Own server and Cloud. Endpoints use the
OpenAI-compatible `chat/completions` contract. An on-device endpoint must be
loopback; this setting requires an installed compatible runtime, not merely an
NPU. Model execution and CPU/GPU/NPU acceleration belong to that runtime. TVs and
older devices can use a separate server or use conventional search alone.

A configured model receives the query, approved candidate IDs/categories and
permitted transcript passages. It receives no library token, viewing history,
provider description, or arbitrary URL. Cloud mode requires HTTPS. The settings
copy explains that queries and supplied excerpts are sent to the selected runtime.
API tokens are stored through CredentialVault, separately from non-secret settings.

The response can choose only known category enums and exact supplied passage
IDs, start times and verbatim text. Invented IDs, quotes, timestamps, links and
trust fields have no effect. AI cannot admit an excluded item, change its work
association, declare it spoiler-safe, or manufacture a summary. Timeout, invalid
JSON, missing runtime or insufficient evidence falls back to keyword search.
Loopback inference on imported transcripts can work offline.

SRT/VTT imports are bounded to 512 KiB and 500 valid cues. They stay profile local
unless the user has selected remote inference and requests a search. Registry
transcripts require explicit analysis permission and a permission-provenance URL.
YouTube metadata alone never grants transcript/AI permission.

## Profiles, storage and limits

- Plex restricted profiles block external discovery, personal external playback
  and remote AI. Jellyfin/Emby external access requires a known unrestricted user
  policy; parental ratings, folder/tag restrictions and access schedules block it.
  Policy is refreshed by the existing server health probe. Unknown fails closed.
- Profile identity is captured for every session. Late callbacks, settings writes,
  playback and download ownership cannot adopt a newly selected profile.
- Exclusions, personal links, transcripts and progress are per profile. Profile
  removal and logout remove their extras data and encrypted credentials.
- Client metadata cache: 24 query keys / 1 MiB, 12-hour freshness, 29-day maximum
  fallback age. Discovery unavailable may use still-eligible cached metadata.
  Each entry is still checked by current preferences; Clear cache removes it.
- Personal links and progress: 500 each. Imported transcripts: 20 / 512 KiB total,
  256 KiB per stored transcript. Offline references: 100 titles × at most 100 IDs.
- Requests disable redirects, bound responses to 1 MiB and impose deadlines.
  Provider keys stay on the helper; only explicit endpoint credentials go there.
- New copy uses Slang and the existing explicit English-fallback manifest. Other
  locales retain English for these new keys until language review; no fake
  translation-completeness claim is made. RTL and enlarged-text layouts are tested.

## Discovery service

See [service setup](../../tools/extras_service/README.md). It is optional and
self-hosted; this PR does not provision a public hosted endpoint or API accounts.
Configure its URL/token from any title's Extras settings. Without it, native extras,
personal links and imported-transcript search remain available.

The service validates exact TMDB associations, checks YouTube uploader, public
availability, age restrictions and region, then emits versioned records. Missing
keys or an upstream failure returns a bounded partial response. Search results
without independent association go only into an operator review queue, never the
client feed. A reviewed registry update is needed to admit them.

## Verification

Automated coverage lives in `test/extras/`, the affected detail/TV/catalogue/storage
and download suites, and `tools/extras_service/test_service.py`. It covers source
spoofing, wrong work/remake, duplicate uploads, spoilers, permissions, profile
changes, encrypted settings, bounded caches, native download ownership, inference
fabrication, failures, HTTP authentication, quotas and registry validation. Widget
coverage exercises 320-pixel screens at 200% text size, RTL, desktop previews and TV
QR controls. Existing detail-screen and TV-navigation regression suites also run.
`scripts/test_extras_service.py` connects the credential-free service tests to
the existing shared CI guard lane.

Validation on 2026-11-06, with current main `dc13cce55054` merged and the pinned
Flutter 3.47.1 SDK:

- All 377 affected Flutter regression tests pass.
- All 19 discovery-service tests pass, using local fixtures and loopback HTTP.
- Focused Dart analysis reports no issues; generated-file freshness, changed-Dart
  formatting, container image pins, changelog range validation and diff checks pass.
- The repository-wide check script is not green: it reports issues in existing
  formatting, translation cleanup, workflow guards, icons, analyzer/unused code and
  native-format checks. This host also lacks `swift-format`. An isolated checkout
  of main reproduces the same 221 hardcoded-string and 223 localization findings;
  this feature adds neither. Generated-file freshness was rerun successfully after
  code generation. No global check or supported platform is disabled by this PR.

These are source and host-side tests. Physical Android/iOS/Windows/macOS/TV playback,
provider login/age/region behavior, app launch support and vendor-store packages
require the normal device/release qualification; they are not claimed as tested
by a Linux widget runner.

## Provider references

- [YouTube player parameters](https://developers.google.com/youtube/player_parameters)
- [YouTube captions download authorization](https://developers.google.com/youtube/v3/docs/captions/download)
- [YouTube API developer policies](https://developers.google.com/youtube/terms/developer-policies)
- [TMDB movie videos](https://developer.themoviedb.org/reference/movie-videos)
- [Wētā Fellowship VFX](https://www.wetafx.co.nz/videos/the-lord-of-the-rings-the-fellowship-of-the-ring-vfx)
- [Wētā Fellowship VFX breakdown](https://www.wetafx.co.nz/videos/the-lord-of-the-rings-the-fellowship-of-the-ring-vfx-breakdown)
