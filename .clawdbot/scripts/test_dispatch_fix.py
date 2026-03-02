#!/usr/bin/env python3
"""Integration tests for dispatch-fix.sh.

Covers: arg validation, task lookup, template filling, spawn-agent invocation,
fixTarget state update, and notification.
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


class TestDispatchFix(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.scripts = self.root / "scripts"
        self.state = self.root / "state"
        self.prompts = self.root / "prompts"
        self.logs = self.state / "logs"
        self.scripts.mkdir(parents=True)
        self.state.mkdir(parents=True)
        self.prompts.mkdir(parents=True)
        self.logs.mkdir(parents=True)

        # Copy the real dispatch-fix.sh
        shutil.copy2(SCRIPT_DIR / "dispatch-fix.sh", self.scripts / "dispatch-fix.sh")

        # Write a config.sh that points to our temp dirs
        write_exec(
            self.scripts / "config.sh",
            f'#!/usr/bin/env bash\n'
            f'REPO_ROOT="{self.root}"\n'
            f'CLAWDBOT_DIR="{self.root}"\n'
            f'PROMPTS_DIR="{self.prompts}"\n'
            f'STATE_DIR="{self.state}"\n'
            f'TASKS_FILE="{self.state}/active-tasks.json"\n'
            f'LOCK_FILE="{self.state}/.tasks.lock"\n'
            f'LOG_DIR="{self.logs}"\n',
        )

        # Mock notify.sh — logs calls
        self.notify_log = self.root / "notify.log"
        write_exec(
            self.scripts / "notify.sh",
            f'#!/usr/bin/env bash\nnotify(){{ echo "$*" >> "{self.notify_log}"; }}\n',
        )

        # Mock spawn-agent.sh — logs args
        self.spawn_log = self.root / "spawn.log"
        write_exec(
            self.scripts / "spawn-agent.sh",
            f'#!/usr/bin/env bash\nset -euo pipefail\necho "$*" >> "{self.spawn_log}"\n',
        )

        # Mock fill-template.sh — outputs template with simple substitution
        write_exec(
            self.scripts / "fill-template.sh",
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            'TEMPLATE="$1"; shift\n'
            'CONTENT=$(cat "$TEMPLATE")\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  case "$1" in\n'
            '    --var) KEY="${2%%=*}"; VAL="${2#*=}"; '
            'CONTENT="${CONTENT//\\{$KEY\\}/$VAL}"; shift 2 ;;\n'
            '    *) shift ;;\n'
            '  esac\n'
            'done\n'
            'echo "$CONTENT"\n',
        )

        # Copy fix-feedback.md template
        shutil.copy2(
            SCRIPT_DIR.parent / "prompts" / "fix-feedback.md",
            self.prompts / "fix-feedback.md",
        )

        # Default task
        self.default_task = {
            "id": "test-task-1",
            "branch": "fix/test-branch",
            "agent": "claude",
            "phase": "reviewing",
            "description": "Fix the widget",
            "productGoal": "Better widgets",
        }

    def tearDown(self):
        self.tempdir.cleanup()

    def _write_tasks(self, tasks: list) -> None:
        (self.state / "active-tasks.json").write_text(
            json.dumps(tasks, indent=2) + "\n", encoding="utf-8"
        )

    def _run(self, args: list, expect_fail: bool = False) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["CLAWDBOT_STATE_DIR"] = str(self.state)
        result = subprocess.run(
            ["bash", str(self.scripts / "dispatch-fix.sh")] + args,
            capture_output=True,
            text=True,
            env=env,
        )
        if not expect_fail:
            self.assertEqual(result.returncode, 0,
                             f"dispatch-fix.sh failed:\nstdout: {result.stdout}\nstderr: {result.stderr}")
        return result

    # --- Arg validation ---

    def test_missing_task_id_fails(self):
        self._write_tasks([self.default_task])
        result = self._run(["--feedback", "fix this"], expect_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--task-id is required", result.stderr)

    def test_missing_feedback_fails(self):
        self._write_tasks([self.default_task])
        result = self._run(["--task-id", "test-task-1"], expect_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--feedback is required", result.stderr)

    def test_unknown_arg_fails(self):
        self._write_tasks([self.default_task])
        result = self._run(["--task-id", "x", "--feedback", "y", "--bogus"], expect_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown argument", result.stderr)

    # --- Task lookup ---

    def test_task_not_found_fails(self):
        self._write_tasks([self.default_task])
        result = self._run(
            ["--task-id", "nonexistent", "--feedback", "fix this"],
            expect_fail=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not found", result.stderr.lower())

    # --- Happy path ---

    def test_happy_path_spawns_agent_and_updates_state(self):
        self._write_tasks([self.default_task])
        result = self._run([
            "--task-id", "test-task-1",
            "--feedback", "Please fix the merge conflicts",
        ])

        self.assertIn("Dispatch-fix complete", result.stdout)
        self.assertIn("test-task-1", result.stdout)

        # spawn-agent.sh was called with correct args
        spawn_out = self.spawn_log.read_text(encoding="utf-8")
        self.assertIn("test-task-1", spawn_out)
        self.assertIn("fix/test-branch", spawn_out)
        self.assertIn("claude", spawn_out)
        self.assertIn("--phase fixing", spawn_out)

        # fixTarget updated to reviewing
        tasks = json.loads(
            (self.state / "active-tasks.json").read_text(encoding="utf-8")
        )
        task = next(t for t in tasks if t["id"] == "test-task-1")
        self.assertEqual(task["fixTarget"], "reviewing")

        # Notification sent
        notify_out = self.notify_log.read_text(encoding="utf-8")
        self.assertIn("test-task-1", notify_out)
        self.assertIn("fixing", notify_out)

    def test_filled_prompt_contains_feedback(self):
        self._write_tasks([self.default_task])
        self._run([
            "--task-id", "test-task-1",
            "--feedback", "Resolve merge conflicts with main",
        ])

        # Find the generated prompt file
        prompt_files = list(self.logs.glob("prompt-test-task-1-fixing-*.md"))
        self.assertTrue(len(prompt_files) > 0, "prompt file should be created")
        content = prompt_files[0].read_text(encoding="utf-8")
        self.assertIn("Resolve merge conflicts with main", content)
        self.assertIn("Fix the widget", content)

    def test_agent_override_in_spawn(self):
        """--agent codex should pass codex to spawn-agent.sh."""
        self._write_tasks([self.default_task])
        result = self._run([
            "--task-id", "test-task-1",
            "--feedback", "fix it",
            "--agent", "codex",
        ])

        spawn_out = self.spawn_log.read_text(encoding="utf-8")
        self.assertIn("codex", spawn_out)
        self.assertIn("Agent:  codex", result.stdout)


if __name__ == "__main__":
    unittest.main()
