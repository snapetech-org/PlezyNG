# Adaptive mobile layout and tvOS actions

The mobile shell can place navigation inside a system vertical bar and report
fold bounds to Flutter. Hosted sheets choose one side of a fold, respect the
bar and keyboard insets, and retain the fork's back and focus handling. Video
routes claim bar ownership before opening playback, so replacement routes do
not flash it back on. Normal phone, desktop and TV shells retain their existing
selection rules. Navigation remains scrollable when its destinations cannot fit.

The native iOS bridge compiles its new system API only with a compatible SDK;
older SDKs report empty geometry and use the normal layout. Headless tests can
exercise geometry, RTL, inset and ownership behavior independently of that SDK.

On tvOS, library trailers play internally. External YouTube trailers are offered
only when the YouTube app is available. Browser-only provider links are hidden.
Failed handoffs display localized feedback; provider links cannot launch local
files, scripts or unrelated OS handlers. Existing Seerr actions and extras
previews remain available.

Validation: 130 focused Flutter tests passed across shell, sheets, catalog,
menus and trailer helpers. Both changed Swift sources passed parsing on Linux.
This is not an Apple SDK build or physical-device qualification; native Apple
validation remains a separate check. The Android playback adaptation is tested
separately against the fork's pinned engine.

## Upstream sources

These authors contributed the linked changes to upstream Plezy. Pleazyng
independently adapted and tested them, without implying direct contribution to
or endorsement of this fork.

- [Fold and vertical-bar layout](https://github.com/edde746/plezy/commit/b4192d6f355921aa9dbdd89b000012e7c4496fa7) by [@v-vincere](https://github.com/v-vincere).
- [Sheet safe areas](https://github.com/edde746/plezy/commit/04ec8506c78dc29b4dfc18f751943fb6ecb89eec) by [@edde746](https://github.com/edde746).
- [tvOS trailer and link actions](https://github.com/edde746/plezy/commit/16d5b404cb14163a776b701265e55b6f66cdfc34) by [@moust4ki](https://github.com/moust4ki).

See the [source ledger](../../UPSTREAM_ATTRIBUTION.md).
