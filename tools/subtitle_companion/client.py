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

    def create_caption_channel(self):
        """Return a six-hour transport capability, not a companion admin token.

        The SDK does not turn this into an app invite or send it to anyone.
        App room binding and client-side AES-GCM encryption remain required.
        """
        if self.capabilities().get('captionRelay') != 1:
            raise ValueError('Companion does not support caption channels')
        return self.request('POST', '/v1/caption-channels', {'version': 1})

    def revoke_caption_channel(self, identifier):
        if not isinstance(identifier, str) or not re.fullmatch(r'[0-9a-f]{32}', identifier):
            raise ValueError('Invalid caption channel ID')
        return self.request('DELETE', f'/v1/caption-channels/{identifier}')

    def jobs(self):
        return self.request("GET", "/v1/jobs")["jobs"]

    @staticmethod
    def route(job_id, action=None):
        if not re.fullmatch(r"[0-9a-f]{32}", job_id):
            raise ValueError("Invalid job ID")
        return f"/v1/jobs/{job_id}" + (f"/{action}" if action else "")

    def create(self, *, task, identity, media=None, **options):
        if task == 'sound_localize' and self.capabilities().get('microphoneArrayLocalization') is not True:
            raise ValueError('companion_microphone_array_localization_unavailable')
        if task == 'vocal_notes' and self.capabilities().get('isolatedVocalNoteProposals') is not True:
            raise ValueError('companion_solo_vocal_note_proposals_unavailable')
        if options.get('sceneObjectTracking', False) or task == 'scene_track':
            caps = self.capabilities()
            detector = caps.get('sceneObjectDetector')
            if caps.get('sceneObjectTracking') is not True or not isinstance(detector, dict) or options.get('sceneDetectorFingerprint') != detector.get('fingerprint'):
                raise ValueError('companion_scene_detector_changed_resubmit_after_review')
            if task == 'scene_track' and caps.get('sceneTitleTracking') is not True:
                raise ValueError('companion_whole_title_tracker_unavailable')
        if task == 'reading' and options.get('readingMode') == 'ruby' and 'ruby' not in self.capabilities().get('readingModes', []):
            raise ValueError('Companion cannot produce ruby reading markup')
        if options.get("lyricSyllables") or options.get("lyricPitchEvidence", False) or options.get("sceneMotionTracking", False) or options.get("sceneAudioEvidence", False) or options.get("sceneTemporalRegions", False) or options.get("timelineOffsetMs", 0) or options.get("itemTimeline", False) or options.get("soundStereoEvidence", False):
            caps = self.capabilities()
            if options.get('lyricSyllables') and caps.get('lyricSyllables') is not True:
                raise ValueError('companion_does_not_support_lyric_syllables')
            if options.get('lyricPitchEvidence', False) and caps.get('lyricPitchEvidence') is not True:
                raise ValueError('companion_does_not_support_lyric_pitch_evidence')
            if options.get("sceneMotionTracking", False) and caps.get("sceneMotionTracking") is not True:
                raise ValueError("Companion has no local motion tracker")
            if options.get("sceneAudioEvidence", False) and caps.get("sceneAudioEvidence") is not True:
                raise ValueError("Companion has no declared joint audio/image provider")
            if options.get("sceneTemporalRegions", False) and caps.get("sceneTemporalRegions") is not True:
                raise ValueError("Companion cannot produce temporal scene proposals")
            if (options.get("timelineOffsetMs", 0) or options.get("itemTimeline", False)) and caps.get("sourceTimelineOffsets") is not True:
                raise ValueError("Companion cannot preserve source timeline offsets")
            if options.get("soundStereoEvidence", False) and caps.get("soundStereoEvidence") is not True:
                raise ValueError("Companion cannot return stereo evidence")
        path = None if media is None else Path(media)
        digest = hashlib.sha256()
        size = 0
        if path:
            size = path.stat().st_size
            limit = 100*1024**2 if task == 'sound_localize' else 4*1024**2 if task == 'vocal_notes' else 1024**3
            if not 0 < size <= limit:
                raise ValueError(f"Input exceeds the {limit//1024**2} MiB task limit")
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
        if artifact.get('name') != 'dubbed.wav' or artifact.get('mime') != 'audio/wav':
            raise ValueError('Invalid audio artifact metadata')
        return self.artifact(job_id, artifact)

    def artifact(self, job_id, artifact):
        digest, size = artifact.get("sha256"), artifact.get("bytes")
        kinds = {'dubbed.wav': 'audio/wav', 'scene-tracks.jsonl': 'application/x-ndjson'}
        if (artifact.get('name') not in kinds or artifact.get('mime') != kinds[artifact['name']] or
                not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest) or type(size) is not int or not 0 < size <= 32 * 1024**2):
            raise ValueError("Invalid artifact metadata")
        connection = self._connection()
        try:
            connection.request("GET", self.route(job_id, f"artifacts/{digest}"), headers=self.headers)
            response = connection.getresponse()
            data = response.read(size + 1)
            if response.status != 200 or response.getheader('Content-Type') != artifact['mime'] or len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                raise ValueError("Artifact failed integrity verification")
            return data
        finally:
            connection.close()
