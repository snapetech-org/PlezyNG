# Automatic paired caption defaults

The encrypted caption-defaults dialog offers an independent opt-in for automatic
synchronization while the app is active. It checks on activation/profile setup
and every five minutes, with a manual check action. No OS worker or closed-app
network activity is added. Existing cloud-folder authorization and the separately
paired defaults key are required; changing that destination or key requires a
fresh opt-in. Disconnecting first retires the automatic cycle.

A durable common content digest distinguishes one-sided edits from conflicts.
An empty channel publishes the saved local defaults. Matching local/shared
defaults establish the baseline. Later local edits publish only against that
observed shared baseline; a sole shared edit imports only while local settings
still equal it. Different initial presets, concurrent versions and divergent
local/remote changes stop for the existing explicit preview/choice flow. No
wall-clock winner is selected. Acknowledging a sole imported version advances
causal context without inventing a conflict-resolution revision.

Only saved appearance for two app lanes and default forced/SDH rules participate.
Existing overlays, track selection, title overrides, native corrections and fonts
are not changed or sent. Each settings owner rechecks its group when its serialized
write runs. A simultaneous manual edit is preserved; previously completed group
imports are retained if a later group fails, and the cycle stops for review. The
three preference groups are not one storage transaction. No partial import is
recorded as a completed common baseline. Subsequent manual preview remains the
recovery path. Successful baseline persistence compares the entire policy journal
inside a database transaction.

Profile/source generations, configuration changes, backgrounding and disposal
retire in-flight operations at their existing guarded boundaries. An already
dispatched immutable cloud upload may finish, but cannot silently attach or
select captions. Transfer bounds, AES-GCM envelopes, immutable generations and
causal conflicts reuse the existing subtitle cloud register. Status never claims
that an offline or failed exchange succeeded.

No network synchronization, model, test, analyzer, build or CI was run. Source
integration, conflict recovery and platform behavior remain unqualified.
