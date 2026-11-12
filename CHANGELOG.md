# Changelog

## [Unreleased]

- Route an explicit private Apple selection to macOS as well as iOS and tvOS, and bound the macOS compile and package job to 100 and 150 minutes.

- Add per-rendition intro/outro trim markers, playhead editing, trimmed-range preview and a persisted host override for automatic trim and marked long-instrumental skips. Instrumental sections under eight seconds are preserved.

- Pause and restart queued karaoke companion work around active music playback, and prioritize preparation for the track most recently selected by the host.

- Add a TV-first karaoke layout with a scaled D-pad navigation rail, couch-readable song rows, stage-first performance view, queue routing after requests, and no file-picker actions on TV.

- Create and select a persistent singer identity from the active Pleazyng profile; keep paired LAN guest singers separate.

- Make paired host handover exclusive: a newly paired one-use host link revokes the previous host grant, and expired pairing receipts are removed so reconnects cannot reuse stale credentials.

- Save karaoke A–B practice loops per rendition and restore them with the profile session.

- Compare a private karaoke take with its matching guide vocal or original audio at the recorded rendition position, key and tempo where supported.

- Add an optional persisted visual four-beat count-in to A–B practice-loop restarts, timed from saved BPM analysis and the current playback rate. No audible metronome is included.

- Add host-stage corrections for preparation key, tempo and chord timeline estimates, and retain them across re-analysis and session restore without treating them as scored note charts.

- Avoid repeated `media-title` expansion in each iOS and tvOS mpv context while preserving macOS window titles. The source is upstream Plezy commit [`847842c3d0`](https://github.com/edde746/plezy/commit/847842c3d075b56d686409850e12fa1cca0b19d9), contributed there by [@edde746](https://github.com/edde746); Pleazyng independently adapted it. See [UPSTREAM_ATTRIBUTION.md](UPSTREAM_ATTRIBUTION.md#credited-plezy-commits).

- Move a playing or paused movie or episode to Google Cast from the video player's **Play on** control. The phone follows the receiver's current playback and keeps play, pause, seek and stop controls.

- Show music output selection in Now Playing and the mini-player during an open session, with localized receiver setup guidance in Settings.
- Keep the Android Automotive hardware feature in the dedicated AAOS manifest and enforce Google Play delivery version code 189 or higher after the v3.0.33+188 bundle was rejected for declaring Android Auto projection metadata and the automotive hardware feature together.

- Accept expiring OPDS acquisition URLs while keeping credentialed source and catalogue URLs rejected, and keep signed credentials out of saved entry identity.

- Open saved Multiview sessions on demand from Settings, with localized guidance for managing active sessions, so app startup goes straight to the normal browsing and resume flow.

- Pass the configured Pleazyng relay and owned Discord application ID into every official release build, including Microsoft Store payloads, enabling optional provider routes without upstream-service fallbacks.

- Make `plezyctl --open` use the registered `pleazyng://open-media` scheme so selected results open in Pleazyng.

- Fix Launchpad PPA binary uploads rejected for 1970 timestamps on bundled Dolby Vision tools, and allow re-uploading an existing release with a new PPA revision using the PPA's existing source tarball and current packaging fixes.

- Keep paged local folder listings in a deterministic order when filenames differ only by letter case.

- Read local CBR and CB7 comics through bounded RAR and 7z extraction, including source classification, BookOrbit/OPDS file metadata and codec notices in the app's Licenses screen.

- Support secure Kavita OPDS onboarding from a copied Auth Key URL or a separate key field, migrate existing copied URLs into encrypted credentials, and keep the key out of saved source endpoints and entry identifiers.

- Correct current aerynOS release guidance to reflect the qualified 3.0.33-5 downstream package; retain the v3.0.7 playback failure as historical evidence.

- Compile the Android GameStream/Moonlight integration with the app for arm64, ARMv7, x86 and x86_64.

- Reconcile the MilkDrop capability record with the promoted ordered PCM mpv artifacts and `.milk2` source implementation, keeping rendering, runtime, rights and device qualification gates explicit.

- Add Android GameStream to app-owned Multiview through a retained Moonlight surface with session-owned connection, audio/input leases and teardown; enforce Moonlight's one-active-connection limit. Independently adapted from the pinned [Moonlight Android receiver revision](https://github.com/moonlight-stream/moonlight-android/commit/b48494cb96bff23d8886c4775cc4f39a1075495d), authored upstream by [@cgutman](https://github.com/cgutman); see [UPSTREAM_ATTRIBUTION.md](UPSTREAM_ATTRIBUTION.md#credited-moonlight-android-source).

- Expand Multiview's isolated native video capacity to four sessions across Apple TV, Android, desktop and TV controller backends; reject a fifth open before player construction.

- Let users set Stremio add-on priority, persist it per profile, and preserve local order and enabled state when importing the account again.

- Preserve the selected duplicate playlist occurrence when starting playback on a transferred device, including cloned rows and shuffled queues.
- Check enabled Stremio add-on manifests daily while a profile is active, show pending updates in settings, and require review before applying them.

- Extend reproducible native gapless qualification to ALAC, AAC and Opus, and fix JSON receipts while recording encoder versions and measured error tolerances.

- Use the current Google Cast Swift queue-update method when rearming repeat playback on iOS.

- Keep native car and voice catalogs bound to their original server, library, backend and album. Carry library constraints through paged Jellyfin/Emby browsing and playback without losing artist credits or accepting foreign rows and stale pages.

- Add reproducible native gapless file-output qualification for WAV, FLAC, MP3 encoder padding and mixed lossless joins, pinned by the tested library checksum.

- Expose Plex server radio and personalized mixes in Music home and native car Recommended browsing, with server family labels, scoped voice lookup, shuffle/repeat and finite enqueue actions.

- Use the current Swift Cast request-abort callback so acknowledged queue rearming compiles against the iOS SDK.

- Store large music queue occurrence IDs and metadata offsets in a bounded, block-cached disk index; immutable snapshots lease the index instead of copying per-track handles.

- Use the same bounded queue storage for temporary remote-device transfers and release their mutable owners after capturing the immutable transfer state.

- Play Plex server radio through the shared music session, retain manual exclusions during rolling refills, and persist credential-free recipes that require fresh library authorization after restart.

- Read Plex server-authored radio catalogs and open only account-authorized station keys through the audio PlayQueue API; reject foreign or malformed catalog and queue windows.

- Preserve incremental music queue saves with bounded order storage: write only moved positions, changed metadata and new or retired occurrences.

- Add optional rolling playback for saved filtered music stations, with exact-preview adoption, persisted rules, whole-album exclusions and native car controls. Keep downloads and offline playback finite and reject snapshots from another station source.

- Add saved Album Radio recipes that play complete ordered albums, refill from authorized sonic neighbors, preserve queue edits and account ownership, and support finite download previews and native car playback.

- Save Sonic Adventure track counts and maximum sonic distance, forward them to each Plex path request, and reject paths that omit a waypoint or exceed their budget. Retire discovery editors and related results with their original profile/account.
- Keep canonical music order implicit, spill large shuffled and album-shuffle orders to bounded scratch storage, avoid decoding album labels again during merge output, persist order in pages, and clear shuffled tails without per-item arrays or retaining discarded metadata in the active spool.
- Require Chocolatey package authors and owners to match the maintainer account, and validate project/source URLs from the generated package before publishing.

- Connect TorBox through its device authorization flow, verify the returned token against the account endpoint, and retain API-key setup as a fallback.

- Support Stremio `manifest.config` fields during add-on installation and reconfiguration, with bounded schema validation and profile-encrypted settings.

- Require the complete acknowledged Cast occurrence order before returning playback locally, and recheck it during preparation and receiver pause so receiver edits cannot be overwritten by a stale queue.

- Support repeat-one and repeat-all for bounded standalone Cast queue transfers, with acknowledged native item rearming, restart recovery and receiver repeat settings preserved on return. Keep local playback intact if preparation or ownership checks fail.

- Manage pending Plex item-sharing invitations from Shared playlists, with explicit whole-invitation confirmation, original-account preflight and single-attempt acceptance or decline. Refresh accepted browsing after decisions and retire stale confirmations with their profile.

- Keep native car/voice and music-link queue admission paged and account-bound. Preserve duplicate playlist entries, reject foreign/incomplete batches, and prevent metadata fetched before an account change from becoming a catalog entry owned by the replacement account.
- Route iOS and tvOS packages through compatible GitHub-hosted macOS by default, with a verified private-JIT retry when hosted tvOS is canceled before runner assignment; keep nonpublishing builds from blocking versioned releases.
- Gate verified private Apple retries on run-scoped Mac availability and live APFS/NFS capacity, and keep Apple release checks on the same runner route as iOS/tvOS packaging.

- Admit album and artist playback in bounded metadata pages, preserving Plex child/grandchild routes and MediaBrowser music credits. Recheck the original account and play intent between pages and reject malformed or unauthorized pages before replacing the queue.
- Start the bundled offline MilkRust sample automatically for a new music visualizer profile when native audio is available; keep saved engine and original-scene choices.
- Keep MilkDrop pointer input on the visualization canvas so preset-control clicks do not trigger shader mouse events.

- Correct the optional live audio spectrum filter so FFmpeg accepts its centroid and flatness measurements during music visualization.
- Keep large music queues lazy through car status updates and karaoke snapshots; reject stale native queue references after identical duplicate tracks are reordered.

- Remove an obsolete music-playback warning from translations so release code analysis recognizes the working music player.
- Add optional per-span pronunciation readings to karaoke lyric packages and render them as ruby annotations on the Flutter and browser stages, with line-level pronunciation retained as a fallback.
- Preserve simple WebVTT ruby readings through import and export as timed per-span pronunciations. Refuse LRC/WebVTT exports when the format cannot preserve other lyric metadata or timing, and close WebVTT speaker tags correctly.
- Preserve syllable units and optional source confidence in karaoke lyric editor revisions; unknown confidence remains unknown.
- Keep existing line end times, word/syllable spans and pronunciation when tap-timing a karaoke lyric line.
- Reject unknown lyric span units and invalid confidence metadata instead of silently converting them to word timings.
- Update the karaoke qualification ledger to reflect current source checks and runner routing.
- Include span-level singer assignments in karaoke duet choices, stage labels, and part colors.
- Ignore empty karaoke singer-part IDs in duet choices and stage coloring.
- Reject karaoke lyric packages whose timed spans do not reconstruct their parent lyric text.
- Bound karaoke package sections, tags, singer labels, readings, and rendition metadata.
- Add a dedicated karaoke word/syllable timing editor with exact-text split/merge and explicit timing boundaries.
- Page large music playlists directly into the bounded metadata window, validate each page against its original account and library, and keep the audible queue intact if preparing replacement metadata fails. Validate owned offline playlist batches without repeatedly scanning every download.

- Flush the TrueHD decoder's stream state through FFmpeg on reset instead of recreating its native context, and align the Android decoder ABI check with the pinned FFmpeg 9 libraries. Independently adapted from [upstream 54a002f](https://github.com/edde746/plezy/commit/54a002f9b7271603d6eecba16079990dd1f83d28), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Use the existing translations for the preferred subtitle languages setting in Playback settings.
- Fix bundled visualizer presets failing to install when the extraction isolate captured unsendable catalog and cancellation state.
- Verify that Windows release bundles contain the MilkRust renderer, visualizer helper, starter presets and corresponding source, and that their libmpv matches the checksum-pinned build input.
- Choose peak, bass or treble filter types for each native music group equalizer band.

- Reject Linux visualizer packages whose bundled libmpv lacks the required music PCM tap or whose MilkRust runtime, helper, notices, source, or offline sample pack is missing.
- Label per-show podcast automatic downloads and finished-episode retention by their actual behavior, including an explicit Off choice.

- Skip an orphaned download file during cleanup if its size or modification time changed after the review scan.

- Make orphaned-download review discoverable in Download settings, using the same guarded scan and confirmation as the Downloads toolbar.
- Prefer the available MilkRust renderer for new visualizer profiles, falling back to projectM when necessary while preserving each user's saved engine choice. Clarify how to open presets from Now Playing; native release qualification remains in progress.

- Preserve video aspect ratio on window resize. Retire Stretch fit and interpret saved Stretch choices as Contain; the player now cycles between Contain and Cover.
- Added an owner-authorized Plex music playlist access dialog with explicit recipient confirmation, fresh playlist preflight and account retirement guards.
- Edit the native music group equalizer from its group screen, with saved enable, gain and per-band controls scoped to the active profile. Correct the native availability switch description.

- Retry the published release's PPA, Snap, and WinGet deliveries with the tools and complete manifest set required by their selected runners.
- Edit collection titles, sort titles, summaries, posters and backgrounds with account-bound decisions, square music artwork and correct Plex collection writes; refresh the collection view after artwork or metadata changes.

- Create and populate Plex artist and album collections from music menus with correct member types, subtype/library checks, immutable seeds and account guards across metadata URI discovery.

- Add the Plex playlist access-grant transport with validated credential-free playlist URIs, bounded recipients, account-retirement checks, explicit acknowledgements and no automatic mutation retries.

- Read actual owned and accepted received Plex playlist grants; revalidate recipient, source and item identity before revoking one item grant, without canceling unrelated sharing. Show the current recipients in the playlist access dialog with explicit revocation confirmation and account-bound decisions. Remove the unused Stretch label after retiring that video fit mode.

- Page accepted incoming Plex audio playlists through the authorized server, bound metadata reads, retire stale account/catalog results and recheck exact access before opening. Browse shared playlists from Music home with paging and read-only detail, retain shared-session playback, and bind one-time downloads to their original source across dialogs.

- Bind track-to-album playback to the original profile, account, server and visible library. Preserve owned offline playback from Downloads without fetching a live album, and reject stale or foreign album rows.

- Stop playlist pagination and artist/album expansion when their account, profile, library visibility or play request changes. Validate queue rows against the original source and keep offline playlist occurrences limited to owned files.

- Clear large shuffled queue tails in place without per-item keep/remap arrays or stale active-spool records while preserving canonical duplicate occurrences. Reuse immutable queue snapshots across cursor and status updates so the queue sheet can skip unchanged row reconciliation.

- Spool large live music metadata into a bounded decoded window while preserving immutable occurrence snapshots, shuffle, edits and asynchronous saves. Restore SQLite queue rows through that window, keep queue rendering lazy, and trim decoded metadata on memory pressure.

- Assemble the complete frozen release from independently signed iOS and tvOS sibling runs, verifying both IPA attestations and original platform artifact identities before publication.
- Keep shared libraries read-only for collection changes and bind collection confirmations to their original authorized account.

- Add server-authored recommendation previews to customizable Music home. Preserve native family titles, bound parallel loading and preview sizes, reject foreign rows, and recheck profile, library and account ownership before opening or starting an album queue.

- Choose selected Bluetooth music outputs for profile-owned automatic driving view entry. Respect the foreground, profile/PIN result and master preference; retire automatic routes with their owner and preserve manual routes and shared playback on disconnect.

- Observe Android 13+ selected media routes through the public audio-attribute API, with stable Bluetooth identities, foreground subscription cleanup and explicit unknown measurements. Available or communication devices and masked addresses cannot arm driving entry.

- Persist explicitly selected Bluetooth driving-route identities per profile, with bounded storage, serialized changes and retirement guards. Reuse one foreground-only OS-route observer for Apple diagnostics and driving integration.

- Choose Apple music output through the native audio-session route picker and inspect the selected route. Route notifications refresh diagnostics, stale inspections cannot overwrite newer routes, and observation stops in the background without activating audio or autoplaying.

- Inspect the audible music renderer, including the independent native group source speaker, and recover to the system default output without replacing the queue, playhead, pause state or general DSP. Account-retired or failed inspections cannot show a stale report.

- Manage advertised Sonic and loudness tasks from track details with verified-owner checks, server-wide confirmation and live individual server activities. Retired accounts, routes and background panels cannot send late actions.

- Isolate native music socket fixtures across parallel test processes and inject the independent source-speaker decoder in output EQ tests.

- Hold the music play/pause control to stop the shared session from Now Playing, the mini-player or driving view. Keep taps and keyboard selection on play/pause, suppress accidental card actions, and announce the hold action to screen readers.

- Serialize native music group joins, replacements and departures so a new source waits for the retiring speaker, capture lease and Companion listener. Rejoining during a slow output close no longer collides with the old port or disables the replacement capture.

- Browse played music occurrences with Back To and upcoming occurrences with Up Next. Preserve full queue access, map filtered edits to the correct occurrence, retire stale callbacks and duplicate swipe widgets, and fit queue controls and track text at larger accessibility sizes.

- Keep native source-speaker volume and mute local to that speaker. Preserve remote PCM and shared fade/headroom envelopes when changing or muting the source, and restore direct local output correctly on departure.

- Reuse the existing Apple ARM runner-pool input for iOS and tvOS recovery so the release workflow stays within GitHub's 25-input limit.

- Freeze official Apple authentication podspec metadata so unchanged AppAuth and Google Sign-In versions pass locked native dependency installation after CDN metadata edits.

- Verify a signed tvOS-only recovery as a sibling source for the focused iOS rebuild only when its release assembly stopped before publication.

- Recover the signed iOS package on the private Apple Silicon runner after the hosted archive reached its job limit, reusing the same qualified product and successful platform outputs.

- Keep the source speaker audible in native music groups through an independent clocked PCM renderer. Apply its output and per-speaker EQ locally, mute buffered audio immediately during workspace handoff, and await speaker teardown when stopping.

- Register a third audio-only music core for the clocked native-group source speaker, independent of both fade decoders on every native platform.

- Share bounded native group PCM rendering across output roles and retire late accepted decoder opens after their owner has closed.

- Let an approved tvOS-only release repair build on the private Mac while the original iOS release job continues; keep other core release runs serialized.

- Promote verified native music DSP artifacts across Apple, Android, Linux and Windows together, including the rebuilt EQ filters, ordered PCM hooks and matching package verification receipts.

- Reject playlist artwork with corrupt pixel data before upload and preserve the original upload bytes across asynchronous playlist identity checks.

- Show bounded, account-scoped artwork in CarPlay music lists, including owned offline artwork. Discard stale browse/image replies and keep image requests, decoding and presentation caches bounded.

- Edit playlist artwork from the detail screen: select a current server image, upload a bounded image or restore default artwork. Retire picker results and accepted writes when the owning account changes.

- Add guarded Plex playlist artwork listing, selection, bounded image upload and default restoration, with fresh identity checks and propagated permission failures.

- Retire playlist deletion confirmations and single-entry write acknowledgements after an account or route change. Refresh browse callers after accepted moves/removals and keep uncertain stale writes from reloading a different account.

- Use bounded Plex track and album loudness analysis when file ReplayGain tags are absent. Carry independent, peak-limited gain through offline, cached, gapless and overlapping playback, and refresh current/armed modes when leveling or shuffle changes.

- Select and remove multiple music playlist entries with pointer or D-pad controls. Preserve repeated occurrences, recheck the owning account and server entries, and reload partial or uncertain batches before an explicit retry.

- Edit Plex playlist titles and summaries from playlist detail, keep unsaved drafts on failure, retire stale account forms and refresh browse lists after accepted changes.

- Add guarded Plex playlist title and summary updates, preserving entries and smart rules, rejecting observed edit conflicts and reloading accepted server state.

- Persist only changed music queue rows in bounded transactional batches, safely stage cyclic shuffle/reorder updates and fence retired profile stores.

- Show pinned music on Music Home with removal and drag ordering. Pin artists, albums and tracks from music actions, and reopen current authorized detail routes through the shared session.

- Store bounded Music Home artist, album and track pins for the active profile and account. Refresh authorized metadata before saving or opening, and retire stale account, library and profile operations.

- Keep local headphone/output correction out of native group source PCM. Apply the general music curve while transmitting and restore the latest local output preset on departure without replacing the shared queue.

- Apply speaker edits to the current local native music source without promoting a remote player. Keep native source/receiver Stop controls available when discovery loses the selected peer.

- Negotiate native speaker channel preferences and send synchronized stereo, 5.1 and 7.1 PCM without exceeding the UDP MTU. Preserve/reorder known surround capture layouts, downmix other supported layouts, and retire changed or invalid peer formats independently.

- Apply native per-player parametric EQ relays through the shared music session, persist bounded profile settings and publish accepted state. Preserve other speakers' PCM while transmitting, roll back rejected changes and keep ordinary playback available when a restored preset lacks decoder support.

- Add finite, bounded parametric EQ to the native audio-state reconciler, preserving independent ten-band/effect state and rolling back rejected graphs. Require executable native DSP verification before qualifying the dependency; the previous Linux/Android filter lists omitted EQ.

- Accept native per-player volume relays on hosted, source and receiver mesh connections. Serialize bounded commands, recheck account/connection ownership and publish accepted state without reopening audio or forwarding receiver gain to the source.

- Retire stalled or disconnected native metadata streams through their socket deadline, avoiding synchronous close errors during pending HTTP flushes. Apply the same safe teardown to the live PCM bridge.

- Keep native music capture and its source clock running while speakers join or leave. Gate new PCM on acknowledgement, preserve existing output on failed/cancelled additions and let one peer depart without stopping its siblings.

- Add explicit native Caldera / Plexamp availability, multicast discovery, mesh hosting and incoming source/sink membership through the shared music session. Bound peer controls and replaceable group setup, accept native additional-sink relays, and retire availability with the active profile/account.

- Open native group WAV audio without multi-second format probing and cap priming silence while the audible clock warms up. Verify scheduled pulse timing against the actual pinned Linux decoder with a timed null output.

- Match native music gain to the pinned decoder's cubic volume curve and ReplayGain, preserving equal-power fades and EQ headroom. Update queued group PCM gain at render time and discard late gain reads from retired decoders; keep synthetic native receive tracks out of session persistence.

- Schedule native receive PCM on the renderer's audible audio clock, including driver delay, and resample continuously between independent source/output clocks. Bound drift, phase correction, priming and stale-clock lifetime while preserving shared-player ownership.

- Follow native group source metadata in Now Playing and shared media controls, forwarding transport and seek to the verified Companion playback identity. Preserve paused group membership and feed silence until resumed audio establishes a fresh frame clock; retire subscriptions on source or account changes.

- Fold known surround and height speaker layouts into native group stereo output while retaining original multichannel PCM for visualizations. Reject unknown, duplicate or non-finite capture data before transmission.

- Serve bounded native-source metadata and target-qualified, replay-protected transport controls to selected group peers through the shared music session. Correct stale documentation: the current dependency lock already includes the ordered PCM ABI.

- Follow native music-source hardware drift with bounded transmit-clock feedback and monotonic descriptor timestamps; prevent rejected receive timing outliers from changing frame unwrapping. Accept the empty HTTP 200 command acknowledgements emitted by current native Companion players.

- Send the shared music queue to explicitly selected native Caldera / Plexamp speakers after acknowledged membership, with bounded PCM mixing, resampling, clocked UDP output and account-scoped cleanup. Keep queue occurrences and local transport authoritative, and restore prior local muting on departure.

- Expose ordered, bounded music PCM capture on Android, Apple, Linux and Windows, sharing the native tap with presentation-timed visualizations and releasing capture on player teardown.

- Receive a selected Caldera / Plexamp source through the shared music player using bounded Xita framing, clock mapping, packet reordering and loss concealment. Retire the stream on account, profile or playback ownership changes; send the native Hello handshake for manual connections. Physical synchronization remains unmeasured.

- Enter and verify native Open Media qualification fields through the real keyboard on Wayland before accepting HTTP consent or starting playback.

- Reject iOS worker signing profiles that omit requested Enhanced Security grants before native compilation, preserving the extension's security settings and existing distribution identity.

- Wake aerynOS source tracking after canonical main updates and automated release-metadata reconciliation using a dedicated repository-scoped credential, retaining scheduled catch-up and independent native qualification before package publication.

## [3.0.33] - 2026-11-11

- Pin Apple authentication dependency metadata to its immutable official specification and normalized sandbox checksum, preserving the same code and dependency versions when CocoaPods CDN metadata changes.

- Provision and verify the Tizen Rust launcher before native compilation, keeping the pinned MilkRust compiler isolated without modifying the host launcher.

- Keep Nix package versions and hashes synchronized with complete, authenticated releases, retrying concurrent metadata updates without rebuilding the application.

- Allow bounded GitHub tag propagation after freezing a qualified source, without recreating tags or accepting mismatched references.

- Keep OpenMedia app links inside the active profile navigator, and allow standalone playback without a multiview workspace. Preserve the existing profile-owned mini-player while preventing route-construction failures that left audio playing behind a black screen.

- Validate Apple's case-insensitive bundle identities and iOS-capable universal worker registrations against strict iOS App Store profiles; provide a native signing preflight without rebuilding the application.

- Isolate the relay store write queue between widget test clocks, retaining ordered account teardown, download preservation and same-account re-login coverage.

- Align Apple native qualification and tvOS AOT with the Apple Silicon macOS 26 / Xcode 26.5 release toolchain, preserving the layered icon, pinned native Swift features and SDK-matched native tests.

- Build the relay and its health check with Go 1.27.4 to address the standard-library HTTP server race in [GO-2026-6859](https://pkg.go.dev/vuln/GO-2026-6859), including the matching immutable multi-platform container builder.

- Require native qualification to show moving video and audio on the untouched Open Media route as well as the standard server player; seeking or reattaching cannot stand in for initial-frame readiness.

- Reveal native video when playback renders its first frame before the view mounts or a playing surface is reattached. The shared widget reads current frame readiness across player backends while preserving explicit loading and display-negotiation holds.

- Include XKB keyboard data in the Nix runtime so GTK can initialize and accept keyboard input inside the package environment.

- Prepare and validate distinct iOS Runner and RommWorker App Store profiles before compilation, using the existing distribution identity and Apple API access. Retain the attested unsigned IPA before Store packaging, so a signing failure preserves the successful developer artifact.

- Prepare the unchanged pinned iOS Steam sources before Xcode with bounded retries, so dependency-network failures stop before expensive compilation and the Xcode phase reuses the verified source recipe.

- Keep cold offline Jellyfin/Emby rating intents in the exact saved client namespace so they can reconcile after discovery.

- Control existing Caldera/Plexamp groups from music synchronization: discover native speakers or connect manually, select a source and additional speakers, and send native group, transport and volume commands. Native audio-node interoperability and physical synchronization remain unqualified. Independently implemented using [anatosun’s protocol research](https://github.com/anatosun/caldera-snapjack).

- Restore detached Chromecast music controls after restart only for the acknowledged receiver queue and the same profile accounts, without saving stream URLs or reloading the receiver.

- Record music ratings during a cold offline start using the saved profile account, and review remote conflicts before replaying them after reconnection.

- Keep Apple workflow ownership separate from the approved source checkout when cleaning build workspaces. Reuse a separately verified signed tvOS repair output when only iOS still needs building, preserving the same qualified product source and native dependencies.

- Preserve the explicitly selected tvOS runner pool when recovering signed Apple packages, without adding a candidate source reference.
- Browse personal Plex music history with managed and shared user tokens. Owner queries stay filtered to the owner, and non-owner pages reject mixed users and pin the returned server account for further pages.

- Refresh music rating conflicts when another device changes the server value during resolution. Choices from the older conflict cannot overwrite or discard the updated decision.

- Release a returned or stopped Chromecast queue as soon as the same receiver acknowledges its stop, so another queue can be transferred immediately.

- Keep album titles out of track performer credits. Music details distinguish explicit release editions from audio versions and show the versions' audio codecs and channel layouts.

- Evaluate release build jobs after intentionally skipped capture/CI ancestors, while requiring successful source validation. Permit retrying an audited validation-only recovery run that produced no build, artifact or publication side effects.

- Return a standalone Chromecast music queue to this device from Now Playing. Playback resumes at the receiver's current occurrence and position, keeping shuffle order and duplicate tracks.

- Bind a detached Chromecast queue to its acknowledged media session and exact receiver occurrence before preparing a return to local playback.

- Start a saved music station from shuffled tracks, shuffled albums, least played tracks, or oldest releases. The filter editor follows the station's track or album mode, and an invalid album block is skipped in full.

- Keep rolling mixes bound to their original server account across refills and restart. A replaced authentication session cannot append a late batch.

- Repair Apple release packaging without changing the qualified application source: pin iOS device archives to the bundled arm64 ABI and make copied native frameworks writable before re-signing. Reuse successful platform artifacts with an exact reviewed packaging revision and publicly attested source identities. Include the complete upstream people/source ledger in public release notes.

- Check Plex loudness data from Music details and request server analysis of a track when the current account owns a supported Plex server.

- Distinguish missing Plex loudness data from failed or refused reads, and validate track provenance and server ownership before accepting a manual analysis request.

- Keep mix and Sonic Adventure previews tied to their original source accounts and visible libraries. Playback, queueing, downloads and playlist saves reject a revoked preview.

- Keep sequential albums gapless even when queued from a playlist. Sweet Fades follows edits to the actual queue and stays available for shuffled and mixed queues.

- Transfer an eligible music queue to Chromecast from Now Playing. The receiver can advance the prepared queue after the sender disconnects, and the phone retains its queue paused after an acknowledged handoff.

- Prepare bounded standalone Cast music queues in playback order, with separately identified repeats, paused receiver acknowledgement, and authorization checks on every source.

- Browse paged Plex server playback history from Recently Played for music libraries owned by the active Plex account. Keep provider plays separate from local listening charts and paired imports.

- Add bounded Plex music-history requests that validate each event against the verified server owner and requested library.

- Use the app's rounded transport and speaker icons in listening history and synchronized groups.

- Scan authorized music NFC links from Music home on Android. Cancelling or replacing a scan invalidates its tag callback without consuming the next scan.

- Keep loaded listening history pages visible while local playback and paired-device imports refresh the list. Coalesce database notifications and rebuild the current window with cursor pages from one snapshot.

- Edit native Plex smart-playlist directory rules without losing repeated clauses, exact operators, relative dates, source types, grouping, sort or limits. Track, album and artist rules keep their server query semantics during preview and save.

- Bind Cast ownership to both the receiver connection and media session, prepare loads paused before authorized playback, and time out stalled native acknowledgements. A failed local return after receiver revocation keeps the selected occurrence without advancing or autoplaying.

- Add an iOS music widget with expiring Now Playing metadata and profile/queue-checked transport on iOS 17+. The widget never restores playback from stale data and is embedded in signed archives when its separate App Group provisioning profile is configured.

- Read and write credential-free music NFC links on supported iPhones from Music home and Music details. NFC-capable signed builds use the existing profile authorization path; builds without the reader capability keep NFC controls hidden.

- Manage independently paired music receivers from Now Playing's Sync screen, with discovery, secure pairing, per-endpoint removal and profile-bound teardown without replacing the existing companion control peer.

- Add independently negotiated music group endpoints with per-device clocks, departure and authorization guards, so one receiver can leave without pausing the leader or disconnecting other receivers.

- Import paired-device listening history through bounded cursor pages, portable account matching and cumulative occurrence-ID reconciliation. Legacy unscoped events stay private, replay cannot add plays, and imported events never send server scrobbles.

- Bind newly recorded listening occurrences to portable account identities, keep legacy unscoped history private, and reject conflicting occurrence IDs before cross-device reconciliation.

- Route Chromecast music through the existing shared queue and controls, with receiver-only stream resolution, paused load acknowledgement, repeat/shuffle/duplicate preservation, and receiver-takeover fallback without local DSP claims.

- Add acknowledged remote music output switching inside the shared queue, preserving playback occurrences and playhead while rejecting stale preparation and returning locally paused after receiver revocation.

- Add an idempotent COPR EPEL10 target bootstrap for x86_64 and ARM64 that preserves existing Fedora targets. Native Red Hat family installation and playback qualification remain required before advertising support.

- Dispatch Cast media loads before awaiting receiver acknowledgement, retaining synchronous status events and cleaning up failed or timed-out handshakes.

- Qualify Apple simulator startup on fresh, SDK-matched job-owned devices. Preserve existing simulator saves and real tvOS database recovery checks, and retain ownership receipts for cleanup.

- Preserve local listening/report ownership when a paired music group fails source preflight, and correct smart-playlist integration lints found by the whole-repository analyzer.

- Harden group departure against replayed invitations/acknowledgements and transport failures; prevent delayed Cast status/report callbacks from retiring or reporting a replacement receiver session.

- Await real Linux music-decoder destruction before checking survivor progress and completing native sanitizer qualification. Preserve asynchronous application teardown and leak detection. Allow release operators to skip manual Discord dispatch while package and store delivery continues.

- Add an explicitly negotiated two-device music synchronization group over authenticated companion pairing: receiver preflight, monotonic clock-offset sampling, sequenced playhead anchors, drift correction, heartbeat expiry, and lease-bound teardown. Queue/mode replacement ends the group; arbitrary multi-endpoint grouping and acoustic latency qualification remain separate.

- Bind Cast loads to profile/authentication and matching receiver media-session acknowledgements, serialize competing loads, and retire progress/control ownership when another sender replaces the media.

- Write durable music links to writable Android NFC tags from music details, with explicit scanning/cancellation, tag-capacity checks, optional hardware support, and credential-free NDEF records resolved through normal profile authorization when scanned.

- Add an Android home-screen music widget with live metadata and localized transport accessibility labels. Controls use the shared profile-scoped session, reject stale widget intents, and never persist stream credentials; internal app installation is required.

- Preserve server ownership when refreshing playlist metadata and bind existing smart-playlist editor loads to the profile that requested them.

- Detect server-side rating/favorite changes before replaying offline music edits, retain conflicting decisions for explicit resolution, and recognize writes already acknowledged by another device.

- Create, preview, edit and copy Plex music smart playlists with ordered nested expressions, sorting and limits. Filter-form additions preserve existing expressions and writes retain server-side rules rather than fixed track lists.

- Expose music performers, writers, producers and available composer/contributor credits alongside exact edition and media-variant details, with account-bound metadata loading rather than title-based recording merges.

- Build the registered Linux dual-decoder test before CTest and always execute native reliability tests, including when kernel ThreadSanitizer entropy tuning is unavailable. Explicitly requested sanitizer instrumentation must be available; compilation alone does not establish runtime qualification.

- Browse live, profile-owned music listening occurrences through bounded cursor pages, preserving repeated plays and deterministic ordering without loading all history.

- Revalidate station previews before both Play and individual track selection. Reject account, hidden-library and download-ownership changes; play owned offline previews without an online fallback.

- Keep station storage-budget units and the unlimited marker inside the translated label on every base locale.

- Exercise independent concurrent music decoders against real Linux libmpv with generated PCM and null output, including separate gain and outgoing-core teardown. This is not acoustic or physical-device qualification.

- Restart the paired Linux music endpoint when reinstalling its service, preserve service files if stopping fails, and expose failed service status to diagnostic callers.

- Add a customizable Favorites music shelf and large driving shortcuts for favorites and owned downloads. Revalidate source visibility and download ownership before explicit playback in the shared session.

- Apply separate cellular and remote music streaming-quality overrides, with cellular taking precedence and unchanged original-quality offline downloads.

- Add estimated per-station download storage budgets with whole-album preservation, retry validation, and accounting for already linked download bytes during scheduled refreshes.

- Remember the last 20 explicitly submitted searches per profile, with one-tap replay, individual removal, and clearing. Typing alone does not save partial queries.

- Keep failed station download batches separate from bounded offline snapshots. Migrate older retries without losing their candidates, prune only snapshot metadata, and reject saved tracks from a different library or account.

- Use revision-checked downloaded loudness analysis for offline fades and overlapping playback. Start repeated playlist tracks at the selected occurrence instead of the first matching song.

- Reject Chocolatey installer and package payloads larger than 190,000,000 bytes before submission, preventing scanner-size regressions without removing playback components.

- Add Friendgänger Guest DJ mixing across currently accessible friend-shared music libraries, preserving queue order and rejecting hidden, revoked, or account-switched sources.

- Correct maintained Dart, Kotlin import and Linux native formatting in the newly integrated music hosts. Include acknowledged paired music-queue transfer and stable Plex Home write scopes across token rotation.

- Capture one main workflow for exact-source reusable CI and every platform build. Create the stable tag only after all required CI jobs pass, so failed preflight candidates do not consume release versions. Preserve main-only private-runner access, use private ARM hardware when hosted capacity is insufficient, and select the intended simulator SDK runtime. Keep all native and artifact gates and delivery tooling separate from frozen product source.

- Deliver aerynOS packages automatically from complete published Pleazyng releases, retaining the original Linux artifacts and requiring native qualification before feed promotion. Wake delivery directly after core publication, with retries separate from core success. Retire the separate unreleased-source build lane and repair Search navigation in its native playback harness.

- Keep queued music ratings and station retries bound to the correct account. Older pending rating records remain stored but no longer replay automatically.

- Stage the locked iOS device worker framework before Release linking and verify its resolved search path and ARM64 slice. Link the webOS worker's existing atomic operations against the SDK's shared runtime and support explicit iOS recovery without rebuilding successful platforms.

- Run tvOS release AOT compilation on a compatible ARM host and support verified tvOS-only recovery while retaining successful immutable artifacts from every other platform.

- Keep the main run loop available during real Apple H.264 pixel qualification, distinguish pause event-queue recovery from immediate intent updates, and retain failed native test results for diagnosis. Use a consistent bounded completion budget for Apple native callbacks and scheduler barriers while preserving playback timing and PiP timeout assertions.

- Make tvOS native qualification await the real Dart database startup and verify its SQLite version against the embedded source receipt before the XCTest host exits.

- Embed the iOS game worker before Flutter/CocoaPods bundle postprocessing so Xcode can process the app's Info.plist without an extension-copy dependency cycle. Distinguish bridge-owned Objective-C exports from Foundation classes supplied by the OS during tvOS validation.

- Include genuine tvOS builds of the Dart Objective-C bridge and process-wide PDFium gate alongside SQLite; verify their locked source recipes, native exports and platform metadata before embedding. Use the current SDK's optional Boolean Siri resume/shuffle properties directly.

- Build and embed SQLite from checksum-pinned source for the actual tvOS device/simulator SDK, preserving the locked Dart package's compile options and FFI exports. Verify a real Dart database open and SQLite version during native qualification. Correct the iOS intent-handler override for the current Flutter SDK and allow Apple test queue barriers to tolerate startup work.

- Link the C++ runtime in every production iOS emulator-worker configuration, and verify that setting without a qualification-only linker workaround. Keep the release controller alive across bounded retries of transient GitHub inventory failures.

- Automatically deliver every complete fresh release to the configured Google Play testing track, verify the committed bundle, preserve interrupted uploads for retry, and serialize release builds and app-wide Play edits. Retire the old v3.0.7 store-repack workflows.

- Support task-owned GitHub-hosted Apple source workspaces in AppleDouble cleanup while retaining exact run/source checks and the private NFS ownership fence.

- Fix Tizen ARM sandbox compilation by declaring the ELF architecture constants required by its older audit headers; retain the existing fail-closed syscall policy.

- Prepare 3.0.31+190 as a fresh all-platform release from current source, including the shared native-video aperture clear and expired-trial review navigation repair. Supersede the v3.0.7 channel bootstrap for usable publication; preserve its original artifacts and failure evidence.

- Fix store-review access after trial expiry: retain dialog navigation on the locked screen, dismiss the review dialog with Back, and restore normal application navigation after a valid grant.

- Correct iOS local pod checksums using CocoaPods canonical metadata and check the isolated worker lock on every Apple validation.
- Lock the isolated iOS emulator worker and its current pod specifications so deployment-mode CocoaPods installation succeeds.
- Fix macOS LuaJIT architecture verification with current Xcode tools so native builds can validate the bundled runtime.
- Integrate all three previously deferred native playback changes into normal packages: [Amlogic Dolby Vision letterboxing](https://github.com/edde746/plezy/commit/63f8cd5a054e2ecc5c28dd30fe8066f4356a10c4), [Apple GLSL presets and ambient lighting](https://github.com/edde746/plezy/commit/2e1654b316150f59cbc4774602ed4f02a3515527), and [Amlogic/MediaTek TV subtitle timing](https://github.com/edde746/plezy/commit/6cc283a7da3d75ed90ec232dd7f5da1f25681b4f). Independently adapted from changes contributed upstream by [@edde746](https://github.com/edde746), preserving Pleazyng's FEL/HDR/neural components and Android ExoPlayer Lanczos support. See [behavior and qualification](docs/plezyng/playback-compositor.md) and [source credit](UPSTREAM_ATTRIBUTION.md#native-compatibility-integration--packaged-and-verified).
- Fix an embedded macOS startup deadlock found by real headless playback: skip PCM-tap teardown for temporary Cocoa clients that never owned a tap. Verify shader implementations in every packaged Apple architecture and retain a real GPU playback regression probe.
- Fix Windows workspace-window compilation with the supported Windows SDK target while retaining monitor-aware sizing.
- Prepare v3.0.24 from the corrected desktop workspace integration and current main, retaining the upstream source credits and Apple runtime compatibility backport.
- Build and relocate the bundled GTK input-method cache in Linux bundles and aerynOS packages so fresh password entry uses the matching shipped modules. Preserve locale-capable input methods and gate snapshots on ordinary fresh sign-in.

- Add the ordinary Linux snapshot builder and fresh native aerynOS VM harness for continuous channel qualification; automatic feed promotion is being integrated separately.

- Preserve selected source files when copying recovery entries, allowing offline recovery validation to compile and verify edition changes.
- Localize the new music audio and headphone controls across supported languages.
- Complete translations for the new Seerr request actions and source setup guidance.
- Backport the Swift 6.2 compatibility fix from [AetherEngine commit fa8cc48b](https://github.com/superuser404notfound/AetherEngine/commit/fa8cc48b93a5b9c83367bf4fb3d731fb3862a177), contributed upstream by [@superuser404notfound](https://github.com/superuser404notfound). This credits the upstream contribution, not a direct contribution to Pleazyng.
- Qualify and publish an independent aerynOS preview from source 3.0.22+181: native install, visible video, automatic Profile 7 routing and renderer-startup fallback pass in the VM. Keep physical HDR/FEL accuracy unqualified and preserve the immutable v3.0.7 failure record.

- Prepare aerynOS recipes independently from x64 checksums, and restore aerynOS as a downstream publication target subject to native qualification.
- Record the complete review of 64 upstream commits through Plezy 2.26, with originating commit and contributor links, retained fork behavior and packaged native integrations. Pleazyng keeps its name, logo, native components and GPL license file; the upstream trademark policy is excluded. See the [review and source credits](docs/maintainers/upstream-sync-2026-11-09.md).

- Run post-publication catalog verification through a read-only reusable workflow, preserving automatic validation while removing the privileged workflow-run trigger rejected by repository policy.

- AppImage update metadata and verified zsync sidecars: build x64 AppImages with fork-specific update information, verify control-file names, blocks and digests, checksum and attest both artifacts, and preserve immutable legacy images without update metadata. Independently adapted from [upstream d832b421](https://github.com/edde746/plezy/commit/d832b4212ceabc68bfee6785177f40bd2a724723), contributed upstream by [@nataloko](https://github.com/nataloko); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).
- Restore interrupted source audio, books and readers from the media-session tray using current profile authorization and the exact saved edition. Keep source URLs out of workspace snapshots, preserve background audio checkpoints, and prevent delayed resume requests from replacing a newer player.
- Repair the TV containment workflow after its integration script was renamed.
- Prepare the Flutter 3.47.8 security engine while retaining the Windows presentation fixes independently adapted from [@edde746's upstream patch series](https://github.com/edde746/flutter-plezy/commit/06654fe6ff3fff67fdaa74e2a7c41ecbbc90bee2). Build validation and release SDK migration are pending; see [source credit](UPSTREAM_ATTRIBUTION.md).

- Restore downstream aerynOS recipe preparation and isolated native qualification under the owner’s subsequent explicit restore-and-continue instruction. Public availability remains conditional on qualified artifacts; no official repository entry is implied.

- Enable automatic Dolby Vision/Profile 7 FEL routing and compatibility fallback by default. Preserve explicit Off and manual conversion choices, try implemented local Android/Apple/desktop paths before server conversion, and retain ordinary Apple playback when the bundled DV runtime cannot initialize. Keep qualification and actual layer use explicit; neural motion smoothing remains separately opt-in.

- Add a quota-bounded, authorization-scoped music prefetch cache with Wi-Fi policy and partial-file cleanup. Separate the AAOS host-rendered media build from parked video restrictions, retain one player session, and make headphone search usable with large text and a keyboard.

- Add full-library album anniversaries, per-output music EQ assignments, and 6,029 offline-searchable headphone profiles derived from [AutoEq](https://github.com/jaakkopasanen/AutoEq) by Jaakko Pasanen and contributors under the MIT license. Explicitly identify ten-band approximations, retain source provenance and display the license in-app. Preserve station sort direction and clarify sort labels.
- Integrate a configurable Music home, device-local listening history/charts, six Guest DJ modes, saved filter-based stations with scheduled downloads, opt-in prompt playlists, music ReplayGain/EQ/preamp/output controls and named presets. Reuse existing profiles, library filters, playlists, downloads and Now Playing; protect pending work across account changes.
- Retain authorized lyrics and bounded seek-print analysis with downloaded music, add per-track lyric timing, durable music links and queued rating/favorite edits. Keep offline station playback limited to the active profile's completed downloads.
- Add shared iOS phone/CarPlay engine startup, Siri media intents, Android headless device/restriction handling and background profile-frame scheduling; expand native playlist browsing and prevent pagination from consuming CarPlay navigation levels. Native signing/build/device qualification and remaining parity code are tracked in `docs/plezyng/music/STATUS.md`.
- More reliable iOS speed-change qualification: test the immediate position jump and the steady rate after output restarts, retaining the fork’s simulator limitation and deterministic flush-order coverage. Independently adapted from [upstream 48926474](https://github.com/edde746/plezy/commit/48926474e863b8079558e41cb1d4776439ed1555), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Keep the descriptor-worker integration check in its dedicated native isolation lane, using its required verified headers, instead of accidentally invoking it as an argument-free Python unit test.

- Translate the seven new Seerr request and availability-alert messages across all supported locales, removing their temporary English fallbacks and reducing the fallback budget to its prior ceiling.

- Actionable tvOS trailers and external links: play library trailers internally, offer YouTube handoff only when its app is installed, hide unsupported browser links and report failed handoffs; preserve Seerr actions and block unsafe provider URI schemes. Independently adapted from [upstream 16d5b404](https://github.com/edde746/plezy/commit/16d5b404cb14163a776b701265e55b6f66cdfc34), contributed upstream by [@moust4ki](https://github.com/moust4ki); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Sheet safe areas beside a vertical system bar: remove the opposite status-bar inset and align hosted and modal sheets with the mobile content edge while retaining keyboard insets and back handling. Independently adapted from [upstream 04ec8506](https://github.com/edde746/plezy/commit/04ec8506c78dc29b4dfc18f751943fb6ecb89eec), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Adaptive fold and vertical-bar mobile layout: place navigation in the system bar, keep hosted sheets on one side of a fold and retain player ownership across route replacement; preserve the fork’s scrollable navigation and system-bar styling. Independently adapted from [upstream b4192d6f](https://github.com/edde746/plezy/commit/b4192d6f355921aa9dbdd89b000012e7c4496fa7), contributed upstream by [@v-vincere](https://github.com/v-vincere); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).
- Publish and natively qualify Pleazyng v3.0.7 channel repacks on AUR, Fedora COPR and the maintained Nix flake; submit the Nixpkgs package for review. Publish and install the signed Homebrew Cask, and activate the Google Play lifetime product while retaining the remaining store-review qualification gates. Replace pending installation text with the verified Pleazyng channel commands.

- Keep the descriptor-worker integration probe in its provisioned native workflow instead of executing it as an argument-free unit guard, and normalize the shared worker header so repository checks remain green.

- Switch Android mpv display mode before decoder creation: hold VOD decoding at demux preload while display matching settles, bound and cancel stale holds, reject predecessor-player tokens, and retain first-frame Live TV matching, Dolby/FEL routing and motion-processing output targets. Independently adapted from [upstream c577edda](https://github.com/edde746/plezy/commit/c577edda5cdf4b0a0c3d5dd0d543e432c5bed0d8), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).
- Translate the new Seerr availability-alert copy across all 32 base locales (with regional inheritance), and keep unexpected quick-request failures localized instead of exposing raw exception text.

- System certificate authorities for GitHub asset redirects: retain system-only certificate trust through githubusercontent.com redirects on Android and dart:io, without enabling the upstream anime-feed migration. Independently adapted from [upstream cbd9205f](https://github.com/edde746/plezy/commit/cbd9205f2cef71973dd7cadf568477c448cb3787), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Stable package publication metadata guard: reject GitHub pre-releases even when their tags look like stable versions, retaining manual publication and the fork publisher. Independently adapted from [upstream 1dd75b3e](https://github.com/edde746/plezy/commit/1dd75b3e5e95913cdaa5b8c22911490e72dfb7c5), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Windows pending-resize engine correction: pin the checksum-verified +2 engine for the existing Flutter ABI, retaining DirectComposition and x64/arm64 cache layouts; native Windows qualification remains separate. Independently adapted from [upstream 90b7ccca](https://github.com/edde746/plezy/commit/90b7ccca68cffcfe51fc8994c3463fcbf769ec18), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Hold playback beneath the resume profile picker: pause the covered player and refuse native, media-session, Watch Together and Play Next resume intents until profile selection finishes, preserving Automotive restrictions and active PiP. Independently adapted from [upstream 9fe138ab](https://github.com/edde746/plezy/commit/9fe138aba39414e38099cc17cfd4296f47059778), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Add optional title, library and global persistence for custom video zoom, retaining session-only defaults and bounded values. Independently adapted from [upstream e90973fb](https://github.com/edde746/plezy/commit/e90973fba999838fbeb9d14b8aa8226130918be8), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Allow trusted immutable version tags to run the same hosted hybrid CI and release matrix as `main`, so exact release-source validation and publication cannot race concurrent main-branch work.

- Repair AUR, COPR and Nix repacks of v3.0.7 with byte-matched WebKit helper processes, required sandbox tools and regenerated GTK image-loader caches. Qualify Nix WebView rendering and JavaScript with the WebKit process sandbox enabled. Existing GitHub release assets remain immutable.

- Pin hosted Apple jobs to the installed Xcode 26.5 toolchain and retry the exact locked nested Dolby Vision build once after Xcode's package-model abort, retaining verified task-owned checkouts while discarding partial build products.

- Keep focus visible on light surfaces, remove gray scrim bands and declare transparent status-bar styling for pages without app bars. Independently adapted from upstream commits [4eabc30c](https://github.com/edde746/plezy/commit/4eabc30c804c9e6869a8c48fa1d6d174f7d36fbb), [13426a00](https://github.com/edde746/plezy/commit/13426a00c034097b2301967f281adbfd58381598), [c7f86ab8](https://github.com/edde746/plezy/commit/c7f86ab85fbc2c3497676744b6b5b0b6907887d7), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Debounce artwork resize requests and retain resolution on shrink, keep Watch Together guests synchronized after version changes, and select Skia on Android devices without Vulkan 1.1. Independently integrated upstream contributions by [@strata-scribe](https://github.com/strata-scribe) ([38c48f14](https://github.com/edde746/plezy/commit/38c48f14ac4107cc94b2ab2f41444f0448d64da0)) and [@edde746](https://github.com/edde746) ([6c87210c](https://github.com/edde746/plezy/commit/6c87210c6162ecaf5e9a77560353a7948e1e93bd), [d2424018](https://github.com/edde746/plezy/commit/d2424018297a00fe1f8bc97ef2bb207f6a515499)); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Retain newly-online Continue Watching copies, reconcile artwork through the authoritative on-deck fetch, and undo display switches that finish after fullscreen playback has ended. Independently adapted from upstream commits [119ce59d](https://github.com/edde746/plezy/commit/119ce59def9eacef8ac70e2b8c0d7fdfe771e0a4), [f2985a7b](https://github.com/edde746/plezy/commit/f2985a7b06b1190507946cde824779880d7d2af8), [ddcfda3c](https://github.com/edde746/plezy/commit/ddcfda3c4e349ec315f1c5496a5a0e95128b6997), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Preserve companion-remote controls across reconnect, restore TV focus to newly opened pages and avoid a flaky diagnostic counter-order assertion. Independently adapted from upstream commits [e871d095](https://github.com/edde746/plezy/commit/e871d095171855914d8f0634b3507a80e67bedce), [5076836a](https://github.com/edde746/plezy/commit/5076836a5dbb2f54b8316fdcb9d94330c1ddbf01) and [55ef954e](https://github.com/edde746/plezy/commit/55ef954e23bbcb6fac81b15a84ff7442c87c6d58), contributed upstream by [@edde746](https://github.com/edde746); see [source credit](UPSTREAM_ATTRIBUTION.md#reviewed-upstream-synchronization--2026-11-09).

- Close Linux emulator sandbox gaps in shared IPC, descriptor signal ownership and newer metadata syscalls, including when compiled with older kernel headers. Remove inherited capabilities, preserve thread-creation fallbacks and add regressions using private file, semaphore and message-queue fixtures.

- Apply the repository's native Kotlin and Swift formatters to the integrated Android isolation, car adapter, and iOS application changes before release validation.

- Verify the retained-home playback fix through the production player route and scaffold for Linux, Windows, shared Apple/mpv, and Android/ExoPlayer. Cover background artwork updates, the first-frame cover during source reloads, preserved controls, and returning home.

- Generate AUR metadata with native makepkg so its public package index receives the package stanza, checksum the local recipe sources, and preserve native provider binaries when creating Fedora RPMs without synthetic debug packages.

- Build the nested Dolby Vision package graph directly from its verified `Package.resolved` pins, removing a redundant Xcode 26 resolve-only action that aborted consistently on hosted Apple Silicon.

- Retire the mutable updater-feed branch in favor of published release assets, preserve an immutable legacy updater bridge, and continuously audit/test the Decky build dependency graph.

- Verify the signed, ticket-stapled app inside the existing macOS disk image before publishing Homebrew, rather than requiring a second ticket on the outer image. Add a locked downstream Nix flake for the existing v3.0.7 Linux release.

- Remove the vulnerable deepmerge build dependency from the Steam Cloud Decky extension, preserve its host React/UI and ESM entry contract with an esbuild runtime regression, and integrate the reviewed UI, TypeScript, React types and tslib dependency updates.
- Repair existing-release Linux channel packaging: preserve binary payloads and root ownership in AUR packages, normalize bundled ELF search paths and GTK caches in COPR repacks, and add native x64/ARM64 Nix and macOS signature qualification without rebuilding application artifacts.
- Require OS containment for native RomM emulation on every platform. iOS, tvOS, webOS and Tizen builds without a supported isolated helper now report native play unavailable; core probing cannot load a library into the app. Existing downloads, saves and capability-checked browser/streaming routes are preserved. Android package validation now requires the isolated worker and the required JNI entry points.

- Isolate Android RomM cores in a permissionless service with a distinct UID. Pass only read-only game/firmware descriptors through a bounded virtual filesystem, retain audio and saves in the app, and wait for Android's process-death notification before releasing a session. Add device-runtime fault and access-boundary tests.


- Retry the nested Dolby Vision Swift package resolution once from clean task-owned state when Xcode 26 aborts inside its package-graph model; ordinary resolver failures still fail immediately.

- Keep mixed-library search expectations aligned with the supported Jellyfin/Emby book and audiobook item types.

- Install XcodeGen and Git LFS in Apple native CI before exercising generated Dolby Vision projects, matching the release jobs on both Intel and Apple-Silicon hosted Macs.

- Correct Pleazyng's Flatpak app-data path, sandbox wording, package filenames and Play test identity. Replace upstream installation directions with Pleazyng Pacman/RPM downloads and explicit pending channel status; add checksum-pinned Nix recipe preparation and a release qualification guide without claiming unpublished packages are available.

- Add a minimal native Requests destination for movies, TV seasons, ebooks and audiobooks with profile-owned status, discovery/search and basic details. SeerrNG book requests retain format-specific availability; the minimal flow keeps destination, approval and administrative controls in the server interface. Requested downstream by [@Tatsu941](https://github.com/Tatsu941) in [#267](https://github.com/snapetech-org/pleazyng/issues/267).

- Include Book and AudioBook items in Jellyfin/Emby All browsing and library searches, fixing ebook libraries that appeared empty until switching to Folders ([#266](https://github.com/snapetech-org/pleazyng/issues/266)).

- Separate comparison statuses from their explanations: put scope notes on a new line in italic parentheses in the README and website.

- Publish a responsive website feature comparison and link it from About and the repository. Use neutral capability names, concise comparison cells and linked evidence; preserve the current logo.
- Run desktop RomM cores in a separate sandboxed helper with bounded IPC, crash/hang recovery, parent-owned audio/saves, and OS-confirmed teardown. Package and sign the macOS helper, restrict Windows cores with AppContainer, and require Landlock/seccomp on Linux. Add real worker-fault validation across desktop operating systems; mobile and TV containment remains tracked separately.
- Automatically migrate untouched legacy webOS credentials to authenticated storage during startup, preserving concurrent changes and recoverability after interrupted writes.

- Run arm64-only tvOS simulator qualification on the documented Apple Silicon hosted runner, preserving Intel hosted lanes for compatible iOS/macOS checks. An Intel simulator host cannot execute the required tvOS arm64 destination.

- Include copyright metadata and a commit-pinned Pleazyng app icon in future Chocolatey packages.

- Integrate multi-seed music mixes, saved recipes, Plex sonic similarity and waypoint paths into artist, album and Now Playing screens; reuse playlist saving and downloads. Preserve full large queues in paged storage, add guarded radio continuation, album shuffle/skip, analysis seek prints, applied music EQ/normalization, signal-path information and a large-control driving view.
- Add native Android music browsing and CarPlay templates over the profile-owned music session. Native signing/device qualification and remaining Plexamp parity are tracked explicitly in `docs/plezyng/music/STATUS.md`. The existing [media-controls dependency](https://github.com/edde746/media_controls/tree/a27208e641790029ac54d825b97508575caee1a7), maintained by [@edde746](https://github.com/edde746), is vendored at its existing pin to extend its single Android media session; see [source attribution](UPSTREAM_ATTRIBUTION.md#music-media-session-integration).

- Preserve compressed RomM source archives and their receipt hashes inside Android packages by using asset-safe filenames; retire only prior archives verified by their own receipts.

- Package the embedded Android Moonlight and Steam receiver modules in ordinary app builds, including their native libraries and activity/stream implementations. Previously Gradle configured the modules without linking them into the application.

- Scroll Settings QA assertions into view on smaller phones before checking them, then restore the top of the list for deeper navigation checks.

- Prevent Android API 36 Back from navigating twice after keyboard use. While Flutter’s system Back callback is registered, let it own navigation instead of also forwarding synthesized raw Back keys; preserve predictive gestures, IME dismissal, and legacy/root Back handling.

- Retry Apple SwiftPM resolution once from a fresh run-scoped checkout after Xcode 26's internal package-graph insertion crash, while continuing to fail ordinary dependency errors without retrying.

- Make the fresh-install authentication QA flow use the setup screen’s Back control, avoiding a second navigation pop when Maestro hides an already absent keyboard.

- Remove obsolete karaoke translation entries after the room security changes, restoring strict translation hygiene checks.

- Use the verified `macos-26-intel` hosted image for Apple CI, signing preflight, and release builds after generic `macos-26` jobs were cancelled before receiving a public runner. Prepare the checksum-verified pinned Flutter SDK for either x64 hosted Macs or ARM64 private JIT, retaining the latter only for explicitly constrained execution.

- Fix native video being hidden behind media-detail artwork on Windows and other retained desktop surfaces. Clear only the video aperture after its first frame, preserving controls, surrounding workspace content, and the black startup cover ([#292](https://github.com/snapetech-org/pleazyng/issues/292)).

- Give hosted Apple validation and release jobs short, task-owned local scratch paths with bounded free-space checks and exact cleanup, while preserving the private NFS path for explicitly constrained Apple JIT runs.

- Route protected release-channel publication for containers, AUR, COPR, PPA, Snap, Chocolatey, and WinGet through compatible GitHub-hosted runners, removing the superseded private-JIT-only dispatch contract and container proxy requirement.

- Correct release-workflow guidance to match the hybrid profile: compatible Apple jobs use GitHub-hosted macOS runners, while storage-heavy webOS work retains its private JIT route.

- Add feature-documentation source footers with verified upstream PR/issue/commit links and author credits, turn the README's historical ticket numbers into links, and preserve the distinction between a source proposal and delivered behavior.

- Harden HTTP response memory limits, request cancellation, authenticated metadata origins, nested crash-report redaction, companion TLS admission, lending gateway concurrency, and provider request budgets. Local PINs use random-salt PBKDF2 verifiers with durable attempt limits and upgrade on successful activation; new webOS credential envelopes authenticate ciphertext and its logical key. Preserve HLS tail playback and renew active sharing leases. LAN sharing offers HTTPS and requires explicit consent for plaintext compatibility. Add automatic security regressions, enforced dependency locks, and weekly multi-ecosystem dependency maintenance. See `docs/security/audit-remediation-2026-11-09.md` for validation and remaining deployment, isolation and qualification work.

- Route trusted-main Apple validation and release builds through compatible GitHub-hosted macOS runners in the hybrid profile, retaining private Apple JIT only as an explicit fallback.

- Add a documented Plex/Plezy/Pleazyng feature comparison, distinguish inherited features from fork additions and Plex-only gaps, and correct media-link examples to `pleazyng://`. Pleazyng independently verified the upstream inventory at [commit `738e18fdc5`](https://github.com/edde746/plezy/commit/738e18fdc552ace910dedabf6e689ab74e1dae58), authored upstream by [@edde746](https://github.com/edde746); see the [source credit](UPSTREAM_ATTRIBUTION.md#feature-inventory-reference).

- Publicly credit 89 Plezy pull requests, issues, commits, and the pinned upstream inventory whose code, reports, or ideas informed implemented behavior or maintained plans in Pleazyng. The [source ledger](UPSTREAM_ATTRIBUTION.md) separates shipped adaptations, related feature context, and planned work and makes clear that those people contributed to Plezy, not directly to this fork.

- Reuse already verified Android SDK packages and retry failed SDK Manager requests before failing, preserving toolchain pins and avoiding unnecessary hosted-tool updates.

- Rebuild canceled or timed-out Android jobs during verified platform recovery while continuing to reject their artifacts for reuse.

- Disable duplicate Gradle file-system watches in ephemeral Android CI, retain dependency caches, and provide verbose build progress with bounded JVM diagnostics without stopping builds for system load.

- Include all transitive Python helpers in the release assembly checkout, check imports in isolation, and reuse verified webOS packages during an assembly-only retry.

- Link the webOS navigation channel to the existing pinned Flutter common runtime, verify that ARM link before SDK builds, and retain verified Linux/Mac repair artifacts across a webOS-only retry.

- Start independent recovery builds while source Android is still running; require its completed successful job and verified artifact before final release assembly.

- Verify the original PDFium CocoaPods XCFramework download through the asset API and allow a fresh qualified Mac build during artifact recovery without repeating successful platform builds.

- Keep download diagnostics out of CMake path output and support explicitly rebuilding Linux during verified artifact recovery, retaining required Mac notarization and Gatekeeper qualification.

- Supply the pinned Python installer loader path and support completing Apple builds for verified recovery after another platform fails; preserve immutable application CI and reject changed native download pins.

- Prefetch and install the exact webOS Python 3.14.8 archive before setup-python, retaining existing tool caches and the upstream installer completion checks.

- Prefetch the pinned SMB hook, Apple torrent CMake sources and Linux native archives through the same verified API path, preserving their original shared-cache layouts and native hashes.

- Stage pinned PDFium, Gradle, CMake sources, Windows tools and webOS toolchains through verified GitHub API downloads when release-page transport fails, preserving source pins and isolated native ABI outputs.

- Accept canonical pleazyng build provenance in TV packages and prefetch checksum-pinned SQLite, libdovi and AppImage runtime assets with verified retries. Reuse immutable application CI only after checking that subsequent changes are confined to release infrastructure.

- Set Flutter and webOS versions together, and validate package metadata in commit/CI guards and before the release driver starts CI or creates a tag.

- Preserve pointer entry and text-field focus while giving submenu Back handlers their own focus scope; retain staged filter edits until their parent editor closes.

- Keep native TV exit disabled while a dialog or another focus scope covers the home sidebar, including dialogs above the profile navigator.

- Unwind remote and system Back through playback submenus, options and paused controls before leaving the player; reserve native TV exit for the home landing page.

- Keep the canonical GitHub update feed on system certificate authorities in Android and Dart.

- Rename the GitHub repository and local checkout to pleazyng, update canonical links and runner routing, and preserve historical release verification through the original repository identity. Refresh Apple podspec metadata checksums, check them before native compilation, and recognize renamed workspaces during scoped build cleanup.

- Apply source-aware audio diagnostics to Samsung Tizen, retain native channel/rate/bitrate data, and reject contradictory source hints. Refresh spotlight and queue artwork on server changes across layouts, and cancel unfinished redirect bodies in the shared native TV proxy.

- Keep live-program and audio-format header subscriptions independently keyed, and avoid resolving an artwork URL when an item has no picture.

- Fill LG's unknown direct-play audio labels from matched original-source metadata with explicit diagnostic provenance, and stop unsupported desktop media-control calls on native TVs.

- Keep bounded redacted diagnostics in native TV app storage, including active webOS audio format changes, so playback and artwork failures can be inspected without switching the TV input.

- Recover home artwork after server reconnects and endpoint changes, keep image requests on their owning server, and use available fallback pictures for wide preview cards without remembering transient failures indefinitely.

- Show the active audio format and channel layout in playback controls, and supply native webOS codec, sample-rate, channel and bitrate diagnostics to the performance overlay.

- Keep client-only subtitle selections from burning an unrelated server-selected track, and bound redirected webOS subtitle downloads without consuming redirect bodies.

- Render local and HTTP-delivered Blu-ray PGS subtitle images over native webOS video, preserving authored positioning, transparency and timing without subtitle burn-in.

- Stream macOS release build output in verbose mode to bypass Flutter's quadratic filter on long native linker commands.

- Resolve the macOS app to its local APFS path before Gatekeeper assessment, avoiding permission failures through protected NFS source workspaces after successful signing and notarization.

- Keep Apple process observation running when a system process query is delayed under Xcode load; retry the query instead of turning successful native tests into a cleanup failure.

- Detect LG native playback silently dropping all audio tracks from an audio-bearing source, then perform the bounded audio-only compatibility retry; preserve supported passthrough and genuinely silent videos.

- Remove duplicate webOS evidence JSONs from public downloads while retaining them in the verified submission ZIP; keep macOS recovery reports in CI and preserve package provenance and Discord delivery deduplication.

- Preserve native webOS direct play and receiver passthrough on the first attempt; retry audio conversion only after explicit native audio-format rejection, retaining compatible HEVC/HDR video copying.

- Stop only the completed Apple build’s recorded orphaned Interface Builder services before scratch cleanup, preserving active compilers and unrelated processes.

- Wait for both the Apple job and workflow to finish cancellation before draining their recorded build processes, preserving the terminal-state checks during GitHub's transition.

- Refresh public release availability automatically after publication, distinguish GitHub's branch target from the immutable build tag, and preserve historical absence evidence without blocking CI on stale facts.

- Prepare the complete Pleazyng 3.0.4 corrective release with package build 163, including all current-main fixes and every required platform.

- Recover the unfinished Apple runner process observer, retain cancelled-job scratch before cleanup, and drain only captured build descendants after verified cancellation while preserving other jobs.

- Separate webOS video slots from UI audio, propagate native load failures before disposal, release failed controller creation for retries, and preserve HLS/DASH transport hints behind authenticated proxy URLs.

- Update device acceptance for search submission, single-Back playback exit, compact download menus and scrolling service pages; retain all Maestro artifacts in the requested directory and document the full headless qualification procedure.

- Route offline playback acceptance through its dedicated CI control proxy, and reject direct attempts without that proxy before building or installing.

- Consume Android's duplicate system Back callback while the app owns a held Back key, preventing a single press after text input from closing two profile or settings screens while preserving gestures and app exit.

- Give the media-detail overflow button a localized accessible name so phone users can discover actions such as Download after the toolbar compacts.

- Update device acceptance flows for the local HTTP consent dialog, current profile labels and keyboard dismissal, and allow installing test-only Android APKs in the headless runner.

- Keep native instrumentation facade APIs and callbacks in the test-only Android variant, and pass complete MPV arguments so release optimization does not remove test entry points.

- Finish source database initialization before opening another connection, preventing first-launch SQLite migration races that can interrupt profile teardown and logout.

- Package matching release Flutter engine and Dart artifacts in Android's minified validation build, and boot its activity during instrumentation to catch VM startup failures.

- Keep the library picker visible on phones by placing toolbar actions in an accessible overflow menu and truncating long library titles within the available width.

- Make the compressed-subtitle boundary fixtures use explicit best compression so their original size and compression-ratio assertions remain valid with newer JDK zlib versions.

- Preserve ML Kit's manifest-discovered registrar constructors during Android shrinking so on-device translation can initialize, and exercise them in the minified instrumentation suite.

- Point every Maestro end-to-end flow at the current Pleazyng application ID and guard it against Android identity drift.

- Include the safe HTTP helper in the Jellyfin test fixture image, make its seeded configuration writable by the non-root server, and supply translations to the TV games acceptance harness.

- Fix the Steam timer teardown call after adapting queue callback signatures, restoring native builds with strict C pointer checks.

- Document clean rooted-TV deployment of the published webOS IPK, and keep SSH input open while observing native install/remove completion without requiring the ares CLI.

- Skip nonexistent log downloads for skipped Apple jobs during artifact-only release recovery, avoiding misleading warnings and repeated delays after successful assembly.

- Verify an existing immutable release tag immediately before draft creation, and use the default branch API permission target so release-only recovery works with the normal GitHub token.

- Remove validated interrupted-signing temporary files and NFS AppleDouble metadata from the owned macOS signing copy, and canonicalize identical entitlement keys without changing effective permissions before sealing nested bundles.

- Retain a verified APFS compilation snapshot automatically before Mac signing, preserve it after packaging failures, and remove only that snapshot after successful DMG upload.

- Assemble the complete release from verified original platform artifacts and a fully qualified Mac packaging recovery, preserving exact-source CI, native inputs, all platform requirements and signed provenance.

- Allow signed macOS-only validation and compilation recovery with the hybrid runner profile, retaining main-ref and CPU baseline checks.

- Recover a completed same-version Mac compilation for signing-only validation with explicit source, job, tree-hash and compiler-setting evidence; signing, notarization, Gatekeeper and package checks remain mandatory.

- Make copied read-only macOS frameworks writable inside the owned app bundle before re-signing, preserving shared caches and rejecting external bundle symlinks.

- Validate macOS Developer ID signing, timestamp access and notarization credentials before compilation, using a checksum-pinned job-local intermediate without duplicate imports and restoring the original keychain search list.

- Drain active jobs after a release platform fails, preserve their artifacts and diagnostics, and stop obsolete queued Apple builds automatically.

- Resolve webOS audio visualization namespaces, retain textures for the legacy SDK lifetime, and compile-check every audio plugin source before building the engine.

- Restore the Tizen visualization helper execute permission after SDK packaging without changing signed file contents, and retain failed package diagnostics.

- Make scheduled HLS completion tests independent of machine speed while preserving complete-segment AES decryption checks.

- Isolate RomM manual PDF rendering behind the TV platform adapter, preserving supported PDF viewers and detecting unsupported Tizen imports before native builds.

- Prepare the complete Pleazyng 3.0.3 corrective release with package build 162, preserving the earlier immutable tags.

- Publish QAIRT context manifests atomically and reject previously published output directories, preserving valid package metadata after interrupted builds.
- Identify native Tizen video output in playback diagnostics when the player reports no output property.
- Keep Google Tensor export filenames and provider keys consistent with runtime model packs, accepting compiler-suffixed output names without selecting other targets.

- Keep local and CI build validation independent of SDK analytics requests while retaining every diagnostic and check.

- Retain Windows visualization helper debug symbols in the build artifacts directory rather than shipping them in the application bundle.

- Build the Tizen visualization helper with the bundled Khronos EGL headers and include those headers and notices in its corresponding source archive.
- Prepare Apple release sources from the exact Git revision without copying ignored caches or filesystem provenance metadata over NFS.

- Stage the executable Pleazyng launcher consistently across Linux release bundles, CI, Snap and COPR packaging.
- Check localization source-review snapshots and generated native resources before committing, matching the release CI checks.
- Derive tvOS framework deployment metadata from every selected Mach-O slice, correcting read-only build copies while preserving shared caches and genuine higher runtime requirements.
- Accept canonical and legacy Pleazyng deep links in the shared Apple handler, with native alias tests and registration consistency checks.
- Harden edge OAuth against oversized-body stalls, cross-site session creation and single-client daily quota exhaustion; apply consistent browser security headers.
- Preserve successful GitHub releases when later notifications or store/package publication fail, and support targeted channel retries against immutable release artifacts.
- Keep WinGet and Chocolatey metadata preparation independent of required platform artifacts and checksums.

- Keep edge-hosted provider authorization redirects in the browser instead of following them inside the relay.

- Host MyAnimeList and AniList sign-in on a bounded Cloudflare OAuth service while preserving existing callback URLs and local Trakt and Steam authentication.

- Pin all native playback platforms to the current verified fork revision and reject stale native dependencies before release builds.
- Add Trakt browser sign-in with S256 PKCE through the owned HTTPS relay while retaining TV device-code sign-in; include Trakt attribution and privacy/disconnect information.

- Sign macOS helpers and nested code before sealing their containers, preserve helper entitlements, and refresh runtime receipt hashes after final signing.

- Preserve macOS exception handling across the bundled Rust, LuaJIT, Objective-C and C++ runtimes by packaging the pinned LuaJIT archive as a separate signed dynamic library.
- Update the iOS native tests to import the renamed Pleazyng application module.
- Keep the native tvOS Steam HDR plane compatible with the tvOS SDK while preserving its 10-bit PQ presentation path.
- Run the two Linux sanitizer jobs concurrently on hosted runners while preserving private-runner serialization.
- Configure hosted Ubuntu mirror-list files as well as classic and Deb822 package sources, so CI and release downloads use the official HTTPS archive with bounded network retries.

- Use the macOS SDK's OpenGL 4.1 profile constant in both visualization hosts so the bundled runtime compiles on current Xcode versions.

- Isolate Apple Dolby Vision runtime subbuilds from the enclosing app's Xcode settings, preserving unique framework outputs, pinned dependencies and the older API deployment floor.

- Select Rust compiler tools from the isolated pinned toolchain so Apple visualization builds do not depend on global Rust shims.
- Keep validated Steam relay ports explicitly typed as 16-bit values in Windows builds.
- Use Ubuntu's main HTTPS archive for hosted Linux sanitizer dependencies, with download retries and timeouts while preserving private-runner package sources.

- Respect disabled audio in controller-only Steam sessions and keep codec negotiation tests explicit about video and input capabilities.
- Match Steam worker, timer and queue callback signatures to the APIs that call them.
- Accept Xcode-created empty visualization output directories while retaining artifact verification.
- Keep Windows visualization paths and ABI comparisons compatible with strict C++20 builds, and use the existing Flutter monitor-DPI helper for detached playback windows.

- Build the renamed application target in both Linux native reliability jobs, with one shared check for Linux and Windows target names.
- Correct Apple local pod checksums using CocoaPods' installed JSON specs, preserving dependency versions and deployment locking.
- Repair mGBA DMA logging for Windows compilers without changing log behavior; ship the generated build source, hashes and recipe alongside pristine upstream sources.

- Accept registered `pleazyng://` links in the Android native handler while retaining legacy aliases, and check native acceptance alongside platform registrations.
- Keep Apple CocoaPods lockfiles aligned with the bundled game cores and recording plugins while preserving existing dependency pins.
- Declare OpenGL/GLX and Wayland server libraries found in the complete Linux bundle across the Debian, RPM, PPA, COPR and Snap recipes.
- Run independent Android, Linux native and server CI jobs in parallel while preserving all required release checks.
- Build the bundled Windows game cores and streaming helpers with the conforming preprocessor, macro-safe controller argument names and warning-clean audio/video code.
- Correct scalar affine matrix transposition and preserve translation in ARM64 streaming transforms.

- Build the bundled Apple game host and cores on current SDKs with correct Objective-C++ audio support, SDK capability detection and finished-framework selection.
- Keep Windows native CI aligned with the renamed application target and check out only the runtime's corresponding source when building MilkRust, avoiding unrelated overlong preset paths.
- Restore the truncated Linux gamepad input/hotplug handlers from the checksum-verified upstream package, preserving local effects support, and include the standard exception header used by playback.
- Keep the private Mac awake automatically for each ephemeral runner's lifetime, releasing the idle-sleep assertion when that runner exits.

- Prepare the pinned visualization runtime before desktop CI configuration, refresh Apple packages before Flutter configuration, and resolve Xcode SDK paths when packaging bundled game cores.
- Validate documented release absence against authenticated GitHub metadata without treating authentication or server failures as an absent release.

- Preserve UTF-8 extension bytes when selecting visualizer texture decoders under C++20.

- Allow explicit signed Apple archive and notarized Homebrew Cask qualification during GitHub-only releases, validating requested steps and assets without enabling store uploads.

- Bundle the pinned native Vulkan loader alongside libmpv and shaderc, preserving its symlink chain and rejecting stale native archives without it.

- Require compiled PME Vulkan evidence in every Linux and Windows native package before promoting application pins.

- Build and bundle the Samsung neural provider automatically in ordinary Android builds, retaining vendor licensing and checksum-bound source receipts.

- Include implemented neural/NPU experiments in normal compatible builds with the persisted Motion smoothing → Neural opt-in, and bundle Intel NPU and Vulkan GPU providers together on Linux x64.
- Reject CRLF header injection in the Apple experimental playback bridge, including headers supplied through MPV change-list commands.
- Declare the Vulkan loader and other shared-bundle runtime dependencies consistently in PPA, COPR and Snap packages, and verify alternate recipes against the canonical Linux package lists.
- Repair Apple Distribution PKCS12 import and certificate-chain resolution, validate new-bundle profiles, and archive iOS/tvOS with separate app/extension signing bindings.

- Curated title extras with strict identity and publisher checks, bounded previews, profile-specific exclusions, and optional evidence-backed AI search.
- Isolate Steam relay regression tests from a running desktop Steam client and model server deletion permission before validating shared-file deletion.
- Add Microsoft Store lifetime billing with verified online licence ownership and separate trial/IAP MSIX payloads; preserve free direct Windows downloads.

- Refuse incomplete native engine pin promotions and retain checksum-bound package receipts for every required architecture and implemented neural path.

- Keep Homebrew release checks aligned with verified repository downloads and versioned Cask publication.

- Size Apple Flutter SDK disk preflights from verified archive metadata with a 4 GiB local reserve and 12 GiB runner admission floor; recover NFS mounts through the stable VPN route without depending on a hung app command.
- Complete privacy translation fallbacks and stabilize local artwork regression checks by waiting for actual asynchronous file resolution.
- Resolve the Apple runner's GitHub API repository from the checkout independently of product rebranding.

- Target Amazon API uploads by the console App ID and preserve listing metadata, artwork and review state during binary updates.

- Fix Android Clang compilation of the visualization GPU drain callback while preserving the graphics loader ABI.

- Fix malformed Steam input-only and Granite patch headers that blocked fresh Android/Fire TV builds, and expose native source preparation errors before compilation.
- Keep service endpoint regression tests and store-preview tooling aligned with the current Pleazyng integration.

- Require a signed Amazon Fire TV / Stick APK and verification receipt in release assets, with an Android-only validation build and the renamed Amazon lifetime unlock SKU.
- Translate all caption and speech-processing status messages across 37 locales, verify generated locale resolution, and record the completed audit regression checks and remaining delivery gaps.
- Batch Android download capacity checks with bounded byte/time budgets, retain disk-full handling through flush/close, and keep restored downloads with missing managed media available for retry.
- Exclude replaceable Android/macOS offline media from backup, recheck Jellyfin/Emby deletion permissions, prevent repeated remote context actions, and record consistent HDR configuration diagnostics across platforms.

- Keep configured service endpoints on system certificate trust, validate storefront brokers, repair rebrand-sensitive regression fixtures, and verify native torrent reads beyond 4 GiB.
- Record current release availability separately from historical publication evidence when the recorded release is no longer returned by GitHub.

- Share a Dart source formatter that preserves canonical generated files, preventing formatting and generation from repeatedly invalidating each other.

- Run the full Flutter application regression suite once in the required Unit Tests job, preserving browser and vendor coverage without repeating the suite during code analysis.

- Repair integrated Games, RomM, karaoke, visualizer, localization and native runtime build failures. Keep optional fork services from breaking local Games and companion remote sessions when no relay is configured, and preserve results and filters during progressive search.

- Include webOS and Tizen in every complete versioned release, verify actual package source and checksums, and build the release matrix once after exact-source CI. Keep physical-device qualification separate from feature availability.
- Isolate offline converter workers from app and Python loader overrides so bundled runtimes also work on newer Linux distributions with a different system shell.
- Prepare 3.0.1 with matching webOS metadata and a shared Linux client SDK that resolves without the producer's private Lua and Wayland protocol build dependencies.
- Open bundled offline HDR10/SDR exports from Playback settings when Dolby Vision experiments are enabled; select synchronized layer files and save a new local MKV without replacing source files.
- Package a self-contained Linux FEL-derived HDR10/SDR converter with its Python runtime, decoder, compositor and encoders; verify actual exports without network access or system tools. Keep Apple experimental video below Flutter controls and make incremental runtime packaging repeatable.
- Bundle experimental Dolby Vision/FEL playback in normal compatible builds and use a persisted, default-off Settings switch. Add an in-app Apple runtime for macOS 15 and iOS/tvOS 18 while retaining the normal app deployment floors; device output remains unqualified.
- Keep Android FEL reconstruction controlled by the runtime experimental setting when a FEL-capable engine is bundled.
- Build the pinned MilkRust runtime with its corrected dependency lock and compiler fixes, keep isolated rustup installs independent, and verify bundled presets through actual GL/GLES rendering.
- Correct the v2 torrent transfer fixture and update remote playback reporting and P2P storage documentation.

- Preserve search results on cancellation and filters during partial responses, and keep optional relay absence from crashing settings.

- Build and package the three default RomM emulator cores with the app, preserve their source/notices, validate Android delivery, and install the desktop host after bundle cleanup.

- Preserve typography sizes when applying theme packages, reject encoded RomM path traversal before URL normalization, trim karaoke VTT terminators and distinguish damaged recording data from I/O failures.
- Register the selected Plex version and stacked part before direct play; keep stream identity across external-player and Cast progress reports, and recheck server deletion permissions before removal.
- Add held-select context actions to focusable list rows, a per-launch Linux HDR output override, and iOS backup exclusions for managed downloads and artwork.

- Keep automatic download rules stopped after storage exhaustion until an explicit download or retry; batch desktop capacity checks within a bounded write budget and count reclaimable iOS storage.

- Fix karaoke file-picker/TV APIs, nullable media titles and optional player interfaces; register desktop microphone capture plugins.
- Patch Steam Cloud plugin build matching and cleanup dependencies while preserving the Decky Rollup preset.

- Restore truncated Games screen actions and repair malformed visualizer validation and RomM save-key syntax.
- Rebrand the app and generated platform artwork as Pleazyng by SnapeTech, migrate public package identities and media/OAuth links, and align future release and package recipes while retaining the current repository name.

- Declare the RomM WebKit runtime in Linux packages and keep release-recovery checks aligned with mandatory webOS delivery.
- Patch the karaoke separation runtime, constrain local model checkpoint loading, and verify CPU stem generation with the current audio backend.
- Fix the black screen after sign-in when a profile binds before the file-source database finishes opening, and retain bounded webOS widget-error diagnostics.
- Resolve webOS dependencies once with the enforced lockfile, keep its package version at 3.0.0, and reject stale package metadata before starting a build.
- Announce published stable releases to Discord automatically, including GitHub-only releases, and retain per-message delivery receipts for safe retries.
- Share Android CI/release caches and apply the Maven Central mirror before Flutter's included Gradle build resolves plugins.
- Keep Apple JIT queue discovery active before platform jobs appear and retry failed launches while their jobs remain queued.
- Keep Swift package resolution inside each Apple job's DerivedData directory so completed JIT jobs reclaim that output.
- Reclaim default Xcode DerivedData belonging to a completed Apple JIT job after retaining its logs and failed build products.
- Set the Apple JIT APFS admission floor to 37 GiB, matching the pinned Flutter installer’s 30 GiB reserve plus 7 GiB install headroom.
- Automate serial Apple JIT job handling in release runs and preserve per-job diagnostics.
- Pin the validated WebOS engine archive produced by the release builder and keep GitHub-only macOS artifacts unsigned unless notarized Homebrew preparation is requested.
- Bound the Flutter Chrome CI browser test and per-test timeout so stalled runs terminate.
- Verify the WebOS objcopy tool with the same install-root-normalized hash used by the pinned NDK environment check.
- Keep 3.0.0 iOS and tvOS developer artifacts available for GitHub-only releases, with signed App Store IPAs behind an explicit opt-in.
- Normalize LG NDK tool and environment-fragment hashes across per-run installation paths so the WebOS candidate verifier accepts the checksum-pinned SDK.
- Fix tvOS release framework selection, Windows app-local runtime installation, Android R8 compatibility, WebOS SDK setup, and trusted-main hosted Linux Snap packaging.
- Keep the Windows CMake install prefix concrete while routing runtime files, libraries, and notices to the executable directory.
- Build macOS release candidates with Flutter's Xcode signing overrides before optional Developer ID signing and notarization.
- Cache and verify the pinned FFmpeg header archive for Android private JIT CI and release builds.
- Use direct FFmpeg downloads only on the trusted public hybrid lane, run native formatting on hosted Intel macOS, and keep Flutter Windows plugins on MSVC while building the ARM64 Whisper dependency with Clang.
- Retry transient TLS resets in Windows Flutter setup and wait for slow iOS simulator decode callbacks.
- Fix WebOS release candidate setup when the verified LG NDK installer is downloaded without executable permissions.
- Give the LG NDK installer system Python and core utilities while isolating setup-python's library path.
- Source the LG NDK environment without setup-python's inherited loader path, then restore libpython for the Python 3.14 engine tools.
- Restore GGML import-library dependencies to the Windows ARM64 Whisper plugin link interface.
- Fetch full Windows source history so the pinned Opus CMake version probe can resolve tags.
- Mount Apple JIT source workspaces under writable `/Volumes` so the Mac can provide the short NFS path without changing its sealed root volume.
- Remove AppleDouble files created while preparing pinned Steam sources so Xcode does not compile Finder metadata as C source.
- Use a short Apple NFS workspace path for Dart native-asset install names, and include EGL headers absent from the pinned Tizen SDK rootstrap.
- Select one Git executable when patching the pinned Flutter tool on Windows ARM64.
- Fix the hybrid Linux release runner expression so release jobs parse and dispatch.
- Run compatible native formatting on standard macOS runners in the 3.0.0 hybrid CI profile.
- Delete AppleDouble sidecars directly from per-run NFS source workspaces before iOS and macOS Xcode builds.
- Give Android release builds more memory on private JIT guests and install the pinned Python dependencies required by the webOS engine bootstrap.
- Exercise multi-frame Windows Steam decoding in native CI and report dropped frames.
- Require a successful exact-main all-platform release-mode candidate before creating the version tag.
- Build the bundled Mbed TLS Everest crypto helper as a static library when the parent enables shared libraries, fixing Windows native links.
- Fix the Windows build-guard test fixture to include the Steam CMake file that verifies the static Mbed TLS configuration.
- Keep Apple SwiftPM checkouts, Flutter build output, Xcode DerivedData, result bundles, and signing archives on local APFS while using NFS for scoped source workspaces and SMB for verified retained archives.
- Fix MSVC Windows builds by giving controller axis values distinct local names.
- Build native Windows ARM64 with MSVC plugins and the pinned Clang-built Whisper backend on the standard `windows-11-vs2026-arm` runner in the 3.0.0 hybrid profile.
- Keep Windows native sample interpolation explicit about its float output precision so MSVC does not promote conversion warnings to errors.
- Fix Windows C++20 builds that treated deprecated UTF-8 path APIs and HDR SDK shim warnings as errors.
- Preserve Android API 25 compatibility when matching Google Tensor LiteRT device models.
- Fix Steam video decoding on Apple by supplying monotonic VideoToolbox presentation timestamps.
- Restart the Gradle daemon before Android API compatibility lint to avoid carrying memory from JVM tests.
- Bundle the locked Sherpa ONNX Linux runtime pair and verify it resolves before packaging.
- Route Android Gradle and Robolectric runtime downloads through Google's Maven Central mirror to avoid shared private JIT egress 429 throttling.
- Check Android fallback event ordering on the fallback event stream and upload Gradle JVM test reports after CI failures.
- Keep Android MPV fallback CI tests aligned with video-surface resume behavior and native open-event ordering.
- Drain download manager callbacks before closing the application database, and keep desktop exit bounded when work does not settle.
- Keep the pinned tvOS Flutter framework in native test products after Flutter asset generation.
- Localize subtitle, external-access and music visualizer controls.
- Keep the iOS CocoaPods lockfile checksum aligned with the current Podfile.
- Update iOS and tvOS native test doubles for the shared MPV video-rect method.
- Build the Tizen torrent bridge with libtorrent session parameters to avoid a duplicate link symbol.

- Make release run names show the action, runner pool and tag; route platform matrices by explicit targets.
- Verify the imported macOS signing identity is a Developer ID certificate before signing and notarization.
- Align Dolby workflow route checks with the private Windows x64 and macOS ARM64 JIT labels.
- Load the Google ML Kit simulator helper after Flutter creates CocoaPods plugin symlinks.
- Fix native Kotlin formatting in the Android LiteRT model validation message.
- Keep recently added playback and subtitle messages on the approved English fallback until translations are reviewed.
- Guard iOS-only Flutter callback headers so the pinned tvOS engine builds with Xcode 27.
- Verify Apple Steam archive architectures one at a time for Xcode 27.
- Offer a server transcode after an eligible Plex HTTP 500 file refusal.
- Preserve health status after a transient timeout when the current server endpoint is still reachable.
- Keep TV focus on the visible route and avoid no-op nested scrolling that can collapse the library header.
- Explain when a downloaded subtitle fails to appear in the player.
- Wait for a queued active-profile rebind cycle to settle before returning to its caller.
- Add the repository root to Python guard-test imports so nested CI checks resolve project modules.
- Find the Linux `gio-launch-desktop` helper in `/usr/lib` when packaging the app bundle.
- Retry transient FFmpeg source download failures without weakening signature verification.
- Declare VDPAU and Vulkan loader packages required by Linux bundles.
- Include the pinned Vulkan-backed WebGPU provider in Linux app builds by default for Neural motion processing.
- Prefer the RX 7900 XT for Linux PME inference and Vulkan filter compute while keeping display rendering independent.
- Show Neural model-pack download progress in playback diagnostics while the current smoothing fallback remains active.
- Select the RX 7900 XT for Linux MIGraphX inference by HIP adapter identity, while honoring explicit ROCm device visibility.
- Select the RX 7900 XT for Windows DirectML inference when available, leaving the independently selected output adapter free for presentation.
- Promote the RX 7900 XT-bound Windows DirectML route ahead of generic GPU providers and prevent silent compute fallback to another adapter.
- Keep Neural interpolation SDR-only while resolving desktop HDR/Dolby Vision requests to active MPV smoothing with an explicit reason.
- Retain source Dolby Vision capability in live playback reports when the active player omits its profile.
- Report the PME inference adapter separately from its Vulkan preprocessing and warping GPU.
- Carry selected-stream scan type into live motion capability reports, disable smoothing for interlaced sources, and format its stats parser with Flutter 3.47.1.
- Confirm desktop neural interpolation against 24 consecutive decoded PTS intervals and report measured cadence in playback diagnostics.
- Prefer the named RX 7900 XT Vulkan adapter for PME compute when present, independently of MPV's output adapter.
- Resolve scan type from MPV's active FFmpeg video track after in-session track changes, and report unknown when the demuxer index space cannot be matched safely.
- Keep motion processing disabled until the next media open after an interlaced or unclassifiable track switch.
- Allow model packs to be omitted from optimized bundles and downloaded after Neural is selected, while preserving bundled fallbacks by default.
- Include verified Google Tensor G5/G6 AOT motion models in the default Android LiteRT pack and preserve them across ordinary exports.
- Remove stale CocoaPods aggregate framework links from the iOS simulator test project.
- Enable the pinned Google ML Kit helper for Apple Silicon iOS simulator builds.
- Patch the pinned tvOS Flutter engine headers for Xcode 27 availability checks.
- Patch the pinned tvOS AMSMB2 manifest safely when SwiftPM marks its checkout read-only.
- Preserve punctuation when converting podcast descriptions with inline HTML to plain text.
- Use the explicit English fallback for new podcast and version-selection labels until localized copy is reviewed.
- Clear current Dart analysis diagnostics in library playback, Jellyfin shuffle, and shader list construction.
- Accept the pinned Windows MPV archive from the PlezyNG mpv-build fork while keeping its repository and checksum locked.
- Keep the Linux MIGraphX runtime mapped through PME teardown to avoid unloading provider state early.

- Fix the pinned Opus CMake package config for Windows builds with a relative install prefix.

- Fall back to packaged LiteRT providers when Qualcomm HTP context preparation fails.
- Normalize modifier scan codes on remote Android keys when they obscure the actual key.
- Mark rejected Plex account tokens as needing sign-in again and retry profile binding after the next sign-in.
- Keep the explicitly selected Jellyfin subtitle when same-language files tie on metadata.
- Match the active display's refresh rate during fullscreen playback on macOS without changing its resolution or scaling.
- Ask which library or server copy to play when Continue Watching merges several copies of a title.
- Shuffle full Plex video-library sections through server queues and route MediaBrowser libraries through the existing complete paged queue.
- Log specific Watch Together relay connection failures while keeping existing user-facing error notices.
- Add a Podcasts hub with Apple Podcasts discovery, optional Podcast Index search/trending, private RSS setup, OPML portability, episode filters and existing-player/offline integration.
- Support Audiobookshelf podcast shows and episodes with episode-scoped resume/progress, and add RSS dates, video enclosures, explicit/season metadata and Podcasting 2.0/Podlove chapters.
- Refresh pinned MPV and FFmpeg artifacts to the verified private native build.
- Refresh all Apple, Android, Linux, and Windows MPV pins to the verified current artifact manifest.

- Fix iOS Sherpa ONNX CocoaPods staging, isolate Apple Pub caches, and remove the unsupported warning flag from pinned tvOS AMSMB2.

- Refresh the iOS CocoaPods checksum for `plezy_torrent` so deployment installs match the current podspec.
- Refresh the macOS CocoaPods checksum for `plezy_torrent` so deployment installs match the current platform podspec.
- Refresh the tvOS CocoaPods checksum for `plezy_torrent_tvos` so deployment installs match the current platform podspec.

- Install the GStreamer runtime plugins required to build Linux release bundles with Steam decoder support.
- Provision native Temurin JDK 21 on private Windows CI and release runners so CMake can
  resolve JNI.
- Prefetch and checksum-verify the pinned WinSparkle source through Schannel curl before Windows CMake configuration.
- Prefetch checksum-locked Boost and libtorrent sources through verified Schannel curl before Windows CMake configuration.
- Restore Android CI coverage for MPV Dolby Vision preference routing and fallback playback stats after Activity detachment.
- Route the checksum-pinned simdutf CMake archive through verified Schannel curl on Windows private JIT runners while retaining FetchContent hash verification.
- Ensure the vendored iOS, tvOS, and macOS torrent XCFrameworks have concrete CocoaPods targets, and inspect the generated iOS Pods project in CI diagnostics.
- Fetch checksum-locked Windows native archives through verified Schannel curl on private JIT builds.
- Materialize tvOS CocoaPods plugin symlinks from Flutter's resolved metadata so private runners use stable lockfile paths.
- Create the Windows Vulkan runtime output directory before downloading the checksum-pinned runtime through verified Schannel curl.
- Stabilize Android and Windows validation on private CI runners, retry the pinned FFmpeg header download, and bypass the proxy for loopback tests.
- Fix Android Kotlin compilation by correcting a duplicate visibility modifier and implementing the shared video-surface method.
- Restore Apple CI by quoting simulator-only Xcode project settings and keeping the macOS test plugin current with its shared protocol.
- Fix Android debug compilation under AGP 9 by aligning Android plugin Java and Kotlin targets at JVM 17 for the live preset-switch path.
- Replace MPV GLSL enhancement chains in one update, keep ambient lighting last, and share path-list escaping with subtitle loading.
- Stage LiteRT runtime libraries under their Android ABI paths and verify required native libraries and SDK headers before packaging.
- Preserve fractional display cadence in motion clarity, accept 48×1000/1001 Hz, and report MPV's active PME phase budget alongside its display-sync timing source.
- Align desktop PME source eligibility with the filter's supported 720p and 1080p inputs; validate Tensor AOT output interfaces after compilation.
- Default Tensor AOT export to the verified 720p shape while retaining 720p and 1080p GPU exports, allow explicit Tensor shape selection, and prune stale models after successful export.
- Allow serialized live Performance/Balanced/Quality preset switching in already-active desktop and Android Neural sessions, with prior-preset restoration on setup failure and MPV fallback where available.
- Bound Android Gradle and Kotlin daemon memory so private CI runners can complete Android tests and release builds.
- Fix Android private-JIT builds for the sharing plugin and pinned LiteRT OpenVINO runtime downloads.
- Keep Apple native tests on the simulator's native architecture and preserve the 30 GiB Mac JIT disk floor during Flutter setup.
- Fix the Linux native runner build with Flutter's mutable `FlValue` accessors.
- Quote the Windows Flutter cache key so GitHub can parse and dispatch CI workflows.
- Prepare the checksum-verified Flutter SDK in each Mac JIT job's temporary APFS workspace with resumable parallel downloads.
- Retry transient Flutter SDK setup failures on Windows x64 JIT runners.
- Stabilize player startup assertions, install FFmpeg for unit tests, and retry transient Android Gradle fetch failures.
- Fix Apple native configuration to use Boost headers from CMake's extracted source root.
- Install GStreamer development packages for Linux native CI and set Git identity in codegen test clones.
- Set the Linux bundle install prefix before configuring plugins so libtorrent's generated pkg-config install stays inside the bundle.
- Fix Tizen subtitle PCM capture compilation by importing the base64 decoder.
- Fix household issue-report build errors and use the shared app icon in the playback failure shortcut.
- Align shared Apple Steam test wiring and native localization generation, normalize untranslated catalogs without claiming language review, and document receiver test evidence and outstanding implementation gates.
- Repair combined application compilation across visualizer and subtitle archive extraction, IPTV, catalog search, motion and player settings. Preserve bounded archive writes, stale-operation guards and subtitle timing, use shared icon styling, and explicitly track untranslated messages as English fallbacks.
- Add an optional Brandfetch hotlink fallback for official connector logos, with curated provider domains and approval gates for AllDebrid and TorBox.
- Add attributed Amazon and Xbox marks to their matching external destinations.
- Show the Discord brand mark on its rich-presence integration switch.
- Add attribution-backed marks to additional service and file-source connection flows.
- Apply the CI native formatting toolchain to C/C++/Objective-C and Kotlin sources; no behavior change.
- Resolve newly added Apple plugins into the iOS, macOS and tvOS CocoaPods locks so deployment-mode installs succeed in release builds.
- Omit Watchmode availability rows whose links are all unsafe or invalid, so the Links screen never shows a provider it cannot open.
- Add a player-neutral bounded PCM capture contract and capability-gated Linux, Windows, Apple, and Android MPV live-caption bridges alongside Android ExoPlayer; patched MPV runtimes and target-device qualification remain required, and accelerator placement remains explicitly unverified per operation.
- Add opt-in experimental motion processing across MPV, Apple VideoToolbox, Android LiteRT/QNN, and desktop PME, with capability reporting and platform qualification limits documented separately.
- Make Android LiteRT calibration reproducible with atomic, hash-checked samples, explicit calibration/holdout grids, and refreshed W8A8 provenance plus CPU holdout evidence.
- Retarget the active current-display motion-compensation filter when mpv reports a display-rate change.
- Place desktop PME phases on matched MPV display-sync slots, include A/V-corrected slot counts, and expose the timing source in playback diagnostics.
- Serialize motion-processing configuration and health-monitor fallback changes so stale MPV updates cannot overwrite newer settings.
- Serialize per-player motion-provider transitions, power and thermal fallbacks, and teardown so stale async work cannot override newer requests.
- Fix the pinned Windows ML 2.4.89 package SHA-256 so Windows runtime downloads pass integrity verification.
- Keep CPU-only motion providers out of real-time Neural readiness until playback timing is qualified.
- Add an optional pinned OpenVINO Plugin EP runtime for Linux Intel GPUs/NPUs, and allow Qualcomm HTP context preparation to select SoC/model subsets, record QAIRT/calibration provenance, and package only checksum-verified contexts built with the matching QAIRT SDK; partial target sets remain an explicit opt-in.
- Add experimental native MilkRust visualization hosts across Linux, Windows, Apple and Android, with same-player PCM routing, profile-scoped engine selection, and optional SHA-256-checked desktop runtime/source packaging with notices; compiled engines are not in current releases and platform behavior remains unqualified.

- Add profile-scoped Real-Debrid, AllDebrid, Premiumize and TorBox connections, Stremio add-on imports, cloud/server canonical libraries, renewable shared playback, scheduled preparation, and optional native libtorrent streaming; live-provider and packaged-device qualification remains open.

- Add a Watchmode title-availability adapter behind server-side credentials and an explicit commercial-approval gate, plus an iOS-only Apple MusicKit catalog/playback pilot behind a build flag; provider, account and device qualification remains open.

- Clear Watchmode availability rows and loading state when the title Links screen changes profiles.

- Bound Steam startup and first-frame waits; retry unsupported HEVC with H.264, normalize Android/Linux codec framing, and wait for decoder shutdown before reconnecting. Serialize native source preparation and include transitive crypto archives in Apple builds.

- Add an experimental Windows Steam receiver with Credential Manager pairing, cancellable DNS, Media Foundation video, bounded XAudio2 surround audio, retained workspace textures and shared input controls. Windows SDK and device qualification remain required; missing Media Feature Pack support keeps library browsing available.

- Clarify the experimental Steam receiver coverage in Games help and give touch controls descriptive screen-reader labels; preserve existing theme, icon and controller geometry conventions.

- Add themed multi-touch controls to Apple/Linux Steam surfaces, including dual sticks, independent buttons and triggers, compact landscape layout and player-one assistance that preserves physical controller seats.

- Add opt-in Apple Metal Pyrowave source integration with direct GPU conversion, bounded 4:2:0/4:4:4 SDR textures, observed-chroma diagnostics and conventional-codec fallback; retain explicit HDR rejection pending a qualified HDR surface.
- Route normal Linux and Apple Steam launches into the retained workspace receiver as well as supporting the window action.

- Add Apple Steam receiver source and Xcode integration using VideoToolbox pixel-buffer textures, Keychain pairing, bounded multichannel Core Audio and acknowledged teardown. SDK builds and device playback remain qualification gates.
- Route desktop/Apple Steam pointer, scroll and full keyboard input through workspace ownership; release held controls on focus changes and provide Shift+Escape to return to workspace menus.

- Add capability-negotiated Steam Input and game-properties actions on paired computers, plus confirmed Cloud files and Families destinations in the existing adaptive Steam menu.

- Add an embedded Linux Steam receiver with OS-keyring pairing, dedicated H.264/HEVC and PCM decoding, retained Flutter textures, controller seats, connection details and acknowledged reconnect; bundle its fixed GStreamer plugins with Linux releases.

- Export Whisper token timestamps as cue-linked word/token timing records in reviewed subtitle JSON; unsupported accelerators clearly return cue timing without word records.

- Sync and repair subtitle timing across languages by locally translating target cue text for matching while preserving the target wording and applying only the matched timings.

- Keep a bounded, device-local revision history of reviewed subtitles per profile and server library item. Restore, export, or delete prior results; word/token timing records are retained where available.

- Add a desktop/TV connector hub for servers, file sources and categorized provider hand-offs, using provider marks while preserving the existing setup flows.

- Import bounded gzip-compressed TAR subtitle archives (`.tar.gz` and `.tgz`) through the picker, desktop drop, and Android share flows.

- Browse captured Android ExoPlayer transcripts with search, cue-level seeking, and an optional hide-future-dialogue filter.

- Save reviewed subtitle results as standalone SRT or versioned cue JSON files without attaching them to playback or modifying the source.

- Show SDH/closed-caption role markers in playback track labels and identify AI-generated, translated, and synchronized local tracks.

- Explain when burned-in captions remain part of the video image and when the active player cannot receive generated SRT subtitles.

- Automatic preferred subtitle downloads now check the first three ordered languages concurrently and use the highest-priority language with an eligible provider result.

- Show language/script, format, provider, and forced/SDH metadata in server and standalone subtitle search results.

- Remember rejected server and standalone subtitle revisions for 180 days; hide or restore them in search and skip rejected server results during automatic preferred-language downloads.

- Add opt-in subtitle-on-mute for library playback, retrying after the native track catalog arrives and restoring a temporary Off override on unmute unless the viewer changes tracks or the item changes.
- Extend opt-in subtitle-on-mute to standalone source video playback with guarded restoration of the prior track on unmute.
- Add a configurable shortcut to reset subtitle timing to zero through the selected persistence scope and show the applied value.

- Carry selected SDH/closed-caption subtitle intent across library episode changes and saved show preferences, infer the role from older title-only preferences, and preserve the existing server fallback when the matching caption class is unavailable.

- Read BOM-marked UTF-16LE/BE subtitle text for cue inspection and corrected export while preserving source encoding and line endings.

- Add current subtitle cue copy, previous/next cue navigation, and replay with an adjustable preroll for persistent standalone MPV text subtitles.

- Fix clean tvOS CocoaPods setup, Android 17 preview SDK provisioning, and short-path Apple native-asset builds on private JIT runners.
- Fix the macOS native reliability target to import the `PlezyNG` app module.
- Require Android host native-test tools to be provisioned on the private runner before CI starts.

- Add an MPV subtitle-drift preview that applies calibration temporarily and restores prior timing on cancel; saving commits the read-back values.
- Add one-step undo for the most recent applied MPV subtitle drift calibration or reset, including its prior scoped rate and delay.
- Retain downloaded OpenSubtitles text subtitles for standalone MPV VOD, bound to profile, source item, edition and file fingerprint; verify content hashes when restoring and enforce per-file asset limits. Preserve session-only cleanup for transient and live playback.
- Roll back native sync timing when saving an offset fails, keeping player state, confirmation state and persisted settings consistent.
- Export affine-corrected SRT/WebVTT and simple ASS/SSA copies for standalone MPV VOD subtitles; preserve source metadata and cue payload, confirm before removing cues wholly before playback starts, and refuse ASS/SSA karaoke/animation or Effect timing the exporter cannot safely preserve.
- Align a selected SRT/WebVTT cue to the current standalone MPV playback position and persist the one-anchor correction for the active subtitle and audio stream.
- Preview actual cue times and text before applying direct OpenSubtitles SRT, WebVTT, ASS, and SSA downloads on standalone file playback.
- Add subtitle sync controls to standalone MPV VOD OpenSubtitles assets. Persist delay and drift rate by the current audio descriptor, reapply only matching audio calibration after a track switch, and restore corrections only when edition, source file, and subtitle digest still match.
- Search OpenSubtitles by moviehash when a local or cached file is available and its byte size matches the source record; rank reported hash matches ahead of title-only results.
- Add bounded two-anchor subtitle drift calibration for MPV text tracks. Capture matching playback positions, fit one timestamp multiplier plus delay, persist both in the existing scope, and exclude unsupported players and known bitmap subtitle codecs.
- Add exact millisecond audio/subtitle sync entry and backend-aware local subtitle import: MPV keeps its existing formats, Android ExoPlayer accepts SRT/ASS/SSA/VTT on VOD, and Tizen/webOS add SRT/VTT overlays.
- Add a separately persisted sync offset for MPV's secondary subtitle track, using the existing scoped timing controls.
- Import backend-supported subtitle files from bounded ZIP or plain TAR archives; validate safe entry paths, reject links and unsupported TAR extensions, and materialize only the selected subtitle or paired IDX/SUB files into a temporary app cache.
- Add previous/next subtitle cue alignment on MPV, persisting the player-reported offset through the existing scoped controls.
- Expand in-player subtitle readability controls with text color, weight, outline, and background adjustments on MPV and ExoPlayer; hide the style action on unsupported backends. Add a one-tap reset to stored style defaults.
- Add normalized provider, evidence, and licensed-offer contracts with bounded, no-cache availability lookup; keep offers non-actionable until approval and exclude generic OPDS purchase links from local-file access.
- Make a single tap or click toggle playback by default across platforms, with a preference to show the playback controls instead.
- Add signed visualizer catalog support with release-pinned Ed25519 keys, quorum verification, explicit refresh, revocation and rollback protection, and durable install receipts. Remote updates remain disabled until release keys are configured.

- Verify the pinned Windows installer compiler by running its version probe, supporting Inno Setup's zeroed executable version metadata without weakening signature or payload checks.

- Verify publication tools supplied by the private runner bootstrap without requiring administrator access in restricted metadata jobs.

- Publish checksum-verified Snap packages with the same pinned container toolchain used for packaging, preserving private proxy routing and keeping store credentials out of command arguments.

- Prepare release-channel jobs for fresh private runners: explicit GitHub repository context before checkout, native Ruby extension prerequisites, and proxy routing for both BuildKit and container build downloads.

- Provision checksum- and publisher-verified NuGet and Inno Setup before Windows builds, and route ARM64 jobs through the existing PC runner pool.

- Initialize webOS engine dependencies from Flutter's pinned checkout template, and build Snap packages in a digest-pinned Ubuntu 24.04 container on each native private runner architecture.

- Preserve localized error messages from Companion Remote pairing fallbacks.

- Hide URL credentials, query strings, and fragments in HTTP consent prompts.

- Provision Android toolchains from every module's Gradle pins and configure both Java and Gradle downloads for the private runner proxy before SDK setup.
- Improve TV detail announcements with spaced episode labels and keep the download-location settings row compact.

- Retain checksum-verified webOS candidates and their exact source/run receipts in private storage after ephemeral runners exit, so device qualification can use the built package.

- Keep encrypted cloud sync confined to generated state files in dedicated provider locations; reject unsafe WebDAV roots and encoded traversal before any request.
- Add profile-scoped stereo, quad and 5.1 Steam audio requests with bounded Opus multistream decoding, explicit speaker mapping and a stereo compatibility retry for unsupported layouts or outputs.

- Preserve TV navigation-remote assistance for player one without consuming a Steam gamepad seat; release both input paths when a composite device disconnects.

- Add opt-in Companion Remote controls for active PlezyNG game streams: inspect titles, choose audio, mute, fullscreen and confirm disconnect, using temporary session handles that expire on reconnection or replacement.
- Prevent a timed-out Steam host inventory check from launching later, using monotonic deadlines and explicit operation retirement.

- Add live Steam connection details from native receiver counters and host adaptation messages, including actual codec, frame rate, received video payload, queue depth and input reliability; opening details releases game input and keeps measurements local.

- Add one-to-four independent Android Steam controller seats, with a profile setting, stable HID identities, shared native/Flutter device mapping and per-device disconnect cleanup; preserve the single-controller default.

- Add on-demand Steam achievements, news and optional friends-playing context to game details, with identity-bound server requests, spoiler protection and confirmed Steam destinations.
- Add separately permissioned Companion Remote requests to launch installed Steam games, request installation, and open Steam/downloads on the authenticated computer; reject replayed or arbitrary commands and preserve Steam's authority over launch/install results.
- Unify Steam games across computers and library drives with one poster grid, shared favorites, computer filters, timestamped installation snapshots and optional encrypted Companion Remote inventory sharing.
- Refresh linked Steam catalogs with encrypted, revocable, identity-scoped credentials while retaining compatibility with older relays and saved game libraries.
- Add profile-scoped Android Steam quality and codec preferences, first-frame connection state, accessible reconnect controls and teardown acknowledgement before retrying a stream. Other embedded receiver platforms remain in development.

- Apply the coral ribbon identity across native launchers, store artwork and in-app branding, with light/dark marks, matching wordmarks and simplified small-size icons.

- Add metadata-backed mood and familiarity filters, explicit local genre taste controls with hide/restore/reset, private co-present shortlist voting, optional bounded AI reranking, Open Library catalog-only candidates, and gated borrower-catalog candidates to Find your next.
- Add capped, disposable OPDS sample previews, exact-ID adaptation matching, side-by-side Saved-pick comparison, and opt-in encrypted Saved-pick sync with exact-identity re-resolution.
- Add a searchable, region-aware directory of official video, rental, book, audiobook, comics, music and game storefronts to Services and title details; add Google Books catalog search with country-specific sale metadata and official purchase handoff.
- Add a previewed Trakt movie-history CSV export for manual Letterboxd import, preserving rewatches and splitting oversized exports into safe files.
- Surface free/ad-supported video services first and add the Samsung TV Plus official handoff; keep title-level availability disabled until a supplier is approved.
- Fix NFS source setup so mount, identity, and RPC-with-TLS controls appear without showing username or password fields.
- Add OpenSubsonic music-server browsing and playback, plus RSS/Atom podcast subscriptions with encrypted feed URLs and OPML import/export in the existing Files and books experience.
- Normalize punctuation around inline markup in podcast episode descriptions.
- Keep file-source activation profile-scoped through download and shelf reconciliation, and stop cloud settings backup or restore when the initiating profile session changes.
- Require every release-critical CI job, including each native platform matrix row, to pass for the exact release commit; keep implementation and qualification claims in a source-linked capability ledger.
- Add household readiness checks and a QR support flow that drafts a privacy-safe GitHub issue, with optional redacted log upload.
- Add profile-local Find your next review history with localized timestamps and safe detail revalidation.
- Add exact genre filtering across server, catalog, and publication picks within the existing filter sheet.
- Filter Find your next by its displayed source within the existing filter sheet.
- Search Saved picks by title, source, type, or subtitle; Shuffle uses the matching shortlist.
- Add a Home shortcut that opens Saved picks without loading the discovery deck.
- Let people shuffle a saved pick back onto the deck for a deliberate action, without auto-starting playback.
- Clear all active Find your next filters directly from a no-match result.
- Link the QR GitHub issue draft directly from Household setup for faster problem reporting.
- Fix compile errors in discovery, source details and issue reporting by using existing translations and framework symbols; localize the Steam source badge.
- Offer the same QR report flow from the startup failure screen, alongside copy and log upload.
- Include the startup phase and exception type in its reviewed GitHub issue draft while excluding the raw message and stack trace from the QR payload.
- Search the full Find your next source and genre option lists from the existing filter sheet when the quick chips are insufficient.
- Retry an individual Find your next history pick into the deck without changing its Saved picks membership or launching playback.
- Keep Files search accessible during server outages and index identified video titles as well as original filenames, with a bounded migration of existing search data.
- Rank library copies by verified offline access, reachability, complete parts, device codec acceptance and local/remote/cellular quality limits before resolution, updating the existing copy list when connectivity changes.
- Preserve the last reliable Files playback position across native stream failures and expose Retry in the existing player without advancing editions or marking failed playback finished.
- Verify downloaded representations on disk before showing offline availability, require all audiobook/video parts, and reject server versions with a known missing part.
- Include indexed Files and books in main Search with shared relevance, media-kind filters, TV focus, partial-failure results and profile-switch invalidation.
- Accept branded `plezyng://` links across Android, Apple, Linux and Windows while preserving both existing aliases; correct PlezyNG Flatpak launch instructions.
- Bind release builds and configured publication workflows to the exact main commit, and resolve pinned Apple packages before native CI tests.
- Attach the validated ARM Tizen tester handoff to versioned releases and fail closed if its package, checksum, provenance or toolchain files are missing.
- Retain previous server results when a new search is cancelled, while preserving indexed Files and Seerr results.
- Route Windows x64 native CI through the private Packer JIT workflow allowlist.
- Lock iOS, macOS and tvOS CocoaPods dependencies for CI, and retain root dependency overrides when resolving tvOS packages.
- Fix clean tvOS CocoaPods setup, Android 17 preview SDK provisioning, and short-path Apple native-asset builds on private JIT runners.
- Fix the macOS native reliability target to import the `PlezyNG` app module.
- Require Android host native-test tools to be provisioned on the private runner before CI starts.
- Include the Steam audio labels in the explicit English fallback manifest used by strict localization checks.
- Set ThreadSanitizer ASLR entropy through the disposable runner's authorized sysctl.
- Prepare an ephemeral default keychain for the optional Xcode cloud-signing path for iOS App Store builds.

### Localization

- Keep the new Steam audio setting labels available through an explicit English fallback until reviewed translations are available.

### Release automation

- Validate all platform assets before publishing and dispatch configured release channels from one private-JIT orchestrator.
- Retry transient Flathub disconnects while preparing the Linux release runtime and SDK.

### Platform integration

- Keep argument-aware deep-link startup compatible with the webOS entrypoint and format Windows link forwarding for the native toolchain.

### VLC feature parity

- Expand the VLC feature comparison with safe local playlist references, more conversion formats, MPV audio effects, device-local playback bookmarks and temporary A/B loops in existing playback controls.
- Add bounded desktop folder queues and named device-local bookmarks for seekable Open media audio while preserving existing bookmark data.
- Add direct source-queue browsing, upcoming-file shuffle, repeat modes, and item selection in the existing adaptive player sheet; keep audiobook/server order and current-item progress intact.
- Save eligible same-folder desktop file queues as reopenable M3U playlists, and select alternate video tracks through existing MPV playback controls.
- Show direct-input MPV file details in the shared File Info sheet, and expose edition/disc-title switching only when multiple choices are available.
- Preview discovered desktop camera and display inputs in the existing MPV player from Media tools → Capture; keep preview session-only and video-only.
- Use optional MPV audio-analysis metadata in the existing visualizer when Plex loudness data is unavailable, and show conversion profiles only when the installed FFmpeg build supports them.
- Fix the MPV edition selector so it refreshes when a new file loads, without passing an asynchronous value through Flutter's state update callback.
- Keep temporary HLS sharing within its startup window for long-GOP sources by forcing keyframes at the segment cadence; verify that playlist and media segments remain token-scoped and the listener closes cleanly.
- Translate the added video-track, playlist, edition, and capture-preview cues across supported locales, and use the converter's concise help on the existing Open media tile.

## [3.0.7] - 2026-11-09

- Fix remote and system Back in Audio Output and other playback options: return to the parent menu, then close options, hide paused controls, and leave the player on subsequent presses.
- Claim the webOS Back key while inside the app and allow the TV's native exit handling only at the home landing page. Preserve tvOS root Menu behavior and Android duplicate-Back protection.
- Keep pointer-opened submenus in the Back focus chain and let explicit Back dismiss paused controls without waiting for auto-hide holds or the fade animation.
- Include all current-main changes, canonical Pleazyng repository/update links, and every supported release platform.
- Synchronize webOS package metadata with Flutter version 3.0.7+166 and catch mismatches before CI and tagging.

## [3.0.5] - 2026-11-08

- Extend audio diagnostics to Samsung Tizen, preserve native channel/rate/bitrate values, refresh remaining hero/spotlight/queue artwork after server changes, and cancel unfinished native-TV media redirects.

- Keep live-program and audio-format header subscriptions independently keyed, and skip artwork URL resolution for missing pictures.

- Identify original-file audio when LG reports an unknown codec without mislabeling converted streams, retain metadata provenance, and stop unsupported desktop media-control calls on native TVs.

- Retain bounded, redacted native TV diagnostics in app-private storage and check webOS native sources with the same strict Clang frontend used by release builds.

- Recover home-screen cards and hero artwork after server reconnects, endpoint and profile changes; use available fallback images for missing episode screenshots and wide previews.
- Show the active audio codec and channel layout in playback controls, and forward native webOS audio/video metadata to the performance overlay and sanitized native logs.
- Render standalone local and authenticated HTTP PGS subtitle images over native webOS video with authored timing, positioning and transparency.
- Keep client-only subtitle selections independent from Plex subtitle burn-in and bound redirected subtitle downloads.
- Retain all current-main branding, native components and runtime experiments across the complete platform matrix.

## [3.0.4] - 2026-11-07

- Fix LG native video/UI-audio player-slot collisions and native failures that stranded playback initialization and retries.
- Preserve authenticated HLS/DASH playback hints and sanitized native error diagnostics on webOS.
- Include current-main Android navigation, database-startup, shrinking and native playback fixes qualified by the headless acceptance suites.
- Recover Apple cancellation process tracking and retain cancelled build evidence without disturbing other jobs.
- Ship Android, Fire TV, Linux x64/arm64, Windows x64/arm64, universal macOS, iOS, tvOS, Tizen and webOS, with implemented runtime experiments included.

## [3.0.1] - 2026-11-06

- Adopt the Pleazyng name, artwork and package identities. Ship ordered native PCM capture for the new visualization and playback transcription features, and repair integrated Games, RomM, karaoke and offline conversion paths.

- Include Android, Linux x64/ARM64, Windows x64/ARM64, universal macOS, iOS, tvOS, Tizen and webOS in the complete release; verify package provenance and checksums before publication.
- Fix the black screen after Plex sign-in when a profile attaches before its file-source database opens.
- Bundle implemented experimental Dolby Vision/FEL paths in normal compatible packages with a persisted, default-off Playback settings switch. Include the Apple runtime and Linux offline HDR10/SDR exporter; physical output qualification remains device-specific.
- Integrate retained desktop multiview surfaces, MilkRust visualizer runtimes, karaoke preparation and capture, Steam/RomM workflows, podcast synchronization, native themes, and recording recovery improvements.
- Ship ABI-matched Android FFmpeg headers and a Linux shared client SDK that resolves without the native producer's private build dependencies.
- Automate Apple job sequencing and cleanup, reuse checksum-verified native components, and build the complete application matrix once after exact-source CI.
- Announce stable releases to Discord automatically with resumable per-message delivery receipts.

## [3.0.0] - 2026-10-27

This release gathers PlezyNG’s feature work since the fork, platform expansion, and security updates. Experimental playback and platform paths remain identified as experimental below.

### Added

#### Release automation

- Add one-command native dependency refresh and all-platform release orchestration with private JIT and standard-runner profiles.
- Reuse complete, checksum-verified native platform groups after another platform fails, while requiring the full artifact set before updating app dependencies.
- Bind release builds and configured publication workflows to the exact main commit, and resolve pinned Apple packages before native CI tests.
- Validate all platform assets before publishing and dispatch configured release channels through the private-JIT orchestrator.
- Use standard public runners for compatible 3.0.0 Linux, Android, Windows, and Tizen jobs; keep Apple and storage-heavy WebOS on private JIT, and add a GitHub-only publication mode.
- Include ARM webOS and Tizen tester builds in versioned releases, with pinned SDK and host-tool setup for Android, webOS and Tizen.
- Provision pinned Android SDK packages and install hash-verified Python/Ninja plus host prerequisites for Android and webOS private JIT builds; bootstrap the pinned Tizen toolchain on hosted Ubuntu for trusted-main hybrid releases.

#### Localization

- Complete translated labels for deep links and playback screen-lock controls across supported locales.

#### Universal media tools

- Add one Open media workspace for direct streams, playlists, local files and desktop discs, plus desktop conversion, live-stream recording, Wi-Fi transfer, and MPV picture tools. Preserve live `#EXTINF` entries with playlist metadata, and keep favorites and nested launchers in the existing focus-aware Files and books rows.
- Add integrated VLC-inspired media capture, private-LAN HLS sharing, consent-based search extensions and the `plezyctl` helper, with accessible cues, deep links, platform registrations and setup documentation.

#### Playback and downloads

- Add a PlezyNG mpv playback backend, direct Plex server sign-in without plex.tv, and external-player return with playback progress sync.
- Add a pre-play audio/subtitle picker; per-show audio and subtitle preferences; device-language subtitle selection and server subtitle downloads; local subtitle loading in mpv; subtitle size, position, live preview and RGB styling; subtitle-delay shortcuts; and player buffer controls.
- Add touch swipe-to-seek, frame-by-frame stepping while paused, reliable video-playlist repeat, and background video audio on handheld Android and iOS.
- Add video shuffle across Plex, Jellyfin and Emby, a preferred-server setting, remote-streaming quality limits, and separate Continue Watching and Next Up rows.
- Add Plex server-side converted downloads, Jellyfin/Emby converted-download quality, and per-rule quality presets.
- Add per-server Continue Watching downloads, Sync now, random episode selection with custom counts, download storage and per-item sizes, and explicit removal of failed or paused downloads.
- Add selectable local movie prerolls, Plex server prerolls, Jellyfin/Emby cinema intros and theme songs on media detail pages.
- Add program-aware Plex Live TV timeshift, Google Cast playback handoff, and Android playback automation links.
- Add configurable Plex commercial-marker skipping, six animated music visualizers and optional loudness-aware music fades.

#### Libraries and discovery

- Add Plex watchlist filtering and sorting, Seerr requests for titles missing from the server, custom MDBList shelves, director credits with person pages, library item counts, bulk watch-state updates and a version picker that remembers choices across episodes.
- Add plezy://watch links, random movie selection, estimated finish times and profile-scoped new-episode alerts.
- Add local profile PIN gates for Settings, Explore and download deletion, per-profile Explore visibility, and optional hiding of empty libraries.
- Add Find your next, a profile-local cross-media discovery deck for libraries, live TV, file sources and completed downloads, with filters, saved picks, Undo and normal playback routes.
- Add a content screensaver that rotates artwork from selected connected libraries.

#### Sources and cross-device sync

- Add read-only SMB 2/3, FTP/FTPES/FTPS, pinned-host-key SFTP and NFSv3 sources, including optional NFS RPC-with-TLS, custom trust certificates and client identities; add DLNA discovery with manual server entry.
- Add standalone-video matching through Trakt, OpenSubtitles search and downloads, and Kodi/Jellyfin NFO sidecar metadata and posters.
- Add encrypted WebDAV state sync for file-source playback progress and notes, plus HTTPS WebDAV settings backup and restore.
- Add explicit cross-provider item and edition pairing so shared progress, bookmarks and notes can be mapped between sources.

#### Books, comics and accessibility

- Add ebooks, comics and multipart audiobooks with reading preferences, zoom, bookmarks, notes, offline editions and chapter-aware controls; connect local files, OPDS, Audiobookshelf, Google Drive, OneDrive, Dropbox, WebDAV and S3-compatible storage.
- Add Komga comic sources, ComicInfo metadata, streamed comic pages, spreads, continuous scrolling, thumbnails, touch zoom and per-comic display settings.
- Add encrypted cross-device audiobook progress, bookmarks and notes, with public-library discovery and a default-off OverDrive/Libby handoff.
- Add app-wide accessibility preferences for text size, bold text, contrast, reduced motion and larger controls, along with expanded language, regional-format and metadata-language choices.

#### Games, workspace and Dolby Vision

- Add a Games category with LAN discovery, profile libraries, pairing and Android Moonlight streaming; add experimental Android Steam account catalog and streaming support and experimental Pyrowave support.
- Add a retained Multiview workspace for video, music, sources and publications, with floating/split layouts, shared audio and input ownership, two simultaneous video sessions, and an Android Steam game surface.
- Add profile-aware Dolby Vision routing and server-transcode compatibility checks. Add experimental P7 FEL implementations for Android, Windows and Apple, plus a Linux gpu-next option and offline HDR/SDR tools. Availability is controlled at runtime; qualification describes tested device output.

#### Platforms and release channels

- Add experimental LG webOS TV playback with OLED sign-in, OS-backed credentials and app-private artwork caching, plus ARM package build tooling; keep its IPK out of public artifacts until redistribution and exact-device qualification are approved.
- Add experimental Samsung Tizen TV playback, signed TPK packaging and a disabled Apps2Samsung catalog recipe.
- Add PlezyNG-branded cross-platform release packaging, versioned private-JIT builds, checksums and credential-gated submissions for mobile, desktop and TV stores, plus Linux packages, Windows package-manager submissions and multi-architecture relay images.
- Attach a downloadable ARM Samsung Tizen tester handoff with its checksum, source and toolchain evidence; label it as development-signed and requiring TV re-signing.
- Add a seven-day full-app trial followed by a one-time lifetime unlock, a public privacy notice and PlezyNG branding across app icons, launchers, TV and store artwork.

### Security

- Upgrade Cronet to 500.1.0 for CVE-2026-11215.
- Upgrade Mbed TLS to 3.6.7 for the affected 3.6.x security advisories.
- Encrypt cross-device audiobook progress, bookmarks and notes with AES-256-GCM; cloud providers store only encrypted state generations.
- Upgrade the branding asset generator to Pillow 13.0.0 to include upstream security fixes.
- Clarify that the branding verifier parses only the checked-in Android launcher manifest.
- Clarify that the publication reader's local WebSocket bridge is restricted to loopback and a per-session capability.
- Restrict OAuth authorization redirects to configured provider hosts, preserve relay error status for log downloads, and remove the bundled Trakt client secret.
- Update the relay to Go 1.27.3 for GO-2026-6809 and refresh its immutable container pin.

- Require a random, revocable pairing code for companion remotes and bound unauthenticated WebSocket traffic before fragmented messages can accumulate. Update both devices and pair once.
- Verify playback TLS certificates, provide trust roots for OpenSSL players, prefer HTTPS server discovery, and require explicit consent for HTTP sign-in. Keep authenticated failover on HTTPS except for the exact Direct Plex or Jellyfin endpoint the user approved.
- Move credential keys to OS secure storage and migrate tracker tokens and Seerr cookies without signing users out. Preserve old credentials when the keychain is temporarily unavailable.
- Use 130-bit log retrieval codes; existing shared links keep their original expiry.
- Require a fork-owned updater public key and verify it matches the signing seed. Builds without a configured key retain GitHub release notifications and manual downloads.

### Changed

- Complete locale catalogs, record explicit fallbacks for new Steam account copy, fix release validation, and configure Gradle to use the private JIT runner's HTTPS proxy.
- Keep argument-aware deep-link startup compatible with the webOS entrypoint and format Windows deep-link forwarding for the native toolchain.
- Keep settings import and reset feedback visible when root rebuilds for locale or TV-mode changes.
- Route Windows release packaging through PlezyNG's private Windows runner.
- Use shared focus controls for Home row dialogs, subtitle styling and video equalizer sliders, with TV text input for Home row names.
- Use Plezy's shared Material Symbols icons for file-source, source-detail, player and standalone subtitle-search actions.
- Keep library/publication-reader search, page entry and bookmark notes on shared focus-aware fields and scoped dialog actions.
- Keep comic page images resident during pinch gestures; apply zoom once when the gesture ends.
- Route public-library forms and email dialogs through shared focus-aware fields and dialog actions for keyboard and TV navigation.
- Show source, audiobook sync and lending search errors with the same live, theme-colored feedback.
- Report failed sync rules and unavailable-server retries, and give orphan review one safe initial focus target.
- Align audiobook sync conflicts, playback input dialogs and source menus with shared Mono rows, focus and compact overflow patterns.
- Validate Seerr sign-in fields before asking users to allow an unencrypted HTTP connection.
- Keep Games entry points limited to supported Android handheld and TV builds; style Steam stream controls and dialogs with Mono surfaces, focus states and localized touch accessibility text.
- Refresh the sign-in background with current plezyng.app artwork, including WebP and high-resolution assets for 4K screens, responsive login choices and QR sizing.
- Keep SMB setup copy localized and show the Videos shelf by default only for local and SMB sources.
- Polish catalog, source, TV and cross-media discovery surfaces with Plezy's Mono focus and icon styles, RTL-aware navigation, accessible controls, responsive layouts, and localized error handling.
- Complete localization coverage across settings, playback, downloads and accessibility labels; improve right-to-left focus navigation, numeric input, localized units and native permission prompts, and correct regional wording in source setup and Find your next controls.
- Mirror navigation affordances and tree controls for right-to-left reading order.
- Keep Steam touch-control hit areas at least 48dp, resolve overlapping targets by nearest control, and expose the localized controller label to Android accessibility.
- Route reader, source-setup, audiobook-sync and player text entry and dialog actions through Plezy's shared focus controls for keyboard and TV navigation.
- Route the Google Drive source label through localization.
- Keep both iOS SwiftPM lockfiles pinned to the same Google Cast SDK revision.
- Explain the default behavior on the screensaver library selection page.
- Format the download and screensaver library views with Flutter's configured Dart formatter.
- Check iOS audio-output ordering while allowing the Spatial Audio driver on iOS 26.
- Build Android app and plugin modules with SDK 37 and generate BuildConfig for current Android dependencies.
- Brand default and alternate app icons, splash art, and TV launch graphics with the PlezyNG badge.
- Keep the webOS TV package icon generated from the approved NG-badged logo.
- Refresh package and store descriptions to explain PlezyNG's Plex client features.
- Refresh the release-channel guide with configured publishers and remaining credential requirements.
- Record the current Google Play foreground-service demo links and release-run results in the channel guide.
- Declare Bash explicitly when naming the Snap release artifact.
- Update remaining app and OAuth messages to PlezyNG and make donation copy provider-neutral.
- Keep Android signing material until all signed store builds finish, and clean it up afterward.
- Fix music fade gain handling across track transitions and avoid visualizer profile requests before the active track is ready.

- Require explicit action and private-pool selections for build, scan, package and release dispatches; release builds use an exact version tag and validate the release commit on private JIT runners.
- Prepare Android SDK, pinned CocoaPods and webOS build prerequisites on private runners; preserve the JIT proxy for package tooling and accept Ubuntu’s canonical os-release link in webOS preflight.
### Fixed

- Restore TV remote focus to the Retry action while Plex sign-in is waiting.
- Stop Games host setup when saving fails, and show a retry state when the game library cannot load.
- Respect reduced motion in Supporter sheet scrolling, expose mobile profile PIN entry to screen readers, and retain D-pad focus on the locked-settings action; let PIN controls wrap at large text sizes.
- Restore visible keyboard and remote focus in workspace controls and Games forms; show full pane titles in pointer tooltips and isolate game and host metadata in right-to-left labels.
- Re-check a protected local profile PIN before every explicit download deletion, keep cancelled-download dismissal safe, and use explicit button actions for keyboard and remote Find Next controls.
- Keep compact Find Next artwork retries in the focus order and isolate recommendation summaries for mixed-direction text.
- Use shared focus-aware fields and viewport-sized dialogs for cloud backup, custom players, MDBList shelf editing, searchable settings, and Home Layout.
- Keep Games search scoped to the active profile, size pairing dialogs and QR codes for the available viewport, and report when the Sunshine PIN page cannot be opened.
- Restore navigator-managed Back handling in the companion remote dialog, use valid directional insets in RTL trees, and resolve the Flutter/intl `TextDirection` import collision.
- Make Multiview music visualizer presets change the scene, isolate track labels in mixed-direction text, and give music/source playback controls the shared keyboard and remote focus treatment.
- Keep playback controls and elapsed/total times in their familiar left-to-right order in RTL layouts, and isolate source titles and chapter names from surrounding text.
- Complete discovery, source-setup and subtitle-search translations; fix reviewed library and audiobook wording, add Arabic and Asian subtitle-language choices, and preserve regional numerals, mixed-direction titles and large-text layouts.
- Use the localized sort and filter labels in the audiobook library menu.
- Use CocoaPods for iOS and macOS builds until the pinned WebView plugin compiles with Xcode 26’s Swift Package Manager integration.
- Let Xcode choose signing identities for iOS and tvOS archives instead of forcing one across all targets.
- Keep raw companion remote transport exceptions out of discovery and session messages.
- Preserve existing TV and keyboard toolbar focus order when adding Find your next discovery actions.
- Localize standalone source setup and subtitle search, use shared icons and TV-aware text fields, and report when Trakt finds no metadata matches.
- Show NFS mount, identity, and RPC-with-TLS controls in its source setup, persist OPDS stream-only file flags, and handle standalone metadata arrays and missing DLNA totals.
- Fix FTP/SFTP stream typing and the SMB license text constructor for current Dart/Flutter APIs.
- Observe failures from shared online metadata lookups during cleanup.
- Keep entitlement-controlled themes and icons locked when store access is disabled in the build.
- Remove stale SVG imports after switching the setup and app-icon previews back to raster artwork.
- Localize the About screen privacy-policy link.
- Cover AVFoundation speed flush ordering deterministically when simulator audio is unavailable.
- Keep unsigned macOS release builds available when only the shared mobile Apple team ID is configured.

### Removed

- Remove unused upstream website, legacy app-store and Sentry upload automation, and funding links.
