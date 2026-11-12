# Reviewed upstream synchronization — 2026-11-09

Reviewed every commit after `1fc16b6c11b2f154c80484f95ba08074d2433e41`
through upstream Plezy `738e18fdc552ace910dedabf6e689ab74e1dae58` (2.26).
The 64 records below have explicit dispositions: 26 independently adapted,
24 already covered, eight retained fork implementations/pins and six excluded.
The three native-dependent changes are now implemented and packaged.

Pleazyng keeps its name and logo. The upstream trademark-policy file and its
README policy changes are excluded. The code LICENSE blob is identical between
the reviewed upstream snapshot and the fork: `f288702d2fa16d3cdf0035b15a9fcbc552cd88e7`.
This is a source comparison, not a claim about unrelated third-party services.

## Native compatibility integration

The fork preserves its normal FEL/HDR/NPU components and checksum/capability
locks. Android AAR `82ace919fd97` and Apple Libmpv `93fdd133cea1` include the
three integrations; app controls follow these packaged implementations.

- Amlogic transparent letterboxing excludes Amazon devices and retains opaque
  margins on other hardware.
- Apple GLSL and ambient lighting use the AVFoundation libplacebo/MoltenVK
  stage, including stretched output. The runtime's documented Dolby Vision,
  Core Image and composited-frame exclusions remain explicit.
- Android TV subtitle delay is enabled with early queueing and per-frame
  repetition, preserving unchanged subtitle content without disturbing cadence.

[Android build](https://github.com/snapetech-org/mpv-build/actions/runs/42728730494),
[Apple builds](https://github.com/snapetech-org/mpv-build/actions/runs/42731121521)
and [Apple assembly/consumer links](https://github.com/snapetech-org/mpv-build/actions/runs/42735647569)
passed. Real Mac M4 headless playback and Android TV API-36 JNI/playback checks
also passed. The Mac initialization deadlock found by that playback probe was
fixed before promotion. Physical TV black levels, scanout timing and heavy
shader performance remain hardware-specific qualification.

The consolidated upstream-maintainer anime feed is also intentionally declined:
the fork keeps its independent source feeds and cache format. Upstream version,
purchase-copy and publisher changes retain the fork's own identities/contracts.
Distribution commands retain the fork’s own package identity and maintained
instructions.

## Validation and limits

Focused validation passed: remote/focus regressions (13), discover/display
regressions (124), artwork/room tests (41 passed, one skipped), theme tests (46),
zoom suites, profile-resume tests (67), certificate/domain tests (10), Android
playback regressions (89), adaptive UI/trailer tests (130), and AppImage contract
tests (eight). These are separate suites, with overlapping coverage.

Android native compilation passed against the fork's pinned engine; eight
Gradle tests covered hold lifecycle and stale-player ownership. The native
source was verified against `0bc258ca3`. Renderer policy tests passed separately.
The real Linux descriptor worker/proxy fault tests passed. The real pinned
AppImage packager produced a matching update pair and accepted a legacy image
through the explicit historical-artifact path. Windows engine +2's published
SHA-256 and its single source-commit delta were verified; its ABI stamp remains
unchanged. Changed Swift production and speed-test sources passed parsing.

These results qualify the stated source/unit/packaging paths. Physical HDR/DV,
Apple SDK/device execution, Windows desktop execution and a new all-platform
release are separate qualification work. A fresh cross-platform CI run was
started; its result is tracked separately from these local results.

## Per-commit dispositions

The contributors below made these contributions to **upstream Plezy**.
Pleazyng independently adapted or verified the stated scope. Retained, excluded
and planned records are reviewed sources; they do not imply participation in,
or endorsement of this fork, or claim unfinished behavior has shipped.

| Upstream commit | Contributor | Subject | Disposition | Fork evidence |
| --- | --- | --- | --- | --- |
| [43ae7da7b6](https://github.com/edde746/plezy/commit/43ae7da7b6ab7fa526cb14063dfb7f1427dc6a4d) | [@K1ngfish3r](https://github.com/K1ngfish3r) | docs: update aerynOS installation instruction (#2864) | retained | Retain the fork’s separately maintained package identity and distribution instructions instead of copying the upstream package command verbatim. |
| [fa7fadece1](https://github.com/edde746/plezy/commit/fa7fadece1ab87d07a144a25549fedf3c056dcf9) | [@edde746](https://github.com/edde746) | fix(watch-together): make the participant count badge clickable (#2846) | covered | The participant badge is already interactive; the existing implementation and regression coverage match the upstream behavior. |
| [43d8e8562b](https://github.com/edde746/plezy/commit/43d8e8562b8272e2d339efb38828e9fb1f2d03c9) | [@edde746](https://github.com/edde746) | fix(player): apply swipe brightness to the active display on iPhone Duo | covered | The iPhone brightness path already uses the active display and retains the fork’s native lifecycle handling. |
| [ffe7d792d8](https://github.com/edde746/plezy/commit/ffe7d792d865750880e6fc3369c7ec2ff08b37dc) | [@edde746](https://github.com/edde746) | feat(libraries): add a Genres tab that opens Browse filtered to one genre | covered | Genre browsing already exists through backend-neutral library tabs; retain the fork’s query and source adapters. |
| [1f357ec0a6](https://github.com/edde746/plezy/commit/1f357ec0a6cef67ffe2b5eaf5d7cab5b9948f69f) | [@edde746](https://github.com/edde746) | chore(android): route the mpv core with mpv-android's playback helpers (#2872) | retained | Keep fork-local routing and Media3 EGLSurfaceTexture consumption, preserving custom motion/HDR paths instead of replacing the native AAR and helpers wholesale. |
| [1dd75b3e5e](https://github.com/edde746/plezy/commit/1dd75b3e5e95913cdaa5b8c22911490e72dfb7c5) | [@edde746](https://github.com/edde746) | ci(packages): skip package updates for pre-releases | adapted | 19666675a: reject GitHub pre-release metadata even for stable-looking tags; preserve manual publication. Six resolver behavior tests passed. |
| [d8e991d30d](https://github.com/edde746/plezy/commit/d8e991d30d66ca0e1c7b4f098bf4915c3e23d1f8) | [@edde746](https://github.com/edde746) | fix(watch-together): log why a relay connection or room attempt fails | covered | Watch Together diagnostic behavior is present; retain the fork’s log redaction and session guards. |
| [0a4fdd179f](https://github.com/edde746/plezy/commit/0a4fdd179f82e89aea2b61b3f45df5938ca28d6e) | [@edde746](https://github.com/edde746) | chore: exclude nested git worktrees from analysis | covered | Exact patch equivalence: nested worktrees are already excluded from analysis. |
| [b5bae49493](https://github.com/edde746/plezy/commit/b5bae49493fe4a28bd19f209a7331e134f928f87) | [@edde746](https://github.com/edde746) | feat(libraries): shuffle a whole movie or TV library | covered | Whole-library shuffle and queue launch are already implemented through the fork’s backend-neutral client APIs. |
| [caf76b9589](https://github.com/edde746/plezy/commit/caf76b9589ba67e26e6f1820603c20ef8a5a9cb1) | [@edde746](https://github.com/edde746) | feat(discover): ask which copy to play when Continue Watching merged several | covered | Continue Watching version selection already exists; newer copy and artwork corrections were independently adapted below. |
| [9829d247f5](https://github.com/edde746/plezy/commit/9829d247f5fc142aeefe7bce09bf712d24e48e1a) | [@edde746](https://github.com/edde746) | feat(player): match the display refresh rate in fullscreen on macOS | covered | macOS decoded-display matching and its Swift regression coverage are already present. |
| [4f2a4f25a7](https://github.com/edde746/plezy/commit/4f2a4f25a78525fca196c79a3fbcc70be3c1c2db) | [@jucor](https://github.com/jucor) | fix(jellyfin): keep the picked subtitle among identical same-language files (#2880) | covered | Jellyfin identical-subtitle choice is already implemented with matching production and regression behavior. |
| [0a9ad36e27](https://github.com/edde746/plezy/commit/0a9ad36e27bfff7e45d4eb9dd363a4ad7d47b47a) | [@edde746](https://github.com/edde746) | fix(profiles): prompt re-auth when plex.tv rejects the account token (#2904) | covered | Plex profile reauthentication is present; preserve scoped client, transport and permission state. |
| [ff2a02b793](https://github.com/edde746/plezy/commit/ff2a02b7936ecc68f9d4444b3e83459825af0a8d) | [@edde746](https://github.com/edde746) | fix(android): keep remote OK releases whose scan code is a modifier (#2883) | covered | Remote OK modifier/scan handling is present; retain the fork’s additional Android back-key handling. |
| [9bb6ab5f32](https://github.com/edde746/plezy/commit/9bb6ab5f32980bce749ad05ad56e36317a7cd9c6) | [@edde746](https://github.com/edde746) | chore: bump build number to 159 | excluded | Retain the fork’s release version and build numbering; upstream build 159 is upstream-only metadata. |
| [d832b4212c](https://github.com/edde746/plezy/commit/d832b4212ceabc68bfee6785177f40bd2a724723) | [@nataloko](https://github.com/nataloko) | feat(linux): ship an AppImage with zsync update information (#2910) | adapted | Shared x64 AppImage packager, fork-specific update metadata, verified zsync sidecar, SHA-256/provenance for both files, legacy-safe assembly and hosted smoke coverage. |
| [7b999fb0f4](https://github.com/edde746/plezy/commit/7b999fb0f4b7ccf4dfb85ee9cc38883b06978a76) | [@jucor](https://github.com/jucor) | fix(player): say a subtitle download may have failed when it never appears (#2874) | covered | Subtitle download failures already produce user-facing feedback; keep the fork’s download/session architecture. |
| [63f8cd84c7](https://github.com/edde746/plezy/commit/63f8cd84c78d684b6ed2d19cf989ec61dade8417) | [@edde746](https://github.com/edde746) | fix(tv): keep the library header still while moving along the top row | covered | The TV library header already remains stationary under content scrolling. |
| [e68af60f58](https://github.com/edde746/plezy/commit/e68af60f58ef6d14a1d7c55c4d163a7da4c94652) | [@edde746](https://github.com/edde746) | fix(focus): keep the remote on a detail page when the main screen under it refocuses | covered | Covered-route focus boundaries are present; the later unclaimed-focus handoff correction was adapted below. |
| [41c8aa0768](https://github.com/edde746/plezy/commit/41c8aa0768e9e21a1ad2b37a170daf149bf13ffe) | [@edde746](https://github.com/edde746) | fix(servers): keep a reachable server online when its health probe hits a dead socket | covered | Dead-socket server probing/failover behavior is already present, with additional fork transport hardening retained. |
| [9b514179d3](https://github.com/edde746/plezy/commit/9b514179d34970496eb557f3fb425a034a9e6e17) | [@edde746](https://github.com/edde746) | docs: restrict the Plezy name and logo for distributed forks | excluded | Owner-directed exclusion of the trademark policy and associated README changes. Pleazyng’s name and logo remain unchanged; LICENSE is unchanged. |
| [ba1bd03f5b](https://github.com/edde746/plezy/commit/ba1bd03f5bdf04897ad3aa88112fd30746e7dc08) | [@yellowleadarr](https://github.com/yellowleadarr) | feat(player): offer a server transcode from the HTTP 500 server-limit dialog (#2911) | covered | Forced transcode after server-limit HTTP 500 is already present; retain the fork’s capability and authorization checks. |
| [90b7ccca68](https://github.com/edde746/plezy/commit/90b7ccca68cffcfe51fc8994c3463fcbf769ec18) | [@edde746](https://github.com/edde746) | build(windows): bump patched engine to windows-v3.47.1+2 | adapted | 19666675a: pin Windows engine +2 for pending-resize correction, preserve the Flutter ABI stamp and checksum checks. Published digest and source delta verified; Windows execution qualification is separate. |
| [5cb4dc8aa1](https://github.com/edde746/plezy/commit/5cb4dc8aa15586f7555715a90425e41b5f5561c9) | [@edde746](https://github.com/edde746) | build: pin mpv-build assets from the release each run uploaded them to | covered | The fork’s native revision resolver already records full per-asset provenance/URLs and capability pins; retain that stronger lock format. |
| [f7ab4e6183](https://github.com/edde746/plezy/commit/f7ab4e6183ca20019c8f3faeaa7aa39f8a5535e0) | [@edde746](https://github.com/edde746) | build: pin mpv-build with the optional letterbox fill on the Android OSD plane | retained | Retain the fork’s checksum/capability-locked native assets. This upstream pin is not a drop-in replacement for its normal FEL/NPU components. |
| [63f8cd5a05](https://github.com/edde746/plezy/commit/63f8cd5a054e2ecc5c28dd30fe8066f4356a10c4) | [@edde746](https://github.com/edde746) | fix(player): keep Dolby Vision letterbox bars black on Amlogic boxes with mpv | adapted | Independently adapted Amlogic transparent letterboxing with the Amazon exception. Normal Android engine 6168c50b5c17 and AAR 82ace919fd97 include the native option; all four ABIs were built and inspected, and API-36 Android TV JNI read/write and playback lifecycle checks passed. Physical Dolby Vision black levels remain hardware-specific qualification. |
| [4eabc30c80](https://github.com/edde746/plezy/commit/4eabc30c804c9e6869a8c48fa1d6d174f7d36fbb) | [@edde746](https://github.com/edde746) | fix(focus): tint the background focus fill from the theme so it shows in light mode | adapted | eab1f98a4: theme-derived focus fills, retaining Mono palettes and custom player chrome; focused theme tests passed. |
| [e871d09517](https://github.com/edde746/plezy/commit/e871d095171855914d8f0634b3507a80e67bedce) | [@edde746](https://github.com/edde746) | fix(remote): keep the selected tab across a companion remote reconnect | adapted | 366cd4965: preserve companion-remote control and scroll state through reconnect; focused remote tests passed. |
| [13426a00c0](https://github.com/edde746/plezy/commit/13426a00c034097b2301967f281adbfd58381598) | [@edde746](https://github.com/edde746) | fix(ui): fade light-theme scrims to a clear surface instead of clear black | adapted | eab1f98a4: correct light-theme scrim interpolation while preserving the fork’s rasterized gradients and RTL behavior. |
| [16d5b404cb](https://github.com/edde746/plezy/commit/16d5b404cb14163a776b701265e55b6f66cdfc34) | [@moust4ki](https://github.com/moust4ki) | fix(tvos): stop offering Explore actions tvOS cannot open (#2939) | adapted | f8849ad49: internal library trailers, capability-checked YouTube handoff and actionable errors, retaining Seerr/preview UI and rejecting unsafe provider URI schemes. |
| [b4192d6f35](https://github.com/edde746/plezy/commit/b4192d6f355921aa9dbdd89b000012e7c4496fa7) | [@v-vincere](https://github.com/v-vincere) | feat(ios): adapt the mobile shell to iPhone Duo's vertical bar and fold (#2922) | adapted | f8849ad49: fold/vertical-bar shell and native bridge with SDK availability guards; preserve scrollable rails, system styling, keyboard and back handling. Geometry is headlessly tested; Apple SDK/device qualification is separate. |
| [c7f86ab85f](https://github.com/edde746/plezy/commit/c7f86ab85fbc2c3497676744b6b5b0b6907887d7) | [@edde746](https://github.com/edde746) | fix(ui): keep the status bar clear on screens without an app bar (#2934) | adapted | eab1f98a4: transparent root status-bar styling, retaining the fork’s form-factor scaling and theme behavior. |
| [268c072b40](https://github.com/edde746/plezy/commit/268c072b40b0ca23ab15a98ba55a5e292517b253) | [@edde746](https://github.com/edde746) | build: pin mpv-build with user shaders on the AVFoundation video output | retained | Retain fork Apple native package pins; the upstream shader-bearing package cannot replace the fork’s ordered PCM, motion and experimental components wholesale. |
| [2e1654b316](https://github.com/edde746/plezy/commit/2e1654b316150f59cbc4774602ed4f02a3515527) | [@edde746](https://github.com/edde746) | feat(player): enable shaders and ambient lighting on iOS, tvOS and macOS | adapted | Independently enabled Apple MPV shader presets and ambient lighting with normal Libmpv 93fdd133cea1. All six Apple platform groups were built, every packaged architecture passed the real-stage check, and iOS/tvOS consumers linked. Real Mac M4 playback exercised hardware decoding, GLSL, stretched output and shutdown; the discovered embedded Cocoa initialization deadlock was fixed. Dolby Vision and other documented runtime exclusions remain explicit. |
| [178441bff8](https://github.com/edde746/plezy/commit/178441bff816425d549fd295801bff0868d16afb) | [@edde746](https://github.com/edde746) | feat(trackers): load anime mappings from the edde746/anime-mappings release | retained | Keep independent Fribb/Anime-Lists source feeds and their caches. The consolidated upstream-maintainer binary feed changes the data authority and cache format, uses unbounded inflation and writes before decode validation. |
| [04ec8506c7](https://github.com/edde746/plezy/commit/04ec8506c78dc29b4dfc18f751943fb6ecb89eec) | [@edde746](https://github.com/edde746) | fix(sheets): keep hosted sheets clear of iPhone Duo's status bar and vertical bar | adapted | f8849ad49: sheet safe areas and vertical-bar alignment, preserving keyboard insets and existing focus/back behavior. |
| [ae63adbc8f](https://github.com/edde746/plezy/commit/ae63adbc8fd82bbcb8070be95066bdf1dd04febf) | [@edde746](https://github.com/edde746) | fix(server): build the relay with Go 1.27.3 for the crypto/x509 advisory | covered | The relay already uses Go 1.27.3 in go.mod and its checksum-pinned container image. |
| [6a2304497b](https://github.com/edde746/plezy/commit/6a2304497b59c58acbd1149efe2bd11494501414) | [@edde746](https://github.com/edde746) | build(website): update vite and undici past open advisories | excluded | Upstream website dependency update does not apply to the fork’s separately maintained website. Do not restore the removed upstream website tree. |
| [52e34acc7b](https://github.com/edde746/plezy/commit/52e34acc7b5c2153bedd427b759efb2886c19514) | [@edde746](https://github.com/edde746) | test(ios): expect ao_spatial first on iOS 26 and allow the speed flush's restart | covered | The fork’s audio-output order test already tolerates the spatial output before AVFoundation. Use the later jump/rate regression below instead of broadly loosening timing tolerance. |
| [d242401829](https://github.com/edde746/plezy/commit/d2424018297a00fe1f8bc97ef2bb207f6a515499) | [@edde746](https://github.com/edde746) | fix(android): use Skia on phones and tablets without Vulkan 1.1 | adapted | d43a1cf6e: select Skia without Vulkan 1.1; seven standalone Kotlin renderer tests passed. |
| [38c48f14ac](https://github.com/edde746/plezy/commit/38c48f14ac4107cc94b2ab2f41444f0448d64da0) | [@strata-scribe](https://github.com/strata-scribe) | fix(artwork): debounce resize upgrades and retain resolution on shrink to avoid server churn (#2924) | adapted | d43a1cf6e: debounce artwork resizing and retain resolution on shrink, preserving the fork’s fallback artwork behavior. |
| [d192a726b8](https://github.com/edde746/plezy/commit/d192a726b8a8dd512d648f5cce9d568508d3ecd3) | [@edde746](https://github.com/edde746) | fix(downloads): exclude downloaded media from iCloud Backup on iOS | covered | Managed download/artwork roots are already excluded from iCloud backup, including existing legacy roots and recreated folders; preserve unrelated documents. |
| [80c562ff06](https://github.com/edde746/plezy/commit/80c562ff06db237b48592a89efb0f0b7baeb0e10) | [@edde746](https://github.com/edde746) | fix(downloads): stop the free-space guard capping desktop download speed (#2967) | covered | The fork’s vendored downloader already bounds desktop write capacity and accounts for drained packets; existing recovery/credential behavior remains intact. |
| [0ef47f2711](https://github.com/edde746/plezy/commit/0ef47f2711ecb5ff30089831410b6f29b580cdcb) | [@adamsparsons](https://github.com/adamsparsons) | fix(tv): trigger list tile long-press from D-pad hold-select (#2964) | covered | Shared D-pad select/hold controller already handles rows; retain fork switch/list behavior and cancellation across focus changes. |
| [5076836a5d](https://github.com/edde746/plezy/commit/5076836a5dbb2f54b8316fdcb9d94330c1ddbf01) | [@edde746](https://github.com/edde746) | fix(focus): give a page opened over the main screen focus when it claims none | adapted | 366cd4965: pass remote navigation to a newly covered route that has not claimed focus; adapted fork-specific focus harness passed. |
| [e90973fba9](https://github.com/edde746/plezy/commit/e90973fba999838fbeb9d14b8aa8226130918be8) | [@edde746](https://github.com/edde746) | feat(player): remember zoom per show, library, or everywhere | adapted | 1108a174d: optional global/title/library zoom persistence, session-only by default; retain profile resets, finite bounds and agent validation. Focused zoom tests passed. |
| [f9eef589ad](https://github.com/edde746/plezy/commit/f9eef589ad5fbbf4f65d37fb68aadb9dd9fb0952) | [@edde746](https://github.com/edde746) | build: pin mpv-build with every-frame presentation of a delayed Android subtitle plane | retained | Retain fork native package pins and normal experimental components; evaluate its subtitle-plane repeat patch with the native timing migration below. |
| [6cc283a7da](https://github.com/edde746/plezy/commit/6cc283a7da3d75ed90ec232dd7f5da1f25681b4f) | [@edde746](https://github.com/edde746) | fix(subtitles): line mpv subtitles up with their picture on Amlogic and MediaTek TV boxes | adapted | Independently adapted the one-refresh subtitle offset for Amlogic and MediaTek TV devices after integrating early queueing and per-video-frame repetition into the normal Android/FEL engine. Scheduler, unchanged-content, rebind and runtime JNI range checks passed. Phones and unknown SoCs retain zero delay; physical TV scanout timing remains hardware-specific qualification. |
| [119ce59def](https://github.com/edde746/plezy/commit/119ce59def9eacef8ac70e2b8c0d7fdfe771e0a4) | [@edde746](https://github.com/edde746) | fix(discover): keep version copies when a server comes online after the first load | adapted | 215032961: retain newly-online Continue Watching version copies; preserve profile, transport and synthetic hub behavior. |
| [ddcfda3c4e](https://github.com/edde746/plezy/commit/ddcfda3c4e349ec315f1c5496a5a0e95128b6997) | [@edde746](https://github.com/edde746) | fix(player): undo a display switch that lands after fullscreen or playback ended | adapted | 215032961: restore display switches completing after fullscreen closes; preserve failed-restore retries and fork lifecycle guards. |
| [cbd9205f2c](https://github.com/edde746/plezy/commit/cbd9205f2cef71973dd7cadf568477c448cb3787) | [@edde746](https://github.com/edde746) | fix(android): verify the anime mappings download against system authorities only | adapted | 19666675a: system-only certificate trust through GitHub asset redirects in Android and dart:io. Ten TLS/domain tests passed. |
| [fa8acc3eed](https://github.com/edde746/plezy/commit/fa8acc3eedc015e8381f6acdcbefaf448798552a) | [@edde746](https://github.com/edde746) | test(artwork): wait for local file resolution instead of a fixed delay | covered | The fork already waits for artwork files using a bounded five-second monotonic stopwatch loop. |
| [9fe138aba3](https://github.com/edde746/plezy/commit/9fe138aba39414e38099cc17cfd4296f47059778) | [@edde746](https://github.com/edde746) | fix(profiles): ask for a profile on resume over an open player | adapted | 31e20ddd7: hold playback under the resume profile picker across media keys, native resume, room control and Play Next; preserve Automotive and active PiP behavior. 67 focused tests passed. |
| [6c87210c61](https://github.com/edde746/plezy/commit/6c87210c6162ecaf5e9a77560353a7948e1e93bd) | [@edde746](https://github.com/edde746) | fix(watch-together): keep a guest synced after switching to another version of the room's file | adapted | d43a1cf6e: synchronize Watch Together guests after version changes, using the fork’s existing localized failure feedback. |
| [f2985a7b06](https://github.com/edde746/plezy/commit/f2985a7b06b1190507946cde824779880d7d2af8) | [@edde746](https://github.com/edde746) | fix(discover): stop Continue Watching posters flipping after playback | adapted | 215032961: reconcile artwork through authoritative on-deck data; preserve synthetic Continue Watching/Next Up hubs and reject stale client responses. Discover/display suite passed 124 tests. |
| [f993f9a145](https://github.com/edde746/plezy/commit/f993f9a145158950e5a6ab67a22570a277c9520d) | [@edde746](https://github.com/edde746) | fix(supporter): name the cosmetic purchase Theme & Icon Pack | excluded | Upstream Theme & Icon Pack purchase copy is product-specific. Retain the fork’s commerce model, product identifiers and wording. |
| [c577edda5c](https://github.com/edde746/plezy/commit/c577edda5cdf4b0a0c3d5dd0d543e432c5bed0d8) | [@edde746](https://github.com/edde746) | fix(player): switch the display before the Android mpv decoder opens | adapted | 0bc258ca3: hold Android VOD decoding at demux preload for display matching; preserve motion cadence and Dolby/FEL routing, add player-instance ownership guards. 89 playback tests and eight Gradle tests passed; native bridge compiled against the fork engine. |
| [b0e5919fdb](https://github.com/edde746/plezy/commit/b0e5919fdbd33a32e50acc5a7c4ae533be2d57d8) | [@edde746](https://github.com/edde746) | build: pin mpv-build with the paused frame on a repointed Android Surface | retained | Retain the fork’s native package revisions and FFmpeg 9.0.2/runtime contracts; qualify the upstream paused-frame/performance package refresh as a separate engine migration. |
| [55ef954e23](https://github.com/edde746/plezy/commit/55ef954e23bbcb6fac81b15a84ff7442c87c6d58) | [@edde746](https://github.com/edde746) | test(diagnostics): let the RSS peak trail current RSS in the memory-pressure test | adapted | 366cd4965: remove unsupported ordering assumptions between non-atomic OS RSS counters; retain positive independent-counter assertions. |
| [cb74c6968d](https://github.com/edde746/plezy/commit/cb74c6968d81bcc94aca27498e1ab19e607a17ba) | [@edde746](https://github.com/edde746) | build(android): fetch the Media3 adapter's FFmpeg headers from GitHub | retained | Keep checksum-pinned FFmpeg 9.0.2 headers and the fork’s bounded official-source prefetch. The upstream change pins an 8.0.1 archive and must not downgrade this ABI. |
| [48926474e8](https://github.com/edde746/plezy/commit/48926474e863b8079558e41cb1d4776439ed1555) | [@edde746](https://github.com/edde746) | test(ios): check a speed write by its position jump and the rate after restart | adapted | f8849ad49: check speed-write position jump separately from steady rate after restart; preserve simulator limitations and deterministic flush ordering tests. Swift parsing passed; Apple execution qualification remains separate. |
| [671a0d7b7b](https://github.com/edde746/plezy/commit/671a0d7b7bf7dacf37dc4a6086b6a9c0734904f7) | [@edde746](https://github.com/edde746) | chore: bump version to 2.26.0 | excluded | Retain the fork’s 3.x release version; upstream 2.26 numbering is upstream-only release metadata. |
| [d4ec916550](https://github.com/edde746/plezy/commit/d4ec916550527b1bb4dc29fca223e1d2ed4c24fe) | [@github-actions\[bot\]](https://github.com/apps/github-actions) | chore: update cask to 2.26.0 | excluded | Retain the fork’s own Homebrew publisher, names and immutable artifacts instead of upstream 2.26 cask URLs/hashes. |
| [738e18fdc5](https://github.com/edde746/plezy/commit/738e18fdc552ace910dedabf6e689ab74e1dae58) | [@edde746](https://github.com/edde746) | fix(release): expect the Linux AppImage assets in the draft release | covered | The fork already accepts additive Linux assets and requires its x64 AppImage. New advertised update pairs are verified before publication, while historical immutable artifacts retain their original contract. |

## History checkpoint

The reviewed upstream snapshot is recorded as a history parent after these
adaptations and dispositions. The reconciliation uses Git's `ours` merge
strategy; the fork tree retains the decisions above. Behavioral scope is
specified by the disposition table, including the three unshipped native items.

## Follow-up upstream review — 2026-11-12

Upstream subsequently advanced beyond the 64-commit checkpoint above. Commit
[`847842c3d0`](https://github.com/edde746/plezy/commit/847842c3d075b56d686409850e12fa1cca0b19d9),
authored upstream by [@edde746](https://github.com/edde746), sets a constant
mpv title before initialization on iOS and tvOS to avoid repeatedly expanding
the default `media-title` title. The upstream report measured about 2% CPU in
its iPhone Air bench app and explicitly did not measure Plezy. Pleazyng
independently adapted the option in its shared iOS/tvOS context setup and added
iOS/tvOS contract tests; macOS continues using its window title. This
follow-up is an adaptation, not a claim that the upstream branch is otherwise
synchronized. Apple target execution remains separate qualification.

## Upstream sources

Each reviewed record links its originating upstream commit and upstream author.
The table and follow-up above are the source list for this implementation/review record.
See the [source ledger](../../UPSTREAM_ATTRIBUTION.md),
[adaptive UI record](adaptive-mobile-and-tvos.md) and
[AppImage contract](appimage-update-contract.md).
