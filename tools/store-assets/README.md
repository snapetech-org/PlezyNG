# Store asset tooling

`preview_capture_test.dart` renders TV, phone, tablet and desktop layouts using
production Flutter widgets and the test suite's synthetic appearance fixtures.
Run it explicitly with `PLEAZYNG_PREVIEW_OUTPUT` set; it is outside normal test
discovery. `package_previews.py` adds visible labels and packages a contact sheet,
manifest and ZIP. These are interface previews, not store screenshots.

For real app screenshots, use `scripts/capture_app_screenshot.py` against an
explicit ADB serial and the exact installed APK. See
[the Fire TV runbook](../../docs/maintainers/fire-tv.md) for both workflows.
