# Curated title extras

Implementation branch starts from `cd68151ccd3de7eb306af0487ae7abc04c4b956a`.

The feature attaches a maximum four-card preview to a film or show. Expanded
browsing retains the same eligibility rules. Empty is a valid outcome. No
home-feed recommendations, popularity signals, automatic queue expansion, or
AI-based exceptions to source and title checks are permitted.

The shared contracts distinguish native library extras, manually attached
links, reviewed associations, and provider candidates. External candidates
need an exact canonical parent identity and either a reviewed association or
a verified publisher plus a catalogue association. Franchise/season/episode
scope requires an explicit label. Ambiguous associations fail closed.

AI is optional, source-permission-aware enrichment. It cannot introduce URLs,
alter trust, mark content spoiler-safe, or promote a rejected candidate.
Conventional topic and transcript search remains available without AI.

Platform qualification, service setup, test evidence and operational limits
are recorded here as the implementation is completed.
