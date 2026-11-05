# Local IPTV recording storage

Direct HTTP captures keep their native container. HLS captures are self-contained
local HLS archives: the recording's `.m3u8` entry points to an app-owned sibling
media directory. Video and default external audio retain separate playlists.
Initialization maps belong to individual segments; discontinuities and available
programme timestamps remain in the local playlists. AES-128 resources are
decrypted before publication; remote URLs and keys are not written to disk.

Resources are written to partial files, flushed, and renamed before a local
playlist references them. Capture stops between complete resources. Transient
fetches retry up to three times; a scheduled deadline or an interrupted process
does not delete completed media. Recovery finalizes existing event playlists,
retains interrupted captures and measures the actual local media bytes.

The normal Recordings player opens the local master playlist and deletion removes
both the recording and its validated sibling archive. A marker cannot select an
absolute path, parent directory or symbolic link for deletion.

Current limits: 12-hour schedules, 50,000 segments per rendition, 64 MiB per media
resource, 64 GiB per recording, and AES-128 identity keys. Other DRM/encryption
methods are explicitly rejected. Hardware/player and crash-recovery acceptance
must be exercised on each supported target; regression tests added with this
implementation have not been executed on the authoring host.
