# Store review access

Store pricing remains a seven-day full-feature trial followed by one USD $2.99
non-consumable lifetime unlock, wherever the distribution platform supports
billing. Free package channels remain free. Localized prices come from the store.

Android store builds support an explicitly disclosed **Store review access**
action in Settings > Pleazyng lifetime access and on the expired-trial screen.
It accepts an Ed25519-signed grant scoped to `org.snapetech.pleazyng` and the
`store-review` purpose. A valid grant enables all features until its expiration,
independent of the seven-day trial. It does not create a purchase, modify store
history, reset a trial, or write the lifetime ownership cache. The action is
absent when the public verification key is unconfigured.

Apple builds cannot redeem or load these grants. Validate Apple's native
StoreKit review/sandbox purchase and restore flow instead; do not promise
review access until that validation passes and paid agreements are active.

## Issuer setup

The Android store build steps use repository variable `REVIEW_ACCESS_PUBLIC_KEY`.
Only this public key is compiled into the app. Provision once on an authenticated
maintainer machine with Python `cryptography` installed:

```sh
python3 scripts/provision_store_review_access.py --output /private/task/path/review-code.txt
```

The command refuses to rotate an existing configured key, stores the issuing
key in GitHub secret `REVIEW_ACCESS_SIGNING_KEY`, stores the generated review
code in `STORE_REVIEW_ACCESS_CODE`, and creates an owner-only mode-0600 handoff
file. Never commit or log that file or either secret. The generated grant lasts
365 days. Renew it before expiration using the same issuer key; rotating the
public key would invalidate already distributed grants in new builds.

The optional `--emit-code` is for a trusted in-memory console-entry consumer,
never for CI logs or terminal display. No private signing key is printed.

## Google Play instructions

Provide the official public Jellyfin evaluation server as the media account:
`https://demo.jellyfin.org/stable`, user `demo`, empty password. Verify that the
demo is operational before each submission. Describe that it supplies sample
media, not customer accounts or hosted media provided by Pleazyng.

In App access, provide the private signed code and explain the two entry points
above. Google can activate it without a purchase, personal payment method,
account creation, or reliance on a trial. Disclose this review-only access
mechanism; it must never be a hidden behavior or triggered by reviewer detection.

Before sending a build for review, confirm its embedded public key matches the
configured key, redeem the supplied grant in that actual signed build with an
expired trial, restart, and check full access and purchase/restore availability.
Unit tests or secret-name presence alone do not complete this device validation.
