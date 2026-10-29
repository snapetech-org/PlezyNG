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
