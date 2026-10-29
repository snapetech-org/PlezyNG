# Steam visual and interaction completion

Status: implementation in progress on PR #81. Baseline: `3fb6d831a7765310b37b216d47cffde96b53c7d8`.

## Acceptance scope

- [ ] Keep the Games library focused on artwork, recent games, favorites, search and computer/installation filters. Move connections and streaming preferences into the existing scoped navigation and settings patterns.
- [ ] Provide a clear first-use path: account linking imports the catalog; computer pairing supplies a streaming route. Keep each optional and explain the distinction at the action.
- [ ] Replace the details alert with a responsive poster/title/action layout, computer availability rows, retained host tools and on-demand Steam activity.
- [ ] Show canonical multi-computer availability without inventing live reachability or entitlement. Support an explicit preferred computer independently of recording a successful play.
- [ ] Apply one Steam source treatment to cards, connections, details and the stream state surface. Preserve PlezyNG themes, typography, focus borders and adaptive menus.
- [ ] Provide actionable loading, filtered-empty, account-private/stale, connection failure and stream recovery states, with readable status and accessible names.
- [ ] Verify keyboard/controller paths, screen-reader semantics, narrow layouts, large text, RTL, light/dark/OLED/custom palettes and reduced motion. Render actual production widgets with deterministic fixtures for visual inspection.
- [ ] Document the implemented flows, branding provenance, localization status and remaining physical-device acceptance. Commit and publish in checkpoints through the GitHub connector.

## Branding boundary

Valve's December 2024 [family brand guidelines](https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/steamworks_docs/english/steam_brandGuidelines.pdf), pages 5–8, require a separate logo licence, unmodified approved artwork, clear space and a 50-pixel logo height. The [Web API terms](https://steamcommunity.com/dev/apiterms) allow factual API attribution and grant branding rights for applicable web pages; they do not establish a general native-client logo licence. The [OpenID documentation](https://partner.steamgames.com/doc/features/auth) explicitly supplies sign-in artwork for third-party websites.

Use consistent, subordinate plain-text Steam source labels in the native UI, alongside familiar action icons. Do not redraw Valve's mark, recolor it through the app accent, copy certification badges, or imply endorsement. Use the official sign-in artwork only in the supported website authentication context, preserving its original pixels and accessible text. Keep the existing profile, credential, host permission and external-navigation boundaries intact.

## Verification record

Pending implementation and actual widget renders. Widget evidence will be distinguished from physical TV/mobile/desktop and live Steam validation; translations will retain explicit provenance.
