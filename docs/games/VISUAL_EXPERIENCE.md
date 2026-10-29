# Steam visual and interaction completion

Status: implemented on [PR #81](https://github.com/snapetech-org/PlezyNG/pull/81), with production-widget render review and portable regression checks. Physical-device acceptance and reviewed translations remain open. Baseline: `3fb6d831a7765310b37b216d47cffde96b53c7d8`.

## Acceptance scope

- [x] Keep the Games library focused on artwork, recent games, favorites, search and computer/installation filters. Move connections and streaming preferences into the existing scoped navigation and settings patterns.
- [x] Provide a clear first-use path: account linking imports the catalog; computer pairing supplies a streaming route. Keep each optional and explain the distinction at the action.
- [x] Replace the details alert with a responsive poster/title/action layout, computer availability rows, retained host tools and on-demand Steam activity.
- [x] Show canonical multi-computer availability without inventing live reachability or entitlement. Support an explicit preferred computer independently of recording a successful play.
- [x] Apply one Steam source treatment to cards, connections, details and the stream state surface. Preserve PlezyNG themes, typography, focus borders and adaptive menus.
- [x] Provide actionable loading, filtered-empty, account-private/stale, connection failure and stream recovery states, with readable status and accessible names.
- [x] Exercise keyboard/controller paths, semantics, narrow layouts, large text, RTL, light/dark/OLED/custom palettes and reduced motion in widget tests. Render actual production widgets with deterministic fixtures for visual inspection.
- [x] Document the implemented flows, branding provenance, localization status and remaining physical-device acceptance. Publish implementation and evidence through the GitHub connector.

## Implemented flows

The Games tab is a normal PlezyNG library: existing poster shape, gutters, focus outline, favorites, recents, search and filters. Connections, streaming preferences and help are labeled app-bar actions. Search/filter recovery clears both kinds of filters. Large text reduces the poster column count as well as increasing caption space. Full game names and availability remain in card semantics and details.

First use explains two independent choices: find/pair a computer for play, or link Steam to import the account catalog. The Connections page refreshes discovery on entry, retains manual add/pair/wake/forget controls, groups account link/refresh/unlink together and provides a return to All games. A linked catalog alone is never shown as a ready receiver. Private, stale and truncated account inventories keep their explanations and recovery entry point.

Game details use a responsive artwork/title/action layout and grouped computer rows. Play, Choose computer, Favorite and Mini-player retain existing action semantics. Desktop actions fit beside the cover; phone and large-text layouts stack, with Play before the longer inventory explanation. Each route shows the observed installation state, source, checked time and preferred state. Its existing menu also exposes permissioned installation, launch, Input and properties actions. The merged Android/iOS controller-only mode appears as Use as controller in the card menu and details, with an explanation that picture/sound remain on the host. Its native code is preserved from `3eccf6ecbc5bd2aa71c5673a77d4b6642f52b347`; SDK/live-host qualification still applies. Activity remains on demand; achievements, news and optional friends context are expandable. Cloud/Families keep their separate authorization and review flows.

Explicit computer preferences use optional version-2 `routeSelections` data. They survive successful play on another host; selecting Automatic overrides remembered successful-route history. Setting a preference does not create a recent play or claim a connection. Deserialization accepts only current game/route identities, and older stores without the optional field retain their previous behavior.

The streaming settings route retains existing keys, defaults and capability gates. Picture/sound, controller and advanced streaming groups separate everyday choices from opt-in Pyrowave/internet settings. Desktop library sharing stays in this page. Stream connection/recovery surfaces identify the game and computer, offer readable status and appropriate actions, and scroll inside small workspace panes. Cancelling during reconnect prevents a replacement receiver or late internet tunnel from being attached.

Pushed pages observe profile/source ownership and controller changes. Profile retirement hides stale content, removes only owned routes/dialogs and retires the corresponding streams. Viewing details starts neither a stream nor an account activity request. Credential, permission, external-navigation and account boundaries remain authoritative.

## Browse-only platforms and secure sign-in

On webOS/Tizen, the library remains a first-class destination. The existing
notice component explains playback availability, card activation opens details,
and favorites, filters, Steam activity and Connections remain interactive.
Playback-specific controls are omitted. Connections explains Companion imports
instead of suggesting unavailable native pairing. A directly opened streaming
settings route explains the receiver requirement.

When secure storage is unavailable, sign-in uses a profile-owned memory grant
with a visible session-only explanation. Cached game metadata remains available
on the next visit; online actions then offer sign-in again. Sign-in owns its
exact dialog and cannot dismiss an unrelated page after a profile change.
Cloud/Families dialogs share scoped navigation ownership.

## Branding boundary

Valve's December 2024 [family brand guidelines](https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/steamworks_docs/english/steam_brandGuidelines.pdf), pages 5–8, require a separate logo licence, unmodified approved artwork, clear space and a 50-pixel logo height. The [Web API terms](https://steamcommunity.com/dev/apiterms) allow factual API attribution and grant branding rights for applicable web pages; they do not establish a general native-client logo licence. The [OpenID documentation](https://partner.steamgames.com/doc/features/auth) explicitly supplies sign-in artwork for third-party websites.

Use consistent, subordinate plain-text Steam source labels in the native UI, alongside familiar action icons. Do not redraw Valve's mark, recolor it through the app accent, copy certification badges, or imply endorsement. Use the official sign-in artwork only in the supported website authentication context, preserving its original pixels and accessible text. Keep the existing profile, credential, host permission and external-navigation boundaries intact.

The browser OpenID landing page embeds Valve's original [sign-in image](https://shared.fastly.steamstatic.com/community_assets/images/steamworks_docs/english/sits_large_border.png), 118 × 51 pixels, SHA-256 `a8ce76bb630ac20d6a7b7b26db0e8464709188a5f234d54eaf8be8c96d605dcc`. No logo was redrawn or recolored. The page explains catalog linking, links only to the validated Valve endpoint, collects no credentials and loads no remote image/script. Its restrictive CSP includes a tested stylesheet hash; no-store, no-referrer and anti-framing headers protect the short-lived sign-in flow. A new native logo licence has not been established.

## Verification record

Local Linux verification on 2026-10-29 against code commit `db4376768ebf95b0c87afe7e0892fb723a346b74` (tree `140515235f462dd4acef360f630ac3e99facfecb`):

- 167 Games and Steam workspace/texture widget and unit tests passed, including multi-computer preference persistence, profile retirement, activity privacy, host permissions, stream ownership and cancellation during reconnect. The final run includes controller-only menu dispatch and microphone refusal.
- The focused visual/card suite exercises actual production widgets, action callbacks, D-pad selection, semantics, filter recovery, 2× RTL text, responsive geometry and existing light/dark/OLED/paper/glacier themes. Capture uses real Roboto and Material Symbols fonts, not the test font.
- Focused Dart analysis passed; Go `go test -race ./...` passed, including OpenID endpoint/state validation, no credential forms or remote assets, and CSP stylesheet validation.
- Localization integrity checks cover 37 locales and 4,407 messages. New copy has explicit English-fallback provenance; it is not claimed as reviewed translation. Removed obsolete keys were removed from regional overrides too.

These are production-widget fixtures and portable tests, not screenshots of live Steam sessions or proof of OS accessibility/device behavior. The following remain build/live acceptance gates: actual screen-reader reading order (VoiceOver, TalkBack, NVDA and Orca), physical TV remotes/controllers, system font scaling and RTL input, real host discovery and large catalogs, native back/predictive-back behavior, OS reduced motion, browser return-to-app and supported-platform packaging. Native receiver, HDR, Valve approval and relay deployment gates in [LIVE_TEST_HANDOFF.md](LIVE_TEST_HANDOFF.md) still apply.

## Reproduce the widget review

Normal tests need no external artwork or screenshot directory:

```sh
flutter test test/games test/multiview/steam_game_workspace_surface_test.dart test/multiview/steam_texture_surface_test.dart
cd server
go test -race ./...
```

To render, set `PLEZY_STEAM_VISUAL_DIR` to an output directory and `PLEZY_STEAM_FONT_DIR` to Flutter's `bin/cache/artifacts/material_fonts`. Optional `PLEZY_STEAM_COVER_DIR` contains `620.jpg`, `220.jpg` and `413150.jpg`; these fixture covers come from the corresponding public Steam `library_600x900.jpg` CDN resources. They are test inputs, not new bundled product assets. The render harness precaches the actual resized image keys and uses deterministic computer/account fixtures.

```sh
PLEZY_STEAM_VISUAL_DIR=build/steam_visuals \
PLEZY_STEAM_FONT_DIR="$FLUTTER_ROOT/bin/cache/artifacts/material_fonts" \
PLEZY_STEAM_COVER_DIR=/path/to/fixture-covers \
flutter test --concurrency=1 test/games/game_visual_experience_test.dart
```

The detail fixture is mounted as the home route; normal in-app navigation also supplies the existing back affordance. RTL captures deliberately retain English fallback copy to stress directional isolation; they are not an Arabic translation review.

## Reviewed screenshots

Eight original production-widget captures and a ninth browse-only catalog capture, with separate code-bound receipts, are in [visuals/](visuals/README.md). They cover desktop dark, phone paper, 2× RTL/custom palette, first use, responsive details, grouped settings and OLED stream recovery. The browse-only capture is bound to `54298205c062ee2bf3c26fffbb9413df2584f1d7`; the original eight retain their earlier source receipt.
