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
import importlib.metadata
import json
import os
from pathlib import Path
import re
import secrets
import socket
import shutil
import signal
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

VERSION = "plezy-karaoke-worker-3"
MAX_ASSET = 512 * 1024 * 1024
MAX_WORK = 20 * 1024 * 1024 * 1024
WORKER_MEMORY_LIMIT = 8 * 1024 * 1024 * 1024
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
        self.lock = threading.RLock(); self.condition = threading.Condition(self.lock)
        self.states = {}; self.processes = {}; self.process_job_handles = {}
        self.canceled = set(); self.preempted = set(); self.upload_reserved = 0
        self.pending = {}; self.dispatcher_running = False; self.current_job_id = None; self.performance_leases = {}
        self.stopping = False
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

    def reserved_work(self):
        limit = 4 * MAX_ASSET
        reserved = 0
        for job_id, state in self.states.items():
            if state.get("status") not in {"queued", "running"} and job_id not in self.processes: continue
            directory = self.jobs / job_id
            used = sum(f.stat().st_size for f in directory.rglob("*") if f.is_file() and not f.is_symlink()) if directory.exists() else 0
            reserved += max(0, limit - used)
        return reserved

    def separation_runtime_ready(self):
        floors = {"torch": (2, 15, 0), "torchaudio": (2, 11, 0), "torchcodec": (0, 17, 0), "setuptools": (84, 1, 0)}
        for name, minimum in floors.items():
            try:
                found = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:\+[A-Za-z0-9.]+)?", importlib.metadata.version(name))
                if not found or tuple(map(int, found.groups())) < minimum: return False
            except importlib.metadata.PackageNotFoundError:
                return False
        return True

    @staticmethod
    def memory_limit_available():
        if os.name == "nt":
            return True
        try:
            import resource
            return hasattr(resource, "RLIMIT_AS")
        except ImportError:
            return False

    @staticmethod
    def _windows_memory_job(process):
        import ctypes
        from ctypes import wintypes

        class BasicLimitInformation(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_longlong),
                ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD),
            ]

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount",
            )]

        class ExtendedLimitInformation(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", BasicLimitInformation),
                ("IoInfo", IoCounters),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateJobObjectW.restype = wintypes.HANDLE
        kernel.CreateJobObjectW.argtypes = (ctypes.c_void_p, wintypes.LPCWSTR)
        kernel.SetInformationJobObject.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD)
        kernel.SetInformationJobObject.restype = wintypes.BOOL
        kernel.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
        kernel.AssignProcessToJobObject.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        kernel.CloseHandle.restype = wintypes.BOOL
        job = kernel.CreateJobObjectW(None, None)
        if not job:
            raise ctypes.WinError(ctypes.get_last_error())
        information = ExtendedLimitInformation()
        information.BasicLimitInformation.LimitFlags = 0x100 | 0x200 | 0x2000
        # Per-process and aggregate memory limits; kill the worker tree if the server exits.
        information.ProcessMemoryLimit = WORKER_MEMORY_LIMIT
        information.JobMemoryLimit = WORKER_MEMORY_LIMIT
        try:
            if not kernel.SetInformationJobObject(job, 9, ctypes.byref(information), ctypes.sizeof(information)):
                raise ctypes.WinError(ctypes.get_last_error())
            if not kernel.AssignProcessToJobObject(job, wintypes.HANDLE(int(process._handle))):
                raise ctypes.WinError(ctypes.get_last_error())
            return job
        except Exception:
            kernel.CloseHandle(job)
            raise

    @classmethod
    def _apply_memory_limit(cls, process):
        if os.name == "nt":
            return cls._windows_memory_job(process)
        return None

    @staticmethod
    def _close_memory_job(job):
        if job is None or os.name != "nt":
            return
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        kernel.CloseHandle.restype = wintypes.BOOL
        kernel.CloseHandle(job)

    def capabilities(self):
        ffmpeg = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
        model_ready = bool(self.models and self.models.is_dir() and self.model_revision)
        has = lambda name: importlib.util.find_spec(name) is not None
        memory_limited = self.memory_limit_available()
        return {"schema": 1, "worker": VERSION, "maxAssetBytes": MAX_ASSET, "concurrency": 1, "device": "cpu",
            "memoryLimitBytes": WORKER_MEMORY_LIMIT, "memoryLimitEnforced": memory_limited,
            "scheduler": {"playbackAware": True, "preemptsForPlayback": True,
                "resumePolicy": "restart-job-after-playback", "priorityPolicy": "user-selected-latest-first"},
            "capabilities": {"waveform": memory_limited and ffmpeg, "render": memory_limited and ffmpeg,
                "analyze": memory_limited and ffmpeg and has("librosa"),
                "reference": memory_limited and ffmpeg and has("librosa"),
                "separate": memory_limited and ffmpeg and model_ready and has("demucs") and self.separation_runtime_ready(),
                "align": memory_limited and ffmpeg and model_ready and has("whisperx"),
                "midi": memory_limited and bool(shutil.which("fluidsynth") and self.soundfont and self.soundfont.is_file())},
            "modelRevision": self.model_revision,
            "separationRuntimeReady": self.separation_runtime_ready(),
            "qualification": "Runtime dependencies detected; model accuracy, DSP filters and hardware are not device-qualified"}

    def submit(self, body):
        request_id, kind, assets = body.get("id", ""), body.get("kind"), body.get("assets")
        priority = body.get("priority", 50)
        if not JOB_ID.fullmatch(request_id) or kind not in KINDS or not isinstance(assets, list) or not 1 <= len(assets) <= 8:
            raise ValueError("Invalid job request")
        if isinstance(priority, bool) or not isinstance(priority, int) or not 0 <= priority <= 100:
            raise ValueError("Job priority must be between 0 and 100")
        if not isinstance(body.get("params", {}), dict): raise ValueError("Invalid job parameters")
        for asset in assets:
            if not isinstance(asset, str) or not IDENTITY.fullmatch(asset) or not (self.assets / asset).is_file():
                raise ValueError("Upload every input asset first")
        request = {"kind": kind, "assets": assets, "params": body.get("params", {}), "worker": VERSION, "modelRevision": self.model_revision}
        fingerprint = hashlib.sha256(json.dumps({**request, "priority": priority}, sort_keys=True).encode()).hexdigest()
        with self.condition:
            if request_id in self.states:
                old = self.states[request_id]
                if old["fingerprint"] != fingerprint: raise ValueError("Job ID reused for different inputs")
                return old
            if sum(s["status"] in {"queued", "running"} for s in self.states.values()) >= 8: raise ValueError("Preparation queue is full")
            copy_bytes = sum((self.assets / asset).stat().st_size for asset in assets)
            if copy_bytes > 4*MAX_ASSET: raise ValueError("Job inputs exceed the 2 GiB work-directory limit")
            if len(self.states) >= 1024 or self.usage()+self.upload_reserved+self.reserved_work()+4*MAX_ASSET > MAX_WORK:
                raise ValueError("Companion quota reached; remove completed jobs/assets")
            if not self.capabilities()["capabilities"][kind]: raise ValueError("This companion lacks the configured dependencies for this operation")
            directory = self.jobs / request_id; directory.mkdir()
            try:
                atomic_json(directory / "request.json", request)
                for index, asset in enumerate(assets):
                    # Copies prevent jobs mutating the content-addressed input cache.
                    shutil.copyfile(self.assets / asset, directory / f"input-{index}")
                created_ms = round(time.time()*1000)
                state = {"schema": 1, "id": request_id, "status": "queued", "kind": kind, "fingerprint": fingerprint,
                         "priority": priority, "createdMs": created_ms, "modelRevision": self.model_revision}
                self.states[request_id] = state; atomic_json(directory / "state.json", state)
                self.pending[request_id] = (priority, created_ms)
                self._start_dispatcher_locked()
                return dict(state)
            except Exception:
                self.states.pop(request_id, None)
                shutil.rmtree(directory, ignore_errors=True)
                raise

    def _start_dispatcher_locked(self):
        if self.dispatcher_running:
            return
        self.dispatcher_running = True
        try:
            self.pool.submit(self._dispatch)
        except Exception:
            self.dispatcher_running = False
            raise

    def shutdown(self):
        with self.condition:
            self.stopping = True
            processes = list(self.processes.values())
            self.condition.notify_all()
        for process in processes:
            self.kill(process)
        self.pool.shutdown(wait=False, cancel_futures=True)

    def _performance_active_locked(self):
        now = time.monotonic()
        return any(lease["activeUntil"] > now for lease in self.performance_leases.values())

    def update_performance(self, body):
        client_id, sequence, active = body.get("clientId"), body.get("sequence"), body.get("active")
        if not isinstance(client_id, str) or not JOB_ID.fullmatch(client_id):
            raise ValueError("Invalid performance client ID")
        if isinstance(sequence, bool) or not isinstance(sequence, int) or not 1 <= sequence <= 2**31 - 1:
            raise ValueError("Invalid performance update sequence")
        if not isinstance(active, bool):
            raise ValueError("Performance activity must be a boolean")
        lease_seconds = body.get("leaseSeconds", 45 if active else 0)
        if isinstance(lease_seconds, bool) or not isinstance(lease_seconds, int):
            raise ValueError("Invalid performance lease")
        if active and not 15 <= lease_seconds <= 6 * 60 * 60:
            raise ValueError("Active performance leases must be between 15 seconds and six hours")
        with self.condition:
            now = time.monotonic()
            for old_id, lease in list(self.performance_leases.items()):
                if now - lease["updatedAt"] > 6 * 60 * 60:
                    self.performance_leases.pop(old_id, None)
            previous = self.performance_leases.get(client_id)
            if previous is None or sequence > previous["sequence"]:
                if previous is None and len(self.performance_leases) >= 128:
                    expired = [key for key, lease in self.performance_leases.items() if lease["activeUntil"] <= now]
                    for key in expired:
                        self.performance_leases.pop(key, None)
                if previous is None and len(self.performance_leases) >= 128:
                    raise ValueError("Too many performance clients are registered")
                self.performance_leases[client_id] = {
                    "sequence": sequence,
                    "activeUntil": now + lease_seconds if active else 0,
                    "updatedAt": now,
                }
                if active and self.current_job_id is not None:
                    job_id = self.current_job_id
                    self.preempted.add(job_id)
                    process = self.processes.get(job_id)
                    if process is not None:
                        self.kill(process)
            self.condition.notify_all()
            active_clients = sum(lease["activeUntil"] > now for lease in self.performance_leases.values())
            return {"active": active_clients > 0, "activeClients": active_clients}

    def _dispatch(self):
        while True:
            with self.condition:
                while True:
                    if self.stopping:
                        self.dispatcher_running = False
                        return
                    if not self.pending:
                        self.dispatcher_running = False
                        self.condition.notify_all()
                        return
                    if self._performance_active_locked():
                        self.condition.wait(timeout=1)
                        continue
                    job_id = min(self.pending, key=lambda item: (-self.pending[item][0], -self.pending[item][1], item))
                    self.pending.pop(job_id, None)
                    if self.states.get(job_id, {}).get("status") != "queued":
                        continue
                    self.current_job_id = job_id
                    break
            self.execute(job_id)
            with self.condition:
                if self.current_job_id == job_id:
                    self.current_job_id = None
                self.condition.notify_all()

    def _requeue_preempted_locked(self, job_id, directory):
        if job_id not in self.preempted or job_id in self.canceled:
            return False
        self.preempted.discard(job_id)
        shutil.rmtree(directory / "output", ignore_errors=True)
        state = self.states[job_id]
        state["status"] = "queued"
        state.pop("error", None)
        state.pop("result", None)
        atomic_json(directory / "state.json", state)
        self.pending[job_id] = (state.get("priority", 50), state.get("createdMs", 0))
        return True

    def remove(self, job_id):
        with self.condition:
            state = self.states.get(job_id)
            if state is None: raise KeyError(job_id)
            if state["status"] in {"queued", "running"} or job_id in self.processes:
                raise ValueError("Cancel and wait for the worker to stop before removing this job")
            request_path = self.jobs / job_id / "request.json"
            try: assets = json.loads(request_path.read_text()).get("assets", [])
            except (OSError, ValueError): assets = []
            shutil.rmtree(self.jobs / job_id, ignore_errors=False)
            self.states.pop(job_id, None)
            used = {asset for state in self.states.values() for asset in state.get("result", {}).get("inputAssets", [])}
            # Request inputs remain in per-job snapshots; retain any digest still referenced by a job.
            for directory in self.jobs.iterdir():
                try: used.update(json.loads((directory / "request.json").read_text()).get("assets", []))
                except (OSError, ValueError): pass
            for asset in assets:
                if asset not in used and IDENTITY.fullmatch(asset): (self.assets / asset).unlink(missing_ok=True)
            return {"id": job_id, "status": "removed"}

    def execute(self, job_id):
        directory = self.jobs / job_id
        with self.condition:
            if self.stopping or job_id in self.canceled: return
            if self._performance_active_locked():
                state = self.states[job_id]
                self.preempted.discard(job_id)
                self.pending[job_id] = (state.get("priority", 50), state.get("createdMs", 0))
                return
            self.states[job_id]["status"] = "running"
            atomic_json(directory / "state.json", self.states[job_id])
        command = [sys.executable, str(Path(__file__).with_name("worker.py")), str(directory)]
        if self.models: command += ["--models", str(self.models)]
        if self.soundfont: command += ["--soundfont", str(self.soundfont)]
        errors = bytearray()
        memory_job = None
        try:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                start_new_session=os.name != "nt", creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
            try:
                memory_job = self._apply_memory_limit(process)
            except Exception as error:
                self.kill(process)
                try:
                    process.wait(timeout=5)
                finally:
                    if process.stderr:
                        process.stderr.close()
                raise RuntimeError("Could not enforce the karaoke worker memory limit") from error
            with self.condition:
                self.processes[job_id] = process
                if memory_job is not None:
                    self.process_job_handles[job_id] = memory_job
                if self.stopping or job_id in self.canceled or job_id in self.preempted or self._performance_active_locked(): self.kill(process)
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
            with self.condition:
                state = self.states[job_id]
                if self._requeue_preempted_locked(job_id, directory):
                    pass
                elif job_id in self.canceled: state["status"] = "canceled"
                elif process.returncode:
                    state.update(status="failed", error=errors[-3000:].decode(errors="replace"))
                else:
                    result = json.loads((directory / "result.json").read_text())
                    state.update(status="completed", result=result)
                atomic_json(directory / "state.json", state)
        except Exception as error:
            with self.condition:
                if not self._requeue_preempted_locked(job_id, directory):
                    self.states[job_id].update(status="canceled" if job_id in self.canceled else "failed", error=str(error))
                    atomic_json(directory / "state.json", self.states[job_id])
        finally:
            with self.condition:
                self.processes.pop(job_id, None)
                memory_job = self.process_job_handles.pop(job_id, None)
                self.preempted.discard(job_id)
                self.condition.notify_all()
            self._close_memory_job(memory_job)

    @staticmethod
    def kill(process):
        if process.poll() is not None: return
        if os.name == "nt": subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass

    def cancel(self, job_id):
        with self.condition:
            if job_id not in self.states: raise KeyError(job_id)
            if self.states[job_id]["status"] in {"completed", "failed", "canceled", "interrupted"}: return dict(self.states[job_id])
            self.canceled.add(job_id)
            self.pending.pop(job_id, None)
            self.preempted.discard(job_id)
            if job_id in self.processes: self.kill(self.processes[job_id])
            self.states[job_id]["status"] = "canceled"
            atomic_json(self.jobs / job_id / "state.json", self.states[job_id])
            self.condition.notify_all()
            return dict(self.states[job_id])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def handle_one_request(self):
        # A socket idle timeout alone can be defeated by sending one byte at a
        # time. Bound the entire unauthenticated request line/header phase.
        self._header_expired = threading.Event()
        def expire():
            self._header_expired.set()
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self._header_timer = threading.Timer(self.server.header_timeout, expire)
        self._header_timer.daemon = True
        self._header_timer.start()
        try:
            super().handle_one_request()
        finally:
            self._header_timer.cancel()

    def parse_request(self):
        try:
            return super().parse_request() and not self._header_expired.is_set()
        finally:
            self._header_timer.cancel()

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
                with jobs.lock:
                    if jobs.usage()+jobs.upload_reserved+jobs.reserved_work()+length > MAX_WORK: raise ValueError("Companion storage quota exceeded")
                    jobs.upload_reserved += length
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
                finally:
                    temp.unlink(missing_ok=True)
                    with jobs.lock: jobs.upload_reserved -= length
            if path == ["v1", "performance"] and method == "POST":
                size = self.body(4096); body = self.rfile.read(size)
                if len(body) != size: raise ValueError("Truncated request")
                return self.reply(200, jobs.update_performance(json.loads(body)))
            if path == ["v1", "jobs"] and method == "POST":
                size = self.body(128*1024); body = self.rfile.read(size)
                if len(body) != size: raise ValueError("Truncated request")
                return self.reply(202, jobs.submit(json.loads(body)))
            if len(path) >= 3 and path[:2] == ["v1", "jobs"] and JOB_ID.fullmatch(path[2]):
                job_id = path[2]
                if len(path) == 3:
                    if method == "DELETE":
                        if urlsplit(self.path).query == 'delete=1':
                            try: return self.reply(200, jobs.remove(job_id))
                            except KeyError: return self.reply(200, {"id": job_id, "status": "removed"})
                        return self.reply(200, jobs.cancel(job_id))
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
    header_timeout = 10
    def __init__(self, *args, tls_context=None, handshake_timeout=5, **kwargs):
        self.slots = threading.BoundedSemaphore(8)
        self.tls_context = tls_context
        self.handshake_timeout = handshake_timeout
        super().__init__(*args, **kwargs)
    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False): request.close(); return
        try: super().process_request(request, client_address)
        except Exception: self.slots.release(); raise
    def process_request_thread(self, request, client_address):
        try:
            # Accept stays non-blocking with respect to TLS. Handshakes share
            # the same bounded worker budget as HTTP, before authentication.
            request.settimeout(self.handshake_timeout)
            if self.tls_context is not None:
                request = self.tls_context.wrap_socket(request, server_side=True, do_handshake_on_connect=False)
                request.do_handshake()
            super().process_request_thread(request, client_address)
        except (OSError, ssl.SSLError):
            self.shutdown_request(request)
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
        context.load_cert_chain(args.cert, args.key); server.tls_context = context
    try: server.serve_forever()
    finally:
        server.jobs.shutdown(); server.server_close()


if __name__ == "__main__": main()
