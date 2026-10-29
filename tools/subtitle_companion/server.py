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
        for folder in root.iterdir():
            if not folder.is_dir() or folder.is_symlink() or not JOB_ID.fullmatch(folder.name):
                continue
            try:
                job = read_json(folder / "job.json")
                if job["id"] != folder.name or not HEX.fullmatch(job["scope"]):
                    continue
                if job["state"] in {"queued", "running", "uploading"}:
                    job["state"] = "paused" if (folder / "input.media").is_file() else "awaiting_audio"
                self.jobs[job["id"]] = job
                self.save(job)
                (folder / "audio.part").unlink(missing_ok=True)
                (folder / "analysis.wav").unlink(missing_ok=True)
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
        if task not in {"transcribe", "align", "diarize", "translate", "ocr"}:
            raise ValueError("unsupported_task")
        for key in ("identity", "audioDigest", "requestId"):
            if not isinstance(value.get(key), str) or not HEX.fullmatch(value[key]):
                raise ValueError("invalid_identity")
        size = value.get("audioBytes", 0)
        if type(size) is not int or size < 0 or size > MAX_INPUT or (task != "translate" and size < 1):
            raise ValueError("input_limit")
        language = value.get("language")
        if language is not None and (not isinstance(language, str) or not re.fullmatch(r"[a-z]{2,3}", language)):
            raise ValueError("invalid_language")
        if task in {"align", "translate"} and not language:
            raise ValueError("language_required")
        target = value.get("targetLanguage")
        if task == "translate" and (not isinstance(target, str) or not re.fullmatch(r"[a-z]{2,3}", target) or target == language):
            raise ValueError("target_language_required")
        if task == "align" and value.get("spokenLanguage") != language:
            raise ValueError("alignment_requires_matching_spoken_language")
        cues = value.get("cues", [])
        if not isinstance(cues, list) or len(cues) > 50000 or (task in {"align", "translate"} and not cues):
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
        track = value.get("audioTrack", 0)
        if type(track) is not int or not 0 <= track <= 63:
            raise ValueError("invalid_audio_track")
        crop = value.get("crop", [0, 0.65, 1, 0.35])
        if not isinstance(crop, list) or len(crop) != 4 or any(type(n) not in (int, float) or not 0 <= n <= 1 for n in crop):
            raise ValueError("invalid_crop")
        x, y, w, h = crop
        if w < 0.05 or h < 0.05 or x + w > 1.001 or y + h > 1.001:
            raise ValueError("invalid_crop")
        with self.lock:
            canonical = {"task": task, "identity": value["identity"], "audioDigest": value["audioDigest"],
                         "audioBytes": size, "language": language, "targetLanguage": target,
                         "cues": cues, "audioTrack": track, "crop": crop,
                         "translateToEnglish": value.get("translateToEnglish") is True,
                         "preprocess": value.get("preprocess") is True}
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
                   "fingerprint": fingerprint, "created": time.time(), "state": "ready" if task == "translate" else "awaiting_audio"}
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

    def handle_api(self):
        store = self.server.store
        supplied = self.headers.get("Authorization", "")
        if self.headers.get("Origin") or not hmac.compare_digest(supplied, "Bearer " + store.token):
            self.reply(401, {"error": "unauthorized"})
            return
        scope = self.headers.get("X-Plezy-Scope", "")
        if not HEX.fullmatch(scope):
            raise ValueError("invalid_scope")
        route = urlsplit(self.path)
        if route.query or route.fragment:
            raise ValueError("unsupported_query")
        path = route.path
        if path == "/v1/capabilities" and self.command == "GET":
            installed = lambda module: importlib.util.find_spec(module) is not None
            tasks = []
            if installed("faster_whisper") and shutil.which(os.environ.get("PLEZY_FFMPEG", "ffmpeg")):
                tasks.append("transcribe")
                if installed("whisperx"):
                    tasks.extend(["align", "diarize"])
            if installed("argostranslate"):
                tasks.append("translate")
            if shutil.which("tesseract") and shutil.which(os.environ.get("PLEZY_FFMPEG", "ffmpeg")):
                tasks.append("ocr")
            self.reply(200, {"version": 1, "tasks": tasks, "qualified": False, "maxInputBytes": MAX_INPUT,
                             "maxDurationSeconds": 3600, "maxJobs": MAX_JOBS,
                             "modelDownloadsAllowed": os.environ.get("PLEZY_ALLOW_MODEL_DOWNLOADS") == "1",
                             "placementEvidence": "unverified", "mediaAccess": "explicit-file-upload-only"})
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
        with store.lock:
            job = store.jobs.get(identifier)
            if job is None or job["scope"] != scope:
                self.reply(404, {"error": "not_found"})
                return
            folder = store.root / identifier
            if action == "audio" and self.command == "PUT":
                if job["state"] not in {"awaiting_audio", "failed"} or identifier in store.processes:
                    raise ValueError("audio_already_staged")
                if self.length() != job["audioBytes"]:
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
                    if job["task"] != "translate" and not (folder / "input.media").is_file():
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
                self.reply(200, read_json(folder / "result.json", MAX_RESULT))
                return
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

    def length(self):
        if self.headers.get("Transfer-Encoding"):
            raise ValueError("content_length_required")
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 <= length <= MAX_INPUT:
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
