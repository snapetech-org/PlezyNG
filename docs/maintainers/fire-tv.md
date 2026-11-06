# Amazon Fire TV / Stick release

The signed universal `pleazyng-amazon-firetv.apk` is required for every versioned
release, alongside `pleazyng-amazon-firetv-provenance.json`. It includes ARMv7 and
ARM64 for compatible Fire OS TVs and Sticks. This Android APK does not establish
compatibility with Amazon devices running a different operating system.

The release job uses the existing Android signing secrets and fails if they are
missing or incomplete. It selects the Amazon OpenIAP dependency and compiles
`SUPPORTER_MODE=iap`, `AMAZON_STORE=true`, and
`LIFETIME_UNLOCK_PRODUCT_ID=pleazyng_lifetime_unlock`. The owner's Amazon draft
SKU has that identifier, updated name/description/artwork, and the retained USD
$2.99 base price. Apple and Google store records must be reconciled separately.

`verify_firetv_apk.py` verifies the APK signature, rejects Android debug signing,
checks `org.snapetech.pleazyng`, the Leanback launcher, optional touchscreen,
both ARM runtimes, and the bundled Amazon authentication public key. Its receipt
records the APK hash, size, signer fingerprint, version and static qualification.
GitHub attests and publishes both files. This is not playback or IAP qualification.

To produce only Android artifacts from current main, without creating or changing
a release or uploading to a store:

```sh
gh workflow run build.yml -R snapetech-org/PlezyNG --ref main \
  -f action=build -f runner_pool=private -f execution_profile=hybrid \
  -f mode=android-validation -f include_webos_build=false \
  -f include_webos_release=false -f include_tizen_build=false
```

Download the successful run's `android-apk` artifact. Full release mode includes
these files in the draft assets and SHA256SUMS; the coverage gate rejects an
omission even if signing secrets are absent. Never rename an older package to
represent a new build or attach it to a different source revision.

`publish-app-stores.yml`, channel `amazon-appstore`, downloads and checks the
release APK and uploads it through Fastlane to the existing Amazon edit, without
submitting for review. Draft GitHub releases are accepted for this binary upload.
Listing assets, IAP Test submission, export compliance, device targeting and
final store review remain separate console steps. Preserve the draft price.

Capture genuine TV screens at 1920×1080, phone screens in portrait, and tablet
screens in their native orientation. Record source SHA, APK SHA256, device/AVD,
screen dimensions, density and capture command. Emulator captures must say
emulator; Android TV emulation is not Fire OS device qualification. Keep mockups
outside store screenshot slots and label them as interface concepts. Do not
include account credentials, private libraries, or invented playback claims.
