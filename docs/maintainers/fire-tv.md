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
checks `org.snapetech.pleazyng`, the enabled/exported Leanback launcher activity or alias in the compiled manifest, optional touchscreen,
both ARM runtimes, and the bundled Amazon authentication public key. Its receipt
records the APK hash, size, signer fingerprint, version and static qualification.
GitHub attests and publishes both files. This is not playback or IAP qualification.

To produce only the signed Amazon APK from current main, without creating or changing
a release or uploading to a store:

```sh
gh workflow run build.yml -R snapetech-org/PlezyNG --ref main \
  -f action=build -f runner_pool=private -f execution_profile=hybrid \
  -f mode=android-validation -f include_webos_build=false \
  -f include_webos_release=false -f include_tizen_build=false
```

Download the successful run's `android-apk` artifact. In Android validation mode it contains the Amazon APK and receipt; generic Android APKs and the Play bundle are built only in full release mode. Full release mode includes
these files in the draft assets and SHA256SUMS; the coverage gate rejects an
omission even if signing secrets are absent. Never rename an older package to
represent a new build or attach it to a different source revision.

`publish-app-stores.yml`, channel `amazon-appstore`, downloads and checks the
release APK plus its receipt, verifies their matching package/hash/signing evidence, and uploads it through Fastlane to the existing Amazon edit, without
submitting for review. Draft GitHub releases are accepted for this binary upload.
Listing assets, IAP Test submission, export compliance, device targeting and
final store review remain separate console steps. Preserve the draft price.

Capture genuine TV screens at 1920×1080, phone screens in portrait, and tablet
screens in their native orientation. Record source SHA, APK SHA256, device/AVD,
screen dimensions, density and capture command. Emulator captures must say
emulator; Android TV emulation is not Fire OS device qualification. Keep mockups
outside store screenshot slots and label them as interface concepts. Do not
include account credentials, private libraries, or invented playback claims.

## Native captures and labeled previews

After installing the signed candidate on an explicitly selected test AVD/device,
open a public demo library or other screenshot-cleared content. Capture at least
three distinct TV views (for example home, library and details); record emulator
limits separately from Fire OS hardware testing. Use the signed universal APK
on the TV, phone and tablet AVDs so image provenance matches the candidate:

```sh
python3 scripts/capture_app_screenshot.py --serial emulator-5580 \
  --kind android-tv-emulator --apk /path/pleazyng-amazon-firetv.apk \
  --source-sha FULL_APK_SOURCE_SHA --name tv-home --output /path/native-captures
```

The tool checks that Pleazyng is resumed and that the installed base APK hash
matches the supplied file. Capture receipts include source, APK/image hashes,
model, OS SDK, density and dimensions. TV captures must already be 1920×1080;
the tool never stretches phone images into TV screenshots.

For concept review before a native capture is available, render the production
Flutter widgets with the repository's synthetic appearance fixtures:

```sh
PLEAZYNG_PREVIEW_OUTPUT=/path/raw-previews flutter test --no-pub \
  tools/store-assets/preview_capture_test.dart
python3 tools/store-assets/package_previews.py --input /path/raw-previews \
  --output /path/interface-previews --source-sha FULL_SOURCE_SHA
```

The packager requires Pillow. It adds a visible preview label, a contact sheet,
manifest and ZIP. These fixtures do not represent a complete running app session;
they include synthetic movie metadata and test/debug UI. They are not eligible
for store screenshot slots. Keep them separate from native captures.
