# Isolated solo-vocal notes and viewer review

Source workflow, October 29, 2026. Confidence: moderate for integration;
unknown for isolation, pitch/boundary accuracy and runtime behavior. No tests,
models, builds, analyzers, dependency installs, audio execution or CI ran.

The optional `vocal_notes` companion task accepts an explicitly chosen mono
16 kHz PCM16 WAV, at most two minutes and 4 MiB. The viewer declares that it is
an isolated solo vocal retaining the original file clock and supplies matching
lyric cues: at most 120, at most 12 seconds per cue and two minutes in total.
The task does not automatically isolate, downmix, resample or substitute a
player source. The host validates the container and limits, but cannot verify
the acoustic declaration or its alignment with the main recording.

Local librosa pYIN proposes voiced F0 and YIN provides a consistency check.
They are related estimators; agreement is not independent validation. Retained
frames need a voiced score of at least 0.8, agreement within 35 cents, pitch
within 35 cents of a semitone, no substantial clipping, and a stable group of
at least five frames. Analysis uses 2048-sample/128 ms windows and a 320-sample/
20 ms hop, without implicit centering/padding. Candidate boundaries describe
accepted frame centers plus half a hop. The output grid is not an onset/offset
error bound. Octaves, instrument bleed, harmony, vibrato, slides and melisma can
defeat these gates or leave missing notes.

The host preserves cue wording and timing and emits a separate evidence record:
stable digest-bound candidate IDs, pitch, median Hz/cents, voiced-score minima,
frame/rejection counts, skipped/omitted counts and runtime parameters. At most
80 candidates per cue and 1000 per job are retained. No note becomes a lyric
word timing or a rendered caption automatically.

The app's research review has an individual note editor. All proposals start
unselected. A viewer can correct pitch and file-clock boundaries, omit a
proposal, or add a missing note within a cue. Export rejects invalid MIDI
pitches, times outside the cue and overlapping selected notes, and requires a
fresh declaration that the selected notes were checked against the isolated
source. Every selection or edit clears that declaration. Audition/comparison is
the viewer's responsibility; this editor does not replace the playback owner or
silently play another file.

`plezyng.reviewed-vocal-notes.v1` JSON retains selected notes, whether they were
accepted/corrected/added, original evidence, unselected candidate counts, job and
input digests, cues, clock basis and the viewer's review declaration. It keeps
`qualityQualified: false`: viewer-reported review is not a measured model result.
Caption files remain unchanged. Unexported edits are session-local; exporting
the note track is the persistence step. No automatic note-to-syllable assignment,
score following, MIDI playback or protected-service vocal extraction is claimed.

The dependency already appears in `requirements-research.txt` (`librosa` 0.11.x).
The separate mixed-soundtrack pitch experiment retains its original mix-only
scope. Actual vocal-note and boundary qualification still requires independent
annotated recordings and held-out measurement.

Primary API references:

- [librosa 0.11 pYIN](https://librosa.org/doc/0.11.0/generated/librosa.pyin.html)
- [librosa 0.11 pitch implementation](https://librosa.org/doc/0.11.0/_modules/librosa/core/pitch.html)
