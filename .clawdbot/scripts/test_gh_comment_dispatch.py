#!/usr/bin/env python3
"""Integration-style tests for gh-comment-dispatch.sh routing and safeguards.

Covers: dispatch for any user, bot LLM evaluation gate, dispatch limits,
existing task dedup/feedback routing, plan-only detection, bot self-skip.
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
        # Bot evaluator stub — defaults to needsChanges=true
        # Tests can override via GH_BOT_EVAL_RESULT env var
        write_exec(
            self.scripts / "gh-comment-evaluate-bot.py",
            '#!/usr/bin/env python3\n'
            'import json, os, sys\n'
            'body = sys.stdin.read()\n'
            'override = os.environ.get("GH_BOT_EVAL_RESULT", "")\n'
            'if override:\n'
            '    print(override)\n'
            'else:\n'
            '    print(json.dumps({"needsChanges": True, "taskDescription": "Bot-identified fix", "reason": "Test stub"}))\n',
        )
        write_exec(
            self.scripts / "dispatch.sh",
            "#!/usr/bin/env bash\nset -euo pipefail\necho \"$*\" >> \"${DISPATCH_LOG:?}\"\n",
        )
        write_exec(
            self.scripts / "notify.sh",
            "#!/usr/bin/env bash\nnotify(){ echo \"$*\" >> \"${NOTIFY_LOG:?}\"; }\n",
        )
        write_exec(
            self.scripts / "dispatch-fix.sh",
            "#!/usr/bin/env bash\nset -euo pipefail\necho \"$*\" >> \"${DISPATCH_FIX_LOG:?}\"\n",
        )

        # Stub gh CLI — returns "open:false" for PR state queries so PRs aren't skipped
        self.gh_stub = self.root / "gh"
        write_exec(
            self.gh_stub,
            '#!/usr/bin/env bash\n'
            '# Stub gh for tests: PR state = open, reactions = noop, comments = noop\n'
            'if [[ "$*" == *"pulls/"*"--jq"* ]]; then\n'
            '  echo "open:false"\n'
            'elif [[ "$*" == *"issues/"*"--jq"* ]]; then\n'
            '  echo "open"\n'
            'elif [[ "$*" == *"reactions"* ]]; then\n'
            '  exit 0\n'
            'elif [[ "$1" == "issue" && "$2" == "comment" ]]; then\n'
            '  exit 0\n'
            'elif [[ "$1" == "api" && "$*" == *"replies"* ]]; then\n'
            '  exit 0\n'
            'else\n'
            '  exit 0\n'
            'fi\n',
        )

        self.dispatch_log = self.root / "dispatch.log"
        self.dispatch_fix_log = self.root / "dispatch-fix.log"
        self.notify_log = self.root / "notify.log"

    def tearDown(self):
        self.tempdir.cleanup()

    def _write_tasks(self, tasks: list) -> None:
        (self.state / "active-tasks.json").write_text(
            json.dumps(tasks, indent=2) + "\n", encoding="utf-8"
        )

    def run_dispatch(self, poll_output: str, max_dispatches: str = "3",
                     extra_env: dict = None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        # Put gh stub at front of PATH
        env["PATH"] = str(self.root) + ":" + env.get("PATH", "")
        env.update(
            {
                "CLAWDBOT_STATE_DIR": str(self.state),
                "GH_COMMENT_MAX_DISPATCHES": max_dispatches,
                "GH_COMMENT_DEFAULT_AGENT": "claude",
                "POLL_OUTPUT": poll_output,
                "DISPATCH_LOG": str(self.dispatch_log),
                "DISPATCH_FIX_LOG": str(self.dispatch_fix_log),
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

    # --- Any user can dispatch ---

    def test_any_user_can_dispatch(self):
        comment = make_comment(11, 321, "random-person", "@kopi-claw fix tests")
        self.run_dispatch(comment + "\n")

        self.assertTrue(self.dispatch_log.exists(),
                        "any user should be able to dispatch tasks")

    def test_dispatch_creates_task(self):
        comment = make_comment(12, 100, "someone", "@kopi-claw add dark mode")
        self.run_dispatch(comment + "\n")

        self.assertTrue(self.dispatch_log.exists())
        dispatch_out = self.dispatch_log.read_text(encoding="utf-8")
        self.assertIn("--phase planning", dispatch_out)

    # --- Bot self-skip ---

    def test_bot_self_comment_skipped(self):
        comment = make_comment(80, 100, "kopi-claw", "@kopi-claw fix tests")
        result = self.run_dispatch(comment + "\n")

        self.assertFalse(self.dispatch_log.exists(),
                         "bot should not dispatch its own comments")
        self.assertIn("skipping self-comment", result.stdout.lower())

    # --- Bot LLM evaluation gate ---

    def test_known_bot_with_changes_dispatches(self):
        """Bot comment evaluated as needing changes should dispatch a task."""
        eval_result = json.dumps({"needsChanges": True, "taskDescription": "Fix variable shadowing", "reason": "Real bug"})
        comment = make_comment(400, 100, "kilo-code[bot]",
                               "@kopi-claw found variable shadowing bug")
        self.run_dispatch(comment + "\n",
                          extra_env={"GH_COMMENT_KNOWN_BOTS": "kilo-code[bot]",
                                     "GH_BOT_EVAL_RESULT": eval_result})
        self.assertTrue(self.dispatch_log.exists(),
                        "bot comment with real changes should dispatch")

    def test_known_bot_without_changes_skipped(self):
        """Bot comment evaluated as not needing changes should be skipped."""
        eval_result = json.dumps({"needsChanges": False, "taskDescription": "", "reason": "Style-only suggestions"})
        comment = make_comment(401, 100, "kilo-code[bot]",
                               "@kopi-claw code looks fine, minor style nits")
        result = self.run_dispatch(comment + "\n",
                                   extra_env={"GH_COMMENT_KNOWN_BOTS": "kilo-code[bot]",
                                              "GH_BOT_EVAL_RESULT": eval_result})
        self.assertFalse(self.dispatch_log.exists(),
                         "bot comment with no real changes should not dispatch")
        self.assertIn("no actionable changes", result.stdout.lower())

    def test_known_bot_with_existing_task_routes_feedback(self):
        """Bot comment on PR with existing task should route as feedback."""
        self._write_tasks([{
            "id": "gh-100-feature",
            "phase": "reviewing",
            "sourceNumber": "100",
        }])
        eval_result = json.dumps({"needsChanges": True, "taskDescription": "Fix bug", "reason": "Real issue"})
        comment = make_comment(402, 100, "kilo-code[bot]",
                               "@kopi-claw fix the error handling")
        self.run_dispatch(comment + "\n",
                          extra_env={"GH_COMMENT_KNOWN_BOTS": "kilo-code[bot]",
                                     "GH_BOT_EVAL_RESULT": eval_result})
        self.assertFalse(self.dispatch_log.exists(),
                         "should route to existing task, not create new one")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "gh-100-feature")
        self.assertTrue(len(task.get("findings", [])) > 0)
        self.assertTrue(self.dispatch_fix_log.exists(),
                        "should spawn fix agent for reviewing task")

    # --- Dispatch limit ---

    def test_overflow_is_queued(self):
        c1 = make_comment(101, 500, "user1", "@kopi-claw fix tests")
        c2 = make_comment(102, 501, "user2", "@kopi-claw add logging")
        queue_file = self.state / "gh-comment-queue.jsonl"

        self.run_dispatch(c1 + "\n" + c2 + "\n", max_dispatches="1")
        first_cycle_dispatches = (self.dispatch_log.read_text(encoding="utf-8")
                                  .strip().splitlines())
        self.assertEqual(len(first_cycle_dispatches), 1)
        self.assertTrue(queue_file.exists(),
                        "overflow comments should persist to queue")

    def test_dispatch_limit_zero_queues_everything(self):
        comment = make_comment(200, 300, "someone", "@kopi-claw fix tests")
        queue_file = self.state / "gh-comment-queue.jsonl"

        self.run_dispatch(comment + "\n", max_dispatches="0")
        self.assertFalse(self.dispatch_log.exists(),
                         "nothing should be dispatched when limit is 0")
        self.assertTrue(queue_file.exists(), "comment should be queued")

    # --- Existing task dedup / feedback routing ---

    def test_existing_task_routes_as_feedback(self):
        self._write_tasks([{"id": "gh-50-bugfix", "phase": "implementing",
                            "sourceNumber": "50"}])
        comment = make_comment(50, 50, "someone",
                               "@kopi-claw this needs better error handling")
        self.run_dispatch(comment + "\n")

        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "gh-50-bugfix")
        self.assertIn("findings", task)
        self.assertTrue(len(task["findings"]) > 0)
        self.assertFalse(self.dispatch_log.exists(),
                         "should not create new task when existing task found")

    def test_existing_task_spawns_fix_when_reviewing(self):
        self._write_tasks([{
            "id": "gh-50-feature",
            "phase": "reviewing",
            "sourceNumber": "50",
        }])
        comment = make_comment(500, 50, "someone",
                               "@kopi-claw this needs better error handling")
        self.run_dispatch(comment + "\n")
        self.assertTrue(self.dispatch_fix_log.exists(),
                        "fix agent should be spawned for reviewing task")

    def test_existing_task_no_fix_when_implementing(self):
        self._write_tasks([{
            "id": "gh-70-feature",
            "phase": "implementing",
            "sourceNumber": "70",
        }])
        comment = make_comment(502, 70, "someone",
                               "@kopi-claw this could use better naming")
        self.run_dispatch(comment + "\n")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "gh-70-feature")
        self.assertTrue(len(task.get("findings", [])) > 0)
        self.assertFalse(self.dispatch_fix_log.exists(),
                         "should not spawn fix agent during active phase")

    # --- Branch-number matching ---

    def test_find_task_by_branch_number(self):
        self._write_tasks([{
            "id": "ios-visibility-bug",
            "phase": "reviewing",
            "branch": "fix/1652-ios-visibility",
        }])
        comment = make_comment(300, 1652, "someone",
                               "@kopi-claw this needs better error handling")
        self.run_dispatch(comment + "\n")
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "ios-visibility-bug")
        self.assertIn("findings", task)
        self.assertTrue(len(task["findings"]) > 0)

    def test_branch_number_no_partial_match(self):
        self._write_tasks([{
            "id": "unrelated-task",
            "phase": "implementing",
            "branch": "feat/16590-something",
        }])
        comment = make_comment(301, 1659, "someone",
                               "@kopi-claw fix this bug")
        self.run_dispatch(comment + "\n")
        # Should create a new task since no match
        self.assertTrue(self.dispatch_log.exists())

    # --- Plan only detection ---

    def test_plan_only_sets_require_review(self):
        comment = make_comment(700, 200, "someone",
                               "@kopi-claw plan only: evaluate auth refactor")
        self.run_dispatch(comment + "\n")

        self.assertTrue(self.dispatch_log.exists())
        dispatch_out = self.dispatch_log.read_text(encoding="utf-8")
        self.assertIn("--require-plan-review true", dispatch_out)

    def test_no_plan_only_defaults_false(self):
        comment = make_comment(701, 201, "someone",
                               "@kopi-claw fix the auth bug")
        self.run_dispatch(comment + "\n")

        self.assertTrue(self.dispatch_log.exists())
        dispatch_out = self.dispatch_log.read_text(encoding="utf-8")
        self.assertIn("--require-plan-review false", dispatch_out)

    # --- Malformed input handling ---

    def test_malformed_comment_payload_is_skipped(self):
        malformed = json.dumps(
            {
                "type": "comment",
                "commentId": 999,
                "number": 100,
                "body": "@kopi-claw fix this",
            }
        )
        valid = make_comment(91, 100, "someone", "@kopi-claw fix tests")
        result = self.run_dispatch(malformed + "\n" + valid + "\n")

        self.assertIn("skipping malformed comment payload", result.stdout.lower())
        self.assertTrue(self.dispatch_log.exists())
        dispatch_lines = self.dispatch_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(dispatch_lines), 1)


if __name__ == "__main__":
    unittest.main()
