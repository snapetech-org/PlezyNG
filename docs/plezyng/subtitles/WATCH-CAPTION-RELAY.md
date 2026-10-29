# Companion caption channels

Watch Together captions can use either the existing shared cloud folder or an
expiring channel on a paired subtitle companion. The companion route removes
the shared-folder requirement; it does not modify the Open Watch Party protocol
or send caption assets through a third-party OWP relay.

The host joins room playback, chooses **Expiring companion channel**, creates a
six-hour channel, and explicitly copies its caption code to participating users.
The host must already have paired the companion in subtitle tools. Receivers
paste the code, check the displayed HTTPS destination and expiry, confirm the
same cut/part/audio, and start reception. Every participant needs network access
to that host. HTTP is accepted only on loopback; a localhost code cannot reach
the host from another device. This path adds no NAT traversal or public hosting.

The app code contains an opaque channel ID, a channel-only random capability,
a separate random encryption key, an expiry and the existing hashed room scope.
It never contains the companion administration token, media URLs or account
credentials. Codes stay in memory and enter the clipboard only after an explicit
copy action. They grant shared read/write access to the channel. A group member
can alter/delete its contents; neither the shared key nor the transport proves
which member authored a revision. Do not treat the code as a host signature.

The existing AES-GCM envelope, content digests, cue/word-time validation, causal
revision choices and review/automatic-display controls remain in use. Key
derivation includes the room, epoch, host and canonical media descriptor. Local
playback admission also binds profile, selected copy, audio, opened part and
offset. Mismatched room codes are refused before contacting the relay. Stop,
backgrounding, room/copy/offset changes and local lane replacement cancel
outstanding relay requests and release the installed lane as before. Local
appearance and corrections remain local. The server never decrypts envelopes.

The companion advertises `captionRelay: 1` without requiring inference packages.
Its authenticated administrative routes use the usual profile scope:

| Method / route | Result |
| --- | --- |
| `POST /v1/caption-channels`, body `{"version":1}` | Creates channel ID, random token and expiry; requires companion token |
| `DELETE /v1/caption-channels/{id}` | Revokes a channel created under that profile scope; requires companion token |
| `GET /v1/caption-relay/{id}/list/{namespace}` | Lists bounded immutable generation names; requires channel token |
| `GET /v1/caption-relay/{id}/objects/{name}` | Reads one opaque UTF-8 envelope |
| `PUT /v1/caption-relay/{id}/objects`, body `{name,text}` | Creates an immutable envelope; identical retry is idempotent |
| `DELETE /v1/caption-relay/{id}/objects/{name}` | Deletes a generation for normal client pruning |

Channel tokens cannot access jobs, upload media, create other channels or revoke
channels administratively. Authentication precedes relay body reads. Origin
headers, queries, redirects, unrecognized names and out-of-scope file references
are refused. The Dart transport bounds bodies and has a 45-second overall
request deadline. The Python SDK exposes administrative create/revoke methods;
it does not distribute codes or implement app room/encryption semantics itself.

Channel storage is memory-only: at most eight channels, 256 objects per channel,
2 MiB per envelope, 64 MiB per channel and 128 MiB total ciphertext. Access expires
after six monotonic-clock hours; expired bytes are purged within 30 seconds.
Server restart clears every channel. The creating profile may explicitly revoke
a channel earlier. Stopping local reception does not revoke it for other viewers.
Old asset chunks remain within the channel quota until expiry/revocation; no
unbounded history or implicit storage expansion occurs. A full relay requires a
new channel or expiry, and is reported rather than dropping caption revisions.

Source integration confidence is moderate. Transport behavior, concurrent-device
convergence, clocks and memory accounting require runtime qualification. No
tests, analyzers, builds, dependency/model execution or CI ran for this change.
