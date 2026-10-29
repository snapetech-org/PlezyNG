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
```

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
