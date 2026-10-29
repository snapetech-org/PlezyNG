# Subtitle role preferences and provider preview

The preferred-language settings and in-player track sheet now expose local
profile defaults for forced status and SDH/CC preference. The library track
sheet can save an exact-title override, including an explicit neutral override
of a non-neutral profile default. Up to 200 title identities are stored as
digests within a 64 KiB profile record. Removing an override restores inheritance;
resetting the default preserves title overrides. Preferences do not migrate
between profiles or synchronize to a server.

These rules apply to the existing fallback selection ladder and automatic
preferred-language downloads. Explicit Off, carried/manual choices, authoritative
server choices, and a server's off decision retain their existing priority.
Language order remains ahead of accessibility ranking; provider exact-match
evidence remains ahead of SDH preference for downloads. With neutral rules,
existing candidate order is preserved. Forced filtering uses the existing
effective flag/title-marker semantics. SDH preference uses provider flags when
available and explicit title markers otherwise; missing markers do not prove a
full-dialogue or non-SDH track. Standalone temporary subtitle-on-mute selection
also uses the profile default. Ordinary native source auto-selection remains
engine-owned. Changes do not replace a currently playing selection.

Jellyfin and Emby search results now have a separate text-preview button for
SRT, WebVTT, ASS and SSA. The client uses the authenticated provider-read route,
not the library-attachment POST. Reads are limited to 5 MiB and fifteen seconds,
cancel on disposal/new search, and are discarded after profile/client/search
changes. The dialog shows at most twelve cue intervals and 4,000 characters per
cue. It exposes text and timing, not native ASS rendering or bitmap glyphs.
Downloading/attaching remains a separate explicit action. Provider quotas may
apply to previews, and a later server download is not claimed byte-identical to
the preview. Failure leaves the ordinary download action available.

Plex has no verified provider-preview route in this implementation, so the
control is not exposed there. No undocumented URL is fetched with server
credentials. Standalone OpenSubtitles retains its existing bounded preview.

Primary API references checked on October 29, 2026:

- [Jellyfin SubtitleController](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/SubtitleController.cs): `GetRemoteSubtitles`, separate from `DownloadRemoteSubtitles`.
- [Emby SubtitleService](https://betadev.emby.media/reference/RestAPI/SubtitleService.html): `GET /Providers/Subtitles/Subtitles/{Id}`.

Source review only. No analyzer, formatter, tests, build, server API execution or
CI was run; provider permissions, quotas, runtime behavior and UI accessibility
remain unqualified.
