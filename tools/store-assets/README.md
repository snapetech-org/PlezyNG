# Store asset tooling

`preview_capture_test.dart` renders TV, phone, tablet and desktop layouts using
production Flutter widgets and the test suite's synthetic appearance fixtures.
Run it explicitly with `PLEAZYNG_PREVIEW_OUTPUT` set; it is outside normal test
discovery. `package_previews.py` adds visible labels and packages a contact sheet,
manifest and ZIP. These are interface previews, not store screenshots.

For real app screenshots, use `scripts/capture_app_screenshot.py` against an
explicit ADB serial and the exact installed APK. See
[the Fire TV runbook](../../docs/maintainers/fire-tv.md) for both workflows.

`package_captures.py` checks ADB image receipts, rejects mixed builds and duplicate
frames, validates store dimensions/counts, and exports RGB PNGs without resizing,
cropping or compositing. It removes alpha only after checking every pixel is
opaque. The exported sets include provenance and a ZIP for manual console upload.

The opt-in harness also renders subtitle styling sheets and light/dark/OLED
appearance variants. These use production widgets with simulated state, not a
native video decoder. Prefer a visible video frame and controls captured from the running packaged
app; if unavailable, retain the rendering method and capture limit in the manifest. Blank player
fixtures are layout tests and must not be presented as playback screenshots.

To render only the appearance variants, add `--name
'preview.*(appearance-|subtitle-style-)'` to the Flutter command. Keep new renders
in a separate output directory so earlier manifests retain their original source
revision. The contact sheet includes every supplied scene.

`player_mockup.dart` composes production player controls over an attributed
Caminandes still. It uses simulated
state and never starts a decoder. Run only these with `--name 'preview.*mockup'`;
inspect both the video area and control legibility before updating README assets.
The fixture's [attribution and image license](fixtures/README.md) travel with the
renders. Native playback capture failures are recorded separately, never hidden
by describing a mockup as a running video.

The packager rejects player images whose central video area is empty, and carries
the sample-frame attribution and mockup metadata into generated packs.

For clean README gallery exports, use `package_previews.py --presentation`.
This omits visible footer labels while preserving source, rendering method, image
hashes and credits in the accompanying files.
