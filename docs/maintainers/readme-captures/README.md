# Dark-mode native captures for the README

Six actual signed-app captures: phone welcome/library/details, tablet-layout
library/details, and the Android player settings page. Each PNG has a sibling
JSON receipt verifying the installed APK and image hashes. Images are unchanged
ADB PNGs; no recoloring, cropping, compositing or brightness manipulation.

Source `28486bba2bb42d25bc17d127ca73c5ccc27ba1a3`, version 3.0.0, APK SHA256
`cb02bfbce6fd5b940de104ddcee52c9f34a0e422555ec2f06c8bce336926622a`.
The [signature and attestation evidence](../store-listing-assets/capture-build-evidence/)
identifies the build. This candidate predates the later review-access/NPU work.

The task AVD is `PleazyngGalleryDark`, Android 36 Google APIs x86_64, Pixel 7 base
profile. Android system night mode was enabled. Phone display override:
1080×1920 at density 420. For tablet layouts the same AVD was explicitly
reconfigured to 2560×1600 at density 320; this is an emulator viewport test,
not a separate physical tablet. Public Jellyfin demo content was used.

## Playback capture finding

Playback was attempted with the candidate's mpv and ExoPlayer backends. On this
emulator the control layer and advancing timeline appeared above the prior
movie-details surface rather than a usable video frame. ExoPlayer hardware
and software decoding were tried, as were SwiftShader Vulkan and indirect GLES
emulator configurations. Those images were rejected from the gallery. No claim
of successful video output, physical Fire TV playback or IAP validation is made.
The implementation/release session received the finding and retained diagnostic
paths; no application playback fix was made in this documentation change.

The README uses separately [labeled player mockups](../player-mockups/) with an
attributed film still instead. Existing dark/OLED appearance and subtitle panels
remain widget previews. A missing demo cast photo is the app's visible fallback,
not a loading spinner or a supplied portrait.

The transient Android System UI startup stall was dismissed before capturing;
none of these selected PNGs contains that dialog. All selected images were
reviewed at their README display sizes as well as checked against their receipts.

Visual QA also rejected the older desktop home/detail fixture renders from the
README because their artwork was represented by placeholders. Those historical
fixture assets are retained separately with that limitation documented.
