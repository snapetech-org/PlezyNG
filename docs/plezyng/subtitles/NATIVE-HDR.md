# Native HDR subtitle controls

The app-overlay dialog offers a separate native HDR brightness dialog for MPV.
It requires the running `current-vo` to equal `gpu-next` and reads each option
before offering its control. A configured renderer preference or HDR input
metadata alone does not enable the action. Unsupported options remain absent;
the app never switches the renderer to make the controls available.

Text subtitles and native OSD share `sub-hdr-peak`. Bitmap subtitles use
`image-subs-hdr-peak`. A viewer can enter 10–10000 diffuse-white nits, select the
`sdr` reference (203 nits), or select `video` for bitmap metadata. Each write is
read back; refused or mismatched values report an error. Original values are
preserved verbatim, including defaults from MPV versions newer than this UI.
Restore is explicit and applies only to the selected option.

One dialog owns a player at a time. Media-generation/source changes, disposal,
renderer changes and edits by another controller invalidate the operation.
Changes stay with that player lifetime and are not persisted as a display
calibration or reapplied to another player. These controls do not calibrate the
Flutter caption surface or establish actual screen luminance. Text controls
also affect native messages; the UI discloses this before any change.

The option semantics follow the [MPV stable manual](https://mpv.io/manual/stable/),
`sub-hdr-peak` and `image-subs-hdr-peak`. Source implementation confidence is
moderate. No renderer/device qualification, display measurement, test, build,
analyzer or CI was run. App HDR composition/reference-white calibration and
physical HDR output qualification remain open.
