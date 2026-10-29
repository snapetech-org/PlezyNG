# Owned-source movie fingerprints

Standalone VOD provider search can use OpenSubtitles' file-size plus first/last
64 KiB fingerprint for local, downloaded and range-capable remote files. Remote
reads use the existing source adapter's renewable loopback lease. Provider
credentials and signed addresses never enter the hash service or its result.

The operation has an eight-second budget including acquisition. A source,
profile, edition or opened-file change retires it. Local reads check size and
file timestamps before/after. Remote reads require two exact HTTP 206 ranges,
the declared total size, identity encoding, bounded response bodies and matching
ETag/Last-Modified observations when present. Redirects, entire-file responses,
unknown sizes, live streams, previews and restricted stream-only sources cannot
produce a fingerprint. Errors retain ordinary title/ID search.

This format is a provider matching hint, not a cryptographic identity check.
Unchanged catalog metadata and absent server validators cannot establish that a
remote object was immutable between reads. A match still requires the existing
release/role review; no result is downloaded or attached by this operation.

Source-reviewed only. No requests, tests, analyzers, builds or device runs were
performed under the owner's code-only instruction.
