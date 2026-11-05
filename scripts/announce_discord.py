#!/usr/bin/env python3
"""Announce a published stable release, including its generated release notes."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request

try:
    from maestro.safe_http import safe_urlopen
except ModuleNotFoundError:
    from scripts.maestro.safe_http import safe_urlopen


MAX_EMBED_DESCRIPTION = 3500
RECEIPT_NAME = "discord-announcement-receipt.json"
REPOSITORY = "snapetech-org/PlezyNG"
USER_AGENT = "DiscordBot (https://github.com/snapetech-org/PlezyNG, 1.0)"


class RejectedPost(RuntimeError):
    """Discord definitively rejected a request without creating a message."""


def split_description(text: str) -> list[str]:
    chunks: list[str] = []
    remaining = text
    while len(remaining) > MAX_EMBED_DESCRIPTION:
        boundary = remaining.rfind("\n", 0, MAX_EMBED_DESCRIPTION + 1)
        if boundary >= 0:
            boundary += 1
        else:
            boundary = remaining.rfind(" ", 0, MAX_EMBED_DESCRIPTION + 1)
            if boundary >= 0:
                boundary += 1
        if boundary <= 0:
            boundary = MAX_EMBED_DESCRIPTION
        chunks.append(remaining[:boundary])
        remaining = remaining[boundary:]
    if remaining:
        chunks.append(remaining)
    return chunks


def with_wait_parameter(webhook_url: str) -> str:
    parsed = urlsplit(webhook_url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "discord.com"
        or not parsed.path.startswith("/api/webhooks/")
    ):
        raise ValueError("DISCORD_RELEASE_WEBHOOK must be a Discord webhook URL.")
    query = [(key, value) for key, value in parse_qsl(parsed.query) if key != "wait"]
    query.append(("wait", "true"))
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), parsed.fragment))


def post(webhook_url: str, title: str, release_url: str, description: str) -> dict:
    # Discord normalizes surrounding whitespace in embed descriptions.
    description = description.strip()
    payload = {
        "username": "PlezyNG Releases",
        "allowed_mentions": {"parse": []},
        "embeds": [
            {
                "title": title,
                "url": release_url,
                "description": description,
                "color": 5793266,
            }
        ],
    }
    request = Request(
        webhook_url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        method="POST",
    )
    try:
        with safe_urlopen(request, timeout=30) as response:
            result = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        detail = ""
        try:
            code = json.loads(error.read()).get("code")
            if isinstance(code, int):
                detail = f" (Discord code {code})"
        except (ValueError, AttributeError):
            pass
        failure = RejectedPost if error.code in {400, 401, 403, 404, 422, 429} else RuntimeError
        raise failure(f"Discord webhook returned HTTP {error.code}{detail}.") from None
    except URLError:
        raise RuntimeError("Could not reach the Discord webhook.") from None
    except json.JSONDecodeError:
        raise RuntimeError("Discord returned an invalid announcement response.") from None
    if not isinstance(result, dict):
        raise RuntimeError("Discord returned an invalid release announcement response.")
    embeds = result.get("embeds")
    if (
        not re.fullmatch(r"[0-9]+", str(result.get("id", "")))
        or not re.fullmatch(r"[0-9]+", str(result.get("channel_id", "")))
        or not isinstance(embeds, list)
        or not embeds
        or not isinstance(embeds[0], dict)
        or not isinstance(embeds[0].get("description"), str)
        or embeds[0]["description"].strip() != description
    ):
        if result.get("id") and result.get("channel_id"):
            print(f"Unverified response: Discord message {result['id']} in channel {result['channel_id']}.", file=sys.stderr)
        raise RuntimeError("Discord did not confirm the release announcement.")
    return {"id": result["id"], "channel_id": result["channel_id"]}


def gh(*arguments: str) -> None:
    try:
        subprocess.run(["gh", *arguments], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        raise RuntimeError("Could not read or persist the Discord delivery receipt on GitHub.") from None


def announce(release: dict, webhook_url: str, receipt_path: Path) -> dict:
    """Resume confirmed chunks; never automatically repeat an uncertain POST."""
    version = release["tag_name"]
    body = release.get("body") or "Release assets are available."
    chunks = split_description(body)
    identity = {"release_id": release["id"], "tag": version,
                "body_sha256": hashlib.sha256(body.encode()).hexdigest()}
    receipt = {**identity, "messages": [], "in_flight_chunk": None}
    if any(asset.get("name") == RECEIPT_NAME for asset in release.get("assets", [])):
        gh("release", "download", version, "--repo", REPOSITORY, "--pattern", RECEIPT_NAME,
           "--output", str(receipt_path), "--clobber")
        receipt = json.loads(receipt_path.read_text())
        if any(receipt.get(key) != value for key, value in identity.items()):
            raise RuntimeError("Release notes changed since Discord delivery; review the existing receipt before reannouncing.")
        if (not isinstance(receipt.get("messages"), list)
                or len(receipt["messages"]) > len(chunks)
                or any(not isinstance(message, dict) or not (
                    all(re.fullmatch(r"[0-9]+", str(message.get(key, "")))
                        for key in ("id", "channel_id"))
                    or (message.get("owner_confirmed") is True
                        and message.get("chunk_index") == index
                        and isinstance(message.get("evidence_run_id"), int)
                        and message["evidence_run_id"] > 0))
                    for index, message in enumerate(receipt["messages"]))):
            raise RuntimeError("Invalid Discord delivery receipt.")
        if receipt.get("in_flight_chunk") is not None:
            raise RuntimeError("Previous Discord delivery is uncertain; inspect its retained receipt and channel before retrying.")

    def save() -> None:
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        gh("release", "upload", version, str(receipt_path), "--repo", REPOSITORY, "--clobber")

    for index in range(len(receipt["messages"]), len(chunks)):
        receipt["in_flight_chunk"] = index
        save()
        suffix = f" ({index + 1}/{len(chunks)})" if len(chunks) > 1 else ""
        try:
            message = post(webhook_url, f"PlezyNG {version} is out{suffix}",
                           release["html_url"], chunks[index])
        except RejectedPost:
            receipt["in_flight_chunk"] = None
            save()
            raise
        receipt["messages"].append(message)
        receipt["in_flight_chunk"] = None
        save()
        if index + 1 < len(chunks):
            time.sleep(1)
    print(f"Confirmed {len(receipt['messages'])} Discord release-note messages for {version}.")
    for message in receipt["messages"]:
        if message.get("owner_confirmed"):
            print(f"Page {message['chunk_index'] + 1} confirmed visible by the owner after run {message['evidence_run_id']}.")
        else:
            print(f"Discord message {message['id']} in channel {message['channel_id']}")
    return receipt


def main() -> int:
    webhook_value = os.environ.get("DISCORD_RELEASE_WEBHOOK", "")
    if not webhook_value:
        print("DISCORD_RELEASE_WEBHOOK is required to announce a release.", file=sys.stderr)
        return 1
    release_path = os.environ.get("RELEASE_JSON_PATH") or os.environ.get("GITHUB_EVENT_PATH", "")
    if not release_path:
        print("RELEASE_JSON_PATH or GITHUB_EVENT_PATH is required.", file=sys.stderr)
        return 1

    try:
        event = json.loads(Path(release_path).read_text(encoding="utf-8"))
        release = event.get("release", event)
        if not isinstance(release, dict):
            raise ValueError("release event data is invalid")
        if release.get("draft") or release.get("prerelease") or not release.get("published_at"):
            raise ValueError("only published stable releases can be announced")
        version = release["tag_name"]
        release_url = release["html_url"]
        body = release.get("body") or "Release assets are available."
        if (not isinstance(version, str) or not re.fullmatch(r"v?\d+\.\d+\.\d+", version)
                or release_url != f"https://github.com/{REPOSITORY}/releases/tag/{version}"
                or not isinstance(body, str) or not isinstance(release.get("id"), int)):
            raise ValueError("release event data is incomplete")
        webhook_url = with_wait_parameter(webhook_value)
        receipt_path = Path(os.environ.get("DISCORD_RECEIPT_PATH", str(Path(release_path).with_name(RECEIPT_NAME))))
    except (OSError, KeyError, TypeError, ValueError) as error:
        print(f"release announcement: {error}", file=sys.stderr)
        return 1

    try:
        announce(release, webhook_url, receipt_path)
    except (RuntimeError, OSError, ValueError) as error:
        print(f"release announcement: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
