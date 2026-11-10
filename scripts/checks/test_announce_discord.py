"""Verify safe release delivery and resumable receipts without sending messages."""

import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import announce_discord as discord

spec = importlib.util.spec_from_file_location("discord_release_publisher", ROOT / "scripts/release_all_platforms.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def release(body="First release note"):
    return {"id": 42, "tag_name": "v3.0.0", "body": body,
            "html_url": "https://github.com/snapetech-org/pleazyng/releases/tag/v3.0.0",
            "draft": False, "prerelease": False, "published_at": "2026-11-05T06:48:35Z", "assets": []}


class DiscordDeliveryTest(unittest.TestCase):
    def test_full_release_notes_are_preserved_across_chunks(self):
        body = ("### Changes\n- A release change with Unicode: café.\n" * 200)
        chunks = discord.split_description(body)
        self.assertGreater(len(chunks), 1)
        self.assertEqual("".join(chunks), body)
        self.assertTrue(all(len(chunk) <= discord.MAX_EMBED_DESCRIPTION for chunk in chunks))

    def test_post_suppresses_mentions_and_requires_confirmation(self):
        response = io.BytesIO(json.dumps({"id": "123", "channel_id": "456",
                "embeds": [{"description": "@everyone notes"}]}).encode())
        with patch.object(discord, "safe_urlopen", return_value=response) as send:
            result = discord.post("https://discord.com/api/webhooks/example/test?wait=true", "Release", "https://example.com", "@everyone notes\n\n")
        payload = json.loads(send.call_args.args[0].data)
        self.assertEqual(send.call_args.args[0].get_header("User-agent"), discord.USER_AGENT)
        self.assertEqual(payload["allowed_mentions"], {"parse": []})
        self.assertEqual(result, {"id": "123", "channel_id": "456"})
        with patch.object(discord, "safe_urlopen", return_value=io.BytesIO(b'{}')):
            with self.assertRaisesRegex(RuntimeError, "confirm"):
                discord.post("https://example.com", "Release", "https://example.com", "notes")

    def test_receipt_written_before_post_and_completed_retry_does_not_repost(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / discord.RECEIPT_NAME
            uploads = []

            def gh(*args):
                if args[:2] == ("release", "upload"):
                    uploads.append(json.loads(target.read_text()))

            def post(*args):
                self.assertEqual(uploads[-1]["in_flight_chunk"], 0)
                return {"id": "123", "channel_id": "456"}

            with patch.object(discord, "gh", side_effect=gh), patch.object(discord, "post", side_effect=post) as send:
                receipt = discord.announce(release(), "unused", target)
                self.assertEqual(send.call_count, 1)
                self.assertIsNone(receipt["in_flight_chunk"])
                existing = {**release(), "assets": [{"name": discord.RECEIPT_NAME}]}
                discord.announce(existing, "unused", target)
                self.assertEqual(send.call_count, 1)

    def test_uncertain_delivery_stops_retry_without_a_second_post(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / discord.RECEIPT_NAME
            with patch.object(discord, "gh"), patch.object(discord, "post", side_effect=RuntimeError("network interrupted")) as send:
                with self.assertRaisesRegex(RuntimeError, "network interrupted"):
                    discord.announce(release(), "unused", target)
                existing = {**release(), "assets": [{"name": discord.RECEIPT_NAME}]}
                with self.assertRaisesRegex(RuntimeError, "uncertain"):
                    discord.announce(existing, "unused", target)
                self.assertEqual(send.call_count, 1)

    def test_definite_rejection_can_be_retried_after_fixing_the_client(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / discord.RECEIPT_NAME
            with patch.object(discord, "gh"), patch.object(discord, "post", side_effect=discord.RejectedPost("HTTP 403")):
                with self.assertRaises(discord.RejectedPost):
                    discord.announce(release(), "unused", target)
            self.assertIsNone(json.loads(target.read_text())["in_flight_chunk"])
            existing = {**release(), "assets": [{"name": discord.RECEIPT_NAME}]}
            with patch.object(discord, "gh"), patch.object(discord, "post", return_value={"id": "123", "channel_id": "456"}) as send:
                discord.announce(existing, "unused", target)
                self.assertEqual(send.call_count, 1)

    def test_partial_confirmed_delivery_resumes_only_remaining_chunks(self):
        value = release("a" * (discord.MAX_EMBED_DESCRIPTION + 10))
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / discord.RECEIPT_NAME
            with patch.object(discord, "gh"), patch.object(discord, "post", return_value={"id": "123", "channel_id": "456"}), patch.object(discord.time, "sleep", side_effect=RuntimeError("interrupted after first confirmation")):
                with self.assertRaises(RuntimeError):
                    discord.announce(value, "unused", target)
            value["assets"] = [{"name": discord.RECEIPT_NAME}]
            with patch.object(discord, "gh"), patch.object(discord, "post", return_value={"id": "789", "channel_id": "456"}) as send:
                discord.announce(value, "unused", target)
                self.assertEqual(send.call_count, 1)
                self.assertEqual(send.call_args.args[-1], "a" * 10)

    def test_changed_notes_require_review_instead_of_reposting(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / discord.RECEIPT_NAME
            with patch.object(discord, "gh"), patch.object(discord, "post", return_value={"id": "123", "channel_id": "456"}):
                discord.announce(release(), "unused", target)
            changed = {**release("different notes"), "assets": [{"name": discord.RECEIPT_NAME}]}
            with patch.object(discord, "gh"), patch.object(discord, "post") as send:
                with self.assertRaisesRegex(RuntimeError, "changed"):
                    discord.announce(changed, "unused", target)
                send.assert_not_called()

    def test_owner_confirmed_first_page_is_not_posted_again(self):
        value = release("a" * (discord.MAX_EMBED_DESCRIPTION + 10))
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / discord.RECEIPT_NAME
            with patch.object(discord, "gh"), patch.object(discord, "post", return_value={"id": "123", "channel_id": "456"}), patch.object(discord.time, "sleep", side_effect=RuntimeError("stop")):
                with self.assertRaises(RuntimeError):
                    discord.announce(value, "unused", target)
            receipt = json.loads(target.read_text())
            receipt["messages"] = [{"owner_confirmed": True, "chunk_index": 0, "evidence_run_id": 42}]
            target.write_text(json.dumps(receipt))
            value["assets"] = [{"name": discord.RECEIPT_NAME}]
            with patch.object(discord, "gh"), patch.object(discord, "post", return_value={"id": "789", "channel_id": "456"}) as send:
                discord.announce(value, "unused", target)
                self.assertEqual(send.call_count, 1)
                self.assertEqual(send.call_args.args[-1], "a" * 10)

    def test_project_link_retry_keeps_confirmed_changelog_chunks(self):
        project = ("unused", (discord.route.CHANGELOG_GUILD, "123"))
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / discord.CHANGELOG_RECEIPT_NAME
            with patch.object(discord, "gh"), patch.object(discord, "post", return_value={
                "id": "456", "channel_id": discord.route.CHANGELOG_CHANNEL
            }) as send_notes, patch.object(discord.route, "post", side_effect=[
                discord.route.RejectedPost("Discord returned HTTP 403."),
                f"https://discord.com/channels/{discord.route.CHANGELOG_GUILD}/123/789",
            ]) as send_pointer:
                with self.assertRaises(discord.route.RejectedPost):
                    discord.announce(release(), "unused", target, project_route=project)
                first = json.loads(target.read_text())
                self.assertEqual(len(first["messages"]), 1)
                self.assertFalse(first["in_flight_project_message"])
                existing = release()
                existing["assets"] = [{"name": discord.CHANGELOG_RECEIPT_NAME}]
                receipt = discord.announce(existing, "unused", target, project_route=project)
                discord.announce(existing, "unused", target, project_route=project)
                self.assertEqual(send_notes.call_count, 1)
                self.assertEqual(send_pointer.call_count, 2)
                self.assertIn("/123/789", receipt["project_message"])
                payload = send_pointer.call_args.args[2]
                self.assertEqual(payload["flags"], 4)
                self.assertIn(f"/{discord.route.CHANGELOG_CHANNEL}/456", payload["content"])

    def test_unpublished_prerelease_or_foreign_release_never_posts(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / "release.json"
            for change in ({"draft": True}, {"prerelease": True}, {"published_at": None},
                           {"html_url": "https://github.com/other/project/releases/tag/v3.0.0"}):
                event.write_text(json.dumps({**release(), **change}))
                with patch.dict(os.environ, {"DISCORD_RELEASE_WEBHOOK": "https://discord.com/api/webhooks/example/test", "RELEASE_JSON_PATH": str(event)}), patch.object(discord, "announce") as send:
                    self.assertEqual(discord.main(), 1)
                    send.assert_not_called()

    def test_publication_explicitly_dispatches_notification_for_bot_tokens_too(self):
        for draft in (True, False):
            with self.subTest(draft=draft), patch.object(publisher, "release_metadata", side_effect=[{**release(), "draft": draft}, release()]), patch.object(publisher, "command") as command:
                publisher.publish_github_release("v3.0.0")
                self.assertFalse(any(call.args[0][:3] == ["gh", "workflow", "run"] for call in command.call_args_list))
                with patch.object(publisher, "dispatch_automatic_play", return_value=None):
                    publisher.post_release_actions("v3.0.0", "3.0.0", release_sha="a" * 40,
                        include_webos_release=True, publish_channels=False)
                dispatch = command.call_args.args[0]
                self.assertEqual(dispatch[:4], ["gh", "workflow", "run", "discord-release.yml"])
                self.assertIn("release_tag=v3.0.0", dispatch)
                self.assertIn("runner_pool=hosted", dispatch)


if __name__ == "__main__":
    unittest.main()
