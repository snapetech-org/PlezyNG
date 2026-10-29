# Subtitle companion

Optional, self-hosted processing for PlezyNG's existing subtitle review flow.
No service is started or media uploaded by installing the application. Pair a
host in **AI subtitles → Pair subtitle companion**, then select a task and file.
The Dart client also works on TV builds that cannot run the local speech model,
provided the platform supplies a picker, networking and SRT attachment. Devices
without an OS credential plugin can explicitly choose session-only pairing. There is no browser Player in PlezyNG.

Implemented adapters:

| Task | Host dependency | Behavior |
| --- | --- | --- |
| `transcribe` | FFmpeg, faster-whisper | Selected audio stream, CPU or requested CUDA, word times, VAD, optional English output |
| `align` | FFmpeg, WhisperX, a matching-language CTC model | Align supplied text within plausible cue windows; uncertain cues retain original times |
| `diarize` | FFmpeg, faster-whisper, WhisperX/pyannote model | Anonymous numbered speakers; no names or identity recognition |
| `translate` | Argos Translate and an installed pair | Separate timed cues with source IDs, markup and line breaks preserved |
| `translate_model` | Explicit compatible chat-completions endpoint, model and optional host API key | Faithful/natural/literal modes, neighboring-cue context, protected structural/glossary markers and durable eight-cue checkpoints |
| `script_convert` | OpenCC | Explicit Chinese script/region/phrase conversion, separate from translation |
| `reading` | pykakasi | Japanese inline kana annotations or original + Hepburn romanization, as a separate SRT |
| `ocr` | FFmpeg, Tesseract language data | Burned-caption crop sampled at 2 Hz with temporal deduplication and OCR-score metadata |
| `bitmap_ocr` | Native helper below, FFmpeg development SDK, Tesseract language data | PGS/VobSub display decoding, original RGBA PNG evidence, cue image/text correction and evidence ZIP export |

This is source implementation, not device qualification. `capabilities` reports
installed adapters with `qualified: false`. A CPU/CUDA invocation is not proof
of per-operation device placement. The `ocr` task samples burned captions;
`bitmap_ocr` decodes PGS/VobSub separately. Neither removes burned text or
guarantees OCR accuracy. Diarization does not separate voices
or guarantee correct labels for overlaps. CTC alignment needs approximately
correct <=60-second cue windows and matching spoken-language text.

## Host preparation

Use Python 3.10–3.13 and a dedicated virtual environment. Install FFmpeg from
your platform's maintained distribution, then the relevant requirements file.
Tesseract and its selected language data are separate optional installations.
The repository's private-JIT policy applies to any future packaging/build jobs;
this addition creates no workflow and does not run CI.

```sh
python -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-inference.txt
# Optional text translation; install its language-pair packages separately.
python -m pip install -r requirements-translation.txt
# Optional Chinese script conversion and Japanese reading dictionaries.
python -m pip install -r requirements-text-extras.txt
```

### Configured model translation

`translate_model` is disabled until the host sets `PLEZY_TRANSLATION_URL` to a
full compatible `/v1/chat/completions` URL and `PLEZY_TRANSLATION_MODEL` to its
model ID. A local llama.cpp server is one option; an authenticated provider is
another. HTTP is accepted only for loopback; other hosts require HTTPS. Set an
optional `PLEZY_TRANSLATION_API_KEY` on the companion, never in app preferences.
Set `PLEZY_TRANSLATION_REVISION` to the exact model revision when available and
`PLEZY_TRANSLATION_LANGUAGES` to a comma-separated declared language catalogue.
An empty catalogue means unreported coverage, not a claim of all languages.

The app displays the full destination/model/revision before the explicit
**Forward text and translate** action. This task forwards subtitle text and
neighboring context to that endpoint; the file-only privacy description for
other tasks does not imply model translation stays on the companion. Provider
charges/retention are governed by that separately configured service. The
endpoint receives no audio, playback URL or media-server credentials. Host API
credentials stay on the host. Redirects and environment proxy routing are
disabled. No model endpoint or provider account is configured by installation.

Jobs bind to the shown endpoint/model/revision fingerprint. Configuration
changes refuse resume rather than sending an old job to a new destination.
Eight-cue batches include adjacent dialogue context and preserve cue IDs/times;
whole-track sentence redistribution is not performed. Protected numbers,
speaker labels, markup, line breaks, URLs and glossary markers must occur
exactly once in their original cue. Missing/duplicate IDs, truncated results or
broken markers fail the operation. These checks cannot prove semantic accuracy.
Completed batches persist under the job and are reused on resume. Cancelling
terminates the local worker and connection; an upstream provider may already
have processed/billed the in-flight request. There is no automatic API retry.

OpenCC modes include Simplified/Traditional, Taiwan/Hong Kong variants and
explicit Taiwan phrase conversion. pykakasi modes create inline kana after
kanji or a separate romanization line; native ruby typography and other reading
languages are not claimed. Model mode, package/revision information and glossary
digest are included in companion result provenance; all text tasks return
original cues for paired before/after review. Local revision files currently
retain the operation/language and reviewed cues, not the complete host manifest.
Retain/export host results when full adapter provenance is required.

Optional PGS/VobSub helper (source is included; no build has been run): install
the FFmpeg 6–8 development headers/libraries and pkg-config for the host's
architecture, then configure/build/install the standalone C executable:

```sh
cmake -S native -B native/build -DCMAKE_BUILD_TYPE=Release
cmake --build native/build --config Release
cmake --install native/build --prefix /your/chosen/host/prefix
```

Set `PLEZY_SUBTITLE_DECODER` to the installed `plezy-subtitle-decode` executable
(or `.exe` on Windows). Linux/macOS can use their maintained FFmpeg SDK and
pkg-config; Windows can use a compatible MSYS2/MinGW SDK or a toolchain exposing
the same pkg-config libraries. Architecture and linkage must match. No player
binary is modified by this host helper, and no SDK is downloaded automatically.
Any redistributed FFmpeg/Tesseract runtime retains its upstream license and
source obligations. No binary/runtime packaging or qualification is implied by
these source/build definitions.

`bitmap_ocr` accepts a PGS `.sup`, a supported local container's selected bitmap
subtitle stream, or a ZIP with exactly one basename-matched `.idx`/`.sub` pair.
The ZIP extractor allows only two flat regular entries, rejects encryption and
links, and limits IDX to 1 MiB and SUB to 256 MiB; it writes fixed owned names.
The decoder accepts only PGS and DVD subtitles, file protocols and approved
container demuxers. It emits original palette-derived RGBA, positions, forced
flags, and timing. A subsequent display/clear ends an indefinite PGS event;
only a missing final clear uses the explicitly selected fallback duration.
Raw SUP/VobSub clocks are retained, while container streams subtract the
container start time. Editions/timeline suitability still require review.

Bitmap bounds: one hour, 50000 display/cue records, 32 rectangles per display,
8 million pixels per display, 4096×2160 per rectangle, 4 MiB per PNG, and 32 MiB
unique PNG evidence per job. The native helper has a decode deadline and is
inside the cancellable job process tree. Original PNGs remain in the host job;
only the temporary OCR input is normalized. Unreadable text becomes an explicit
review placeholder. Low-score cues require image review/correction or exclusion
before the app's normal subtitle review. Rectangles remain separate cues; SRT
cannot retain their authored positions. Image evidence is authenticated and
SHA-256 checked, can be exported with original/corrected cue text and source
digest, and is deleted with the job. It is not copied automatically into local
revision history. The Python SDK exposes `evidence_image` as well.

Model downloads are disabled by default. `prepare_models.py` accepts an exact
Hugging Face repository commit and creates a SHA-256/size manifest in a new
directory, retaining model cards/licenses. Configure `PLEZY_WHISPER_MODEL` and
`PLEZY_ALIGN_MODEL` to the prepared directories. Switching directories gives a
reversible model update; keep the previous one for rollback. Model licenses and
pyannote gated-model access still apply. A host owner may explicitly enable
automatic model retrieval with `PLEZY_ALLOW_MODEL_DOWNLOADS=1`; those downloads
are made by the host, not with any media-server credentials.

Environment configuration:

- `PLEZY_SUBTITLE_TOKEN`: a random 32–256 character ASCII bearer token. Pair it
  with the app; the app stores it in the OS credential store, never plaintext
  preferences. Forgetting pairing does not delete host jobs or revoke the host
  token; rotate the host token to revoke existing clients.
- `PLEZY_INFERENCE_DEVICE`: `cpu` (default) or `cuda`. CUDA failures retry on CPU
  and report fallback. Install a compatible CTranslate2/PyTorch CUDA stack on
  that host before requesting CUDA.
- `PLEZY_WHISPER_MODEL`: cached model path (recommended) or faster-whisper model
  ID. Defaults to `base`; it must already be cached if downloads are disabled.
- `PLEZY_ALIGN_MODEL`: a matching-language local CTC model. Required in offline
  mode. Alignment reports unsupported/uncertain regions instead of fabricating
  word boundaries.
- `PLEZY_DIARIZATION_MODEL`, `HF_TOKEN`: optional pyannote model/access token,
  configured only on the host. The media client never receives that token.
- `PLEZY_FFMPEG`: executable path, default `ffmpeg`; no shell interpolation.
- `PLEZY_TESSERACT_LANGUAGE`: installed Tesseract language code(s), default `eng`.
- `PLEZY_SUBTITLE_DECODER`: optional native PGS/VobSub helper executable; no shell interpolation.
- `PLEZY_TRANSLATION_URL`, `PLEZY_TRANSLATION_MODEL`, `PLEZY_TRANSLATION_REVISION`,
  `PLEZY_TRANSLATION_LANGUAGES`, `PLEZY_TRANSLATION_API_KEY`: optional model translation configuration described above.

Start on localhost with `python server.py`. For another device, supply
`--host 0.0.0.0 --cert /path/cert.pem --key /path/key.pem`. The certificate must
be trusted by that device. The client does not bypass TLS validation or follow
redirects with credentials. Never put a token in a URL. The host refuses
unauthenticated requests and browser Origin requests.

## Lifecycle and bounds

The server persists job metadata and owned inputs. Only one worker runs at a
time. Pause/cancel terminates that job's process group, including its decoder;
resume reruns the job. After a server restart, unfinished jobs are paused.
There is no automatic media deletion: **Delete media and result** removes both.
Limits are 12 jobs, 2 GiB total uploaded media, 1 GiB per file, one hour of
decoded audio/video, 5 MiB request JSON, 24 MiB output, 50,000 cues, and 250,000
word records. The queue reports full until old jobs are deleted.

Inputs are explicit files, never arbitrary URLs. FFmpeg's protocol and demuxer
allowlists refuse playlists and external network transports. The chosen audio
stream is decoded independently, leaving playback/passthrough untouched.
Optional 80 Hz high-pass/FFT denoise is recorded in output. OCR uses bounded
raw-frame pipes and does not write an unbounded image sequence. Native/model
stdout and HTTP request logs are suppressed so transcript text, paths and
tokens do not enter logs.

## Protocol / SDK

Every request includes `Authorization: Bearer …` and `X-Plezy-Scope`, the SHA-256
of the app profile ID. Use separate host tokens/installations for mutually
untrusted clients; scope is an ownership partition, not a separate principal.

| Method/path | Purpose |
| --- | --- |
| `GET /v1/capabilities` | Version, installed adapters, limits, download policy, qualification state |
| `POST /v1/jobs` | Idempotent creation by `requestId` plus canonical request digest |
| `PUT /v1/jobs/{id}/audio` | Length-bounded file stream, verified against declared SHA-256 |
| `GET /v1/jobs` / `GET /v1/jobs/{id}` | Reconnect, inspect state/progress |
| `POST /v1/jobs/{id}/start` | Queue or resume after interruption |
| `POST /v1/jobs/{id}/pause` / `cancel` | Terminate the job's worker and decoder |
| `GET /v1/jobs/{id}/result` | Completed result bound to job, media digest and item identity |
| `DELETE /v1/jobs/{id}` | Remove retained media, output and metadata once the worker stops |

`client.py` is a stdlib Python SDK for these operations. The application uses
`lib/services/subtitle_companion_service.dart`, with bounded response parsing,
result-identity verification and the normal reviewed SRT/JSON/sidecar/server
attachment path. Results are never attached automatically. Text translation
uses the language selectors in the companion section; speech generation uses
the speech-language override. For `align`, confirm that the transcript language
matches the actual selected audio track.

Primary adapter references:

- https://github.com/SYSTRAN/faster-whisper/tree/v1.2.1
- https://github.com/m-bain/whisperX/tree/v3.8.6
- https://github.com/argosopentech/argos-translate
- https://ffmpeg.org/ffmpeg.html
- https://tesseract-ocr.github.io/tessdoc/Command-Line-Usage.html

No tests, analyzer, builds, inference runs, device qualification or CI were run
for this implementation, per the owner's instruction.

## Experimental evidence adapters

Install `requirements-research.txt` only for the selected adapters, in a separate
host environment. Models are **explicit local directories**; prepare pinned,
reviewed snapshots with the existing model preparation utility. No model was
installed or executed during implementation.

- `ensemble`: set `PLEZY_SECOND_WHISPER_MODEL` to a second CTranslate2 Whisper
  directory. Both passes run independently. Time-overlapping disagreements are
  returned as alternatives; the client keeps the baseline unless the viewer
  selects an alternative. Agreement is not an accuracy score.
- `separate`: set `PLEZY_SEPARATOR_MODEL` to a trusted local SpeechBrain SepFormer
  package (2/3 sources, 8/16 kHz). Five-minute input maximum, ten-second analysis
  windows/eight-second ownership. Separation artifacts and permutation changes
  are possible; labels explicitly identify **window-local voice candidates**.
  Parallel cues are preserved. This is not cross-window speaker identification.
- `sound_events`: set `PLEZY_SOUND_MODEL` to a local Transformers audio classifier.
  Five-second windows at 2.5-second strides need two consecutive ≥0.8 scores to
  propose a caption. Output says “Possible sound”; mono analysis never claims
  spatial direction. No language/event quality is qualified.
- `completeness`: submit matching cues and media. Bundled Silero VAD is compared
  with the union of subtitle intervals. Original cues are retained; uncovered
  speech intervals and coverage counts are evidence, not proven omissions.
- `extract_text`: choose an embedded subtitle ordinal. FFmpeg converts supported
  text streams (including mov_text) to bounded SRT; drawings, positioning and
  closed-caption service semantics are not represented by SRT.
- `signs`: the chosen OCR crop is retained as a normalized sign region. App
  overlays preserve that region; SRT flattens it. Both burned-caption and sign
  OCR now preserve a representative resized grayscale image for every cue,
  within the 32 MiB image evidence budget, for the existing correction/export UI.

Recognition now accepts the existing glossary's source keys as explicit hotword
hints. Hints do not force recognized spelling and are not model adaptation.
Research adapters remain subprocess-cancellable and use the existing upload,
profile scope, identity, result bounds and four-hour worker deadline.

API references: [SpeechBrain separation](https://github.com/speechbrain/speechbrain/blob/develop/speechbrain/inference/separation.py),
[SepFormer model input contract](https://huggingface.co/speechbrain/sepformer-wsj02mix),
[Transformers audio classification](https://huggingface.co/docs/transformers/main_classes/pipelines#transformers.AudioClassificationPipeline),
[faster-whisper VAD](https://github.com/SYSTRAN/faster-whisper/blob/master/faster_whisper/vad.py).

### Synthesized speech and explicit scene context

`dubbing` accepts only reviewed, already-translated cues (no media upload);
`dub_mix` also uploads matching media and ducks its selected audio stream by
`duckRatio` (0–1). Both are bounded to ten minutes and 500 cues. Install the
research requirements, configure an absolute local `PLEZY_PIPER_MODEL` ONNX
path and `PLEZY_PIPER_LICENSE`, and retain its adjacent model configuration.
The app displays the configured voice/license fingerprint before submission.
The host refuses voice changes between submission and inference. Outputs are
mono 16 kHz PCM WAV, at most 32 MiB. Timing fit uses FFmpeg atempo up to 2×;
overlong utterances are omitted with cue-specific diagnostics. Overlap is mixed
with peak attenuation. The original file is immutable. No voice identity,
cloning, pronunciation quality or lip synchronization is asserted. Download
only after reviewing warnings through `/v1/jobs/ID/artifacts/SHA256` or the SDK's
`audio_artifact`; the app offers an explicit WAV export. An installed voice is
not evidence of redistribution rights.

`ocr_auto` samples up to eight frames across the first two minutes and chooses
a repeatedly occupied text band. It can select credits or scenery; all normal
OCR image correction and timing caveats still apply. Tesseract output is read
with a strict 1 MiB bound and a kill deadline.

`scene_review` accepts at most 30 explicitly chosen cue windows and uploaded
video. Configure `PLEZY_VISION_URL` (chat/completions), `PLEZY_VISION_MODEL`,
`PLEZY_VISION_REVISION`, and optionally `PLEZY_VISION_API_KEY`. This is a separate
forwarding destination from text translation. Capabilities disclose it and the
client binds its fingerprint before any job is sent. The adapter forwards one
640×360 frame and caption per cue, uses no remote tools/code or redirects,
retains source-image evidence, and returns hypotheses alongside unchanged
baseline cues. A single image cannot establish spoken words. The app requires
explicit alternative selection and image review. Compatible protocol shape is
based on the primary [llama.cpp server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
No model/provider was executed or qualified during source implementation.

### Offline model adaptation

`adapt_model.py` is an explicit administrator CLI, never an HTTP job. Use a
separate environment with `requirements-adaptation.txt`, a local safetensors
Whisper tiny/base checkpoint, a local corpus, and three JSON manifests: training,
domain holdout, and general holdout. Each row has exactly `audio` (path relative
to corpus root), `text`, `sha256` (WAV bytes), and `sourceDigest` (parent recording
identity). Use 10–2000 examples per split, 0.1–30-second mono 16 kHz PCM16 WAVs,
and disjoint parent recordings and clip hashes across splits. The tool rechecks
clip integrity when reading. Corpus identities are declarations; they do not
prove speaker, title or population independence.

```sh
python adapt_model.py --base /models/whisper-base-hf --corpus /corpus \
  --train /corpus/train.json --domain-eval /corpus/domain.json \
  --general-eval /corpus/general.json --output /models/candidate-new \
  --language en --license 'Record the model/corpus license and consent here' \
  --device cpu --steps 200 --export-ctranslate2
```

The tool measures baseline and candidate WER/CER with identical disclosed
normalization, requires lower domain WER with no general WER/CER regression for
a positive recommendation, and writes checksums, corpus-manifest digests,
parameters and the declared license to `adaptation-report.json`. It never
activates a candidate or modifies the base. Optional CTranslate2 int8 export
happens only after the HF-model gate; exported quantization still needs its own
quality/hardware qualification. Point `PLEZY_SECOND_WHISPER_MODEL` at a reviewed
export for independent comparison before any deliberate host-model change.
No training, model installation or evaluation was run while adding this code.

### Owned-source uploads and source clocks

Clients advertising `sourceTimelineOffsets` accept `timelineOffsetMs` for
generation-only jobs, bound into the idempotency fingerprint. It represents a
complete opened media part, not a seek into the uploaded bytes. Cue, word and
image times in results include it exactly once. `itemTimeline: true` also marks
zero-offset first parts; a nonzero offset implies it for legacy SDK clients.
The result echoes the flag. Native attachment subtracts the currently opened
part offset once, with explicit review for clipped cues. Overlays, revision
history, drafts, undo checkpoints and JSON exports preserve the item clock.
SRT exports contain the shown times without clock metadata. Server attachment
requires an explicit part contract and is disabled for item-clock results.
The Flutter client can stage
complete VOD files through its source-owned gateway without sending playback
URLs or credentials. Limits remain 1 GiB / one hour; playlists require a decoder.

`soundStereoEvidence: true` on a sound-event job requests repeated stereo energy
measurements. `soundEvidence` records downmix method, window count, median L/R
dB difference and an explicit `eventLocalized: false`. This is not physical
sound localization. The Python SDK checks support before using either extension.

### Sampled temporal scene evidence

`sceneTemporalRegions: true` is an opt-in `scene_review` extension, advertised by
the capability of the same name. It forwards three 640×360 frames per chosen cue
(10%, 50%, 90%) to the reviewed vision destination. One chronological three-panel
PNG per cue preserves compatibility with image correction/evidence exports.
`sceneRegionTracks` contains cue-local adjacent-frame IoU associations, original
sample times/rectangles, and an envelope. These are unverified nonsemantic
proposals, not identities or continuous tracking. `avoidRegions` retains at
most twelve envelopes per cue, preferring repeated observations. All normal
one-hour, thirty-cue, 4 MiB/image and 32 MiB evidence limits still apply. The
Python and Flutter clients refuse the option on a host without the capability.

### Joint audio and image review

A host whose configured `PLEZY_VISION` chat-completions provider accepts both
`image_url` and WAV `input_audio` content in one request may explicitly declare
`PLEZY_VISION_ACCEPTS_AUDIO=1`. This declaration changes the provider fingerprint
and is shown as unqualified in capabilities. It does not probe a model, select a
provider, establish a license, or prove that the model uses both modalities.
The default remains image-only. Incompatible providers fail the job.

`sceneAudioEvidence: true` is available only for `scene_review`, after separate
client consent to forward audio to the declared destination. Each selected-track
clip follows the supplied cue interval (up to 12 seconds, two minutes total) and
is decoded as PCM16 mono 16 kHz WAV with byte and execution bounds. Audio and
chronological frames are sent together. The result records clip hashes, interval,
track and decode format, and requests alternate wording without changing baseline
text or timing. Alternatives still require review against the source audio.
No lip-reading, identity, attested modality use or measured improvement is claimed.
The content-part schema follows the provider-compatible
[Chat Completions contract](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create);
a schema accepting both parts does not imply every model supports them jointly.
No provider request or model execution was performed while implementing this.

### Ruby and lyric word proposals

`readingMode: "ruby"` adds bounded `<ruby>base<rt>reading</rt></ruby>` markup using
the existing Japanese dictionary adapter. `readingModes` advertises the option
and both clients check it. PlezyNG's horizontal app overlay renders the reading
above the base; native SRT playback may flatten it. Plain snapshot export and
spoken subtitles use base text. Readings remain dictionary suggestions, not
verified pronunciation. Existing annotated text is refused for ruby generation
to prevent nested or duplicated annotations.

`singing_align` is advertised with WhisperX plus `PLEZY_SINGING_ALIGN_MODEL`,
an absolute directory containing a reviewed Wav2Vec2 CTC model and vocabulary.
`prepare_models.py --purpose singing-alignment --repo OWNER/MODEL
--revision FULL_COMMIT --output EMPTY_DIRECTORY` prepares and hashes the supported
layout without executing model code. Select a model whose license and language
coverage you have reviewed; this workflow does not supply or qualify weights.

The lyric adapter accepts matching-language lyrics for a media file up to five
minutes, 120 cues and 30 seconds per cue. It compares CTC alignment on original
audio with a median-mask harmonic view, processed in bounded 16-second chunks.
This suppresses percussive energy rather than isolating vocals. Only word
sequences whose boundaries agree within 250 ms across both views are returned.
The original lyric text and cue bounds are unchanged. `lyricTimingEvidence`
records accepted words, rejected cues and observed boundary differences.
Melisma, instruments, chorus overlap and singing pronunciation can defeat both
views; shared agreement is not a calibrated confidence score. No note/syllable
timing or uniform word interpolation is invented. CPU and requested CUDA follow
the existing explicit fallback path, without per-operation placement attestation.
No model preparation, inference, evaluation, rendering or test was run.

### Cue-bounded local scene motion

`scene_review` accepts `sceneMotionTracking: true` only when the host advertises
`sceneMotionTracking`. Install the optional research requirements to supply
OpenCV. The request is capped at 30 cues, 12 seconds per cue and two minutes of
combined cue duration. It starts the provider's image sampling at the cue start,
then follows the initial region texture locally on a 640×360, 12 Hz decoded
frame grid. Extra tracking frames are not forwarded to the configured provider.

The tracker uses bounded feature sets, forward/reverse Lucas–Kanade matching,
RANSAC partial-affine motion, and explicit roundtrip/inlier/scale/rotation/frame
bounds. Failed tracks are retired; a cut/flash gate ends remaining paths. There
is no person identification, embedding, cross-cut matching, occlusion recovery,
or assumed continuation after a failed observation. Thresholds are uncalibrated.
Stored quadrilaterals avoid repeatedly inflating a rotated box's envelope.

Results include `sceneMotionEvidence` with observed frame count, decoder-grid
clock, OpenCV version and stop status, plus sample paths in `sceneRegionTracks`.
Caption placement uses the bounded fixed envelopes. Original words and timing
remain unchanged, and alternatives still require explicit image review. This is
an experimental texture tracker; background drift and false cut gates remain
possible. No tracking/quality/device run was performed during implementation.

API reference: [OpenCV feature optical flow](https://docs.opencv.org/4.x/dc/d6b/group__video__track.html).

### App research evidence export

Completed research jobs expose their bounded measurements in the app before
caption editing: comparison counts, VAD gaps, lyric boundary disagreements,
possible sound events/mix balance, sampled/locally tracked regions, audio/image
requests and synthesized-line fitting. Expand observations or export a JSON
report containing the input digest, clock basis, model/runtime provenance,
returned cues/word proposals, alternatives and artifact digests. These are host
observations before viewer edits and remain unqualified. The app accepts at most
4 MiB of evidence and exports reports up to 24 MiB. Image bundles include the
same metadata; audio/image pixels are exported separately through their existing
explicit actions. No new network destination or automatic upload is added.
