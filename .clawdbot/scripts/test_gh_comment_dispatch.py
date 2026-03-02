#!/usr/bin/env python3
"""Integration-style tests for gh-comment-dispatch.sh routing and safeguards.

Covers: authorization, dispatch limits, approval/rejection routing,
feedback routing, question/other notify-only paths, and bot self-skip.
"""

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).parent


def write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def make_comment(comment_id: int, number: int, author: str, body: str,
                 comment_type: str = "comment") -> str:
    return json.dumps(
        {
            "type": comment_type,
            "commentId": comment_id,
            "number": number,
            "author": author,
            "body": body,
            "url": f"https://example.test/comments/{comment_id}",
            "created": "2026-03-01T00:00:00Z",
            "isPR": True,
        }
    )


class TestGhCommentDispatch(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.scripts = self.root / "scripts"
        self.state = self.root / "state"
        self.scripts.mkdir(parents=True)
        self.state.mkdir(parents=True)

        (self.state / "active-tasks.json").write_text("[]\n", encoding="utf-8")

        shutil.copy2(SCRIPT_DIR / "config.sh", self.scripts / "config.sh")
        shutil.copy2(SCRIPT_DIR / "gh-comment-dispatch.sh", self.scripts / "gh-comment-dispatch.sh")

        write_exec(
            self.scripts / "gh-poll.sh",
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%b' \"${POLL_OUTPUT:-}\"\n",
        )
        write_exec(
            self.scripts / "gh-comment-classify.py",
            '#!/usr/bin/env python3\n'
            'import json, sys\n'
            'comment = json.load(sys.stdin)\n'
            'body = comment.get("body", "").lower()\n'
            'intent = "other"\n'
            'td = "Test description"\n'
            'if "approve" in body:\n'
            '    intent = "approval"\n'
            'elif "reject" in body:\n'
            '    intent = "rejection"\n'
            'elif "fix" in body or "add" in body:\n'
            '    intent = "action_request"\n'
            'elif "this pr" in body or "suggestion" in body:\n'
            '    intent = "feedback"\n'
            '    td = "Feedback on PR"\n'
            'elif body.rstrip().endswith("?"):\n'
            '    intent = "question"\n'
            '    td = "User question"\n'
            'print(json.dumps({\n'
            '    "intent": intent,\n'
            '    "taskDescription": td,\n'
            '    "productGoal": td if intent == "action_request" else "",\n'
            '    "confidence": "high"\n'
            '}))\n',
        )
        write_exec(
            self.scripts / "dispatch.sh",
            "#!/usr/bin/env bash\nset -euo pipefail\necho \"$*\" >> \"${DISPATCH_LOG:?}\"\n",
        )
        write_exec(
            self.scripts / "approve-plan.sh",
            "#!/usr/bin/env bash\nset -euo pipefail\necho \"$*\" >> \"${APPROVE_LOG:?}\"\n",
        )
        write_exec(
            self.scripts / "reject-plan.sh",
            "#!/usr/bin/env bash\nset -euo pipefail\necho \"$*\" >> \"${REJECT_LOG:?}\"\n",
        )
        write_exec(
            self.scripts / "notify.sh",
            "#!/usr/bin/env bash\nnotify(){ echo \"$*\" >> \"${NOTIFY_LOG:?}\"; }\n",
        )

        self.dispatch_log = self.root / "dispatch.log"
        self.approve_log = self.root / "approve.log"
        self.reject_log = self.root / "reject.log"
        self.notify_log = self.root / "notify.log"

    def tearDown(self):
        self.tempdir.cleanup()

    def _write_tasks(self, tasks: list) -> None:
        (self.state / "active-tasks.json").write_text(
            json.dumps(tasks, indent=2) + "\n", encoding="utf-8"
        )

    def run_dispatch(self, poll_output: str, allowed_users: str = "trusted",
                     max_dispatches: str = "3") -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env.update(
            {
                "CLAWDBOT_STATE_DIR": str(self.state),
                "GH_COMMENT_ALLOWED_USERS": allowed_users,
                "GH_COMMENT_MAX_DISPATCHES": max_dispatches,
                "GH_COMMENT_DEFAULT_AGENT": "claude",
                "GH_COMMENT_REQUIRE_PLAN_REVIEW": "true",
                "POLL_OUTPUT": poll_output,
                "DISPATCH_LOG": str(self.dispatch_log),
                "APPROVE_LOG": str(self.approve_log),
                "REJECT_LOG": str(self.reject_log),
                "NOTIFY_LOG": str(self.notify_log),
            }
        )
        return subprocess.run(
            ["bash", str(self.scripts / "gh-comment-dispatch.sh")],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )

    # --- Authorization ---

    def test_unauthorized_user_cannot_dispatch(self):
        comment = make_comment(11, 321, "untrusted", "@kopi-claw fix tests")
        self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertFalse(self.dispatch_log.exists(),
                         "dispatch should not run for unauthorized users")
        notify_out = self.notify_log.read_text(encoding="utf-8")
        self.assertIn("unauthorized user untrusted", notify_out)

    def test_authorized_user_can_dispatch(self):
        comment = make_comment(12, 100, "trusted", "@kopi-claw fix tests")
        self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertTrue(self.dispatch_log.exists(),
                        "dispatch should run for authorized users")

    def test_unauthorized_approval_blocked(self):
        self._write_tasks([{"id": "gh-100-task", "phase": "plan_review",
                            "sourceNumber": "100"}])
        comment = make_comment(20, 100, "stranger", "@kopi-claw approve")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertFalse(self.approve_log.exists(),
                         "approve should not run for unauthorized users")
        self.assertIn("unauthorized approval", result.stdout.lower())

    def test_unauthorized_rejection_blocked(self):
        self._write_tasks([{"id": "gh-100-task", "phase": "plan_review",
                            "sourceNumber": "100"}])
        comment = make_comment(21, 100, "stranger", "@kopi-claw reject")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertFalse(self.reject_log.exists(),
                         "reject should not run for unauthorized users")
        self.assertIn("unauthorized rejection", result.stdout.lower())

    # --- Dispatch limit ---

    def test_overflow_is_queued_and_retried(self):
        c1 = make_comment(101, 500, "trusted", "@kopi-claw fix tests")
        c2 = make_comment(102, 500, "trusted", "@kopi-claw add logging")
        queue_file = self.state / "gh-comment-queue.jsonl"

        self.run_dispatch(c1 + "\n" + c2 + "\n", allowed_users="trusted",
                          max_dispatches="1")
        first_cycle_dispatches = (self.dispatch_log.read_text(encoding="utf-8")
                                  .strip().splitlines())
        self.assertEqual(len(first_cycle_dispatches), 1)
        self.assertTrue(queue_file.exists(),
                        "overflow comments should persist to queue")
        self.assertIn("\"commentId\": 102",
                       queue_file.read_text(encoding="utf-8"))

        self.run_dispatch("", allowed_users="trusted", max_dispatches="1")
        all_dispatches = (self.dispatch_log.read_text(encoding="utf-8")
                          .strip().splitlines())
        self.assertEqual(len(all_dispatches), 2)
        self.assertFalse(queue_file.exists(),
                         "queue should be drained after successful retry")

    def test_dispatch_limit_zero_queues_everything(self):
        comment = make_comment(200, 300, "trusted", "@kopi-claw fix tests")
        queue_file = self.state / "gh-comment-queue.jsonl"

        self.run_dispatch(comment + "\n", allowed_users="trusted",
                          max_dispatches="0")
        self.assertFalse(self.dispatch_log.exists(),
                         "nothing should be dispatched when limit is 0")
        self.assertTrue(queue_file.exists(), "comment should be queued")

    # --- Approval routing ---

    def test_approval_calls_approve_plan(self):
        self._write_tasks([{"id": "gh-42-feature", "phase": "plan_review",
                            "sourceNumber": "42"}])
        comment = make_comment(30, 42, "trusted", "@kopi-claw approve")
        self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertTrue(self.approve_log.exists(),
                        "approve-plan.sh should be called")
        approve_out = self.approve_log.read_text(encoding="utf-8")
        self.assertIn("gh-42-feature", approve_out)

    def test_approval_no_matching_task_notifies(self):
        comment = make_comment(31, 999, "trusted", "@kopi-claw approve")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertFalse(self.approve_log.exists(),
                         "approve-plan.sh should not be called without a task")
        self.assertIn("no matching task", result.stdout.lower())

    # --- Rejection routing ---

    def test_rejection_calls_reject_plan(self):
        self._write_tasks([{"id": "gh-42-feature", "phase": "plan_review",
                            "sourceNumber": "42"}])
        comment = make_comment(40, 42, "trusted", "@kopi-claw reject this plan")
        self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertTrue(self.reject_log.exists(),
                        "reject-plan.sh should be called")
        reject_out = self.reject_log.read_text(encoding="utf-8")
        self.assertIn("gh-42-feature", reject_out)

    def test_rejection_no_matching_task_notifies(self):
        comment = make_comment(41, 999, "trusted", "@kopi-claw reject")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertFalse(self.reject_log.exists(),
                         "reject-plan.sh should not be called without a task")
        self.assertIn("no matching task", result.stdout.lower())

    # --- Feedback routing ---

    def test_feedback_appends_finding(self):
        self._write_tasks([{"id": "gh-50-bugfix", "phase": "implementing",
                            "sourceNumber": "50"}])
        comment = make_comment(50, 50, "trusted",
                               "@kopi-claw this PR needs better error handling")
        self.run_dispatch(comment + "\n", allowed_users="trusted")

        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "gh-50-bugfix")
        self.assertIn("findings", task)
        self.assertTrue(len(task["findings"]) > 0)
        self.assertIn("feedback", task["findings"][0].lower())

    def test_feedback_no_matching_task_notifies(self):
        comment = make_comment(51, 999, "trusted",
                               "@kopi-claw this PR looks odd")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertIn("no matching task", result.stdout.lower())

    def test_unauthorized_feedback_blocked(self):
        self._write_tasks([{"id": "gh-50-bugfix", "phase": "implementing",
                            "sourceNumber": "50"}])
        comment = make_comment(52, 50, "stranger",
                               "@kopi-claw suggestion: use a different approach")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")

        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "gh-50-bugfix")
        self.assertNotIn("findings", task,
                         "unauthorized feedback should not append findings")

    # --- Question / Other routing ---

    def test_question_notifies_only(self):
        comment = make_comment(60, 100, "anyone",
                               "@kopi-claw is this working?")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertFalse(self.dispatch_log.exists())
        self.assertFalse(self.approve_log.exists())
        self.assertFalse(self.reject_log.exists())
        self.assertIn("question", result.stdout.lower())

    def test_other_notifies_only(self):
        comment = make_comment(70, 100, "anyone",
                               "@kopi-claw hello world")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertFalse(self.dispatch_log.exists())
        self.assertIn("unclassified", result.stdout.lower())

    # --- Bot self-skip ---

    def test_bot_self_comment_skipped(self):
        comment = make_comment(80, 100, "kopi-claw",
                               "@kopi-claw fix tests")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")

        self.assertFalse(self.dispatch_log.exists(),
                         "bot should not dispatch its own comments")
        self.assertIn("skipping self-comment", result.stdout.lower())

    # --- Multiple users in allowed list ---

    def test_comma_separated_allowed_users(self):
        comment = make_comment(90, 100, "alice", "@kopi-claw fix tests")
        self.run_dispatch(comment + "\n", allowed_users="bob, alice, charlie")

        self.assertTrue(self.dispatch_log.exists(),
                        "alice should be authorized in comma-separated list")

    # --- Malformed input handling ---

    def test_malformed_comment_payload_is_skipped_and_processing_continues(self):
        malformed = json.dumps(
            {
                "type": "comment",
                "commentId": 999,
                "number": 100,
                "body": "@kopi-claw fix this",
            }
        )
        valid = make_comment(91, 100, "trusted", "@kopi-claw fix tests")
        result = self.run_dispatch(
            malformed + "\n" + valid + "\n", allowed_users="trusted"
        )

        self.assertIn("skipping malformed comment payload", result.stdout.lower())
        self.assertTrue(self.dispatch_log.exists())
        dispatch_lines = self.dispatch_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(dispatch_lines), 1)


if __name__ == "__main__":
    unittest.main()
