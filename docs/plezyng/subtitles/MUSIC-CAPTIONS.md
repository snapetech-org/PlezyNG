# Music playback captions

Source integration, October 29, 2026. Confidence: moderate for source behavior;
unknown for runtime behavior. No tests, analyzers, builds, dependency installs,
model execution or CI were run, following the owner instruction.

The main music queue implements optional `MusicSubtitleService` access to its
existing audio player. Now Playing and its compact workspace pane expose the
shared subtitle tools. Imported or generated text goes through review, can be
saved in local revision history, and can occupy either app overlay lane. History
restoration for this owner returns to review with cue clocks and word spans
retained. Export, translation, companion processing and source read-ahead reuse
the existing workflows and their explicit upload/model choices.

The overlay follows the music owner's clock without opening, seeking, replacing
or disposing its player. Artwork and visualizer views display captions; the
provider lyrics view retains its own presentation. After attaching a new current
app lane through the tools, closing the sheet switches Now Playing out of the
provider-lyrics view so the new captions are visible. Cancelling or only editing
appearance leaves the current view unchanged. Compact panes honor the
workspace's focused-caption policy. The audio surface does not register a video
frame exporter, offer native subtitle attachment, or expose native HDR controls.
Closing the tools or Now Playing leaves the queue owner in control.

Access captures the queue generation, exact source object, current track and
native media generation. Manual advances, gapless adoption, stop/dispose and
profile changes invalidate pending results and overlays. The existing vehicle
restriction predicate also guards entry and ongoing source work. This does not
add background OS execution or a separate audio output owner.

Offline files use the current local file lease. Online analysis resolves a
separate direct source through the owning media-server client and exposes it
through a short-lived loopback gateway. Plex, Jellyfin and Emby now reject an
explicit source ID that no longer resolves, instead of silently selecting a
different version. Plex passes the requested source ID through its resolver.
Returned source/part metadata and multipart offsets must remain stable on
renewal. Signed credentials are not part of revision identities or persisted
analysis URLs. Representation metadata is not a content digest; replacement
under unchanged server metadata cannot be detected by this binding alone.

Local history is scoped by profile, server, item, selected media index and
source metadata. Live PCM remains conditional on the existing native tap and
packaged ABI. Separate source decoding retains the platform decoder's codec and
container limits. This covers PlezyNG's ordinary music-library queue; it does
not promise access to protected Apple MusicKit or another service's audio.
Device/queue-transition qualification and MPV binary publication remain open.
