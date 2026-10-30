#!/usr/bin/env python3
"""Authenticated, bounded subtitle jobs. No source URLs or server credentials.

One worker subprocess owns inference; cancellation terminates that process.
Clients upload a specific file and retain ownership through scope + job digests.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import signal
import shutil
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from text_adapters import TEXT_TASKS, SCRIPT_MODES, MODES, capabilities as translation_capabilities, provider_config

from research import MEDIA_TASKS
from lyric_research import validate_syllables
from microphone_array import MAX_INPUT_BYTES as MAX_ARRAY_INPUT, validate as validate_microphone_array
from vocal_notes import MAX_INPUT_BYTES as MAX_VOCAL_INPUT, validate as validate_vocal_notes
from dubbing import voice_config, capabilities as synthesis_capabilities
from visual_research import vision_capabilities
from scene_objects import capabilities as scene_object_capabilities
from caption_channels import CaptionChannels, RelayError
from caption_reconstruction import validate as validate_reconstruction

MAX_INPUT = 1024**3
MAX_JSON = 5 * 1024**2
MAX_RESULT = 24 * 1024**2
MAX_JOBS = 12
MAX_TOTAL = 2 * 1024**3
HEX = re.compile(r"^[0-9a-f]{64}$")
JOB_ID = re.compile(r"^[0-9a-f]{32}$")


def atomic_json(path: Path, value: dict):
    data = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()
    if len(data) > MAX_RESULT:
        raise ValueError("result_limit")
    temp = path.with_suffix(path.suffix + ".tmp")
    with temp.open("wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def read_json(path: Path, bound=MAX_JSON):
    with path.open("rb") as stream:
        data = stream.read(bound + 1)
    if len(data) > bound:
        raise ValueError("record_limit")
    return json.loads(data)


class Store:
    def __init__(self, root: Path, token: str):
        self.root, self.token = root, token
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = threading.RLock()
        self.jobs: dict[str, dict] = {}
        self.processes: dict[str, subprocess.Popen] = {}
        self.uploads: set[str] = set()
        self.wake = threading.Event()
        self.closing = threading.Event()
        self.caption_channels = CaptionChannels(self.closing)
        for folder in root.iterdir():
            if not folder.is_dir() or folder.is_symlink() or not JOB_ID.fullmatch(folder.name):
                continue
            try:
                job = read_json(folder / "job.json", MAX_RESULT)
                if job["id"] != folder.name or not HEX.fullmatch(job["scope"]):
                    continue
                if job["state"] in {"queued", "running", "uploading"}:
                    job["state"] = "paused" if job.get("task") in TEXT_TASKS or (folder / "input.media").is_file() else "awaiting_audio"
                self.jobs[job["id"]] = job
                self.save(job)
                (folder / "audio.part").unlink(missing_ok=True)
                (folder / "analysis.wav").unlink(missing_ok=True)
                (folder / "ocr_input.png").unlink(missing_ok=True)
                (folder / 'reconstruction-video.part.mp4').unlink(missing_ok=True)
                (folder / 'reconstruction-preview.mp4').unlink(missing_ok=True)
                if job["state"] != "completed":
                    (folder / 'caption-reconstruction.zip').unlink(missing_ok=True)
                shutil.rmtree(folder / "bitmap_input", ignore_errors=True)
            except (ValueError, KeyError, OSError, TypeError):
                # Do not turn malformed records into jobs or execute their paths.
                continue
        self.thread = threading.Thread(target=self.run, name="subtitle-worker", daemon=True)
        self.thread.start()

    def save(self, job):
        atomic_json(self.root / job["id"] / "job.json", job)

    def public(self, job):
        result = {key: job[key] for key in ("id", "state", "identity", "task", "created", "audioDigest")}
        result["error"] = job.get("error")
        result["progress"] = 1.0 if job["state"] == "completed" else 0.0
        progress = self.root / job["id"] / "progress.json"
        if progress.is_file():
            try:
                p = read_json(progress, 4096)
                result["progress"] = max(0.0, min(1.0, float(p.get("fraction", 0))))
                result["phase"] = str(p.get("phase", "processing"))[:80]
            except (OSError, ValueError, TypeError):
                pass
        return result

    def create(self, scope, value):
        task = value.get("task")
        if task not in {"transcribe", "align", "diarize", "ocr", "bitmap_ocr"} | TEXT_TASKS | MEDIA_TASKS:
            raise ValueError("unsupported_task")
        for key in ("identity", "audioDigest", "requestId"):
            if not isinstance(value.get(key), str) or not HEX.fullmatch(value[key]):
                raise ValueError("invalid_identity")
        size = value.get("audioBytes", 0)
        input_limit = MAX_ARRAY_INPUT if task == 'sound_localize' else MAX_VOCAL_INPUT if task == 'vocal_notes' else MAX_INPUT
        if type(size) is not int or size < 0 or size > input_limit or (task not in TEXT_TASKS and size < 1) or (task in TEXT_TASKS and size != 0):
            raise ValueError("input_limit")
        language = value.get("language")
        if language is not None and (not isinstance(language, str) or not re.fullmatch(r"[a-z]{2,3}", language)):
            raise ValueError("invalid_language")
        if task in {"align", "singing_align", "dub_mix"} | TEXT_TASKS and not language:
            raise ValueError("language_required")
        target = value.get("targetLanguage")
        if task in {"translate", "translate_model"} and (not isinstance(target, str) or not re.fullmatch(r"[a-z]{2,3}", target) or target == language):
            raise ValueError("target_language_required")
        if task in {"align", "singing_align"} and value.get("spokenLanguage") != language:
            raise ValueError("alignment_requires_matching_spoken_language")
        cues = value.get("cues", [])
        if not isinstance(cues, list) or len(cues) > 50000 or (task in {"align", "singing_align", "completeness", "dub_mix", "scene_review", "scene_track", "sound_localize", "vocal_notes", "caption_reconstruct"} | TEXT_TASKS and not cues):
            raise ValueError("cue_limit")
        ids = set()
        for cue in cues:
            if not isinstance(cue, dict) or not isinstance(cue.get("text"), str) or not 0 < len(cue["text"]) <= 4000:
                raise ValueError("invalid_cue")
            if not isinstance(cue.get("cueId"), str) or not HEX.fullmatch(cue["cueId"]) or cue["cueId"] in ids:
                raise ValueError("invalid_cue_identity")
            ids.add(cue["cueId"])
            start, end = cue.get("startMs"), cue.get("endMs")
            if type(start) is not int or type(end) is not int or not 0 <= start < end <= 8 * 3600000:
                raise ValueError("invalid_cue_time")
        duck_ratio = value.get("duckRatio", .25)
        if type(duck_ratio) not in (int, float) or not 0 <= duck_ratio <= 1:
            raise ValueError("invalid_duck_ratio")
        voice_fingerprint = None
        if task in {"dubbing", "dub_mix"}:
            voice_fingerprint = synthesis_capabilities()["fingerprint"]
            if value.get("voiceFingerprint") != voice_fingerprint:
                raise ValueError("voice_changed_resubmit_after_review")
            if len(cues) > 500 or max(c["endMs"] for c in cues) > 600000:
                raise ValueError("dubbing_limit_ten_minutes_five_hundred_cues")
        stereo_evidence = value.get("soundStereoEvidence", False)
        if task == 'singing_align' and (len(cues) > 120 or max(c['endMs'] for c in cues) > 300000 or
                any(c['endMs']-c['startMs'] > 30000 for c in cues)):
            raise ValueError('lyric_alignment_limit_five_minutes_120_cues_30_seconds_per_cue')
        lyric_syllables = validate_syllables(value.get('lyricSyllables', {}), cues)
        lyric_pitch = value.get('lyricPitchEvidence', False)
        if type(lyric_pitch) is not bool or (lyric_syllables or lyric_pitch) and task != 'singing_align':
            raise ValueError('lyric_evidence_requires_singing_alignment')
        if lyric_pitch and (importlib.util.find_spec('librosa') is None or
                any(c['endMs']-c['startMs'] > 12000 for c in cues) or
                sum(c['endMs']-c['startMs'] for c in cues) > 120000):
            raise ValueError('lyric_pitch_capability_or_duration_limit')
        if type(stereo_evidence) is not bool or stereo_evidence and task != "sound_events":
            raise ValueError("invalid_sound_stereo_evidence")
        timeline_offset = value.get("timelineOffsetMs", 0)
        if type(timeline_offset) is not int or not 0 <= timeline_offset <= 7 * 3600000:
            raise ValueError("invalid_source_time_offset")
        item_timeline = value.get("itemTimeline", timeline_offset != 0)
        if type(item_timeline) is not bool or timeline_offset and not item_timeline:
            raise ValueError("invalid_source_clock")
        if item_timeline and task not in {"transcribe", "diarize", "ensemble", "separate", "sound_events", "extract_text", "ocr", "ocr_auto", "signs", "bitmap_ocr"}:
            raise ValueError("source_time_offset_requires_generation_task")
        track = value.get("audioTrack", 0)
        if type(track) is not int or not 0 <= track <= 63:
            raise ValueError("invalid_audio_track")
        microphone_array = None
        if task == 'sound_localize':
            if track != 0 or value.get('preprocess', False) is not False or importlib.util.find_spec('numpy') is None:
                raise ValueError('array_requires_unprocessed_channels_and_numpy')
            microphone_array = validate_microphone_array(value.get('microphoneArray'), cues)
        elif value.get('microphoneArray') is not None:
            raise ValueError('microphone_calibration_requires_array_task')
        isolated_vocal = value.get('isolatedLeadVocal', False)
        if type(isolated_vocal) is not bool or isolated_vocal and task != 'vocal_notes':
            raise ValueError('isolated_vocal_declaration_requires_note_task')
        if task == 'vocal_notes':
            if importlib.util.find_spec('librosa') is None: raise ValueError('vocal_note_runtime_unavailable')
            validate_vocal_notes(value)
        subtitle_track = value.get("subtitleTrack", 0)
        if type(subtitle_track) is not int or not 0 <= subtitle_track <= 63:
            raise ValueError("invalid_subtitle_track")
        bitmap_tail = value.get("finalBitmapDurationMs", 2000)
        if type(bitmap_tail) is not int or not 100 <= bitmap_tail <= 30000:
            raise ValueError("invalid_final_bitmap_duration")
        reconstruction_consent = value.get('reconstructionConsent', False)
        if type(reconstruction_consent) is not bool or reconstruction_consent and task != 'caption_reconstruct':
            raise ValueError('invalid_reconstruction_consent')
        if task == 'caption_reconstruct':
            if (importlib.util.find_spec('cv2') is None or
                    not shutil.which(os.environ.get('PLEZY_FFMPEG', 'ffmpeg')) or
                    not shutil.which(os.environ.get('PLEZY_FFPROBE', 'ffprobe'))):
                raise ValueError('reconstruction_runtime_unavailable')
            validate_reconstruction(value)
        mode = value.get("translationMode", "faithful")
        conversion = value.get("scriptConversion", "s2t")
        reading = value.get("readingMode", "hiragana")
        if not isinstance(mode, str) or mode not in MODES or not isinstance(conversion, str) or conversion not in SCRIPT_MODES or not isinstance(reading, str) or reading not in {"hiragana", "hepburn", "ruby"}:
            raise ValueError("invalid_text_derivative_mode")
        if task == "script_convert" and language != "zh" or task == "reading" and language != "ja":
            raise ValueError("text_derivative_language_mismatch")
        glossary = value.get("glossary", {})
        if not isinstance(glossary, dict) or len(glossary) > 200:
            raise ValueError("invalid_glossary")
        folded = set()
        for key, term in glossary.items():
            if (not isinstance(key, str) or not isinstance(term, str) or not 0 < len(key.strip()) <= 128 or not 0 < len(term.strip()) <= 128 or
                    any(c in key + term for c in "\r\n<>\0") or key.casefold() in folded):
                raise ValueError("invalid_glossary_term")
            folded.add(key.casefold())
        provider_fingerprint = None
        if task == "translate_model":
            config = provider_config()
            provider_fingerprint = config["fingerprint"]
            if value.get("translationProviderFingerprint") != provider_fingerprint:
                raise ValueError("translation_provider_changed_resubmit_after_review")
        temporal_regions = value.get("sceneTemporalRegions", False)
        if type(temporal_regions) is not bool or temporal_regions and task != "scene_review":
            raise ValueError("invalid_scene_temporal_regions")
        audio_evidence = value.get("sceneAudioEvidence", False)
        if type(audio_evidence) is not bool or audio_evidence and task != "scene_review":
            raise ValueError("invalid_scene_audio_evidence")
        sign_motion = value.get('signMotionTracking', False)
        if type(sign_motion) is not bool or sign_motion and (task != 'signs' or importlib.util.find_spec('cv2') is None):
            raise ValueError('invalid_sign_motion_tracking')
        motion_tracking = value.get("sceneMotionTracking", False)
        if type(motion_tracking) is not bool or motion_tracking and task != "scene_review":
            raise ValueError("invalid_scene_motion_tracking")
        if motion_tracking and (importlib.util.find_spec("cv2") is None or any(c['endMs']-c['startMs'] > 12000 for c in cues) or
                sum(c['endMs']-c['startMs'] for c in cues) > 120000):
            raise ValueError("scene_motion_capability_or_duration_limit")
        object_tracking = value.get('sceneObjectTracking', False)
        object_fingerprint = None
        if type(object_tracking) is not bool or object_tracking and task != 'scene_review':
            raise ValueError('invalid_scene_object_tracking')
        if object_tracking or task == 'scene_track':
            detector = scene_object_capabilities()
            if detector is None or value.get('sceneDetectorFingerprint') != detector['fingerprint']:
                raise ValueError('scene_detector_changed_resubmit_after_review')
            if object_tracking and (any(c['endMs']-c['startMs'] > 12000 for c in cues) or sum(c['endMs']-c['startMs'] for c in cues) > 120000):
                raise ValueError('scene_object_duration_limit')
            object_fingerprint = detector['fingerprint']
        if task == 'scene_track' and (len(cues) > 5000 or not shutil.which(os.environ.get('PLEZY_FFPROBE', 'ffprobe'))):
            raise ValueError('scene_title_cue_limit_or_probe_unavailable')
        vision_fingerprint = None
        if task == "scene_review":
            config = vision_capabilities()
            if config is None or value.get("visionProviderFingerprint") != config["fingerprint"]:
                raise ValueError("vision_provider_changed_resubmit_after_review")
            vision_fingerprint = config["fingerprint"]
            if audio_evidence and (not config['audioEvidence'] or any(c['endMs']-c['startMs'] > 12000 for c in cues) or
                    sum(c['endMs']-c['startMs'] for c in cues) > 120000):
                raise ValueError('scene_audio_capability_or_duration_limit')
            if len(cues) > 30 or max(c["endMs"] for c in cues) > 3600000:
                raise ValueError("visual_review_limit_thirty_cues_one_hour")
        crop = value.get("crop", [0, 0.65, 1, 0.35])
        if not isinstance(crop, list) or len(crop) != 4 or any(type(n) not in (int, float) or not 0 <= n <= 1 for n in crop):
            raise ValueError("invalid_crop")
        x, y, w, h = crop
        if w < 0.05 or h < 0.05 or x + w > 1.001 or y + h > 1.001:
            raise ValueError("invalid_crop")
        with self.lock:
            canonical = {"task": task, "identity": value["identity"], "audioDigest": value["audioDigest"],
                         "audioBytes": size, "language": language, "targetLanguage": target,
                         "cues": cues, "audioTrack": track, "timelineOffsetMs": timeline_offset, "itemTimeline": item_timeline, "soundStereoEvidence": stereo_evidence, "crop": crop, "duckRatio": duck_ratio, "voiceFingerprint": voice_fingerprint,
                         "subtitleTrack": subtitle_track, "finalBitmapDurationMs": bitmap_tail,
                         "lyricSyllables": lyric_syllables, "lyricPitchEvidence": lyric_pitch,
                         "microphoneArray": microphone_array,
                         "isolatedLeadVocal": isolated_vocal, "reconstructionConsent": reconstruction_consent,
                         "sceneObjectTracking": object_tracking, "sceneDetectorFingerprint": object_fingerprint,
                         "translationMode": mode, "scriptConversion": conversion, "readingMode": reading,
                         "glossary": glossary, "translationProviderFingerprint": provider_fingerprint, "visionProviderFingerprint": vision_fingerprint, "sceneTemporalRegions": temporal_regions, "sceneAudioEvidence": audio_evidence, "sceneMotionTracking": motion_tracking, "signMotionTracking": sign_motion,
                         "translateToEnglish": task == "transcribe" and value.get("translateToEnglish") is True,
                         "preprocess": task in {"transcribe", "align", "diarize"} and value.get("preprocess") is True}
            fingerprint = hashlib.sha256(json.dumps(canonical, sort_keys=True).encode()).hexdigest()
            for old in self.jobs.values():
                if old["scope"] == scope and old["requestId"] == value["requestId"]:
                    if old["fingerprint"] != fingerprint:
                        raise ValueError("idempotency_conflict")
                    return old
            if len(self.jobs) >= MAX_JOBS or sum(j["audioBytes"] for j in self.jobs.values()) + size > MAX_TOTAL:
                raise ValueError("queue_full_delete_old_jobs")
            identifier = secrets.token_hex(16)
            folder = self.root / identifier
            folder.mkdir(mode=0o700)
            job = {**canonical, "id": identifier, "scope": scope, "requestId": value["requestId"],
                   "fingerprint": fingerprint, "created": time.time(), "state": "ready" if task in TEXT_TASKS else "awaiting_audio"}
            self.save(job)
            self.jobs[identifier] = job
            return job

    def run(self):
        while not self.closing.is_set():
            self.wake.wait(1)
            self.wake.clear()
            with self.lock:
                job = next((j for j in self.jobs.values() if j["state"] == "queued"), None)
                if job is None:
                    continue
                job["state"] = "running"
                job.pop("error", None)
                self.save(job)
                folder = self.root / job["id"]
                try:
                    process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("worker.py")), str(folder)],
                                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                               start_new_session=os.name != "nt")
                except OSError:
                    job["state"], job["error"] = "failed", "worker_start_failed"
                    self.save(job)
                    continue
                self.processes[job["id"]] = process
            try:
                code = process.wait(timeout=4 * 3600)
            except subprocess.TimeoutExpired:
                self.kill_tree(process, force=True)
                process.wait()
                code = -1
            with self.lock:
                self.processes.pop(job["id"], None)
                if job["state"] == "running":
                    job["state"] = "completed" if code == 0 and (folder / "result.json").is_file() else "failed"
                    if job["state"] == "failed":
                        try:
                            job["error"] = read_json(folder / "error.json", 4096)["code"]
                        except (OSError, KeyError, ValueError):
                            job["error"] = "worker_failed"
                    self.save(job)
                (folder / "analysis.wav").unlink(missing_ok=True)
                (folder / "ocr_input.png").unlink(missing_ok=True)
                (folder / 'reconstruction-video.part.mp4').unlink(missing_ok=True)
                (folder / 'reconstruction-preview.mp4').unlink(missing_ok=True)
                if job["state"] != "completed":
                    (folder / 'caption-reconstruction.zip').unlink(missing_ok=True)
                shutil.rmtree(folder / "bitmap_input", ignore_errors=True)
            self.wake.set()

    def interrupt(self, job, state):
        # Caller holds the store lock; terminate only this job's process.
        job["state"] = state
        self.save(job)
        process = self.processes.get(job["id"])
        if process is not None:
            self.kill_tree(process, force=False)
            def kill_later():
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: self.kill_tree(process, force=True)
            threading.Thread(target=kill_later, daemon=True).start()

    @staticmethod
    def kill_tree(process, force):
        if process.poll() is not None:
            return
        try:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            else:
                os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
        except (OSError, subprocess.TimeoutExpired):
            if force:
                process.kill()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, store):
        self.store = store
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(address, Handler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try: super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try: super().process_request_thread(request, client_address)
        finally: self.slots.release()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass  # No URL, credential, media name, transcript, or model stdout logs.

    def setup(self):
        super().setup()
        self.connection.settimeout(120)

    def reply(self, status, value):
        data = json.dumps(value, ensure_ascii=False, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def reply_image(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def handle_api(self):
        store = self.server.store
        supplied = self.headers.get("Authorization", "")
        route = urlsplit(self.path)
        if route.query or route.fragment:
            raise ValueError("unsupported_query")
        path = route.path
        relay = re.fullmatch(r"/v1/caption-relay/([0-9a-f]{32})/(list/([0-9a-f]{24})|objects(?:/(plezyng-state-v1-[a-f0-9]{24}-[a-f0-9]{32}-[0-9]{16}\.json))?)", path)
        if relay is not None:
            if self.headers.get("Origin"):
                self.reply(401, {"error": "unauthorized"}); return
            identifier, _, namespace, name = relay.groups()
            # Reject invalid/expired capability before reading a request body.
            store.caption_channels.authorized(identifier, supplied)
            if self.command == 'PUT' and namespace is None and name is None:
                value = self.body_json()
                result = store.caption_channels.request(identifier, supplied, 'PUT', name=value.get('name'), text=value.get('text'))
            elif (self.command == 'GET' and namespace is not None) or (self.command in {'GET', 'DELETE'} and name is not None):
                result = store.caption_channels.request(identifier, supplied, self.command, namespace=namespace, name=name)
            else:
                raise ValueError('unsupported_caption_relay_method')
            self.reply(200, result); return
        if self.headers.get("Origin") or not hmac.compare_digest(supplied, "Bearer " + store.token):
            self.reply(401, {"error": "unauthorized"})
            return
        scope = self.headers.get("X-Plezy-Scope", "")
        if not HEX.fullmatch(scope):
            raise ValueError("invalid_scope")
        if path == '/v1/caption-channels' and self.command == 'POST':
            if self.body_json() != {'version': 1}:
                raise ValueError('unsupported_caption_channel_version')
            self.reply(201, store.caption_channels.create(scope)); return
        channel = re.fullmatch(r'/v1/caption-channels/([0-9a-f]{32})', path)
        if channel is not None and self.command == 'DELETE':
            store.caption_channels.revoke(channel.group(1), scope)
            self.reply(200, {'deleted': True}); return
        if path == "/v1/capabilities" and self.command == "GET":
            installed = lambda module: importlib.util.find_spec(module) is not None
            tasks = []
            if installed('numpy'): tasks.append('sound_localize')
            if installed('numpy') and installed('librosa'): tasks.append('vocal_notes')
            if installed("faster_whisper") and shutil.which(os.environ.get("PLEZY_FFMPEG", "ffmpeg")):
                tasks.extend(["transcribe", "completeness"])
                if os.environ.get("PLEZY_SECOND_WHISPER_MODEL"):
                    tasks.append("ensemble")
                if installed("speechbrain") and os.environ.get("PLEZY_SEPARATOR_MODEL"):
                    tasks.append("separate")
                if installed("transformers") and os.environ.get("PLEZY_SOUND_MODEL"):
                    tasks.append("sound_events")
                if installed("whisperx"):
                    tasks.extend(["align", "diarize"])
                    if os.environ.get('PLEZY_SINGING_ALIGN_MODEL'):
                        tasks.append('singing_align')
            synthesis = None
            if installed("piper") and shutil.which(os.environ.get("PLEZY_FFMPEG", "ffmpeg")):
                try:
                    synthesis = synthesis_capabilities()
                    tasks.extend(["dubbing", "dub_mix"])
                except (ValueError, OSError):
                    pass
            if installed("argostranslate"):
                tasks.append("translate")
            translation = translation_capabilities()
            if translation is not None:
                tasks.append("translate_model")
            if installed("opencc"):
                tasks.append("script_convert")
            if installed("pykakasi"):
                tasks.append("reading")
            if shutil.which("tesseract") and shutil.which(os.environ.get("PLEZY_FFMPEG", "ffmpeg")):
                tasks.extend(["ocr", "ocr_auto", "signs"])
            if shutil.which("tesseract") and shutil.which(os.environ.get("PLEZY_SUBTITLE_DECODER", "plezy-subtitle-decode")):
                tasks.append("bitmap_ocr")
            vision = vision_capabilities()
            scene_detector = scene_object_capabilities()
            if shutil.which(os.environ.get("PLEZY_FFMPEG", "ffmpeg")):
                tasks.append("extract_text")
                if installed('cv2') and shutil.which(os.environ.get('PLEZY_FFPROBE', 'ffprobe')):
                    tasks.append('caption_reconstruct')
                if vision is not None: tasks.append("scene_review")
                if scene_detector is not None and shutil.which(os.environ.get('PLEZY_FFPROBE', 'ffprobe')):
                    tasks.append('scene_track')
            self.reply(200, {"version": 1, "tasks": tasks, "qualified": False, "maxInputBytes": MAX_INPUT,
                             "maxMicrophoneArrayBytes": MAX_ARRAY_INPUT, "captionRelay": 1,
                             "maxDurationSeconds": 3600, "maxJobs": MAX_JOBS, "sourceTimelineOffsets": True, "soundStereoEvidence": True, "sceneTemporalRegions": True,
                             "sceneMotionTracking": vision is not None and installed("cv2"),
                             "signMotionTracking": 'signs' in tasks and installed('cv2'),
                             "sceneObjectTracking": scene_detector is not None, "sceneObjectDetector": scene_detector,
                             "sceneTitleTracking": 'scene_track' in tasks,
                             "sceneTitleMaximumDurationSeconds": 8 * 3600,
                             "sceneTitleMaximumCues": 5000,
                             "lyricSyllables": 'singing_align' in tasks,
                             "lyricPitchEvidence": 'singing_align' in tasks and installed('librosa'),
                             "microphoneArrayLocalization": 'sound_localize' in tasks,
                             "isolatedVocalNoteProposals": 'vocal_notes' in tasks,
                             "modelDownloadsAllowed": os.environ.get("PLEZY_ALLOW_MODEL_DOWNLOADS") == "1",
                             "visionProvider": vision, "sceneAudioEvidence": vision is not None and vision['audioEvidence'], "synthesisVoice": synthesis, "translationProvider": translation, "scriptConversions": list(SCRIPT_MODES), "readingModes": ["hiragana", "hepburn", "ruby"],
                             "placementEvidence": "unverified", "mediaAccess": "explicit-file-upload-only"})
            return
        artifact_match = re.fullmatch(r"/v1/jobs/([0-9a-f]{32})/artifacts/([0-9a-f]{64})", path)
        if artifact_match is not None and self.command == "GET":
            identifier, digest = artifact_match.groups()
            with store.lock:
                job = store.jobs.get(identifier)
                if job is None or job["scope"] != scope or job["state"] != "completed":
                    self.reply(404, {"error": "not_found"}); return
                folder = store.root / identifier
                result = read_json(folder / "result.json", MAX_RESULT)
                kinds = {'dubbed.wav': 'audio/wav', 'scene-tracks.jsonl': 'application/x-ndjson', 'caption-reconstruction.zip': 'application/zip'}
                artifact = next((a for a in result.get("artifacts", []) if a.get("sha256") == digest and
                    a.get("name") in kinds and a.get('mime') == kinds[a['name']]), None)
                if artifact is None or not 0 < artifact.get("bytes", 0) <= 32 * 1024**2:
                    self.reply(404, {"error": "not_found"}); return
                target = folder / artifact['name']
                if target.is_symlink(): raise ValueError("invalid_result_artifact")
                with target.open("rb") as stream: data = stream.read(32 * 1024**2 + 1)
                if len(data) != artifact["bytes"] or hashlib.sha256(data).hexdigest() != digest:
                    raise ValueError("invalid_result_artifact")
            self.send_response(200)
            self.send_header("Content-Type", artifact['mime'])
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers(); self.wfile.write(data); self.close_connection = True
            return
        image_match = re.fullmatch(r"/v1/jobs/([0-9a-f]{32})/evidence/([0-9a-f]{64})", path)
        if image_match is not None and self.command == "GET":
            identifier, digest = image_match.groups()
            with store.lock:
                job = store.jobs.get(identifier)
                if job is None or job["scope"] != scope or job["state"] != "completed":
                    self.reply(404, {"error": "not_found"})
                    return
                folder = store.root / identifier
                result = read_json(folder / "result.json", MAX_RESULT)
                if not any(image.get("sha256") == digest for image in result.get("images", [])):
                    self.reply(404, {"error": "not_found"})
                    return
                image_path = folder / "evidence" / f"{digest}.png"
                if image_path.is_symlink():
                    raise ValueError("invalid_image_evidence")
                with image_path.open("rb") as stream:
                    data = stream.read(4 * 1024**2 + 1)
                if len(data) > 4 * 1024**2 or hashlib.sha256(data).hexdigest() != digest:
                    raise ValueError("invalid_image_evidence")
            self.reply_image(data)
            return
        if path == "/v1/jobs":
            if self.command == "POST":
                value = self.body_json()
                job = store.create(scope, value)
                self.reply(201, store.public(job))
            elif self.command == "GET":
                with store.lock:
                    self.reply(200, {"jobs": [store.public(j) for j in store.jobs.values() if j["scope"] == scope]})
            else:
                self.reply(405, {"error": "method_not_allowed"})
            return
        match = re.fullmatch(r"/v1/jobs/([0-9a-f]{32})(?:/(audio|start|pause|cancel|result))?", path)
        if not match:
            self.reply(404, {"error": "not_found"})
            return
        identifier, action = match.groups()
        completed_result = None
        with store.lock:
            job = store.jobs.get(identifier)
            if job is None or job["scope"] != scope:
                self.reply(404, {"error": "not_found"})
                return
            folder = store.root / identifier
            if action == "audio" and self.command == "PUT":
                if job["state"] not in {"awaiting_audio", "failed"} or identifier in store.processes:
                    raise ValueError("audio_already_staged")
                input_limit = MAX_ARRAY_INPUT if job["task"] == 'sound_localize' else MAX_VOCAL_INPUT if job["task"] == 'vocal_notes' else MAX_INPUT
                if self.length(input_limit) != job["audioBytes"]:
                    raise ValueError("audio_length_mismatch")
                job["state"] = "uploading"
                store.save(job)
                store.uploads.add(identifier)
            elif action in {"start", "pause", "cancel"} and self.command == "POST":
                if action == "start":
                    if identifier in store.processes:
                        raise ValueError("worker_stopping_retry")
                    if job["state"] not in {"ready", "paused", "failed"}:
                        raise ValueError("job_not_resumable")
                    if job["task"] not in TEXT_TASKS and not (folder / "input.media").is_file():
                        raise ValueError("audio_required")
                    job["state"] = "queued"
                    store.save(job)
                    store.wake.set()
                else:
                    store.interrupt(job, "paused" if action == "pause" else "cancelled")
                self.reply(200, store.public(job))
                return
            elif action == "result" and self.command == "GET":
                if job["state"] != "completed":
                    raise ValueError("result_not_ready")
                completed_result = read_json(folder / "result.json", MAX_RESULT)
            elif action is None and self.command == "GET":
                self.reply(200, store.public(job))
                return
            elif action is None and self.command == "DELETE":
                if identifier in store.processes or identifier in store.uploads:
                    raise ValueError("cancel_and_wait_before_delete")
                shutil.rmtree(folder)
                del store.jobs[identifier]
                self.reply(200, {"deleted": True})
                return
            else:
                self.reply(405, {"error": "method_not_allowed"})
                return
        if completed_result is not None:
            # A slow result download must not hold the queue lock and delay
            # another client's cancellation request.
            self.reply(200, completed_result)
            return
        # A slow upload must not hold the queue lock or block cancellation.
        temporary = folder / "audio.part"
        try:
            digest, remaining = hashlib.sha256(), job["audioBytes"]
            with temporary.open("wb") as stream:
                while remaining:
                    if job["state"] != "uploading":
                        raise ValueError("upload_cancelled")
                    block = self.rfile.read(min(65536, remaining))
                    if not block:
                        raise ValueError("incomplete_upload")
                    stream.write(block)
                    digest.update(block)
                    remaining -= len(block)
                stream.flush()
                os.fsync(stream.fileno())
            if digest.hexdigest() != job["audioDigest"]:
                raise ValueError("audio_digest_mismatch")
            with store.lock:
                if job["state"] != "uploading":
                    raise ValueError("upload_cancelled")
                os.replace(temporary, folder / "input.media")
                job["state"] = "ready"
                store.save(job)
                self.reply(200, store.public(job))
        except BaseException:
            with store.lock:
                if job["state"] == "uploading":
                    job["state"] = "awaiting_audio"
                    store.save(job)
            raise
        finally:
            temporary.unlink(missing_ok=True)
            with store.lock:
                store.uploads.discard(identifier)

    def length(self, maximum=MAX_INPUT):
        if self.headers.get("Transfer-Encoding"):
            raise ValueError("content_length_required")
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 <= length <= maximum:
            raise ValueError("input_limit")
        return length

    def body_json(self):
        size = self.length()
        if not 0 < size <= MAX_JSON:
            raise ValueError("json_limit")
        data = self.rfile.read(size)
        if len(data) != size:
            raise ValueError("incomplete_request")
        value = json.loads(data)
        if not isinstance(value, dict):
            raise ValueError("json_object_required")
        return value

    def dispatch(self):
        try:
            self.handle_api()
        except RelayError as error:
            self.reply(error.status, {'error': error.code})
        except (ValueError, KeyError, TypeError) as error:
            code = str(error)
            self.reply(400, {"error": code if re.fullmatch(r"[a-z_]{1,80}", code) else "invalid_request"})
        except (OSError, TimeoutError):
            try: self.reply(503, {"error": "io_failure"})
            except OSError: pass

    do_GET = do_POST = do_PUT = do_DELETE = dispatch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--data", type=Path, default=Path.home() / ".plezy-subtitle-companion")
    parser.add_argument("--cert")
    parser.add_argument("--key")
    args = parser.parse_args()
    token = os.environ.get("PLEZY_SUBTITLE_TOKEN", "")
    if not 32 <= len(token) <= 256 or not token.isascii() or any(c.isspace() for c in token):
        parser.error("Set PLEZY_SUBTITLE_TOKEN to a random 32–256 character ASCII token.")
    if args.host not in {"127.0.0.1", "::1", "localhost"} and not (args.cert and args.key):
        parser.error("Non-loopback listeners require --cert and --key.")
    store = Store(args.data.resolve(), token)
    server = Server((args.host, args.port), store)
    if args.cert and args.key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        store.closing.set()
        with store.lock:
            for job in list(store.jobs.values()):
                if job["state"] in {"running", "queued"}:
                    store.interrupt(job, "paused")
        server.server_close()


if __name__ == "__main__":
    main()
