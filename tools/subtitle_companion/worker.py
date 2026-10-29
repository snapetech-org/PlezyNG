#!/usr/bin/env python3
"""Isolated inference worker. It never receives credentials for a media server."""
from __future__ import annotations

import csv
import difflib
import hashlib
import io
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import wave

from server import MAX_RESULT, atomic_json, read_json
from text_adapters import TEXT_TASKS, translate_model, derivative

MAX_SECONDS = 3600
FORMATS = "matroska,webm,mov,avi,mp3,wav,flac,ogg,aac,ac3,eac3,mpegts,mpeg"


def progress(folder, phase, fraction):
    atomic_json(folder / "progress.json", {"phase": phase, "fraction": max(0, min(1, fraction))})


def decode_audio(folder, job):
    progress(folder, "Decoding selected audio", 0)
    target = folder / "analysis.wav"
    command = [os.environ.get("PLEZY_FFMPEG", "ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
               "-protocol_whitelist", "file,pipe", "-format_whitelist", FORMATS,
               "-i", str(folder / "input.media"), "-map", f"0:a:{job['audioTrack']}", "-vn",
               "-ac", "1", "-ar", "16000", "-t", str(MAX_SECONDS + 0.1)]
    if job.get("preprocess"):
        command.extend(["-af", "highpass=f=80,afftdn=nf=-25"])
    command.extend(["-c:a", "pcm_s16le", "-f", "wav", str(target)])
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=1800)
    if result.returncode:
        raise ValueError("audio_decode_failed")
    import numpy as np
    with wave.open(str(target), "rb") as stream:
        count = stream.getnframes()
        if stream.getnchannels() != 1 or stream.getsampwidth() != 2 or stream.getframerate() != 16000:
            raise ValueError("invalid_decoded_audio")
        if not 0 < count <= MAX_SECONDS * 16000:
            raise ValueError("audio_duration_limit_one_hour")
        audio = np.frombuffer(stream.readframes(count), dtype="<i2").astype(np.float32) / 32768
    return audio


def cue_id(job, index, start, end, text):
    return hashlib.sha256(f"{job['audioDigest']}:{index}:{start}:{end}:{text}".encode()).hexdigest()


def recognize(folder, job, audio, device, model_name=None):
    from faster_whisper import WhisperModel
    model = WhisperModel(model_name or os.environ.get("PLEZY_WHISPER_MODEL", "base"), device=device,
                         compute_type="float16" if device == "cuda" else "int8",
                         cpu_threads=min(8, os.cpu_count() or 2), num_workers=1,
                         local_files_only=os.environ.get("PLEZY_ALLOW_MODEL_DOWNLOADS") != "1")
    segments, info = model.transcribe(audio, language=job.get("language"),
                                     task="translate" if job.get("translateToEnglish") else "transcribe",
                                     word_timestamps=True, vad_filter=True, condition_on_previous_text=False,
                                     hotwords=" ".join(job.get("glossary", {}).keys())[:2000] or None)
    cues, words = [], []
    duration_ms = round(len(audio) / 16)
    for segment in segments:
        text = segment.text.strip()
        start, end = max(0, round(segment.start * 1000)), min(duration_ms, round(segment.end * 1000))
        if not text or len(text) > 4000 or end <= start:
            continue
        identifier = cue_id(job, len(cues), start, end, text)
        cues.append({"cueId": identifier, "index": len(cues) + 1, "startMs": start, "endMs": end, "text": text})
        for word in segment.words or []:
            a, b = max(0, round(word.start * 1000)), min(duration_ms, round(word.end * 1000))
            if b <= a or not math.isfinite(word.probability):
                continue
            words.append({"cueId": identifier, "cueIndex": len(cues), "startMs": a, "endMs": b,
                          "text": word.word.strip(), "confidence": max(0, min(1, word.probability)), "unit": "word"})
        if len(cues) > 50000 or len(words) > 250000:
            raise ValueError("caption_limit")
        progress(folder, "Recognizing speech", end / duration_ms * 0.85)
    return {"cues": cues, "wordTimings": words, "language": "en" if job.get("translateToEnglish") else info.language,
            "languageProbability": float(info.language_probability), "durationMs": duration_ms}


def align(folder, job, audio, device):
    import whisperx
    language = job["language"]
    explicit_model = os.environ.get("PLEZY_ALIGN_MODEL")
    allow_download = os.environ.get("PLEZY_ALLOW_MODEL_DOWNLOADS") == "1"
    if not allow_download and not explicit_model:
        raise ValueError("configure_cached_alignment_model")
    model, metadata = whisperx.load_align_model(language_code=language, device=device,
                                                model_name=explicit_model, model_cache_only=not allow_download)
    output, words, uncertain = [], [], []
    duration_ms = round(len(audio) / 16)
    for index, cue in enumerate(job["cues"]):
        # Whole-title alignment without timing anchors grows the CTC trellis
        # without bound. Each submitted cue must be a plausible <=60s region.
        plain = re.sub(r"<[^>]{0,160}>|\{[^}]{0,160}\}", "", cue["text"]).replace("\\N", " ").strip()
        if cue["endMs"] > duration_ms or cue["endMs"] - cue["startMs"] > 60000 or not plain:
            output.append(cue)
            uncertain.append(cue["cueId"])
            continue
        result = whisperx.align([{"start": cue["startMs"] / 1000, "end": cue["endMs"] / 1000, "text": plain}],
                                model, metadata, audio, device, interpolate_method="ignore",
                                return_char_alignments=False, print_progress=False)
        aligned = [w for w in result.get("word_segments", []) if
                   isinstance(w.get("start"), (int, float)) and isinstance(w.get("end"), (int, float)) and
                   w["end"] > w["start"] and math.isfinite(w.get("score", 0)) and w.get("score", 0) >= 0.35]
        covered = sum(len(re.sub(r"\W", "", w.get("word", ""))) for w in aligned)
        total = len(re.sub(r"\W", "", plain))
        if not aligned or not total or covered / total < 0.8:
            output.append(cue)
            uncertain.append(cue["cueId"])
            continue
        start = max(cue["startMs"], round(min(w["start"] for w in aligned) * 1000))
        end = min(cue["endMs"], round(max(w["end"] for w in aligned) * 1000))
        if end <= start:
            output.append(cue)
            uncertain.append(cue["cueId"])
            continue
        output.append({**cue, "startMs": start, "endMs": end})
        for word in aligned:
            a, b = max(start, round(word["start"] * 1000)), min(end, round(word["end"] * 1000))
            if b > a:
                words.append({"cueId": cue["cueId"], "cueIndex": index + 1, "startMs": a, "endMs": b,
                              "text": word["word"], "confidence": max(0, min(1, word["score"])), "unit": "word"})
        if len(words) > 250000:
            raise ValueError("word_timing_limit")
        progress(folder, "Aligning matching-language transcript", (index + 1) / len(job["cues"]))
    return {"cues": output, "wordTimings": words, "language": language, "durationMs": duration_ms,
            "uncertainCueIds": uncertain, "warnings": [f"{len(uncertain)} cues retained original timing because alignment was unsupported or uncertain.",
            "CTC scores are uncalibrated. Alignment requires matching spoken-language text and approximate cue intervals."]}


def diarize(folder, job, audio, device):
    from whisperx.diarize import DiarizationPipeline, assign_word_speakers
    result = recognize(folder, job, audio, device)
    progress(folder, "Separating anonymous speakers", 0.86)
    pipeline = DiarizationPipeline(token=os.environ.get("HF_TOKEN"), device=device,
                                  model_name=os.environ.get("PLEZY_DIARIZATION_MODEL"))
    diarized = pipeline(audio, min_speakers=1, max_speakers=12)
    segments = [{"start": c["startMs"] / 1000, "end": c["endMs"] / 1000, "text": c["text"]} for c in result["cues"]]
    labelled = assign_word_speakers(diarized, {"segments": segments}, fill_nearest=False)
    speakers = {}
    for cue, segment in zip(result["cues"], labelled["segments"]):
        speaker = segment.get("speaker")
        if speaker is not None:
            label = speakers.setdefault(speaker, f"Speaker {len(speakers) + 1}")
            cue["speaker"] = label
            cue["text"] = f"{label}: {cue['text']}"
    result["warnings"] = ["Anonymous speaker clustering is uncertain, particularly during overlap. No personal identities were inferred."]
    return result


def translate(folder, job):
    from argostranslate import translate as argos
    output = []
    protected = re.compile(r"<[^>]{0,160}>|\{[^}]{0,160}\}|\\[Nnh]|\n|https?://\S+|www\.\S+")
    for index, cue in enumerate(job["cues"]):
        parts, cursor = [], 0
        for match in protected.finditer(cue["text"]):
            plain = cue["text"][cursor:match.start()]
            parts.append(argos.translate(plain, job["language"], job["targetLanguage"]) if plain.strip() else plain)
            parts.append(match.group())
            cursor = match.end()
        plain = cue["text"][cursor:]
        parts.append(argos.translate(plain, job["language"], job["targetLanguage"]) if plain.strip() else plain)
        text = "".join(parts)
        if not text.strip() or len(text) > 4000:
            raise ValueError("translation_structure_failed")
        output.append({**cue, "text": text})
        progress(folder, "Translating installed language pair", (index + 1) / len(job["cues"]))
    return {"cues": output, "wordTimings": [], "language": job["targetLanguage"],
            "durationMs": max(c["endMs"] for c in output), "warnings": ["Translation preserves cue identity, timing, markup and explicit line breaks; review meaning and terminology."]}


def ocr(folder, job):
    # Fixed-rate crops bound decode memory independently of the media resolution.
    # Keep one frame in memory and never create an unbounded image directory.
    x, y, w, h = job["crop"]
    filters = (f"crop=trunc(iw*{w}/2)*2:trunc(ih*{h}/2)*2:trunc(iw*{x}/2)*2:trunc(ih*{y}/2)*2,"
               "scale=960:240:force_original_aspect_ratio=decrease,pad=960:240:(ow-iw)/2:(oh-ih)/2,fps=2")
    command = [os.environ.get("PLEZY_FFMPEG", "ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
               "-protocol_whitelist", "file,pipe", "-format_whitelist", FORMATS, "-i", str(folder / "input.media"),
               "-an", "-sn", "-vf", filters, "-t", str(MAX_SECONDS + 0.5), "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    from bitmap_ocr import png
    evidence = folder / 'evidence'
    evidence.mkdir(mode=0o700, exist_ok=True)
    images, image_sizes, image_bytes = [], {}, 0
    cues, active, frame = [], None, 0
    language = os.environ.get("PLEZY_TESSERACT_LANGUAGE", "eng")
    def finish():
        nonlocal active, image_bytes
        if active is not None and active["endMs"] - active["startMs"] >= 1000:
            active["cueId"] = cue_id(job, len(cues), active["startMs"], active["endMs"], active["text"])
            active["index"] = len(cues) + 1
            encoded = png(960, 240, active.pop('_image'), 1)
            digest = hashlib.sha256(encoded).hexdigest()
            if digest not in image_sizes:
                image_bytes += len(encoded)
                if image_bytes > 32 * 1024**2: raise ValueError('ocr_image_evidence_limit')
                image_sizes[digest] = len(encoded)
                (evidence / f'{digest}.png').write_bytes(encoded)
            images.append({'cueId': active['cueId'], 'sha256': digest, 'bytes': len(encoded),
                'width': 960, 'height': 240, 'x': 0, 'y': 0, 'startMs': active['startMs'], 'endMs': active['endMs'],
                'confidence': active['ocrConfidence'], 'forced': job['task'] == 'signs',
                'requiresReview': active['ocrConfidence'] < .65})
            if job['task'] == 'signs':
                active['role'] = 'sign'
                active['region'] = job['crop']
            cues.append(active)
        active = None
    try:
        while True:
            data = bytearray()
            while len(data) < 960 * 240:
                block = process.stdout.read(960 * 240 - len(data))
                if not block:
                    break
                data.extend(block)
            if not data:
                break
            if len(data) != 960 * 240 or frame >= MAX_SECONDS * 2:
                raise ValueError("video_duration_or_frame_limit")
            result = subprocess.run(["tesseract", "stdin", "stdout", "-l", language, "--psm", "6", "tsv"],
                                    input=b"P5\n960 240\n255\n" + bytes(data), stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, timeout=60)
            if result.returncode or len(result.stdout) > 1024**2:
                raise ValueError("ocr_failed")
            lines = {}
            confidences = []
            for row in csv.DictReader(io.StringIO(result.stdout.decode("utf-8", errors="replace")), delimiter="\t"):
                text = row.get("text", "").strip()
                score = float(row.get("conf", "-1"))
                if text and score >= 50:
                    key = (row.get("block_num"), row.get("par_num"), row.get("line_num"))
                    lines.setdefault(key, []).append(text)
                    confidences.append(score / 100)
            text = "\n".join(" ".join(line) for line in lines.values())[:4000]
            start, end = frame * 500, (frame + 1) * 500
            if text and active is not None and difflib.SequenceMatcher(None, text.casefold(), active["text"].casefold(), autojunk=True).ratio() >= 0.92:
                active["endMs"] = end
            else:
                finish()
                if text:
                    active = {"startMs": start, "endMs": end, "text": text,
                              "ocrConfidence": sum(confidences) / len(confidences), "crop": job["crop"], '_image': bytes(data)}
            frame += 1
            progress(folder, "Reading caption crop (2 frames/second)", frame / (MAX_SECONDS * 2))
        finish()
        if process.wait(timeout=30):
            raise ValueError("video_decode_failed")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()
    return {"cues": cues, "images": images, "wordTimings": [], "language": job.get("language") or "unknown", "durationMs": frame * 500,
            "warnings": ["OCR samples a selected crop at 2 Hz; short captions, stylized text, and scene text can be missed or mistaken for dialogue.",
                         "Timing is quantized to 500 ms and confidence is an uncalibrated OCR score. A representative unmodified crop image is retained for every emitted cue.",
                         "Sign tracks retain their chosen normalized region in app-overlay review. SRT export flattens position; crop images are resized evidence, not full-resolution video frames."]}


def main():
    folder = Path(sys.argv[1]).resolve()
    job = read_json(folder / "job.json", MAX_RESULT)
    if job["task"] not in TEXT_TASKS:
        digest = hashlib.sha256()
        with (folder / "input.media").open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != job["audioDigest"]:
            raise ValueError("staged_media_digest_mismatch")
    if os.environ.get("PLEZY_ALLOW_MODEL_DOWNLOADS") != "1":
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
    requested = os.environ.get("PLEZY_INFERENCE_DEVICE", "cpu")
    if requested not in {"cpu", "cuda"}:
        raise ValueError("unsupported_inference_device")
    fallback = False
    device = requested
    task = job["task"]
    if task == "translate":
        result = translate(folder, job)
        device = "argos-runtime-unreported"
    elif task == "translate_model":
        result = translate_model(folder, job, progress, atomic_json, read_json)
        device = "configured-model-provider-unreported"
    elif task in {"script_convert", "reading"}:
        result = derivative(folder, job, progress)
        device = "host-text-cpu"
    elif task == "extract_text":
        from research import extract_text
        result = extract_text(folder, job, progress)
        device = "ffmpeg-subtitle-decoder-cpu"
    elif task in {"ocr", "signs"}:
        result = ocr(folder, job)
        device = "tesseract-cpu"
    elif task == "bitmap_ocr":
        from bitmap_ocr import run
        result = run(folder, job, progress)
        device = "ffmpeg-decode-and-tesseract-cpu"
    else:
        audio = decode_audio(folder, job)
        from research import AUDIO_TASKS, ensemble, separate, sound_events, completeness
        if task in AUDIO_TASKS:
            adapter = {"ensemble": ensemble, "separate": separate, "sound_events": sound_events, "completeness": completeness}[task]
            function = lambda folder, job, audio, device: adapter(folder, job, audio, device, progress, recognize)
        else:
            function = {"transcribe": recognize, "align": align, "diarize": diarize}[task]
        try:
            result = function(folder, job, audio, device)
        except Exception:
            if device != "cuda":
                raise
            fallback = True
            device = "cpu"
            result = function(folder, job, audio, device)
    if not result["cues"]:
        raise ValueError("no_caption_evidence")
    for index, cue in enumerate(result["cues"]):
        cue["index"] = index + 1
    if task in TEXT_TASKS:
        result["sourceCues"] = job["cues"]
    result.update({"schema": 1, "identity": job["identity"], "audioDigest": job["audioDigest"],
                   "jobId": job["id"], "task": task, "requestedDevice": requested, "runtimeDevice": device,
                   "cpuFallback": fallback, "placementEvidence": "unverified",
                   "model": result.get("model", os.environ.get("PLEZY_WHISPER_MODEL", "base") if task in {"transcribe", "diarize"} else "not-reported"),
                   "preprocessing": "80Hz-highpass-and-FFT-denoise" if job.get("preprocess") else "none"})
    atomic_json(folder / "result.json", result)
    progress(folder, "Complete; review before attachment", 1)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        code = str(error)
        if not re.fullmatch(r"[a-z_]{1,80}", code):
            code = "model_or_decoder_failed_check_host_installation"
        atomic_json(Path(sys.argv[1]) / "error.json", {"code": code})
        sys.exit(1)
