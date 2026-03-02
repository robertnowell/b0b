#!/usr/bin/env python3
"""Robustness tests for gh-poll-process.py.

Covers: empty inputs, missing keys, malformed URLs, deduplication,
and state-file updates.
"""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("gh-poll-process.py")


def run_poll(state: dict, issue_comments: list, review_comments: list) -> tuple[list[dict], dict]:
    """Run gh-poll-process.py and return (output_lines, updated_state)."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as sf:
        json.dump(state, sf)
        state_path = sf.name
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as ic:
        json.dump(issue_comments, ic)
        ic_path = ic.name
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as rc:
        json.dump(review_comments, rc)
        rc_path = rc.name

    result = subprocess.run(
        ["python3", str(SCRIPT_PATH), state_path, "2026-03-01T00:00:00Z", ic_path, rc_path],
        capture_output=True,
        text=True,
        check=True,
    )

    lines = []
    for raw in result.stdout.strip().splitlines():
        if raw.strip():
            lines.append(json.loads(raw))

    with open(state_path) as f:
        updated_state = json.load(f)

    # Cleanup
    Path(state_path).unlink(missing_ok=True)
    Path(ic_path).unlink(missing_ok=True)
    Path(rc_path).unlink(missing_ok=True)

    return lines, updated_state


def make_comment(cid: int, body: str, issue_url: str = "https://api.github.com/repos/o/r/issues/42",
                 user: dict | None = None) -> dict:
    c = {
        "id": cid,
        "body": body,
        "issue_url": issue_url,
        "html_url": f"https://github.com/o/r/issues/42#issuecomment-{cid}",
        "created_at": "2026-03-01T00:00:00Z",
    }
    if user is not None:
        c["user"] = user
    else:
        c["user"] = {"login": "testuser"}
    return c


def make_review_comment(cid: int, body: str,
                        pr_url: str = "https://api.github.com/repos/o/r/pulls/99",
                        user: dict | None = None) -> dict:
    c = {
        "id": cid,
        "body": body,
        "pull_request_url": pr_url,
        "html_url": f"https://github.com/o/r/pull/99#discussion_r{cid}",
        "created_at": "2026-03-01T00:00:00Z",
    }
    if user is not None:
        c["user"] = user
    else:
        c["user"] = {"login": "testuser"}
    return c


class TestEmptyInputs(unittest.TestCase):
    def test_empty_comment_lists(self):
        lines, state = run_poll({"seenCommentIds": []}, [], [])
        self.assertEqual(lines, [])
        self.assertIn("lastChecked", state)


class TestMissingKeys(unittest.TestCase):
    def test_comment_missing_id(self):
        comment = {"body": "@kopi-claw hello"}
        lines, state = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertEqual(lines, [])
        self.assertEqual(state["seenCommentIds"], [])

    def test_comment_body_none(self):
        comment = {
            "id": 150,
            "body": None,
            "issue_url": "https://api.github.com/repos/o/r/issues/10",
            "html_url": "https://github.com/o/r/issues/10#issuecomment-150",
            "created_at": "2026-03-01T00:00:00Z",
            "user": {"login": "someone"},
        }
        lines, state = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertEqual(lines, [])
        self.assertEqual(state["seenCommentIds"], [])

    def test_comment_missing_user(self):
        comment = {
            "id": 100,
            "body": "@kopi-claw fix this",
            "issue_url": "https://api.github.com/repos/o/r/issues/10",
            "html_url": "https://github.com/o/r/issues/10#issuecomment-100",
            "created_at": "2026-03-01T00:00:00Z",
        }
        lines, _ = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["author"], "unknown")

    def test_comment_missing_body(self):
        comment = {
            "id": 200,
            "issue_url": "https://api.github.com/repos/o/r/issues/10",
            "html_url": "https://github.com/o/r/issues/10#issuecomment-200",
            "created_at": "2026-03-01T00:00:00Z",
            "user": {"login": "someone"},
        }
        lines, _ = run_poll({"seenCommentIds": []}, [comment], [])
        # Body doesn't contain MENTION, so should be skipped
        self.assertEqual(len(lines), 0)


class TestMalformedUrls(unittest.TestCase):
    def test_malformed_issue_url(self):
        comment = make_comment(300, "@kopi-claw test", issue_url="not-a-url")
        lines, _ = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["number"], "unknown")

    def test_empty_issue_url(self):
        comment = make_comment(301, "@kopi-claw test", issue_url="")
        lines, _ = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["number"], "unknown")

    def test_non_numeric_url_segment(self):
        comment = make_comment(302, "@kopi-claw test",
                               issue_url="https://api.github.com/repos/o/r/issues/abc")
        lines, _ = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["number"], "unknown")

    def test_valid_numeric_url(self):
        comment = make_comment(303, "@kopi-claw test",
                               issue_url="https://api.github.com/repos/o/r/issues/42")
        lines, _ = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["number"], "42")


class TestDeduplication(unittest.TestCase):
    def test_same_comment_id_twice(self):
        comment = make_comment(400, "@kopi-claw hello")
        lines, _ = run_poll({"seenCommentIds": []}, [comment, comment], [])
        # Only the first occurrence should produce output
        self.assertEqual(len(lines), 1)

    def test_already_seen_id_skipped(self):
        comment = make_comment(500, "@kopi-claw hello")
        lines, _ = run_poll({"seenCommentIds": [500]}, [comment], [])
        self.assertEqual(len(lines), 0)


class TestStateFileUpdate(unittest.TestCase):
    def test_new_ids_persisted(self):
        comment = make_comment(600, "@kopi-claw test")
        _, state = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertIn(600, state["seenCommentIds"])

    def test_lastchecked_updated(self):
        _, state = run_poll({"seenCommentIds": []}, [], [])
        self.assertEqual(state["lastChecked"], "2026-03-01T00:00:00Z")


class TestIsPRField(unittest.TestCase):
    def test_issue_comment_on_issue_is_not_pr(self):
        comment = make_comment(800, "@kopi-claw test",
                               issue_url="https://api.github.com/repos/o/r/issues/42")
        lines, _ = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertEqual(len(lines), 1)
        self.assertFalse(lines[0]["isPR"])

    def test_issue_comment_on_pull_is_pr(self):
        comment = make_comment(801, "@kopi-claw test",
                               issue_url="https://api.github.com/repos/o/r/pulls/42")
        lines, _ = run_poll({"seenCommentIds": []}, [comment], [])
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0]["isPR"])

    def test_review_comment_always_pr(self):
        rc = make_review_comment(802, "@kopi-claw test")
        lines, _ = run_poll({"seenCommentIds": []}, [], [rc])
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0]["isPR"])


class TestReviewComments(unittest.TestCase):
    def test_review_comment_processed(self):
        rc = make_review_comment(700, "@kopi-claw fix this")
        lines, _ = run_poll({"seenCommentIds": []}, [], [rc])
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["type"], "review_comment")
        self.assertEqual(lines[0]["number"], "99")

    def test_review_comment_non_numeric_url(self):
        rc = make_review_comment(701, "@kopi-claw fix this",
                                 pr_url="https://api.github.com/repos/o/r/pulls/xyz")
        lines, _ = run_poll({"seenCommentIds": []}, [], [rc])
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["number"], "unknown")


if __name__ == "__main__":
    unittest.main()
