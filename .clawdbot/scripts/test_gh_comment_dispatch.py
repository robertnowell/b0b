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
        write_exec(
            self.scripts / "dispatch-fix.sh",
            "#!/usr/bin/env bash\nset -euo pipefail\necho \"$*\" >> \"${DISPATCH_FIX_LOG:?}\"\n",
        )

        self.dispatch_log = self.root / "dispatch.log"
        self.dispatch_fix_log = self.root / "dispatch-fix.log"
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
                     max_dispatches: str = "3",
                     extra_env: dict = None) -> subprocess.CompletedProcess:
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
                "DISPATCH_FIX_LOG": str(self.dispatch_fix_log),
                "APPROVE_LOG": str(self.approve_log),
                "REJECT_LOG": str(self.reject_log),
                "NOTIFY_LOG": str(self.notify_log),
            }
        )
        if extra_env:
            env.update(extra_env)
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


    # --- Gap 4: Branch-number matching ---

    def test_find_task_by_branch_number(self):
        """Gap 4: manually-created tasks matched by branch containing PR number."""
        self._write_tasks([{
            "id": "ios-visibility-bug",
            "phase": "reviewing",
            "branch": "fix/1652-ios-visibility",
        }])
        comment = make_comment(300, 1652, "trusted",
                               "@kopi-claw this PR needs better error handling")
        self.run_dispatch(comment + "\n", allowed_users="trusted")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "ios-visibility-bug")
        self.assertIn("findings", task)
        self.assertTrue(len(task["findings"]) > 0)

    def test_branch_number_no_partial_match(self):
        """Gap 4: branch '16590-something' should NOT match number 1659."""
        self._write_tasks([{
            "id": "unrelated-task",
            "phase": "implementing",
            "branch": "feat/16590-something",
        }])
        comment = make_comment(301, 1659, "trusted",
                               "@kopi-claw this PR has a bug")
        result = self.run_dispatch(comment + "\n", allowed_users="trusted")
        self.assertIn("no matching task", result.stdout.lower())

    def test_find_task_by_pr_number_field(self):
        """Gap 4: task with prNumber but no sourceNumber is found."""
        self._write_tasks([{
            "id": "manual-task",
            "phase": "reviewing",
            "branch": "feat/custom-branch",
            "prNumber": "1650",
        }])
        comment = make_comment(302, 1650, "trusted",
                               "@kopi-claw this PR looks odd")
        self.run_dispatch(comment + "\n", allowed_users="trusted")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "manual-task")
        self.assertIn("findings", task)

    # --- Gap 3: Bot reclassification ---

    def test_known_bot_action_request_reclassified(self):
        """Gap 3: known bot action_request becomes feedback — no new dispatch."""
        self._write_tasks([{
            "id": "gh-100-feature",
            "phase": "implementing",
            "sourceNumber": "100",
        }])
        comment = make_comment(400, 100, "kilo-code[bot]",
                               "@kopi-claw fix the error handling")
        self.run_dispatch(comment + "\n", allowed_users="trusted",
                          extra_env={"GH_COMMENT_KNOWN_BOTS": "kilo-code[bot]"})
        self.assertFalse(self.dispatch_log.exists(),
                         "bot action_request should not trigger new dispatch")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "gh-100-feature")
        self.assertTrue(any("feedback" in f.lower()
                            for f in task.get("findings", [])))

    def test_non_bot_action_request_not_reclassified(self):
        """Gap 3: human action_request is not affected by bot reclassification."""
        comment = make_comment(401, 200, "trusted",
                               "@kopi-claw fix the tests")
        self.run_dispatch(comment + "\n", allowed_users="trusted",
                          extra_env={"GH_COMMENT_KNOWN_BOTS": "kilo-code[bot]"})
        self.assertTrue(self.dispatch_log.exists(),
                        "human action_request should still dispatch")

    # --- Gap 1: Feedback spawns fix agent ---

    def test_feedback_spawns_fix_when_reviewing(self):
        """Gap 1: feedback on reviewing task spawns fix agent."""
        self._write_tasks([{
            "id": "gh-50-feature",
            "phase": "reviewing",
            "sourceNumber": "50",
        }])
        comment = make_comment(500, 50, "trusted",
                               "@kopi-claw this PR needs better error handling")
        self.run_dispatch(comment + "\n", allowed_users="trusted")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "gh-50-feature")
        self.assertTrue(len(task.get("findings", [])) > 0)
        self.assertTrue(self.dispatch_fix_log.exists(),
                        "fix agent should be spawned for reviewing task")
        fix_out = self.dispatch_fix_log.read_text(encoding="utf-8")
        self.assertIn("gh-50-feature", fix_out)

    def test_feedback_spawns_fix_when_pr_ready(self):
        """Gap 1: feedback on pr_ready task spawns fix agent."""
        self._write_tasks([{
            "id": "gh-60-feature",
            "phase": "pr_ready",
            "sourceNumber": "60",
        }])
        comment = make_comment(501, 60, "trusted",
                               "@kopi-claw this PR has a race condition")
        self.run_dispatch(comment + "\n", allowed_users="trusted")
        self.assertTrue(self.dispatch_fix_log.exists())

    def test_feedback_no_fix_when_implementing(self):
        """Gap 1: feedback on implementing task records but does not spawn fix."""
        self._write_tasks([{
            "id": "gh-70-feature",
            "phase": "implementing",
            "sourceNumber": "70",
        }])
        comment = make_comment(502, 70, "trusted",
                               "@kopi-claw this PR could use better naming")
        self.run_dispatch(comment + "\n", allowed_users="trusted")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "gh-70-feature")
        self.assertTrue(len(task.get("findings", [])) > 0)
        self.assertFalse(self.dispatch_fix_log.exists(),
                         "should not spawn fix agent during active phase")

    # --- Gap 3.5: Action request routes to existing task ---

    def test_action_request_routes_to_existing_task(self):
        """Gap 3.5: action_request on PR with existing task routes to it."""
        self._write_tasks([{
            "id": "existing-task",
            "phase": "reviewing",
            "sourceNumber": "1661",
        }])
        comment = make_comment(600, 1661, "trusted",
                               "@kopi-claw fix the merge conflicts")
        self.run_dispatch(comment + "\n", allowed_users="trusted")
        self.assertFalse(self.dispatch_log.exists(),
                         "should not create new task when existing task found")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "existing-task")
        self.assertTrue(len(task.get("findings", [])) > 0)
        self.assertTrue(self.dispatch_fix_log.exists(),
                        "should spawn fix agent for existing reviewing task")

    def test_action_request_creates_new_when_no_existing(self):
        """Gap 3.5: action_request without existing task still creates new task."""
        comment = make_comment(601, 9999, "trusted",
                               "@kopi-claw add dark mode support")
        self.run_dispatch(comment + "\n", allowed_users="trusted")
        self.assertTrue(self.dispatch_log.exists(),
                        "should dispatch new task when no existing task found")

    # --- Gap 3 + Gap 1: Bot reclassification in fixable phase ---

    def test_known_bot_reclassified_spawns_fix_when_reviewing(self):
        """Bot feedback on a reviewing task should spawn dispatch-fix.sh."""
        self._write_tasks([{
            "id": "gh-100-feature",
            "phase": "reviewing",
            "sourceNumber": "100",
        }])
        comment = make_comment(402, 100, "kilo-code[bot]",
                               "@kopi-claw fix the error handling")
        self.run_dispatch(comment + "\n", allowed_users="trusted",
                          extra_env={"GH_COMMENT_KNOWN_BOTS": "kilo-code[bot]"})
        self.assertFalse(self.dispatch_log.exists(),
                         "bot should not trigger new task dispatch")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "gh-100-feature")
        self.assertTrue(len(task.get("findings", [])) > 0)
        self.assertTrue(self.dispatch_fix_log.exists(),
                        "bot feedback on reviewing task should spawn fix agent")


if __name__ == "__main__":
    unittest.main()
