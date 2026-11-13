# Microsoft Store preparation

Company enrollment awaits Microsoft business/employment verification. Do not invent package, publisher or product identities before Partner Center assigns them.

## Billing and build separation

`in_app_purchase_msstore` is pinned to version 0.1.0 and its published SHA256 in `pubspec.lock`. It is a third-party BSD-3-Clause Flutter adapter over Microsoft's `Windows.Services.Store.StoreContext`, not a Microsoft/Flutter-maintained plugin. Its source and native build configuration were inspected before integration. Native compilation and live store behavior must still be qualified for Pleazyng.

The adapter uses the existing seven-day full-feature trial. The only accepted purchase product is a durable, non-subscription add-on at the selected US base price of $2.99. Prices displayed to the customer come from the Store. Set the add-on's product ID in Partner Center to `pleazyng_lifetime_unlock` where that field is offered; the actual purchase API and build define use its separate assigned 12-character Store ID.

Only a complete online licence collection can grant or revoke ownership. Cache-only, failed, incomplete and malformed reads preserve the app's cached entitlement. A purchase-stream success does not grant access until matching online ownership is verified. The raw Microsoft add-on `IsActive` flag is not sufficient; expiry is checked. No consumable or subscription path is enabled.

After enrollment, reserve Pleazyng and copy these repository variables exactly:

- `MSSTORE_PACKAGE_NAME`
- `MSSTORE_PUBLISHER`
- `MSSTORE_PUBLISHER_DISPLAY_NAME`
- `MSSTORE_LIFETIME_PRODUCT_ID` (assigned 12-character add-on Store ID)

When all three package-identity variables and the lifetime product ID are configured, the Windows jobs first upload their ordinary unlocked direct-download payloads. Then `scripts/build_microsoft_store.py --arch x64` or `--arch arm64` builds a separate native Store payload with `SUPPORTER_MODE=iap`, `MSSTORE_BUILD=true`, and the assigned `LIFETIME_UNLOCK_PRODUCT_ID`. Incomplete variable configuration skips the optional Store lane and keeps the ordinary direct-download artifacts independent. Missing or invalid product configuration fails before Flutter starts once the lane is enabled. Direct updater defines are omitted. Use a native Windows worker and native Python/Flutter for each architecture.

The builder writes a receipt hashing the executable, AOT and Store plugin. `windows/build-msix.ps1` requires the matching receipt/product/architecture and validates all hashes before packaging. It consumes both separate Store payloads, never the unlocked installer payload. `-EmitManifestOnly` remains available for inspecting identities without assembling a Store package.

## Qualification and publication

Remaining work after Microsoft enables the workspace:

1. Create the durable add-on and configure its US $2.99 price, availability and listing.
2. Build the exact intended source on native x64 and arm64 workers. Check generated MSIX identities and payload receipts; install the package through the supported Store test route.
3. Validate the real Store account, localized price and payment dialog; complete an authorized test purchase and check restart, restore, refund/removed licence, offline cached ownership and fresh offline non-ownership.
4. Confirm the trial lasts seven days and does not restart after an ordinary app restart. Check keyboard/gamepad access to purchase, restore and the expired-trial screen.
5. Submit the qualified bundle with actual Windows screenshots, privacy/declarations, review instructions and complete payout/tax requirements. Partner Center review and submission credentials remain separate from building an MSIX. No automatic Store review submission is claimed.

Microsoft's Store APIs require a packaged app associated with the Partner Center identity. Unpackaged direct downloads and elevated processes cannot be used to prove billing. The new payload receipt explicitly retains `store_purchase_verified=false`; local tests and successful compilation are not a payment qualification.

Sources: [Microsoft purchase/trial APIs](https://learn.microsoft.com/en-us/windows/uwp/monetize/in-app-purchases-and-trials), [plugin source and limitations](https://github.com/trueframedigital/in_app_purchase_msstore).
