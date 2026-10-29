# Offline subtitle dictionaries

Subtitle study offers **Offline dictionaries** alongside the explicit browser
lookup. Subtitle tools also offer **Review spelling with an offline dictionary**.
Import a UTF-8 JSON file, review its title, declared language and attribution, then
choose it explicitly for each lookup or spelling pass. Packs are shared by local
profiles on this device. No content is downloaded or sent to a dictionary service.

```json
{
  "schema": 1,
  "title": "Example English vocabulary",
  "language": "en",
  "license": "Example entries supplied by the user; replace with the actual attribution and license.",
  "entries": [
    {"term": "caption", "definitions": ["Text showing speech or other audio information."]},
    {"term": "London", "definitions": [], "caseSensitive": true},
    {"term": "the", "definitions": []}
  ]
}
```

A pack has 1–50,000 unique NFC-normalized terms, at most 64 UTF-16 code units per
term, up to eight plain-text definitions of 2,000 code units each, a title of 100
code units and required attribution of up to 16,384 code units. Language uses a
bounded BCP-47-shaped tag; it is declared by the author, not detected or verified.
Each file is limited to 8 MiB, with eight packs / 64 MiB maximum. A content digest
binds the import preview to retained bytes and is checked when loading. There is
no executable pack code or markup rendering. Existing Hunspell, StarDict and
dictionary archive formats require conversion to this documented schema; no
general compatibility is implied.

Exact lookup normalizes Unicode NFC and lowercase, with explicit dotted/dotless
I handling for Turkish and Azerbaijani. `caseSensitive` entries require their
authored case for spelling acceptance. Definitions remain available regardless
of case. Inflections, alternate forms and regional spellings must be explicit
entries. This is vocabulary checking, not morphological or contextual grammar
analysis. Spaces and script without word delimiters need exact lookup; the
spelling tokenizer does not claim dictionary segmentation for those languages.

Spelling review scans plain Unicode letter/mark words with internal apostrophes
or hyphens. Styled/ASS cues are skipped to preserve authored semantics. It offers
up to five candidates within one insertion, deletion, substitution or adjacent
transposition. There is no frequency ranking or automatic replacement. Missing
vocabulary can be correct. Each selected occurrence is replaced independently;
original cue IDs and times are retained for the existing derivative review flow.
Names and neighboring occurrences are never silently changed together.

Work is performed in an isolate, bounded to 100,000 tokens, 200 displayed misses
and two million candidate comparisons. Reaching a limit is disclosed as an
incomplete check. The original file remains unchanged. Corrections pass through
normal review, export and attachment identity guards. The import digest and
language are included in the review warnings. Removing a pack does not undo
previously accepted subtitle revisions.

Confidence is moderate in the source integration and unknown in runtime
behavior or language coverage. No tests, analyzers, builds, dictionary execution
or CI were run during this code-only implementation pass.
