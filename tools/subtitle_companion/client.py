"""Small stdlib SDK for the version-1 upload/job/result protocol."""
from __future__ import annotations

import hashlib
import http.client
import json
from pathlib import Path
import re
import ssl
from urllib.parse import urlsplit


class CompanionClient:
    def __init__(self, endpoint: str, token: str, profile: str, *, ssl_context=None):
        self.url = urlsplit(endpoint)
        if self.url.username or self.url.password or self.url.query or self.url.fragment or self.url.path not in {"", "/"}:
            raise ValueError("Use a host URL without credentials, paths, or query parameters")
        if self.url.scheme != "https" and not (self.url.scheme == "http" and self.url.hostname in {"localhost", "127.0.0.1", "::1"}):
            raise ValueError("TLS is required outside localhost")
        self.token = token
        self.scope = hashlib.sha256(profile.encode()).hexdigest()
        self.context = ssl_context or ssl.create_default_context()

    def _connection(self):
        if self.url.scheme == "https":
            return http.client.HTTPSConnection(self.url.hostname, self.url.port, context=self.context, timeout=120)
        return http.client.HTTPConnection(self.url.hostname, self.url.port, timeout=120)

    @property
    def headers(self):
        return {"Authorization": "Bearer " + self.token, "X-Plezy-Scope": self.scope}

    @staticmethod
    def _decode(response):
        data = response.read(24 * 1024**2 + 1)
        if len(data) > 24 * 1024**2:
            raise ValueError("Response exceeded 24 MiB")
        value = json.loads(data)
        if not 200 <= response.status < 300:
            raise RuntimeError(value.get("error", "request_failed"))
        return value

    def request(self, method, route, body=None):
        connection = self._connection()
        try:
            data = None if body is None else json.dumps(body, ensure_ascii=False, allow_nan=False).encode()
            connection.request(method, route, body=data, headers={**self.headers, "Content-Type": "application/json"})
            return self._decode(connection.getresponse())
        finally:
            connection.close()

    def capabilities(self):
        return self.request("GET", "/v1/capabilities")

    def jobs(self):
        return self.request("GET", "/v1/jobs")["jobs"]

    @staticmethod
    def route(job_id, action=None):
        if not re.fullmatch(r"[0-9a-f]{32}", job_id):
            raise ValueError("Invalid job ID")
        return f"/v1/jobs/{job_id}" + (f"/{action}" if action else "")

    def create(self, *, task, identity, media=None, **options):
        if options.get("timelineOffsetMs", 0) or options.get("itemTimeline", False) or options.get("soundStereoEvidence", False):
            caps = self.capabilities()
            if (options.get("timelineOffsetMs", 0) or options.get("itemTimeline", False)) and caps.get("sourceTimelineOffsets") is not True:
                raise ValueError("Companion cannot preserve source timeline offsets")
            if options.get("soundStereoEvidence", False) and caps.get("soundStereoEvidence") is not True:
                raise ValueError("Companion cannot return stereo evidence")
        path = None if media is None else Path(media)
        digest = hashlib.sha256()
        size = 0
        if path:
            size = path.stat().st_size
            if not 0 < size <= 1024**3:
                raise ValueError("Input exceeds the 1 GiB limit")
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
        body = {**options, "task": task, "identity": identity, "audioBytes": size, "audioDigest": digest.hexdigest()}
        body["requestId"] = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
        job = self.request("POST", "/v1/jobs", body)
        if path and job["state"] == "awaiting_audio":
            connection = self._connection()
            try:
                connection.putrequest("PUT", self.route(job["id"], "audio"))
                for key, value in {**self.headers, "Content-Type": "application/octet-stream", "Content-Length": str(size)}.items():
                    connection.putheader(key, value)
                connection.endheaders()
                with path.open("rb") as stream:
                    for block in iter(lambda: stream.read(65536), b""):
                        connection.send(block)
                job = self._decode(connection.getresponse())
            finally:
                connection.close()
        return job

    def start(self, job_id):
        return self.request("POST", self.route(job_id, "start"))

    def status(self, job_id):
        return self.request("GET", self.route(job_id))

    def pause(self, job_id):
        return self.request("POST", self.route(job_id, "pause"))

    def cancel(self, job_id):
        return self.request("POST", self.route(job_id, "cancel"))

    def delete(self, job_id):
        return self.request("DELETE", self.route(job_id))

    def result(self, job_id, *, identity, audio_digest):
        result = self.request("GET", self.route(job_id, "result"))
        if result.get("schema") != 1 or result.get("identity") != identity or result.get("audioDigest") != audio_digest or result.get("jobId") != job_id:
            raise ValueError("Result identity does not match the submitted media")
        return result

    def evidence_image(self, job_id, sha256):
        if not re.fullmatch(r"[0-9a-f]{64}", sha256):
            raise ValueError("Invalid image digest")
        connection = self._connection()
        try:
            connection.request("GET", self.route(job_id, f"evidence/{sha256}"), headers=self.headers)
            response = connection.getresponse()
            data = response.read(4 * 1024**2 + 1)
            if response.status != 200 or len(data) > 4 * 1024**2 or hashlib.sha256(data).hexdigest() != sha256:
                raise ValueError("Image evidence failed integrity verification")
            return data
        finally:
            connection.close()

    def audio_artifact(self, job_id, artifact):
        digest, size = artifact.get("sha256"), artifact.get("bytes")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest) or type(size) is not int or not 44 < size <= 32 * 1024**2:
            raise ValueError("Invalid audio artifact metadata")
        connection = self._connection()
        try:
            connection.request("GET", self.route(job_id, f"artifacts/{digest}"), headers=self.headers)
            response = connection.getresponse()
            data = response.read(size + 1)
            if response.status != 200 or len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                raise ValueError("Audio artifact failed integrity verification")
            return data
        finally:
            connection.close()
