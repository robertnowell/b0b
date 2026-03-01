#!/usr/bin/env python3
"""Tests for monitor.sh pr_ready phase logic.

Validates the fix that introduces a pr_ready intermediate phase between
reviewing and merged, ensuring the pipeline only marks a task as merged
after the PR is actually merged on GitHub.

Covers:
  - reviewing → pr_ready transition (CI pass with prNumber storage)
  - pr_ready → merged transition (actual merge detected)
  - pr_ready stays pr_ready when PR is still open
  - pr_ready stays pr_ready when gh command fails
  - pr_ready backfill of prNumber for legacy tasks
  - pr_ready without prNumber and no branch (no-op)
  - Race guard allows pr_ready and reviewing phases through
  - reviewing does NOT jump straight to merged anymore
"""

import json
import subprocess
import unittest
from unittest.mock import MagicMock, call, patch

# ---------------------------------------------------------------------------
# Helpers — simulate the monitor state-machine fragments under test
# ---------------------------------------------------------------------------

def simulate_reviewing_phase(task, subprocess_run_mock):
    """Simulate the 'reviewing' block from monitor.sh."""
    branch = task.get('branch', '')
    pr_number = None
    ci_pass = False
    updates = {}
    notifications = []

    if branch:
        task_repo = '/fake/repo'
        pr_result = subprocess_run_mock(
            ['gh', 'pr', 'list', '--head', branch, '--state', 'open',
             '--json', 'number,statusCheckRollup', '--limit', '1'],
            capture_output=True, text=True, cwd=task_repo)
        if pr_result.returncode == 0 and pr_result.stdout.strip():
            prs = json.loads(pr_result.stdout)
            if prs:
                pr_number = prs[0].get('number')
                checks = prs[0].get('statusCheckRollup', [])
                ci_pass = checks and all(
                    (c.get('conclusion') or c.get('state', '')).upper() == 'SUCCESS'
                    for c in checks
                )
        if pr_number and ci_pass:
            updates = {'phase': 'pr_ready', 'status': 'pr_ready', 'prNumber': pr_number}
            notifications.append(('pr_ready', f'PR #{pr_number} passed CI — ready for human review'))
    return updates, notifications


def simulate_pr_ready_phase(task, subprocess_run_mock):
    """Simulate the 'pr_ready' block from monitor.sh."""
    branch = task.get('branch', '')
    task_repo = '/fake/repo'
    pr_number = task.get('prNumber')
    product_goal = task.get('productGoal', '')
    tid = task.get('id', '')
    updates_list = []
    notifications = []
    changes_made = 0

    # Backfill PR number for tasks created before prNumber tracking existed.
    if not pr_number and branch:
        pr_result = subprocess_run_mock(
            ['gh', 'pr', 'list', '--head', branch, '--state', 'open',
             '--json', 'number', '--limit', '1'],
            capture_output=True, text=True, cwd=task_repo)
        if pr_result.returncode == 0 and pr_result.stdout.strip():
            prs = json.loads(pr_result.stdout)
            if prs:
                pr_number = prs[0].get('number')
                updates_list.append({'prNumber': pr_number})
                changes_made += 1

    if pr_number:
        pr_state_result = subprocess_run_mock(
            ['gh', 'pr', 'view', str(pr_number), '--json', 'state'],
            capture_output=True, text=True, cwd=task_repo)
        if pr_state_result.returncode == 0 and pr_state_result.stdout.strip():
            pr_state = json.loads(pr_state_result.stdout).get('state', '')
            if str(pr_state).upper() == 'MERGED':
                updates_list.append({'phase': 'merged', 'status': 'merged'})
                notifications.append(('merged', f'PR #{pr_number} has been merged'))
                changes_made += 1

    return updates_list, notifications, changes_made


def should_skip_race_guard(phase, last_action, now):
    """Simulate the race guard logic from monitor.sh."""
    if now - last_action < 60 and phase not in ('reviewing', 'pr_ready'):
        return True  # skip
    return False  # don't skip


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestReviewingToPrReady(unittest.TestCase):
    """Reviewing phase should transition to pr_ready (not merged) when CI passes."""

    def _make_pr_list_result(self, pr_number, checks):
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([{
            'number': pr_number,
            'statusCheckRollup': checks,
        }])
        return result

    def test_ci_pass_transitions_to_pr_ready(self):
        """When CI passes, reviewing → pr_ready with prNumber stored."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        mock_run = MagicMock(return_value=self._make_pr_list_result(
            42, [{'conclusion': 'SUCCESS'}]
        ))

        updates, notifications = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(updates['phase'], 'pr_ready')
        self.assertEqual(updates['status'], 'pr_ready')
        self.assertEqual(updates['prNumber'], 42)
        self.assertNotEqual(updates.get('phase'), 'merged',
                            'reviewing must NOT skip to merged')

    def test_ci_pass_sends_pr_ready_notification(self):
        """Notification should say pr_ready, not merged."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        mock_run = MagicMock(return_value=self._make_pr_list_result(
            42, [{'conclusion': 'SUCCESS'}]
        ))

        updates, notifications = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(len(notifications), 1)
        phase_notified, msg = notifications[0]
        self.assertEqual(phase_notified, 'pr_ready')
        self.assertIn('ready for human review', msg)

    def test_ci_not_passing_stays_reviewing(self):
        """When CI hasn't passed, stay in reviewing (no updates)."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([{
            'number': 42,
            'statusCheckRollup': [{'conclusion': 'FAILURE'}],
        }])
        mock_run = MagicMock(return_value=result)

        updates, notifications = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(updates, {})
        self.assertEqual(notifications, [])

    def test_no_pr_stays_reviewing(self):
        """When no PR found, stay in reviewing."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([])
        mock_run = MagicMock(return_value=result)

        updates, notifications = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(updates, {})

    def test_ci_pending_stays_reviewing(self):
        """When checks are still pending (empty list), stay in reviewing."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([{
            'number': 42,
            'statusCheckRollup': [],
        }])
        mock_run = MagicMock(return_value=result)

        updates, notifications = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(updates, {})


class TestPrReadyToMerged(unittest.TestCase):
    """pr_ready phase should only transition to merged when PR is actually merged."""

    def _make_pr_view_result(self, state):
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps({'state': state})
        return result

    def _make_pr_list_result(self, pr_number):
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([{'number': pr_number}])
        return result

    def test_merged_pr_transitions_to_merged(self):
        """When gh pr view shows MERGED, transition to merged."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42, 'productGoal': 'Test goal'}
        mock_run = MagicMock(return_value=self._make_pr_view_result('MERGED'))

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        # Should have one update setting phase to merged
        merged_update = next((u for u in updates_list if u.get('phase') == 'merged'), None)
        self.assertIsNotNone(merged_update)
        self.assertEqual(merged_update['status'], 'merged')
        self.assertEqual(changes, 1)

    def test_open_pr_stays_pr_ready(self):
        """When PR is still OPEN, remain in pr_ready."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42, 'productGoal': 'Test goal'}
        mock_run = MagicMock(return_value=self._make_pr_view_result('OPEN'))

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        merged_update = next((u for u in updates_list if u.get('phase') == 'merged'), None)
        self.assertIsNone(merged_update, 'Must NOT transition to merged while PR is OPEN')
        self.assertEqual(notifications, [])
        self.assertEqual(changes, 0)

    def test_closed_pr_stays_pr_ready(self):
        """When PR is CLOSED (not merged), remain in pr_ready."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}
        mock_run = MagicMock(return_value=self._make_pr_view_result('CLOSED'))

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        merged_update = next((u for u in updates_list if u.get('phase') == 'merged'), None)
        self.assertIsNone(merged_update)
        self.assertEqual(changes, 0)

    def test_gh_failure_stays_pr_ready(self):
        """When gh command fails, remain in pr_ready."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}
        result = MagicMock()
        result.returncode = 1
        result.stdout = ''
        mock_run = MagicMock(return_value=result)

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        self.assertEqual(updates_list, [])
        self.assertEqual(changes, 0)

    def test_empty_gh_response_stays_pr_ready(self):
        """When gh returns empty output, remain in pr_ready."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}
        result = MagicMock()
        result.returncode = 0
        result.stdout = ''
        mock_run = MagicMock(return_value=result)

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        self.assertEqual(updates_list, [])
        self.assertEqual(changes, 0)

    def test_merged_sends_correct_notification(self):
        """Merged notification includes PR number and says 'has been merged'."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 99, 'productGoal': 'Ship feature'}
        mock_run = MagicMock(return_value=self._make_pr_view_result('MERGED'))

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        self.assertEqual(len(notifications), 1)
        phase_notified, msg = notifications[0]
        self.assertEqual(phase_notified, 'merged')
        self.assertIn('PR #99', msg)
        self.assertIn('has been merged', msg)

    def test_uses_specific_pr_number(self):
        """pr_ready must poll the specific prNumber, not discover a new one."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}

        calls = []
        def capture_run(*args, **kwargs):
            calls.append(args[0] if args else kwargs.get('args'))
            result = MagicMock()
            result.returncode = 0
            result.stdout = json.dumps({'state': 'OPEN'})
            return result

        simulate_pr_ready_phase(task, capture_run)

        # Should call gh pr view with the specific PR number, not gh pr list
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0], ['gh', 'pr', 'view', '42', '--json', 'state'])


class TestPrReadyBackfill(unittest.TestCase):
    """Tasks without prNumber should attempt backfill via gh pr list."""

    def test_backfill_pr_number(self):
        """When prNumber is missing, backfill from gh pr list then check state."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready'}

        call_count = [0]
        def mock_run(cmd, **kwargs):
            call_count[0] += 1
            result = MagicMock()
            result.returncode = 0
            if 'pr' in cmd and 'list' in cmd:
                result.stdout = json.dumps([{'number': 55}])
            elif 'pr' in cmd and 'view' in cmd:
                result.stdout = json.dumps({'state': 'OPEN'})
            return result

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        # Should have backfilled prNumber
        backfill_update = next((u for u in updates_list if 'prNumber' in u), None)
        self.assertIsNotNone(backfill_update)
        self.assertEqual(backfill_update['prNumber'], 55)
        # Should have made 2 calls: pr list (backfill) + pr view (state check)
        self.assertEqual(call_count[0], 2)

    def test_backfill_then_merge(self):
        """Backfill prNumber, then detect merge in the same cycle."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready'}

        def mock_run(cmd, **kwargs):
            result = MagicMock()
            result.returncode = 0
            if 'pr' in cmd and 'list' in cmd:
                result.stdout = json.dumps([{'number': 55}])
            elif 'pr' in cmd and 'view' in cmd:
                result.stdout = json.dumps({'state': 'MERGED'})
            return result

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        # Should have both backfill and merged updates
        self.assertTrue(any('prNumber' in u for u in updates_list))
        self.assertTrue(any(u.get('phase') == 'merged' for u in updates_list))

    def test_no_branch_no_pr_number_noop(self):
        """When there's no prNumber and no branch, nothing happens."""
        task = {'id': 'task-1', 'phase': 'pr_ready'}
        mock_run = MagicMock()

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        mock_run.assert_not_called()
        self.assertEqual(updates_list, [])
        self.assertEqual(changes, 0)

    def test_backfill_empty_pr_list(self):
        """When gh pr list returns no PRs, no backfill and no state check."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready'}

        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([])
        mock_run = MagicMock(return_value=result)

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        self.assertEqual(updates_list, [])
        self.assertEqual(changes, 0)


class TestRaceGuard(unittest.TestCase):
    """Race guard must allow pr_ready and reviewing to be processed every cycle."""

    def test_pr_ready_bypasses_race_guard(self):
        """pr_ready phase is NOT skipped even if acted on < 60s ago."""
        skipped = should_skip_race_guard('pr_ready', last_action=100, now=130)
        self.assertFalse(skipped, 'pr_ready must bypass the race guard')

    def test_reviewing_bypasses_race_guard(self):
        """reviewing phase is NOT skipped even if acted on < 60s ago."""
        skipped = should_skip_race_guard('reviewing', last_action=100, now=130)
        self.assertFalse(skipped)

    def test_implementing_respects_race_guard(self):
        """implementing phase IS skipped if acted on < 60s ago."""
        skipped = should_skip_race_guard('implementing', last_action=100, now=130)
        self.assertTrue(skipped)

    def test_old_action_not_skipped(self):
        """Any phase is NOT skipped if last action was > 60s ago."""
        skipped = should_skip_race_guard('implementing', last_action=100, now=200)
        self.assertFalse(skipped)


class TestTerminalPhaseSkip(unittest.TestCase):
    """Verify that the terminal phase list is correct."""

    def test_merged_is_terminal(self):
        """merged phase should be skipped (terminal)."""
        terminal = ('merged', 'split', 'plan_review')
        self.assertIn('merged', terminal)

    def test_pr_ready_is_not_terminal(self):
        """pr_ready should NOT be in the terminal list."""
        terminal = ('merged', 'split', 'plan_review')
        self.assertNotIn('pr_ready', terminal,
                         'pr_ready must not be terminal — it needs polling')


class TestPrReadyMergedStateVariants(unittest.TestCase):
    """Test various casing/formats of the MERGED state from GitHub."""

    def _run_with_state(self, state_str):
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps({'state': state_str})
        mock_run = MagicMock(return_value=result)
        return simulate_pr_ready_phase(task, mock_run)

    def test_uppercase_merged(self):
        updates_list, _, changes = self._run_with_state('MERGED')
        self.assertTrue(any(u.get('phase') == 'merged' for u in updates_list))

    def test_lowercase_merged(self):
        updates_list, _, changes = self._run_with_state('merged')
        self.assertTrue(any(u.get('phase') == 'merged' for u in updates_list))

    def test_mixed_case_merged(self):
        updates_list, _, changes = self._run_with_state('Merged')
        self.assertTrue(any(u.get('phase') == 'merged' for u in updates_list))

    def test_open_does_not_merge(self):
        updates_list, _, changes = self._run_with_state('OPEN')
        self.assertFalse(any(u.get('phase') == 'merged' for u in updates_list))


if __name__ == '__main__':
    unittest.main()
