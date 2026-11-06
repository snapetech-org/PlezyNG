#!/usr/bin/env python3
"""Optional Pleazyng extras discovery service; Python 3.11+, standard library.

Only public title identities leave the client. Media credentials, libraries,
watch history and AI inference are never accepted by this service.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 128 * 1024
MAX_RESPONSE = 1024 * 1024
VIDEO = re.compile(r"^[A-Za-z0-9_-]{11}$")
EXTERNAL = re.compile(r"^(movie|show)/(imdb:tt[0-9]{5,12}|tvdb:[1-9][0-9]{0,9})$")
IDENTITY = re.compile(r"^(movie|show)/tmdb:([1-9][0-9]{0,9})$")
KINDS = {"Behind the Scenes": "makingOf", "Featurette": "makingOf", "Bloopers": "bloopers", "Trailer": "trailer", "Teaser": "trailer"}
ALLOWED_KINDS = {"makingOf", "effects", "makeup", "interview", "deletedScene", "bloopers", "commentary", "trailer", "analysis"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def fetch_json(url, headers=None):
    """Fixed provider origins only; no client-controlled fetch destination."""
    uri = urllib.parse.urlsplit(url)
    if uri.scheme != "https" or uri.hostname not in {"api.themoviedb.org", "www.googleapis.com"}:
        raise ValueError("Unsupported provider")
    req = urllib.request.Request(url, headers={"Accept": "application/json", **(headers or {})})
    with urllib.request.build_opener(NoRedirect).open(req, timeout=8) as response:
        body = response.read(MAX_RESPONSE + 1)
    if len(body) > MAX_RESPONSE:
        raise ValueError("Provider response too large")
    data = json.loads(body)
    if not isinstance(data, dict):
        raise ValueError("Invalid provider response")
    return data


def valid_evidence(url):
    if not isinstance(url, str):
        return False
    uri = urllib.parse.urlsplit(url)
    return uri.scheme == "https" and bool(uri.hostname) and not uri.username and not uri.password


def load_registry(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ValueError("Unsupported registry version")
    if not isinstance(data.get("publishers", []), list) or not isinstance(data.get("associations", []), list):
        raise ValueError("Registry collections must be lists")
    publishers = {}
    for row in data.get("publishers", []):
        if not isinstance(row, dict) or not re.fullmatch(r"UC[A-Za-z0-9_-]{22}", row.get("id", "")):
            raise ValueError("A publisher needs its stable YouTube channel ID")
        if not valid_evidence(row.get("evidenceUrl")) or not row.get("name"):
            raise ValueError("Publisher identity needs a name and verification evidence")
        if row["id"] in publishers:
            raise ValueError("Duplicate publisher ID")
        publishers[row["id"]] = row
    associations = {}
    for row in data.get("associations", []):
        if not isinstance(row, dict) or not VIDEO.fullmatch(row.get("videoId", "")):
            raise ValueError("Invalid reviewed video ID")
        if not valid_evidence(row.get("evidenceUrl")) or not row.get("reviewedBy"):
            raise ValueError("Association requires review provenance")
        if row.get("kind") not in ALLOWED_KINDS or not row.get("parents") or not all(IDENTITY.fullmatch(p) for p in row["parents"]):
            raise ValueError("Association requires exact work IDs and a bonus-feature category")
        if row.get("scope", "work") not in {"work", "franchise", "season", "episode"}:
            raise ValueError("Unknown scope")
        if row.get("scope", "work") != "work" and not row.get("scopeLabel"):
            raise ValueError("Broader associations require a scope label")
        # Transcripts must be supplied separately under a suitable permission.
        # YouTube caption extraction and media downloading are not implemented.
        if row.get("passages") and not (row.get("analysisAllowed") is True and valid_evidence(row.get("transcriptPermissionUrl"))):
            raise ValueError("Transcript enrichment requires documented permission")
        if row["videoId"] in associations:
            raise ValueError("Duplicate reviewed video ID")
        if row.get("passages") and (not isinstance(row["passages"], list) or len(row["passages"]) > 500):
            raise ValueError("Too many transcript passages")
        for passage in row.get("passages", []):
            if (not isinstance(passage, dict) or type(passage.get("start")) is not int or
                type(passage.get("end")) is not int or not 0 <= passage["start"] < passage["end"] <= 86400 or
                not isinstance(passage.get("text"), str) or not 0 < len(passage["text"]) <= 2000):
                raise ValueError("Invalid transcript passage")
        associations[row["videoId"]] = row
    return publishers, associations


class Cache:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.lock = threading.Lock()
        self.db.execute("CREATE TABLE IF NOT EXISTS results (key TEXT PRIMARY KEY, created REAL, body TEXT)")
        self.db.execute("CREATE TABLE IF NOT EXISTS review_queue (video TEXT, parent TEXT, created REAL, PRIMARY KEY(video,parent))")
        self.db.execute("CREATE TABLE IF NOT EXISTS budget (day TEXT, kind TEXT, calls INTEGER, PRIMARY KEY(day, kind))")
        self.db.commit()

    def get(self, key):
        with self.lock:
            # Provider data is refreshed/deleted well before 30 days.
            self.db.execute("DELETE FROM results WHERE created < ?", (time.time() - 86400,))
            self.db.commit()
            row = self.db.execute("SELECT body FROM results WHERE key = ?", (key,)).fetchone()
        return json.loads(row[0]) if row else None

    def put(self, key, body):
        encoded = json.dumps(body, ensure_ascii=False)
        if len(encoded.encode()) > MAX_RESPONSE:
            raise ValueError("Result too large")
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO results VALUES (?, ?, ?)", (key, time.time(), encoded))
            self.db.execute("DELETE FROM results WHERE key IN (SELECT key FROM results ORDER BY created DESC LIMIT -1 OFFSET 1000)")
            self.db.commit()

    def enqueue(self, video, parent):
        if not isinstance(video, str) or not VIDEO.fullmatch(video):
            return
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO review_queue VALUES (?, ?, ?)", (video, parent, time.time()))
            self.db.execute("DELETE FROM review_queue WHERE created < ?", (time.time() - 86400,))
            self.db.execute("DELETE FROM review_queue WHERE rowid IN (SELECT rowid FROM review_queue ORDER BY created DESC LIMIT -1 OFFSET 200)")
            self.db.commit()

    def review_queue(self):
        with self.lock:
            self.db.execute("DELETE FROM review_queue WHERE created < ?", (time.time() - 86400,))
            self.db.commit()
            return [{"url": f"https://www.youtube.com/watch?v={v}", "proposedParent": p}
                    for v, p in self.db.execute("SELECT video,parent FROM review_queue ORDER BY created DESC")]

    def consume(self, kind, limit, cost=1):
        # Conservative rolling UTC bucket; deployment may set a lower budget.
        day = time.strftime("%Y-%m-%d", time.gmtime())
        with self.lock:
            self.db.execute("DELETE FROM budget WHERE day <> ?", (day,))
            row = self.db.execute("SELECT calls FROM budget WHERE day=? AND kind=?", (day, kind)).fetchone()
            if (row[0] if row else 0) + cost > limit:
                return False
            self.db.execute("INSERT INTO budget VALUES (?, ?, ?) ON CONFLICT(day,kind) DO UPDATE SET calls=calls+excluded.calls", (day, kind, cost))
            self.db.commit()
            return True


class Discovery:
    def __init__(self, registry, cache, tmdb_token="", youtube_key="", fetch=fetch_json):
        self.publishers, self.associations = load_registry(registry)
        self.registry_hash = hashlib.sha256(Path(registry).read_bytes()).hexdigest()
        self.cache, self.tmdb_token, self.youtube_key, self.fetch = cache, tmdb_token, youtube_key, fetch
        self.lock = threading.Lock()  # Coalesce cache misses and protect quota globally.

    def google(self, resource, **params):
        if not self.youtube_key:
            raise ValueError("YouTube metadata credentials unavailable")
        if not self.cache.consume("youtube_units", int(os.getenv("EXTRAS_YOUTUBE_DAILY_UNITS", "9000")), 100 if resource == "search" else 1):
            raise ValueError("YouTube budget exhausted")
        return self.fetch("https://www.googleapis.com/youtube/v3/" + resource + "?" + urllib.parse.urlencode({**params, "key": self.youtube_key}))

    def discover(self, request):
        raw = request.get("identities", [])
        if not isinstance(raw, list) or len(raw) > 16:
            raise ValueError("Invalid identity list")
        identities = sorted({i for i in raw if isinstance(i, str) and (IDENTITY.fullmatch(i) or EXTERNAL.fullmatch(i))})[:6]
        if not identities:
            return {"version": 1, "entries": [], "partial": False}
        language, region = request.get("language", "en"), request.get("region", "US")
        if not isinstance(language, str) or not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z]{2})?", language):
            language = "en"
        if not isinstance(region, str) or not re.fullmatch(r"[A-Z]{2}", region):
            region = "US"
        expand = request.get("expand") is True
        analysis = request.get("includeAnalysis") is True
        query = request.get("query", "")
        query = query[:200].strip() if isinstance(query, str) else ""
        # Keys include registry/policy, locale/region and requested search scope.
        key = hashlib.sha256(json.dumps([self.registry_hash, identities, language, region, expand, analysis, query]).encode()).hexdigest()
        with self.lock:
            cached = self.cache.get(key)
            if cached is not None:
                return cached
            canonical, aliases, failed = self.resolve(identities)
            if len(canonical) != 1:
                return {"version": 1, "entries": [], "partial": failed}
            result = self._discover(canonical, language, region, expand, analysis, query)
            result["partial"] = result["partial"] or failed
            for entry in result["entries"]:
                entry["parents"] = sorted(set(entry["parents"]) | {alias for alias, parent in aliases.items() if parent in entry["parents"]})
            if not result["partial"]:
                self.cache.put(key, result)
            return result

    def resolve(self, identities):
        canonical = sorted(i for i in identities if IDENTITY.fullmatch(i))
        if canonical:
            return canonical, {}, False
        aliases, failed = {}, False
        if not self.tmdb_token:
            return [], {}, True
        for identity in identities:
            match = EXTERNAL.fullmatch(identity)
            if not match:
                continue
            kind, external = match.groups()
            source, value = external.split(":", 1)
            try:
                if not self.cache.consume("catalog", 8000):
                    raise ValueError("Catalogue budget exhausted")
                response = self.fetch("https://api.themoviedb.org/3/find/" + value + "?" +
                    urllib.parse.urlencode({"external_source": source + "_id"}),
                    {"Authorization": f"Bearer {self.tmdb_token}"})
                results = response.get("movie_results" if kind == "movie" else "tv_results", [])
                if len(results) == 1 and type(results[0].get("id")) is int and results[0]["id"] > 0:
                    aliases[identity] = f'{kind}/tmdb:{results[0]["id"]}'
            except (ValueError, OSError, KeyError, TypeError, AttributeError):
                failed = True
        return sorted(set(aliases.values())), aliases, failed

    def _discover(self, identities, language, region, expand, analysis, query):
        # Missing catalogue credentials still permit reviewed links, but must
        # not turn an incomplete lookup into a 24-hour cached empty success.
        candidates, partial = {}, not bool(self.tmdb_token and self.youtube_key)
        for video_id, reviewed in self.associations.items():
            if set(identities).intersection(reviewed["parents"]):
                candidates[video_id] = dict(reviewed)
        titles = []
        if self.tmdb_token:
            for identity in identities:
                match = IDENTITY.fullmatch(identity)
                kind, number = match.groups()
                path = "movie" if kind == "movie" else "tv"
                try:
                    if not self.cache.consume("catalog", 8000):
                        raise ValueError("Catalogue budget exhausted")
                    detail = self.fetch(f"https://api.themoviedb.org/3/{path}/{number}?" + urllib.parse.urlencode({
                        "append_to_response": "videos", "language": language, "include_video_language": f"{language.split('-')[0]},en,null"}),
                        {"Authorization": f"Bearer {self.tmdb_token}"})
                    if detail.get("id") != int(number):
                        continue
                    title = detail.get("title") or detail.get("name")
                    if isinstance(title, str):
                        titles.append(title)
                    videos = detail.get("videos", {}).get("results", [])
                    if expand:
                        # A separate unfiltered-language request finds more
                        # catalogue-associated extras without broadening trust.
                        if not self.cache.consume("catalog", 8000):
                            raise ValueError("Catalogue budget exhausted")
                        extra = self.fetch(f"https://api.themoviedb.org/3/{path}/{number}/videos",
                            {"Authorization": f"Bearer {self.tmdb_token}"})
                        videos = videos + extra.get("results", [])
                    for video in videos[:160]:
                        video_id = video.get("key", "")
                        category = KINDS.get(video.get("type"))
                        if video.get("site") != "YouTube" or not VIDEO.fullmatch(video_id) or category is None:
                            continue
                        if video_id not in candidates:
                            candidates[video_id] = {"videoId": video_id, "parents": [identity], "kind": category, "catalogAssociated": True}
                except (ValueError, OSError, KeyError, TypeError, AttributeError):
                    partial = True
        # Search is explicitly requested, channel-scoped and independently
        # budgeted. A search hit NEVER creates its own work association.
        if expand and self.youtube_key and titles:
            for channel in list(self.publishers)[:2]:
                if not self.cache.consume("search", int(os.getenv("EXTRAS_SEARCH_DAILY_LIMIT", "80"))):
                    partial = True
                    break
                try:
                    found = self.google("search", part="snippet", type="video", channelId=channel,
                        q=f'{titles[0]} {query or "making of behind the scenes"}', maxResults=20,
                        relevanceLanguage=language.split('-')[0], regionCode=region, safeSearch="strict")
                    for item in found.get("items", [])[:20]:
                        video_id = item.get("id", {}).get("videoId")
                        # Unknown hits are operator review candidates only;
                        # they never enter the client response or shared feed.
                        if isinstance(video_id, str) and video_id not in candidates:
                            self.cache.enqueue(video_id, identities[0])
                        reviewed = self.associations.get(video_id)
                        if reviewed and set(identities).intersection(reviewed["parents"]):
                            candidates[video_id] = dict(reviewed)
                except (ValueError, OSError, KeyError, TypeError, AttributeError):
                    partial = True
        entries = []
        if candidates and not self.youtube_key:
            return {"version": 1, "entries": [], "partial": True}
        video_ids = sorted(candidates)[:80]
        for offset in range(0, len(video_ids), 40):
            try:
                if not self.cache.consume("metadata", 8000):
                    raise ValueError("Metadata budget exhausted")
                response = self.google("videos", part="snippet,status,contentDetails", id=",".join(video_ids[offset:offset + 40]))
                for video in response.get("items", []):
                    entry = self.normalize(video, candidates, region, analysis)
                    if entry:
                        entries.append(entry)
            except (ValueError, OSError, KeyError, TypeError, AttributeError):
                partial = True
        return {"version": 1, "entries": entries, "partial": partial}

    def normalize(self, video, candidates, region, include_analysis):
        video_id = video.get("id")
        association = candidates.get(video_id)
        if not association:
            return None
        snippet, status, details = video.get("snippet", {}), video.get("status", {}), video.get("contentDetails", {})
        if status.get("privacyStatus") != "public" or status.get("uploadStatus") != "processed":
            return None
        restrictions = details.get("regionRestriction", {})
        if region in restrictions.get("blocked", []) or ("allowed" in restrictions and region not in restrictions["allowed"]):
            return None
        if details.get("contentRating", {}).get("ytRating") == "ytAgeRestricted":
            return None
        publisher = self.publishers.get(snippet.get("channelId"))
        reviewed = bool(association.get("reviewedBy"))
        if not reviewed and not (publisher and association.get("catalogAssociated")):
            return None
        category = association["kind"]
        if category == "analysis" and not include_analysis:
            return None
        # A reviewed publisher ID, when supplied, binds the reviewed link to
        # that uploader. Replacement uploads cannot inherit approval.
        if association.get("publisherId") and association["publisherId"] != snippet.get("channelId"):
            return None
        duration = re.fullmatch(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", details.get("duration", ""))
        seconds = sum(int(v or 0) * scale for v, scale in zip(duration.groups(), (3600, 60, 1))) if duration else None
        return {"id": f"youtube:{video_id}", "parents": association["parents"], "kind": category,
            "origin": "reviewed" if reviewed else "catalog", "scope": association.get("scope", "work"),
            "scopeLabel": association.get("scopeLabel", ""), "title": snippet.get("title", ""),
            "publisherId": snippet.get("channelId", ""), "publisher": snippet.get("channelTitle", ""),
            "url": f"https://www.youtube.com/watch?v={video_id}", "verifiedPublisher": bool(publisher),
            "catalogAssociated": association.get("catalogAssociated", False), "reviewedAssociation": reviewed,
            "spoilerSafe": association.get("spoilerSafe", False), "available": True,
            "language": snippet.get("defaultAudioLanguage", snippet.get("defaultLanguage", "")),
            "durationSeconds": seconds, "thumbnailUrl": snippet.get("thumbnails", {}).get("medium", {}).get("url"),
            "description": association.get("description", ""), "contentGroup": association.get("contentGroup", ""),
            "analysisAllowed": association.get("analysisAllowed", False), "passages": association.get("passages", [])}


def handler_for(discovery, token):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(15)
            super().setup()

        def log_message(self, _format, *_args):
            pass  # Do not log headers, bearer credentials or title queries.

        def reply(self, status, body):
            encoded = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            try:
                self.wfile.write(encoded)
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass

        def do_GET(self):
            self.reply(200 if self.path == "/health" else 404, {"version": 1, "service": "pleazyng-extras"})

        def do_POST(self):
            if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token):
                self.reply(401, {"error": "unauthorized"})
                return
            if self.path != "/v1/discover":
                self.reply(404, {"error": "not_found"})
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if size < 1 or size > MAX_BODY:
                    self.reply(413, {"error": "invalid_size"})
                    return
                self.connection.settimeout(15)
                request = json.loads(self.rfile.read(size))
                if not isinstance(request, dict) or not isinstance(request.get("identities", []), list):
                    raise ValueError("Invalid request")
                self.reply(200, discovery.discover(request))
            except (ValueError, TypeError, OSError, AttributeError):
                self.reply(400, {"error": "invalid_request"})
    return Handler


class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(*args, **kwargs)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--database", default="extras-cache.sqlite3")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8792)
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--review-queue", action="store_true")
    args = parser.parse_args()
    load_registry(args.registry)
    if args.validate:
        print("Registry valid")
        return
    if args.review_queue:
        print(json.dumps(Cache(args.database).review_queue(), ensure_ascii=False, indent=2))
        return
    token = os.getenv("EXTRAS_SERVICE_TOKEN", "")
    if len(token) < 24:
        parser.error("EXTRAS_SERVICE_TOKEN must contain at least 24 characters")
    discovery = Discovery(args.registry, Cache(args.database), os.getenv("TMDB_ACCESS_TOKEN", ""), os.getenv("YOUTUBE_API_KEY", ""))
    BoundedServer((args.host, args.port), handler_for(discovery, token)).serve_forever()


if __name__ == "__main__":
    main()
