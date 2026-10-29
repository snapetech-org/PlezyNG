#!/usr/bin/env python3
"""Opt-in, token-authenticated karaoke companion. Python 3.11+, stdlib server.

Start explicitly with a token file. Non-loopback listeners require TLS. No URL
fetching, arbitrary executable arguments, model downloads or public publishing.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

VERSION = "plezy-karaoke-worker-1"
MAX_ASSET = 512 * 1024 * 1024
MAX_WORK = 20 * 1024 * 1024 * 1024
IDENTITY = re.compile(r"^[a-f0-9]{64}$")
JOB_ID = re.compile(r"^[a-zA-Z0-9_-]{8,128}$")
KINDS = {"waveform", "separate", "align", "analyze", "reference", "render", "midi"}


def atomic_json(path, data):
    temp = path.with_suffix(".pending")
    with temp.open("w", encoding="utf-8") as stream:
        json.dump(data, stream, ensure_ascii=False, allow_nan=False)
        stream.flush(); os.fsync(stream.fileno())
    temp.replace(path)


class Jobs:
    def __init__(self, root, models, model_revision, soundfont, timeout):
        self.root, self.models, self.model_revision, self.soundfont, self.timeout = root, models, model_revision, soundfont, timeout
        self.assets = root / "assets"; self.assets.mkdir(parents=True, exist_ok=True)
        self.jobs = root / "jobs"; self.jobs.mkdir(exist_ok=True)
        self.lock = threading.RLock(); self.states = {}; self.processes = {}; self.canceled = set()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="karaoke-prep")
        for file in self.jobs.glob("*/state.json"):
            try:
                state = json.loads(file.read_text())
                if state["status"] in {"queued", "running"}: state["status"] = "interrupted"
                self.states[file.parent.name] = state
                atomic_json(file, state)
            except (OSError, ValueError, KeyError): continue

    def usage(self):
        return sum(f.stat().st_size for f in self.root.rglob("*") if f.is_file() and not f.is_symlink())

    def capabilities(self):
        ffmpeg = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
        model_ready = bool(self.models and self.models.is_dir() and self.model_revision)
        has = lambda name: importlib.util.find_spec(name) is not None
        return {"schema": 1, "worker": VERSION, "maxAssetBytes": MAX_ASSET, "concurrency": 1, "device": "cpu",
            "capabilities": {"waveform": ffmpeg, "render": ffmpeg, "analyze": ffmpeg and has("librosa"),
                "reference": ffmpeg and has("librosa"), "separate": ffmpeg and model_ready and has("demucs"),
                "align": ffmpeg and model_ready and has("whisperx"), "midi": bool(shutil.which("fluidsynth") and self.soundfont and self.soundfont.is_file())},
            "modelRevision": self.model_revision,
            "qualification": "Runtime dependencies detected; model accuracy, DSP filters and hardware are not device-qualified"}

    def submit(self, body):
        request_id, kind, assets = body.get("id", ""), body.get("kind"), body.get("assets")
        if not JOB_ID.fullmatch(request_id) or kind not in KINDS or not isinstance(assets, list) or not 1 <= len(assets) <= 8:
            raise ValueError("Invalid job request")
        if not isinstance(body.get("params", {}), dict): raise ValueError("Invalid job parameters")
        for asset in assets:
            if not isinstance(asset, str) or not IDENTITY.fullmatch(asset) or not (self.assets / asset).is_file():
                raise ValueError("Upload every input asset first")
        request = {"kind": kind, "assets": assets, "params": body.get("params", {}), "worker": VERSION, "modelRevision": self.model_revision}
        fingerprint = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        with self.lock:
            if request_id in self.states:
                old = self.states[request_id]
                if old["fingerprint"] != fingerprint: raise ValueError("Job ID reused for different inputs")
                return old
            if sum(s["status"] in {"queued", "running"} for s in self.states.values()) >= 8: raise ValueError("Preparation queue is full")
            if len(self.states) >= 1024 or self.usage() >= MAX_WORK: raise ValueError("Companion quota reached; remove completed jobs/assets")
            if not self.capabilities()["capabilities"][kind]: raise ValueError("This companion lacks the configured dependencies for this operation")
            directory = self.jobs / request_id; directory.mkdir()
            atomic_json(directory / "request.json", request)
            for index, asset in enumerate(assets):
                # Copies prevent jobs mutating the content-addressed input cache.
                shutil.copyfile(self.assets / asset, directory / f"input-{index}")
            state = {"schema": 1, "id": request_id, "status": "queued", "kind": kind, "fingerprint": fingerprint,
                     "createdMs": round(time.time()*1000), "modelRevision": self.model_revision}
            self.states[request_id] = state; atomic_json(directory / "state.json", state)
            self.pool.submit(self.execute, request_id)
            return dict(state)

    def execute(self, job_id):
        directory = self.jobs / job_id
        with self.lock:
            if job_id in self.canceled: return
            self.states[job_id]["status"] = "running"
            atomic_json(directory / "state.json", self.states[job_id])
        command = [sys.executable, str(Path(__file__).with_name("worker.py")), str(directory)]
        if self.models: command += ["--models", str(self.models)]
        if self.soundfont: command += ["--soundfont", str(self.soundfont)]
        errors = bytearray()
        try:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                start_new_session=os.name != "nt", creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
            with self.lock:
                self.processes[job_id] = process
                if job_id in self.canceled: self.kill(process)
            def drain():
                while data := process.stderr.read(4096):
                    errors.extend(data)
                    if len(errors) > 16384: del errors[:-16384]
            reader = threading.Thread(target=drain, daemon=True); reader.start()
            deadline = time.monotonic() + self.timeout
            while process.poll() is None:
                if time.monotonic() > deadline or sum(f.stat().st_size for f in directory.rglob("*") if f.is_file()) > 4*MAX_ASSET:
                    self.kill(process); raise ValueError("Job exceeded its runtime or storage bound")
                time.sleep(.5)
            reader.join(timeout=2)
            with self.lock:
                state = self.states[job_id]
                if job_id in self.canceled: state["status"] = "canceled"
                elif process.returncode:
                    state.update(status="failed", error=errors[-3000:].decode(errors="replace"))
                else:
                    result = json.loads((directory / "result.json").read_text())
                    state.update(status="completed", result=result)
                atomic_json(directory / "state.json", state)
        except Exception as error:
            with self.lock:
                self.states[job_id].update(status="canceled" if job_id in self.canceled else "failed", error=str(error))
                atomic_json(directory / "state.json", self.states[job_id])
        finally:
            with self.lock: self.processes.pop(job_id, None)

    @staticmethod
    def kill(process):
        if process.poll() is not None: return
        if os.name == "nt": subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass

    def cancel(self, job_id):
        with self.lock:
            if job_id not in self.states: raise KeyError(job_id)
            if self.states[job_id]["status"] in {"completed", "failed", "canceled", "interrupted"}: return dict(self.states[job_id])
            self.canceled.add(job_id)
            if job_id in self.processes: self.kill(self.processes[job_id])
            self.states[job_id]["status"] = "canceled"
            atomic_json(self.jobs / job_id / "state.json", self.states[job_id])
            return dict(self.states[job_id])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    def setup(self):
        super().setup(); self.connection.settimeout(30)
    def reply(self, status, data):
        body = json.dumps(data, ensure_ascii=False, allow_nan=False).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close"); self.end_headers(); self.wfile.write(body)
        self.close_connection = True
    def authorized(self):
        value = self.headers.get("Authorization", "")
        return hmac.compare_digest(value, "Bearer " + self.server.token) and not self.headers.get("Origin")
    def body(self, maximum):
        if self.headers.get("Transfer-Encoding"): raise ValueError("Content-Length required")
        length = int(self.headers.get("Content-Length", "-1"))
        if not 0 <= length <= maximum: raise ValueError("Request body size rejected")
        return length
    def do_GET(self): self.dispatch("GET")
    def do_POST(self): self.dispatch("POST")
    def do_DELETE(self): self.dispatch("DELETE")
    def dispatch(self, method):
        if not self.authorized(): return self.reply(401, {"error": "Companion token required"})
        jobs = self.server.jobs
        path = urlsplit(self.path).path.split("/")[1:]
        try:
            if path == ["v1", "capabilities"] and method == "GET": return self.reply(200, jobs.capabilities())
            if path == ["v1", "assets"] and method == "POST":
                length = self.body(MAX_ASSET)
                if jobs.usage()+length > MAX_WORK: raise ValueError("Companion storage quota exceeded")
                temp = jobs.assets / ("upload-" + secrets.token_hex(16)); digest = hashlib.sha256()
                try:
                    with temp.open("xb") as output:
                        remaining = length
                        while remaining:
                            data = self.rfile.read(min(65536, remaining))
                            if not data: raise ValueError("Truncated upload")
                            output.write(data); digest.update(data); remaining -= len(data)
                        output.flush(); os.fsync(output.fileno())
                    identity = digest.hexdigest()
                    target = jobs.assets / identity
                    if target.exists(): temp.unlink()
                    else: temp.replace(target)
                    return self.reply(201, {"id": identity, "bytes": length})
                finally: temp.unlink(missing_ok=True)
            if path == ["v1", "jobs"] and method == "POST":
                size = self.body(128*1024); body = self.rfile.read(size)
                if len(body) != size: raise ValueError("Truncated request")
                return self.reply(202, jobs.submit(json.loads(body)))
            if len(path) >= 3 and path[:2] == ["v1", "jobs"] and JOB_ID.fullmatch(path[2]):
                job_id = path[2]
                if len(path) == 3:
                    if method == "DELETE": return self.reply(200, jobs.cancel(job_id))
                    if method == "GET":
                        with jobs.lock: state = dict(jobs.states[job_id])
                        return self.reply(200, state)
                if len(path) == 5 and path[3] == "files" and method == "GET":
                    with jobs.lock: state = jobs.states[job_id]
                    file_info = next((f for f in state.get("result", {}).get("files", []) if f["name"] == path[4]), None)
                    if not file_info or state["status"] != "completed": raise KeyError("No completed result")
                    file = jobs.jobs / job_id / "output" / file_info["name"]
                    if file.is_symlink() or not file.is_file(): raise KeyError("Missing result")
                    self.send_response(200); self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(file.stat().st_size)); self.send_header("Cache-Control", "no-store"); self.end_headers()
                    with file.open("rb") as source: shutil.copyfileobj(source, self.wfile, 65536)
                    return
            return self.reply(404, {"error": "Unknown companion operation"})
        except KeyError: self.reply(404, {"error": "Job or result not found"})
        except (ValueError, TypeError) as error: self.reply(400, {"error": str(error)})
        except (OSError, TimeoutError): self.close_connection = True
        except Exception: self.reply(500, {"error": "Companion operation failed"})


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(*args, **kwargs)
    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False): request.close(); return
        try: super().process_request(request, client_address)
        except Exception: self.slots.release(); raise
    def process_request_thread(self, request, client_address):
        try: super().process_request_thread(request, client_address)
        finally: self.slots.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=59892)
    parser.add_argument("--cert", type=Path); parser.add_argument("--key", type=Path)
    parser.add_argument("--models", type=Path); parser.add_argument("--model-revision")
    parser.add_argument("--soundfont", type=Path); parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    if args.host not in {"127.0.0.1", "::1", "localhost"} and not (args.cert and args.key): parser.error("LAN companions require TLS")
    if not 30 <= args.timeout <= 3600: parser.error("Timeout must be 30–3600 seconds")
    args.root.mkdir(parents=True, exist_ok=True)
    if not args.token_file.exists():
        fd = os.open(args.token_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as stream: stream.write(secrets.token_urlsafe(32))
    token = args.token_file.read_text().strip()
    if len(token) < 32: parser.error("Token must contain at least 32 characters")
    server = Server((args.host, args.port), Handler)
    server.token = token
    server.jobs = Jobs(args.root.resolve(), args.models.resolve() if args.models else None, args.model_revision,
                       args.soundfont.resolve() if args.soundfont else None, args.timeout)
    if args.cert and args.key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.cert, args.key); server.socket = context.wrap_socket(server.socket, server_side=True)
    try: server.serve_forever()
    finally:
        for process in list(server.jobs.processes.values()): server.jobs.kill(process)
        server.jobs.pool.shutdown(wait=False, cancel_futures=True); server.server_close()


if __name__ == "__main__": main()
